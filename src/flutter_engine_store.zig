//! Flutter Engine 下载、缓存和物化模块。
//!
//! 工作流程：
//!
//!   flutter --version --machine
//!             ↓
//!       engineRevision
//!             ↓
//!   GitHub Release:
//!   engine-<revision>/metadata.json
//!             ↓
//!   build/fushell_flutter_engine/<arch>/<revision>/
//!             ↓
//!   校验 SHA256
//!             ↓
//!   copy() 到最终 Flutter bundle
//!
//! 默认仓库：
//!
//!   https://github.com/fushell-poj/fushell-engine-builds
//!
//! 可以通过环境变量覆盖：
//!
//!   FUSHELL_ENGINE_REPOSITORY=https://github.com/example/engine-builds
//!
//! 本模块不负责 Flutter bundle 本身的构建，只负责获得与当前
//! Flutter CLI 匹配的 libflutter_engine.so。

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const cache_lock = @import("cache_lock.zig");

/// 默认的 Flutter Engine 二进制仓库。
pub const default_repository =
    "https://github.com/fushell-poj/fushell-engine-builds";

/// 用于覆盖 Flutter Engine 二进制仓库地址的环境变量。
pub const repository_env = "FUSHELL_ENGINE_REPOSITORY";

/// 相对于 Flutter 项目根目录的默认 Engine 缓存目录。
pub const default_cache_root = "build/fushell_flutter_engine";

/// metadata.json 最大允许大小。
///
/// metadata 正常情况下只有几 KB；设置 1 MiB 上限可以避免错误服务器
/// 或损坏文件导致无界内存分配。
const max_metadata_size = 1024 * 1024;

/// HTTP 响应头缓冲区。
const http_header_buffer_size = 16 * 1024;

/// 下载读缓冲区。
const download_buffer_size = 64 * 1024;

/// Flutter Engine 架构。
///
/// 名称与 metadata.json 中 `artifacts` 的 key 保持一致。
pub const Arch = enum {
    x86_64,
    aarch64,

    /// 返回 metadata 和缓存目录使用的架构名称。
    pub fn name(self: Arch) []const u8 {
        return @tagName(self);
    }
};

/// Flutter Engine 运行模式。
pub const Mode = enum {
    debug,
    profile,
    release,
};

/// 返回当前 Fushell 可支持的本机 CPU 架构。
pub fn nativeArch() !Arch {
    return switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => error.UnsupportedArchitecture,
    };
}

/// 从 `flutter --version --machine` 获取的信息。
///
/// 字符串由调用方 allocator 拥有，使用完成后必须调用 `deinit()`。
pub const FlutterInfo = struct {
    flutter_version: []u8,
    engine_revision: []u8,
    dart_version: []u8,

    /// 释放 FlutterInfo 拥有的所有字符串。
    pub fn deinit(self: *FlutterInfo, allocator: Allocator) void {
        allocator.free(self.flutter_version);
        allocator.free(self.engine_revision);
        allocator.free(self.dart_version);
        self.* = undefined;
    }
};

/// 一个 Engine Release 的 metadata。
///
/// 结构与 fushell-engine-builds 生成的 metadata.json 一致。
pub const Metadata = struct {
    schema: u32,
    engine_revision: []const u8,
    flutter_version: []const u8,
    dart_version: []const u8,
    artifacts: Artifacts,
};

/// metadata.json 中所有架构的产物。
pub const Artifacts = struct {
    x86_64: ?ModeArtifacts = null,
    aarch64: ?ModeArtifacts = null,
};

/// 单个架构下 debug/profile/release 三种 Engine。
pub const ModeArtifacts = struct {
    debug: Artifact,
    profile: Artifact,
    release: Artifact,
};

/// metadata.json 中单个 `.so` 产物的信息。
pub const Artifact = struct {
    file: []const u8,
    sha256: []const u8,
};

/// 下载过程中报告的对象类型。
pub const DownloadKind = enum {
    metadata,
    engine,
};

/// 下载进度事件。
///
/// `total == null` 表示 HTTP 服务端没有返回 Content-Length。
pub const DownloadProgress = struct {
    kind: DownloadKind,
    downloaded: u64,
    total: ?u64,
};

/// 下载进度回调。
///
/// callback 可能从 `io.concurrent()` 创建的后台任务中调用，因此后续
/// 如果 UI 需要跨线程更新，建议 callback 只负责向线程安全队列投递事件。
pub const ProgressSink = struct {
    context: ?*anyopaque = null,

    callback: ?*const fn (
        context: ?*anyopaque,
        progress: DownloadProgress,
    ) void = null,

    /// 报告一次下载进度。
    pub fn report(
        self: ProgressSink,
        progress: DownloadProgress,
    ) void {
        if (self.callback) |callback| {
            callback(self.context, progress);
        }
    }
};

/// 下载操作的结果。
///
/// SHA256 is computed by the backend: streamed for HTTP, read after curl exits.
pub const DownloadResult = struct {
    bytes: u64,
    sha256: [32]u8,
};

/// 抽象下载后端。
///
/// 默认使用 curl；测试注入 fake fetcher 或本地子进程，无需外部网络。
pub const Fetcher = struct {
    context: ?*anyopaque = null,

    fetch_fn: *const fn (
        context: ?*anyopaque,
        allocator: Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
        destination_dir: Io.Dir,
        url: []const u8,
        destination_path: []const u8,
        kind: DownloadKind,
        progress: ProgressSink,
    ) anyerror!DownloadResult = curlFetchToFile,

    /// 返回默认的 curl 下载后端。
    pub fn curl() Fetcher {
        return .{
            .fetch_fn = curlFetchToFile,
        };
    }

    /// 保留纯 Zig HTTP 后端，主要用于以后 std.http proxy 修复后切回来。
    pub fn http() Fetcher {
        return .{
            .fetch_fn = httpFetchToFile,
        };
    }

    pub fn fetchToFile(
        self: Fetcher,
        allocator: Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
        destination_dir: Io.Dir,
        url: []const u8,
        destination_path: []const u8,
        kind: DownloadKind,
        progress: ProgressSink,
    ) !DownloadResult {
        return self.fetch_fn(
            self.context,
            allocator,
            io,
            environ,
            destination_dir,
            url,
            destination_path,
            kind,
            progress,
        );
    }
};

/// `Store.ensure()` 返回的 Engine 信息。
///
/// `path` 是相对于 Store 项目根目录的缓存路径。
/// 所有字符串均由调用方 allocator 拥有。
pub const ResolvedEngine = struct {
    path: []u8,

    engine_revision: []u8,
    flutter_version: []u8,
    dart_version: []u8,

    sha256: []u8,

    /// true 表示本次没有重新下载 Engine 文件。
    from_cache: bool,

    /// 释放返回结果中的所有分配。
    pub fn deinit(
        self: *ResolvedEngine,
        allocator: Allocator,
    ) void {
        allocator.free(self.path);
        allocator.free(self.engine_revision);
        allocator.free(self.flutter_version);
        allocator.free(self.dart_version);
        allocator.free(self.sha256);
        self.* = undefined;
    }
};

/// Read-only cache state used by diagnostics; it contains no owned pointers.
pub const CacheInspection = struct {
    pub const State = enum { missing, unlocked, busy, origin_mismatch, invalid_metadata, inspected };
    pub const ArtifactState = enum { unchecked, missing, verified, hash_mismatch, invalid_file, unreadable };
    state: State,
    modes: [3]ArtifactState = .{ .unchecked, .unchecked, .unchecked },

    pub fn verifiedCount(self: CacheInspection) usize {
        var count: usize = 0;
        for (self.modes) |mode| if (mode == .verified) {
            count += 1;
        };
        return count;
    }
};

/// Flutter Engine 本地缓存。
///
/// Store 不拥有 `repository` 和 `flutter` 指向的内存，这两个值必须至少
/// 存活到 Store 使用结束。
pub const Store = struct {
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    /// Flutter 项目根目录。正常情况下为 cwd；测试可以传临时目录。
    root_dir: Io.Dir,

    repository: []const u8,
    cache_root: []const u8,

    flutter: *const FlutterInfo,

    fetcher: Fetcher,

    /// 使用当前项目目录创建 Store。
    ///
    /// 仓库地址优先读取：
    ///
    ///   FUSHELL_ENGINE_REPOSITORY
    ///
    /// 未设置时使用 `default_repository`。
    pub fn init(
        allocator: Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
        flutter: *const FlutterInfo,
    ) Store {
        const repository =
            environ.get(repository_env) orelse default_repository;

        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .root_dir = Io.Dir.cwd(),
            .repository = repository,
            .cache_root = default_cache_root,
            .flutter = flutter,
            .fetcher = .curl(),
        };
    }

    /// 创建使用指定目录、仓库和 Fetcher 的 Store。
    ///
    /// 主要用于测试，也方便以后实现镜像仓库或特殊下载后端。
    pub fn initWith(
        allocator: Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
        root_dir: Io.Dir,
        repository: []const u8,
        cache_root: []const u8,
        flutter: *const FlutterInfo,
        fetcher: Fetcher,
    ) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .root_dir = root_dir,
            .repository = repository,
            .cache_root = cache_root,
            .flutter = flutter,
            .fetcher = fetcher,
        };
    }

    /// Inspect only: no directories, locks, downloads, repairs or origin writes.
    /// A shared non-blocking lock avoids racing cooperative cache publication.
    pub fn inspectCache(self: *const Store, arch: Arch) !CacheInspection {
        const path = try self.engineDir(arch);
        defer self.allocator.free(path);
        const dir = self.root_dir.openDir(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return .{ .state = .missing },
            else => return err,
        };
        defer dir.close(self.io);
        const lock_stat = dir.statFile(self.io, ".lock", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return .{ .state = .unlocked },
            else => return err,
        };
        if (lock_stat.kind != .file) return .{ .state = .unlocked };
        const lock = try dir.openFile(self.io, ".lock", .{});
        defer lock.close(self.io);
        if (!try lock.tryLock(self.io, .shared)) return .{ .state = .busy };
        defer lock.unlock(self.io);
        if (!try regularFile(dir, self.io, ".repository") or !try regularFile(dir, self.io, "metadata.json")) return .{ .state = .invalid_metadata };
        const origin = try dir.readFileAlloc(self.io, ".repository", self.allocator, .limited(8192));
        defer self.allocator.free(origin);
        if (!std.mem.eql(u8, origin, std.mem.trimEnd(u8, self.repository, "/"))) return .{ .state = .origin_mismatch };
        const bytes = try dir.readFileAlloc(self.io, "metadata.json", self.allocator, .limited(max_metadata_size));
        defer self.allocator.free(bytes);
        var parsed = parseReleaseMetadata(self.allocator, bytes, self.flutter.engine_revision, arch) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{ .state = .invalid_metadata },
        };
        defer parsed.deinit();
        var result: CacheInspection = .{ .state = .inspected };
        for ([_]Mode{ .debug, .profile, .release }, 0..) |mode, index| {
            const artifact = try selectArtifact(&parsed.value, arch, mode);
            const stat = dir.statFile(self.io, artifact.file, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => {
                    result.modes[index] = .missing;
                    continue;
                },
                error.Canceled => return err,
                else => {
                    result.modes[index] = .unreadable;
                    continue;
                },
            };
            if (stat.kind != .file or stat.size > 8 * 1024 * 1024 * 1024) {
                result.modes[index] = .invalid_file;
                continue;
            }
            const actual = sha256File(dir, self.io, artifact.file) catch |err| switch (err) {
                error.Canceled => return err,
                else => {
                    result.modes[index] = .unreadable;
                    continue;
                },
            };
            var expected: [32]u8 = undefined;
            try parseSha256Hex(artifact.sha256, &expected);
            result.modes[index] = if (std.mem.eql(u8, &actual, &expected)) .verified else .hash_mismatch;
        }
        return result;
    }

    /// 确保指定架构和模式的 Flutter Engine 已存在于本地缓存。
    ///
    /// 缓存目录：
    ///
    ///   build/fushell_flutter_engine/<arch>/<engine-sha>/
    ///
    /// 流程：
    ///
    /// 1. 获取并验证 metadata.json。
    /// 2. 根据 arch/mode 查找 Artifact。
    /// 3. 如果缓存 `.so` 存在，先进行 SHA256 校验。
    /// 4. 缓存损坏时删除并重新下载。
    /// 5. 新下载写入 `.part`。
    /// 6. 下载过程中流式计算 SHA256。
    /// 7. hash 正确后才将文件放入正式缓存位置。
    ///
    /// 本函数本身采用普通阻塞式代码，但所有 I/O 都通过 `std.Io`。
    /// 调用方可以使用 `io.concurrent(Store.ensure, ...)` 异步执行。
    pub fn ensure(
        self: *Store,
        arch: Arch,
        mode: Mode,
        progress: ProgressSink,
    ) !ResolvedEngine {
        const cache_dir = try self.engineDir(arch);
        defer self.allocator.free(cache_dir);

        try self.root_dir.createDirPath(
            self.io,
            cache_dir,
        );
        var lock = try self.acquireLock(cache_dir);
        defer lock.deinit();
        // Metadata from a different configured repository is not trusted.
        const repository_path = try Io.Dir.path.join(self.allocator, &.{ cache_dir, ".repository" });
        defer self.allocator.free(repository_path);
        const old_repository = self.root_dir.readFileAlloc(self.io, repository_path, self.allocator, .limited(8192)) catch |err| switch (err) {
            error.FileNotFound, error.StreamTooLong => null,
            else => return err,
        };
        defer if (old_repository) |bytes| self.allocator.free(bytes);

        const metadata_path = try Io.Dir.path.join(
            self.allocator,
            &.{
                cache_dir,
                "metadata.json",
            },
        );
        defer self.allocator.free(metadata_path);

        const repository = std.mem.trimEnd(u8, self.repository, "/");
        if (old_repository == null or !std.mem.eql(u8, old_repository.?, repository)) {
            try deleteIfExists(self.root_dir, self.io, metadata_path);
        }
        var parsed = try self.ensureMetadata(
            metadata_path,
            progress,
        );
        defer parsed.deinit();
        var origin = try self.root_dir.createFileAtomic(self.io, repository_path, .{ .replace = true });
        defer origin.deinit(self.io);
        try origin.file.writeStreamingAll(self.io, repository);
        try origin.replace(self.io);

        const metadata = &parsed.value;

        const artifact =
            try selectArtifact(metadata, arch, mode);

        try validateArtifact(artifact);

        var expected_digest: [32]u8 = undefined;
        try parseSha256Hex(
            artifact.sha256,
            &expected_digest,
        );

        const engine_path = try Io.Dir.path.join(
            self.allocator,
            &.{
                cache_dir,
                artifact.file,
            },
        );
        errdefer self.allocator.free(engine_path);

        if (try fileExists(
            self.root_dir,
            self.io,
            engine_path,
        )) {
            const actual = try sha256File(
                self.root_dir,
                self.io,
                engine_path,
            );

            if (std.mem.eql(
                u8,
                &actual,
                &expected_digest,
            )) {
                return try self.makeResolved(
                    engine_path,
                    metadata,
                    artifact,
                    true,
                );
            }

            // 缓存文件存在但内容损坏。
            try deleteIfExists(
                self.root_dir,
                self.io,
                engine_path,
            );
        }

        const temp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.part",
            .{engine_path},
        );
        defer self.allocator.free(temp_path);
        defer cleanupTemporary(self.root_dir, self.io, temp_path);

        // 清理上一次中断留下的 .part。
        try deleteIfExists(self.root_dir, self.io, temp_path);

        const url = try self.artifactUrl(
            artifact.file,
        );
        defer self.allocator.free(url);

        const download_result =
            self.fetcher.fetchToFile(
                self.allocator,
                self.io,
                self.environ,
                self.root_dir,
                url,
                temp_path,
                .engine,
                progress,
            ) catch |err| {
                deleteIfExists(self.root_dir, self.io, temp_path) catch {};
                return err;
            };

        if (!std.mem.eql(
            u8,
            &download_result.sha256,
            &expected_digest,
        )) {
            try deleteIfExists(
                self.root_dir,
                self.io,
                temp_path,
            );

            return error.EngineHashMismatch;
        }

        // 校验成功后发布缓存文件。
        // Both paths live on the same filesystem; publish only verified bytes.
        try self.root_dir.rename(temp_path, self.root_dir, engine_path, self.io);

        try deleteIfExists(
            self.root_dir,
            self.io,
            temp_path,
        );

        return try self.makeResolved(
            engine_path,
            metadata,
            artifact,
            false,
        );
    }

    /// 使用当前 CPU 架构确保 Engine 已缓存。
    pub fn ensureNative(
        self: *Store,
        mode: Mode,
        progress: ProgressSink,
    ) !ResolvedEngine {
        return self.ensure(
            try nativeArch(),
            mode,
            progress,
        );
    }

    /// 将已缓存的 Engine 拷贝到最终 Flutter bundle 目录。
    ///
    /// destination_dir 是目录，而不是完整文件名。
    ///
    /// 例如：
    ///
    ///   try store.copy(
    ///       .x86_64,
    ///       .release,
    ///       "dist/linux/x64/release",
    ///   );
    ///
    /// 最终生成：
    ///
    ///   dist/linux/x64/release/libflutter_engine.so
    ///
    /// copy() 不会访问网络。如果 Engine 尚未缓存，应先调用 ensure()。
    ///
    /// 返回的路径由调用方 allocator 拥有。
    pub fn copy(
        self: *Store,
        arch: Arch,
        mode: Mode,
        destination_dir: []const u8,
    ) ![]u8 {
        const cache_dir = try self.engineDir(arch);
        defer self.allocator.free(cache_dir);
        var lock = try self.acquireLock(cache_dir);
        defer lock.deinit();
        const origin_path = try Io.Dir.path.join(self.allocator, &.{ cache_dir, ".repository" });
        defer self.allocator.free(origin_path);
        const origin = self.root_dir.readFileAlloc(self.io, origin_path, self.allocator, .limited(8192)) catch |err| switch (err) {
            error.FileNotFound => return error.EngineNotCached,
            else => return err,
        };
        defer self.allocator.free(origin);
        if (!std.mem.eql(u8, origin, std.mem.trimEnd(u8, self.repository, "/"))) return error.RepositoryMismatch;

        const metadata_path = try Io.Dir.path.join(
            self.allocator,
            &.{
                cache_dir,
                "metadata.json",
            },
        );
        defer self.allocator.free(metadata_path);

        var parsed = try loadMetadata(
            self.allocator,
            self.io,
            self.root_dir,
            metadata_path,
        );
        defer parsed.deinit();

        try validateMetadata(
            &parsed.value,
            self.flutter.engine_revision,
        );

        const artifact =
            try selectArtifact(
                &parsed.value,
                arch,
                mode,
            );

        try validateArtifact(artifact);

        var expected_digest: [32]u8 = undefined;
        try parseSha256Hex(
            artifact.sha256,
            &expected_digest,
        );

        const source = try Io.Dir.path.join(
            self.allocator,
            &.{
                cache_dir,
                artifact.file,
            },
        );
        defer self.allocator.free(source);

        if (!try fileExists(
            self.root_dir,
            self.io,
            source,
        )) {
            return error.EngineNotCached;
        }

        const destination = try Io.Dir.path.join(
            self.allocator,
            &.{
                destination_dir,
                "libflutter_engine.so",
            },
        );
        errdefer self.allocator.free(destination);

        // Copy and hash in one pass; a corrupt source never replaces a good destination.
        const input = try self.root_dir.openFile(self.io, source, .{});
        defer input.close(self.io);
        var output = try self.root_dir.createFileAtomic(self.io, destination, .{ .replace = true, .make_path = true });
        defer output.deinit(self.io);
        var read_buffer: [download_buffer_size]u8 = undefined;
        var reader = input.reader(self.io, &read_buffer);
        var chunk: [download_buffer_size]u8 = undefined;
        var hasher = Sha256.init(.{});
        while (true) {
            const n = try reader.interface.readSliceShort(&chunk);
            if (n == 0) break;
            try output.file.writeStreamingAll(self.io, chunk[0..n]);
            hasher.update(chunk[0..n]);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        if (!std.mem.eql(u8, &digest, &expected_digest)) return error.EngineHashMismatch;
        try output.replace(self.io);

        return destination;
    }

    /// 使用当前 CPU 架构将 Engine 拷贝到最终目录。
    pub fn copyNative(
        self: *Store,
        mode: Mode,
        destination_dir: []const u8,
    ) ![]u8 {
        return self.copy(
            try nativeArch(),
            mode,
            destination_dir,
        );
    }

    /// 返回指定架构和当前 Engine revision 对应的缓存目录。
    fn engineDir(
        self: *const Store,
        arch: Arch,
    ) ![]u8 {
        if (!isEngineRevision(self.flutter.engine_revision)) return error.InvalidEngineRevision;
        return Io.Dir.path.join(
            self.allocator,
            &.{
                self.cache_root,
                arch.name(),
                self.flutter.engine_revision,
            },
        );
    }

    /// Serialize readers/publication and all modes sharing one metadata file.
    fn acquireLock(self: *const Store, dir: []const u8) !cache_lock.Lock {
        const path = try Io.Dir.path.join(self.allocator, &.{ dir, ".lock" });
        defer self.allocator.free(path);
        return cache_lock.Lock.acquire(self.io, self.root_dir, path);
    }

    /// 确保 metadata.json 存在且与当前 Flutter Engine revision 匹配。
    fn ensureMetadata(
        self: *Store,
        metadata_path: []const u8,
        progress: ProgressSink,
    ) !std.json.Parsed(Metadata) {
        if (try fileExists(
            self.root_dir,
            self.io,
            metadata_path,
        )) {
            if (loadMetadata(
                self.allocator,
                self.io,
                self.root_dir,
                metadata_path,
            )) |parsed_value| {
                var parsed = parsed_value;

                if (validateMetadata(
                    &parsed.value,
                    self.flutter.engine_revision,
                )) |_| {
                    return parsed;
                } else |_| {
                    parsed.deinit();
                }
            } else |err| switch (err) {
                error.InvalidMetadata, error.StreamTooLong, error.FileNotFound => {},
                else => return err,
            }

            // 本地 metadata 损坏或 revision 不一致。
            try deleteIfExists(
                self.root_dir,
                self.io,
                metadata_path,
            );
        }

        const temp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.part",
            .{metadata_path},
        );
        defer self.allocator.free(temp_path);
        defer cleanupTemporary(self.root_dir, self.io, temp_path);

        try deleteIfExists(
            self.root_dir,
            self.io,
            temp_path,
        );

        const url = try self.metadataUrl();
        defer self.allocator.free(url);

        _ = self.fetcher.fetchToFile(
            self.allocator,
            self.io,
            self.environ,
            self.root_dir,
            url,
            temp_path,
            .metadata,
            progress,
        ) catch |err| {
            deleteIfExists(
                self.root_dir,
                self.io,
                temp_path,
            ) catch {};

            return err;
        };

        var parsed = loadMetadata(
            self.allocator,
            self.io,
            self.root_dir,
            temp_path,
        ) catch |err| {
            try deleteIfExists(
                self.root_dir,
                self.io,
                temp_path,
            );
            return err;
        };

        errdefer parsed.deinit();
        validateMetadata(
            &parsed.value,
            self.flutter.engine_revision,
        ) catch |err| {
            try deleteIfExists(
                self.root_dir,
                self.io,
                temp_path,
            );

            return err;
        };

        // Both paths live on the same filesystem; publish only verified bytes.
        try self.root_dir.rename(temp_path, self.root_dir, metadata_path, self.io);

        try deleteIfExists(
            self.root_dir,
            self.io,
            temp_path,
        );

        return parsed;
    }

    /// 构建 metadata.json 的 GitHub Release URL。
    fn metadataUrl(
        self: *const Store,
    ) ![]u8 {
        const repository =
            std.mem.trimEnd(
                u8,
                self.repository,
                "/",
            );

        return std.fmt.allocPrint(
            self.allocator,
            "{s}/releases/download/engine-{s}/metadata.json",
            .{
                repository,
                self.flutter.engine_revision,
            },
        );
    }

    /// 构建单个 Release asset 的 URL。
    fn artifactUrl(
        self: *const Store,
        filename: []const u8,
    ) ![]u8 {
        const repository =
            std.mem.trimEnd(
                u8,
                self.repository,
                "/",
            );

        return std.fmt.allocPrint(
            self.allocator,
            "{s}/releases/download/engine-{s}/{s}",
            .{
                repository,
                self.flutter.engine_revision,
                filename,
            },
        );
    }
    fn makeResolved(
        self: *const Store,
        engine_path: []u8,
        metadata: *const Metadata,
        artifact: Artifact,
        from_cache: bool,
    ) !ResolvedEngine {
        // engine_path remains caller-owned until this function succeeds.

        const engine_revision =
            try self.allocator.dupe(
                u8,
                metadata.engine_revision,
            );
        errdefer self.allocator.free(engine_revision);

        const flutter_version =
            try self.allocator.dupe(
                u8,
                metadata.flutter_version,
            );
        errdefer self.allocator.free(flutter_version);

        const dart_version =
            try self.allocator.dupe(
                u8,
                metadata.dart_version,
            );
        errdefer self.allocator.free(dart_version);

        const sha256 =
            try self.allocator.dupe(
                u8,
                artifact.sha256,
            );
        errdefer self.allocator.free(sha256);

        return .{
            .path = engine_path,
            .engine_revision = engine_revision,
            .flutter_version = flutter_version,
            .dart_version = dart_version,
            .sha256 = sha256,
            .from_cache = from_cache,
        };
    }
};

/// 执行 `flutter --version --machine` 并返回 Flutter/Engine/Dart 信息.
///
/// flutter 必须能够通过当前 PATH 找到。
///
/// stdout 被解析成 JSON；不会解析面向人类的 `flutter --version` 文本。
pub fn queryFlutterInfo(
    allocator: Allocator,
    io: Io,
) !FlutterInfo {
    const result = try std.process.run(
        allocator,
        io,
        .{
            .argv = &.{
                "flutter",
                "--version",
                "--machine",
            },
        },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0)
                return error.FlutterCommandFailed;
        },
        else => return error.FlutterCommandFailed,
    }

    return parseFlutterInfoJson(
        allocator,
        result.stdout,
    );
}

/// 解析 `flutter --version --machine` 输出。
///
/// 独立为函数主要是为了可以在单元测试中不启动 Flutter 进程。
pub fn parseFlutterInfoJson(
    allocator: Allocator,
    json: []const u8,
) !FlutterInfo {
    const RawInfo = struct {
        frameworkVersion: ?[]const u8 = null,
        flutterVersion: ?[]const u8 = null,

        engineRevision: []const u8,
        dartSdkVersion: []const u8,
    };

    const parsed = try std.json.parseFromSlice(
        RawInfo,
        allocator,
        json,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        },
    );
    defer parsed.deinit();

    const flutter_version =
        parsed.value.flutterVersion orelse
        parsed.value.frameworkVersion orelse
        return error.MissingFlutterVersion;

    if (flutter_version.len == 0)
        return error.MissingFlutterVersion;

    if (!isEngineRevision(
        parsed.value.engineRevision,
    )) {
        return error.InvalidEngineRevision;
    }

    if (parsed.value.dartSdkVersion.len == 0)
        return error.MissingDartVersion;

    // Release tag 使用小写 revision，因此这里统一规范化。
    const engine_revision =
        try allocator.alloc(
            u8,
            parsed.value.engineRevision.len,
        );
    errdefer allocator.free(engine_revision);

    for (
        parsed.value.engineRevision,
        engine_revision,
    ) |source, *destination| {
        destination.* = std.ascii.toLower(source);
    }

    const flutter_copy =
        try allocator.dupe(
            u8,
            flutter_version,
        );
    errdefer allocator.free(flutter_copy);

    const dart_copy =
        try allocator.dupe(
            u8,
            parsed.value.dartSdkVersion,
        );
    errdefer allocator.free(dart_copy);

    return .{
        .flutter_version = flutter_copy,
        .engine_revision = engine_revision,
        .dart_version = dart_copy,
    };
}

/// 检查字符串是否是完整 40 位 Git SHA。
fn isEngineRevision(
    revision: []const u8,
) bool {
    if (revision.len != 40)
        return false;

    for (revision) |c| {
        if (!std.ascii.isHex(c))
            return false;
    }

    return true;
}

/// 从 metadata 中选择指定架构和模式对应的产物。
fn selectArtifact(
    metadata: *const Metadata,
    arch: Arch,
    mode: Mode,
) !Artifact {
    const modes = switch (arch) {
        .x86_64 => metadata.artifacts.x86_64,
        .aarch64 => metadata.artifacts.aarch64,
    } orelse return error.UnsupportedArchitecture;

    return switch (mode) {
        .debug => modes.debug,
        .profile => modes.profile,
        .release => modes.release,
    };
}

/// 校验 metadata 的协议版本和 Engine revision。
fn validateMetadata(
    metadata: *const Metadata,
    expected_revision: []const u8,
) !void {
    if (metadata.schema != 1)
        return error.UnsupportedMetadataSchema;

    if (!isEngineRevision(metadata.engine_revision))
        return error.InvalidEngineRevision;

    if (!std.mem.eql(
        u8,
        metadata.engine_revision,
        expected_revision,
    )) {
        return error.EngineRevisionMismatch;
    }

    if (metadata.flutter_version.len == 0)
        return error.InvalidMetadata;

    if (metadata.dart_version.len == 0)
        return error.InvalidMetadata;
}

/// 校验 metadata 中单个 artifact。
///
/// 文件名必须是简单 basename，禁止 `/`、`\`、`.` 和 `..`，避免恶意或
/// 错误 metadata 通过路径穿越写出缓存目录。
fn validateArtifact(
    artifact: Artifact,
) !void {
    if (artifact.file.len == 0)
        return error.InvalidArtifactFilename;

    if (std.mem.eql(u8, artifact.file, ".") or
        std.mem.eql(u8, artifact.file, ".."))
    {
        return error.InvalidArtifactFilename;
    }

    for (artifact.file) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-')
            return error.InvalidArtifactFilename;
    }

    var digest: [32]u8 = undefined;
    try parseSha256Hex(
        artifact.sha256,
        &digest,
    );
}
/// 读取并解析 metadata.json。
fn loadMetadata(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
) !std.json.Parsed(Metadata) {
    const bytes = try dir.readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_metadata_size),
    );
    defer allocator.free(bytes);

    return parseMetadataBytes(allocator, bytes);
}

fn parseMetadataBytes(allocator: Allocator, bytes: []const u8) !std.json.Parsed(Metadata) {
    if (bytes.len > max_metadata_size) return error.MetadataTooLarge;
    return std.json.parseFromSlice(
        Metadata,
        allocator,
        bytes,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidMetadata,
    };
}

/// Parse the same schema/filename/hash rules used by ensure/copy. The owned
/// parse remains alive while callers inspect artifact names; no borrowed JSON.
pub fn parseReleaseMetadata(allocator: Allocator, bytes: []const u8, expected_revision: []const u8, arch: Arch) !std.json.Parsed(Metadata) {
    var parsed = try parseMetadataBytes(allocator, bytes);
    errdefer parsed.deinit();
    try validateMetadata(&parsed.value, expected_revision);
    inline for (.{ Mode.debug, .profile, .release }) |mode|
        try validateArtifact(try selectArtifact(&parsed.value, arch, mode));
    return parsed;
}

fn regularFile(dir: Io.Dir, io: Io, path: []const u8) !bool {
    const stat = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .file;
}

/// 标准 HTTP 下载器。
///
/// 下载直接写入文件，同时计算 SHA256 和报告下载进度。
fn httpFetchToFile(
    _: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    destination_dir: Io.Dir,
    url: []const u8,
    destination_path: []const u8,
    kind: DownloadKind,
    progress: ProgressSink,
) !DownloadResult {
    const uri = try std.Uri.parse(url);

    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    defer proxy_arena.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    try client.initDefaultProxies(proxy_arena.allocator(), environ);

    var request = try client.request(
        .GET,
        uri,
        .{ .headers = .{ .accept_encoding = .{ .override = "identity" } } },
    );
    defer request.deinit();

    try request.sendBodiless();

    var header_buffer: [http_header_buffer_size]u8 = undefined;

    var response =
        try request.receiveHead(
            &header_buffer,
        );

    if (response.head.status != .ok)
        return error.HttpStatusError;

    var file = try destination_dir.createFile(
        io,
        destination_path,
        .{},
    );
    defer file.close(io);

    const total = response.head.content_length;

    progress.report(.{
        .kind = kind,
        .downloaded = 0,
        .total = total,
    });

    var response_buffer: [download_buffer_size]u8 = undefined;

    const reader =
        response.reader(
            &response_buffer,
        );

    var chunk: [download_buffer_size]u8 = undefined;

    var hasher = Sha256.init(.{});

    var downloaded: u64 = 0;

    while (true) {
        const n =
            try reader.readSliceShort(
                &chunk,
            );

        if (n == 0)
            break;

        const data = chunk[0..n];
        if (kind == .metadata and downloaded + n > max_metadata_size) return error.MetadataTooLarge;

        try file.writeStreamingAll(
            io,
            data,
        );

        hasher.update(data);

        downloaded += n;

        progress.report(.{
            .kind = kind,
            .downloaded = downloaded,
            .total = total,
        });
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    return .{
        .bytes = downloaded,
        .sha256 = digest,
    };
}

/// Download with curl's proxy/TLS support. The supplied environment and directory
/// are authoritative. curl renders its own progress; the callback receives only
/// start/end events (not a fabricated intermediate percentage).
fn curlFetchToFile(
    _: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    destination_dir: Io.Dir,
    url: []const u8,
    destination_path: []const u8,
    kind: DownloadKind,
    progress: ProgressSink,
) !DownloadResult {
    return curlFetchWithExecutable("curl", allocator, io, environ, destination_dir, url, destination_path, kind, progress);
}

/// Injectable executable used by the offline subprocess contract tests.
fn curlFetchWithExecutable(
    executable: []const u8,
    _: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    destination_dir: Io.Dir,
    url: []const u8,
    destination_path: []const u8,
    kind: DownloadKind,
    progress: ProgressSink,
) !DownloadResult {
    const uri = try std.Uri.parse(url);
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.UnsupportedUriScheme;
    const argv: []const []const u8 = &.{
        executable,                               "--disable",      "--globoff",                                        "--fail",                                                "--location",
        "--proto",                                "=http,https",    "--proto-redir",                                    "=http,https",                                           "--retry",
        "3",                                      "--retry-delay",  "1",                                                "--connect-timeout",                                     "15",
        "--speed-limit",                          "1",              "--speed-time",                                     "60",                                                    "--max-time",
        if (kind == .metadata) "120" else "1800", "--max-filesize", if (kind == .metadata) "1048576" else "8589934592", if (kind == .metadata) "--silent" else "--progress-bar", "--show-error",
        "--output",                               destination_path, "--url",                                            url,
    };
    progress.report(.{ .kind = kind, .downloaded = 0, .total = null });
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = destination_dir },
        .environ_map = environ,
        .stdin = .ignore,
    });
    // Also terminate and reap on cancellation/wait failure. No-op after wait.
    defer child.kill(io);
    const term = try @import("child_wait.zig").wait(&child, io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("[engine] curl failed with exit status {d}\n", .{code});
            return error.DownloadFailed;
        },
        else => return error.DownloadFailed,
    }
    const stat = try destination_dir.statFile(io, destination_path, .{});
    if (stat.kind != .file) return error.InvalidDownloadedFile;
    if (kind == .metadata and stat.size > max_metadata_size) return error.MetadataTooLarge;
    const digest = try sha256File(destination_dir, io, destination_path);
    progress.report(.{ .kind = kind, .downloaded = stat.size, .total = stat.size });
    return .{ .bytes = stat.size, .sha256 = digest };
}

/// 计算已有文件的 SHA256。
fn sha256File(
    dir: Io.Dir,
    io: Io,
    path: []const u8,
) ![32]u8 {
    var file = try dir.openFile(
        io,
        path,
        .{},
    );
    defer file.close(io);

    var reader_buffer: [download_buffer_size]u8 = undefined;

    var reader =
        file.reader(
            io,
            &reader_buffer,
        );

    var chunk: [download_buffer_size]u8 = undefined;

    var hasher = Sha256.init(.{});

    while (true) {
        try io.checkCancel();
        const n = reader.interface.readSliceShort(&chunk) catch |err| {
            if (err == error.ReadFailed) return reader.err.?;
            return err;
        };

        if (n == 0)
            break;

        hasher.update(
            chunk[0..n],
        );
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    return digest;
}

/// 将 64 字符 SHA256 hex 字符串转换成 32 字节 digest。
fn parseSha256Hex(
    value: []const u8,
    output: *[32]u8,
) !void {
    if (value.len != 64)
        return error.InvalidArtifactHash;

    for (0..32) |index| {
        const high =
            hexNibble(
                value[index * 2],
            ) orelse
            return error.InvalidArtifactHash;

        const low =
            hexNibble(
                value[index * 2 + 1],
            ) orelse
            return error.InvalidArtifactHash;

        output[index] =
            (@as(u8, high) << 4) |
            @as(u8, low);
    }
}

/// 将十六进制字符转换为 nibble。
fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// 将 SHA256 digest 写成小写 64 字符 hex。
fn digestToHex(
    digest: [32]u8,
) [64]u8 {
    const alphabet =
        "0123456789abcdef";

    var output: [64]u8 = undefined;

    for (digest, 0..) |byte, index| {
        output[index * 2] =
            alphabet[byte >> 4];

        output[index * 2 + 1] =
            alphabet[byte & 0x0f];
    }

    return output;
}

/// 判断文件是否存在。
fn fileExists(
    dir: Io.Dir,
    io: Io,
    path: []const u8,
) !bool {
    _ = dir.statFile(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
}

/// Finish our own temporary-file cleanup even while the task is canceled.
fn cleanupTemporary(dir: Io.Dir, io: Io, path: []const u8) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    dir.deleteFile(io, path) catch {};
}

/// 删除文件，如果不存在则视为成功。
fn deleteIfExists(
    dir: Io.Dir,
    io: Io,
    path: []const u8,
) !void {
    dir.deleteFile(
        io,
        path,
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const test_revision =
    "42d3d75a56efe1a2e9902f52dc8006099c45d937";

const test_engine_bytes =
    "fake flutter engine binary for fushell tests\n";

fn sha256Of(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;

    Sha256.hash(
        data,
        &digest,
        .{},
    );

    return digest;
}

fn createTestMetadata(allocator: Allocator, revision: []const u8, expected_engine: []const u8) ![]u8 {
    const digest =
        sha256Of(expected_engine);

    const hash =
        digestToHex(digest);

    return std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "schema": 1,
        \\  "engine_revision": "{s}",
        \\  "flutter_version": "3.41.9",
        \\  "dart_version": "3.11.5",
        \\  "artifacts": {{
        \\    "x86_64": {{
        \\      "debug": {{
        \\        "file": "libflutter_engine-linux-x64-debug.so",
        \\        "sha256": "{s}"
        \\      }},
        \\      "profile": {{
        \\        "file": "libflutter_engine-linux-x64-profile.so",
        \\        "sha256": "{s}"
        \\      }},
        \\      "release": {{
        \\        "file": "libflutter_engine-linux-x64-release.so",
        \\        "sha256": "{s}"
        \\      }}
        \\    }}
        \\  }}
        \\}}
    ,
        .{
            revision,
            hash[0..],
            hash[0..],
            hash[0..],
        },
    );
}

const FakeFetcher = struct {
    metadata: []const u8,
    engine: []const u8,

    metadata_fetches: usize = 0,
    engine_fetches: usize = 0,

    fn fetch(
        context: ?*anyopaque,
        _: Allocator,
        io: Io,
        _: *const std.process.Environ.Map,
        destination_dir: Io.Dir,
        url: []const u8,
        destination_path: []const u8,
        kind: DownloadKind,
        progress: ProgressSink,
    ) !DownloadResult {
        const self: *FakeFetcher =
            @ptrCast(
                @alignCast(
                    context.?,
                ),
            );

        const data = switch (kind) {
            .metadata => blk: {
                self.metadata_fetches += 1;

                try std.testing.expect(
                    std.mem.endsWith(
                        u8,
                        url,
                        "/metadata.json",
                    ),
                );

                break :blk self.metadata;
            },

            .engine => blk: {
                self.engine_fetches += 1;
                break :blk self.engine;
            },
        };

        progress.report(.{
            .kind = kind,
            .downloaded = 0,
            .total = data.len,
        });

        try destination_dir.writeFile(
            io,
            .{
                .sub_path = destination_path,
                .data = data,
            },
        );

        progress.report(.{
            .kind = kind,
            .downloaded = data.len,
            .total = data.len,
        });

        return .{
            .bytes = data.len,
            .sha256 = sha256Of(data),
        };
    }

    fn asFetcher(
        self: *FakeFetcher,
    ) Fetcher {
        return .{
            .context = self,
            .fetch_fn = fetch,
        };
    }
};

fn testFlutterInfo() FlutterInfo {
    return .{
        .flutter_version = @constCast("3.41.9"),
        .engine_revision = @constCast(test_revision),
        .dart_version = @constCast("3.11.5"),
    };
}

test "parseFlutterInfoJson parses machine output" {
    const allocator =
        std.testing.allocator;

    const json =
        \\{
        \\  "frameworkVersion": "3.41.9",
        \\  "engineRevision": "42d3d75a56efe1a2e9902f52dc8006099c45d937",
        \\  "dartSdkVersion": "3.11.5",
        \\  "channel": "stable",
        \\  "unknownFutureField": true
        \\}
    ;

    var info =
        try parseFlutterInfoJson(
            allocator,
            json,
        );
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings(
        "3.41.9",
        info.flutter_version,
    );

    try std.testing.expectEqualStrings(
        test_revision,
        info.engine_revision,
    );

    try std.testing.expectEqualStrings(
        "3.11.5",
        info.dart_version,
    );
}

test "parseFlutterInfoJson accepts flutterVersion" {
    const allocator =
        std.testing.allocator;

    const json =
        \\{
        \\  "flutterVersion": "3.41.9",
        \\  "engineRevision": "42D3D75A56EFE1A2E9902F52DC8006099C45D937",
        \\  "dartSdkVersion": "3.11.5"
        \\}
    ;

    var info =
        try parseFlutterInfoJson(
            allocator,
            json,
        );
    defer info.deinit(allocator);

    // revision 必须被规范化为小写。
    try std.testing.expectEqualStrings(
        test_revision,
        info.engine_revision,
    );
}

test "parseFlutterInfoJson rejects malformed revision" {
    const allocator =
        std.testing.allocator;

    const json =
        \\{
        \\  "frameworkVersion": "3.41.9",
        \\  "engineRevision": "1234",
        \\  "dartSdkVersion": "3.11.5"
        \\}
    ;

    try std.testing.expectError(
        error.InvalidEngineRevision,
        parseFlutterInfoJson(
            allocator,
            json,
        ),
    );
}

test "sha256 hex round trip" {
    const digest =
        sha256Of(
            "hello fushell",
        );

    const hex =
        digestToHex(digest);

    var decoded: [32]u8 = undefined;

    try parseSha256Hex(
        &hex,
        &decoded,
    );

    try std.testing.expectEqualSlices(
        u8,
        &digest,
        &decoded,
    );
}

test "invalid sha256 is rejected" {
    var digest: [32]u8 = undefined;

    try std.testing.expectError(
        error.InvalidArtifactHash,
        parseSha256Hex(
            "1234",
            &digest,
        ),
    );

    const invalid =
        "gggggggggggggggggggggggggggggggg" ++
        "gggggggggggggggggggggggggggggggg";

    try std.testing.expectError(
        error.InvalidArtifactHash,
        parseSha256Hex(
            invalid,
            &digest,
        ),
    );
}

test "ensure downloads metadata and engine" {
    const allocator =
        std.testing.allocator;
    const io =
        std.testing.io;

    var tmp =
        std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const metadata =
        try createTestMetadata(
            allocator,
            test_revision,
            test_engine_bytes,
        );
    defer allocator.free(metadata);

    var fake = FakeFetcher{
        .metadata = metadata,
        .engine = test_engine_bytes,
    };

    var flutter =
        testFlutterInfo();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var store = Store.initWith(
        allocator,
        io,
        &environ,
        tmp.dir,
        "https://example.invalid/fushell-engine-builds",
        "build/fushell_flutter_engine",
        &flutter,
        fake.asFetcher(),
    );

    var engine =
        try store.ensure(
            .x86_64,
            .release,
            .{},
        );
    defer engine.deinit(allocator);

    try std.testing.expect(
        !engine.from_cache,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        fake.metadata_fetches,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        fake.engine_fetches,
    );

    const stored =
        try tmp.dir.readFileAlloc(
            io,
            engine.path,
            allocator,
            .limited(1024),
        );
    defer allocator.free(stored);

    try std.testing.expectEqualStrings(
        test_engine_bytes,
        stored,
    );
}

test "ensure uses valid cached engine" {
    const allocator =
        std.testing.allocator;
    const io =
        std.testing.io;

    var tmp =
        std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const metadata =
        try createTestMetadata(
            allocator,
            test_revision,
            test_engine_bytes,
        );
    defer allocator.free(metadata);

    var fake = FakeFetcher{
        .metadata = metadata,
        .engine = test_engine_bytes,
    };

    var flutter =
        testFlutterInfo();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var store = Store.initWith(
        allocator,
        io,
        &environ,
        tmp.dir,
        "https://example.invalid/repo",
        "build/fushell_flutter_engine",
        &flutter,
        fake.asFetcher(),
    );

    {
        var first =
            try store.ensure(
                .x86_64,
                .release,
                .{},
            );
        defer first.deinit(allocator);

        try std.testing.expect(
            !first.from_cache,
        );
    }

    {
        var second =
            try store.ensure(
                .x86_64,
                .release,
                .{},
            );
        defer second.deinit(allocator);

        try std.testing.expect(
            second.from_cache,
        );
    }

    try std.testing.expectEqual(
        @as(usize, 1),
        fake.metadata_fetches,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        fake.engine_fetches,
    );
}

test "corrupted cache is downloaded again" {
    const allocator =
        std.testing.allocator;
    const io =
        std.testing.io;

    var tmp =
        std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const metadata =
        try createTestMetadata(
            allocator,
            test_revision,
            test_engine_bytes,
        );
    defer allocator.free(metadata);

    var fake = FakeFetcher{
        .metadata = metadata,
        .engine = test_engine_bytes,
    };

    var flutter =
        testFlutterInfo();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var store = Store.initWith(
        allocator,
        io,
        &environ,
        tmp.dir,
        "https://example.invalid/repo",
        "build/fushell_flutter_engine",
        &flutter,
        fake.asFetcher(),
    );

    var first =
        try store.ensure(
            .x86_64,
            .release,
            .{},
        );
    defer first.deinit(allocator);

    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = first.path,
            .data = "corrupted",
        },
    );

    var second =
        try store.ensure(
            .x86_64,
            .release,
            .{},
        );
    defer second.deinit(allocator);

    try std.testing.expect(
        !second.from_cache,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        fake.engine_fetches,
    );

    const restored =
        try tmp.dir.readFileAlloc(
            io,
            second.path,
            allocator,
            .limited(1024),
        );
    defer allocator.free(restored);

    try std.testing.expectEqualStrings(
        test_engine_bytes,
        restored,
    );
}

test "download with wrong hash is rejected" {
    const allocator =
        std.testing.allocator;
    const io =
        std.testing.io;

    var tmp =
        std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const metadata =
        try createTestMetadata(
            allocator,
            test_revision,
            test_engine_bytes,
        );
    defer allocator.free(metadata);

    var fake = FakeFetcher{
        .metadata = metadata,

        // metadata hash 对应 test_engine_bytes，
        // 但实际下载内容不同。
        .engine = "malicious or corrupted engine",
    };

    var flutter =
        testFlutterInfo();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var store = Store.initWith(
        allocator,
        io,
        &environ,
        tmp.dir,
        "https://example.invalid/repo",
        "build/fushell_flutter_engine",
        &flutter,
        fake.asFetcher(),
    );

    try std.testing.expectError(
        error.EngineHashMismatch,
        store.ensure(
            .x86_64,
            .release,
            .{},
        ),
    );

    const final_path =
        "build/fushell_flutter_engine/" ++
        "x86_64/" ++
        test_revision ++
        "/libflutter_engine-linux-x64-release.so";

    try std.testing.expect(
        !try fileExists(
            tmp.dir,
            io,
            final_path,
        ),
    );
}

test "metadata revision mismatch is rejected" {
    const allocator =
        std.testing.allocator;
    const io =
        std.testing.io;

    var tmp =
        std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wrong_revision =
        "0000000000000000000000000000000000000000";

    const metadata =
        try createTestMetadata(
            allocator,
            wrong_revision,
            test_engine_bytes,
        );
    defer allocator.free(metadata);

    var fake = FakeFetcher{
        .metadata = metadata,
        .engine = test_engine_bytes,
    };

    var flutter =
        testFlutterInfo();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var store = Store.initWith(
        allocator,
        io,
        &environ,
        tmp.dir,
        "https://example.invalid/repo",
        "build/fushell_flutter_engine",
        &flutter,
        fake.asFetcher(),
    );

    try std.testing.expectError(
        error.EngineRevisionMismatch,
        store.ensure(
            .x86_64,
            .release,
            .{},
        ),
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        fake.engine_fetches,
    );
}

test "unsupported architecture is rejected" {
    const allocator =
        std.testing.allocator;
    const io =
        std.testing.io;

    var tmp =
        std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const metadata =
        try createTestMetadata(
            allocator,
            test_revision,
            test_engine_bytes,
        );
    defer allocator.free(metadata);

    var fake = FakeFetcher{
        .metadata = metadata,
        .engine = test_engine_bytes,
    };

    var flutter =
        testFlutterInfo();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var store = Store.initWith(
        allocator,
        io,
        &environ,
        tmp.dir,
        "https://example.invalid/repo",
        "build/fushell_flutter_engine",
        &flutter,
        fake.asFetcher(),
    );

    try std.testing.expectError(
        error.UnsupportedArchitecture,
        store.ensure(
            .aarch64,
            .release,
            .{},
        ),
    );
}

test "copy materializes cached engine as libflutter_engine.so" {
    const allocator =
        std.testing.allocator;
    const io =
        std.testing.io;

    var tmp =
        std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const metadata =
        try createTestMetadata(
            allocator,
            test_revision,
            test_engine_bytes,
        );
    defer allocator.free(metadata);

    var fake = FakeFetcher{
        .metadata = metadata,
        .engine = test_engine_bytes,
    };

    var flutter =
        testFlutterInfo();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var store = Store.initWith(
        allocator,
        io,
        &environ,
        tmp.dir,
        "https://example.invalid/repo",
        "build/fushell_flutter_engine",
        &flutter,
        fake.asFetcher(),
    );

    var engine =
        try store.ensure(
            .x86_64,
            .release,
            .{},
        );
    defer engine.deinit(allocator);

    const destination =
        try store.copy(
            .x86_64,
            .release,
            "dist/linux/x64/release",
        );
    defer allocator.free(destination);

    try std.testing.expectEqualStrings(
        "dist/linux/x64/release/libflutter_engine.so",
        destination,
    );

    const copied =
        try tmp.dir.readFileAlloc(
            io,
            destination,
            allocator,
            .limited(1024),
        );
    defer allocator.free(copied);

    try std.testing.expectEqualStrings(
        test_engine_bytes,
        copied,
    );
}

test "copy rejects corrupted cache" {
    const allocator =
        std.testing.allocator;
    const io =
        std.testing.io;

    var tmp =
        std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const metadata =
        try createTestMetadata(
            allocator,
            test_revision,
            test_engine_bytes,
        );
    defer allocator.free(metadata);

    var fake = FakeFetcher{
        .metadata = metadata,
        .engine = test_engine_bytes,
    };

    var flutter =
        testFlutterInfo();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var store = Store.initWith(
        allocator,
        io,
        &environ,
        tmp.dir,
        "https://example.invalid/repo",
        "build/fushell_flutter_engine",
        &flutter,
        fake.asFetcher(),
    );

    var engine =
        try store.ensure(
            .x86_64,
            .release,
            .{},
        );
    defer engine.deinit(allocator);

    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = engine.path,
            .data = "corrupted after download",
        },
    );

    try std.testing.expectError(
        error.EngineHashMismatch,
        store.copy(
            .x86_64,
            .release,
            "dist",
        ),
    );
}

/// Verify that failed result construction never releases its borrowed path.
fn testResolvedAllocationFailure(allocator: Allocator) !void {
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var info = testFlutterInfo();
    var store = Store.init(allocator, std.testing.io, &env, &info);
    const path = try allocator.dupe(u8, "engine.so");
    errdefer allocator.free(path);
    const digest = digestToHex(sha256Of(test_engine_bytes));
    const artifact: Artifact = .{ .file = "engine.so", .sha256 = &digest };
    const modes: ModeArtifacts = .{ .debug = artifact, .profile = artifact, .release = artifact };
    const metadata: Metadata = .{
        .schema = 1,
        .engine_revision = test_revision,
        .flutter_version = "test",
        .dart_version = "test",
        .artifacts = .{ .x86_64 = modes },
    };
    var resolved = try store.makeResolved(path, &metadata, artifact, false);
    resolved.deinit(allocator);
}

test "resolved result ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testResolvedAllocationFailure, .{});
}

test "curl backend honors directory and explicit environment without network" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("FUSHELL_TEST_BODY", "proxy-environment-reached-child");
    const script = try tmp.dir.createFile(io, "fake-curl", .{ .permissions = .executable_file });
    try script.writeStreamingAll(io, "#!/bin/sh\nset -eu\nwhile [ $# -gt 0 ]; do\nif [ \"$1\" = --output ]; then shift; output=$1; fi\nshift\ndone\nprintf %s \"$FUSHELL_TEST_BODY\" > \"$output\"\n");
    script.close(io);
    const exe = try tmp.dir.realPathFileAlloc(io, "fake-curl", gpa);
    defer gpa.free(exe);
    const result = try curlFetchWithExecutable(exe, gpa, io, &env, tmp.dir, "https://example.invalid/test", "result.part", .metadata, .{});
    try std.testing.expectEqual(@as(u64, 31), result.bytes);
    const content = try tmp.dir.readFileAlloc(io, "result.part", gpa, .limited(100));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("proxy-environment-reached-child", content);
    try std.testing.expectEqualSlices(u8, &sha256Of(content), &result.sha256);
}

test "artifact filenames reject URL syntax and traversal" {
    const digest = digestToHex(sha256Of("test"));
    for ([_][]const u8{ "../engine.so", "a/b", "a\\b", "?name", "%2F", "a#fragment", "", ".", "..", "a\x00b" }) |name| {
        try std.testing.expectError(error.InvalidArtifactFilename, validateArtifact(.{ .file = name, .sha256 = &digest }));
    }
    try validateArtifact(.{ .file = "libflutter_engine-linux-x64-release.so", .sha256 = &digest });
}

test "repository overrides invalidate metadata rather than reuse another origin" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const metadata = try createTestMetadata(gpa, test_revision, test_engine_bytes);
    defer gpa.free(metadata);
    var fake: FakeFetcher = .{ .metadata = metadata, .engine = test_engine_bytes };
    var flutter = testFlutterInfo();
    var store = Store.initWith(gpa, io, &env, tmp.dir, "https://first.invalid/repo", default_cache_root, &flutter, fake.asFetcher());
    var first = try store.ensure(.x86_64, .release, .{});
    defer first.deinit(gpa);
    store.repository = "https://second.invalid/repo";
    try std.testing.expectError(error.RepositoryMismatch, store.copy(.x86_64, .release, "out"));
    var second = try store.ensure(.x86_64, .release, .{});
    defer second.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), fake.metadata_fetches);
    // Identical bytes with the new origin's matching digest may be reused。
    try std.testing.expect(second.from_cache);
}

test "concurrent ensure calls share one download under a persistent inode lock" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const metadata = try createTestMetadata(gpa, test_revision, test_engine_bytes);
    defer gpa.free(metadata);
    var fake: FakeFetcher = .{ .metadata = metadata, .engine = test_engine_bytes };
    var flutter = testFlutterInfo();
    var store = Store.initWith(gpa, io, &env, tmp.dir, default_repository, default_cache_root, &flutter, fake.asFetcher());
    const Task = struct {
        fn run(s: *Store) !void {
            var result = try s.ensure(.x86_64, .release, .{});
            defer result.deinit(s.allocator);
        }
    };
    var first = try io.concurrent(Task.run, .{&store});
    defer first.cancel(io) catch {};
    var second = try io.concurrent(Task.run, .{&store});
    defer second.cancel(io) catch {};
    try first.await(io);
    try second.await(io);
    try std.testing.expectEqual(@as(usize, 1), fake.metadata_fetches);
    try std.testing.expectEqual(@as(usize, 1), fake.engine_fetches);
}

test "inspection is non-mutating, detects partial/corrupt cache and respects locks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var flutter = testFlutterInfo();
    const metadata = try createTestMetadata(a, test_revision, test_engine_bytes);
    defer a.free(metadata);
    var fake: FakeFetcher = .{ .metadata = metadata, .engine = test_engine_bytes };
    var store = Store.initWith(a, io, &env, tmp.dir, "https://example.invalid/engines", "cache", &flutter, fake.asFetcher());
    try std.testing.expectEqual(CacheInspection.State.missing, (try store.inspectCache(.x86_64)).state);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "cache", .{}));
    var resolved = try store.ensure(.x86_64, .debug, .{});
    defer resolved.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), (try store.inspectCache(.x86_64)).verifiedCount());
    for ([_]Mode{ .profile, .release }) |mode| {
        var result = try store.ensure(.x86_64, mode, .{});
        result.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), (try store.inspectCache(.x86_64)).verifiedCount());
    try tmp.dir.writeFile(io, .{ .sub_path = resolved.path, .data = "corrupt" });
    try std.testing.expectEqual(CacheInspection.ArtifactState.hash_mismatch, (try store.inspectCache(.x86_64)).modes[0]);
    const retained = try tmp.dir.readFileAlloc(io, resolved.path, a, .limited(100));
    defer a.free(retained);
    try std.testing.expectEqualStrings("corrupt", retained);
    const dir_path = try store.engineDir(.x86_64);
    defer a.free(dir_path);
    var lock = try store.acquireLock(dir_path);
    try std.testing.expectEqual(CacheInspection.State.busy, (try store.inspectCache(.x86_64)).state);
    lock.deinit();
    store.repository = "https://other.invalid/engines";
    try std.testing.expectEqual(CacheInspection.State.origin_mismatch, (try store.inspectCache(.x86_64)).state);
}
