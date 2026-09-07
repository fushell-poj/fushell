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
/// SHA256 是下载过程中直接计算得到的，不需要下载完成后再次读取整个文件。
pub const DownloadResult = struct {
    bytes: u64,
    sha256: [32]u8,
};

/// 抽象下载后端。
///
/// 正常运行使用 HTTP 实现；测试可以注入 fake fetcher，避免访问网络。
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
        root_dir: Io.Dir,
        repository: []const u8,
        cache_root: []const u8,
        flutter: *const FlutterInfo,
        fetcher: Fetcher,
    ) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .root_dir = root_dir,
            .repository = repository,
            .cache_root = cache_root,
            .flutter = flutter,
            .fetcher = fetcher,
        };
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

        const metadata_path = try Io.Dir.path.join(
            self.allocator,
            &.{
                cache_dir,
                "metadata.json",
            },
        );
        defer self.allocator.free(metadata_path);

        var parsed = try self.ensureMetadata(
            metadata_path,
            progress,
        );
        defer parsed.deinit();

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

        // updateFile 使用原子目标替换语义，并自动创建目标父目录。
        _ = try self.root_dir.updateFile(
            self.io,
            temp_path,
            self.root_dir,
            engine_path,
            .{},
        );

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

        const actual_digest = try sha256File(
            self.root_dir,
            self.io,
            source,
        );

        if (!std.mem.eql(
            u8,
            &actual_digest,
            &expected_digest,
        )) {
            return error.EngineHashMismatch;
        }

        const destination = try Io.Dir.path.join(
            self.allocator,
            &.{
                destination_dir,
                "libflutter_engine.so",
            },
        );
        errdefer self.allocator.free(destination);

        _ = try self.root_dir.updateFile(
            self.io,
            source,
            self.root_dir,
            destination,
            .{},
        );

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
        return Io.Dir.path.join(
            self.allocator,
            &.{
                self.cache_root,
                arch.name(),
                self.flutter.engine_revision,
            },
        );
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
            } else |_| {}

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

        validateMetadata(
            &parsed.value,
            self.flutter.engine_revision,
        ) catch |err| {
            parsed.deinit();

            try deleteIfExists(
                self.root_dir,
                self.io,
                temp_path,
            );

            return err;
        };

        _ = try self.root_dir.updateFile(
            self.io,
            temp_path,
            self.root_dir,
            metadata_path,
            .{},
        );

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
        errdefer self.allocator.free(engine_path);

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
        if (c == '/' or c == '\\')
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

    return std.json.parseFromSlice(
        Metadata,
        allocator,
        bytes,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        },
    );
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
        .{},
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

/// 使用系统 curl 下载文件。
///
/// curl 负责：
/// - HTTP/HTTPS
/// - GitHub Release redirect
/// - HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY
/// - TLS/CA
/// - 网络失败重试
/// - Engine 文件的实时终端进度条
///
/// Store 仍然负责：
/// - `.part` 临时文件
/// - metadata 验证
/// - SHA256
/// - hash 不匹配时删除损坏文件
/// - cache hit 检查
///
/// 注意：正式 Store 使用当前 Flutter 项目 cwd 作为 root_dir，因此
/// `destination_path` 可以直接作为 curl 的输出路径。测试仍然使用 FakeFetcher，
/// 不会调用这个函数。
fn curlFetchToFile(
    _: ?*anyopaque,
    _: Allocator,
    io: Io,
    _: *const std.process.Environ.Map,
    destination_dir: Io.Dir,
    url: []const u8,
    destination_path: []const u8,
    kind: DownloadKind,
    _: ProgressSink,
) !DownloadResult {
    // 当前 curl backend 面向正式 Store（cwd）。
    // 保留参数是为了继续满足 Fetcher 的通用接口。
    _ = destination_dir;

    // curl 默认会读取：
    //
    //   HTTP_PROXY / http_proxy
    //   HTTPS_PROXY / https_proxy
    //   ALL_PROXY / all_proxy
    //   NO_PROXY / no_proxy
    //
    // std.process.spawn 默认继承父进程环境，因此不需要手工传递代理变量。

    const argv: []const []const u8 = switch (kind) {
        .metadata => &.{
            "curl",

            // HTTP >= 400 返回非 0。
            "--fail",

            // GitHub Release 会跳转到实际对象存储。
            "--location",

            // 瞬时网络错误重试。
            "--retry",
            "3",

            "--retry-delay",
            "1",

            "--connect-timeout",
            "15",

            // metadata 很小，不显示进度。
            "--silent",
            "--show-error",

            "--output",
            destination_path,

            url,
        },

        .engine => &.{
            "curl",

            "--fail",
            "--location",

            "--retry",
            "3",

            "--retry-delay",
            "1",

            "--connect-timeout",
            "15",

            // 让 stderr 直接显示 curl 自带的单行进度条。
            "--progress-bar",
            "--show-error",

            "--output",
            destination_path,

            url,
        },
    };

    if (kind == .engine) {
        std.debug.print(
            "[engine] downloading from {s}\n",
            .{url},
        );
    }

    // spawn 而不是 process.run：
    //
    // run() 会捕获 stderr，curl 的进度条就看不到了；
    // spawn() 默认 stdin/stdout/stderr 都继承当前终端。
    var child = std.process.spawn(
        io,
        .{
            .argv = argv,
        },
    ) catch |err| {
        std.debug.print(
            "[engine] unable to start curl: {s}\n",
            .{@errorName(err)},
        );

        return error.CurlUnavailable;
    };

    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print(
                    "[engine] curl exited with status {d}\n",
                    .{code},
                );

                return error.DownloadFailed;
            }
        },

        .signal => |signal| {
            std.debug.print(
                "[engine] curl terminated by signal {d}\n",
                .{signal},
            );

            return error.DownloadFailed;
        },

        .stopped => |signal| {
            std.debug.print(
                "[engine] curl stopped by signal {d}\n",
                .{signal},
            );

            return error.DownloadFailed;
        },

        .unknown => {
            return error.DownloadFailed;
        },
    }

    // curl 成功只代表传输成功。
    //
    // 内容完整性仍由我们自己的 SHA256 校验负责。
    const digest = try sha256File(
        Io.Dir.cwd(),
        io,
        destination_path,
    );

    var file = try Io.Dir.cwd().openFile(
        io,
        destination_path,
        .{},
    );
    defer file.close(io);

    const stat = try file.stat(io);

    return .{
        .bytes = stat.size,
        .sha256 = digest,
    };
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
        const n =
            try reader.interface.readSliceShort(
                &chunk,
            );

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

    var store = Store.initWith(
        allocator,
        io,
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

    var store = Store.initWith(
        allocator,
        io,
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

    var store = Store.initWith(
        allocator,
        io,
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

    var store = Store.initWith(
        allocator,
        io,
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

    var store = Store.initWith(
        allocator,
        io,
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

    var store = Store.initWith(
        allocator,
        io,
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

    var store = Store.initWith(
        allocator,
        io,
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

    var store = Store.initWith(
        allocator,
        io,
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
