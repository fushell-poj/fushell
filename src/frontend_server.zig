//! JIT 热重载使用的长生命周期 Flutter frontend_server 客户端。
//!
//! 子进程启动时不提供命令行 entrypoint，使其持续运行；编译请求按行写入 stdin，
//! 响应则在 stdout 使用每次请求独有的边界 token。成功编译会替换完整 kernel dill，
//! 再由 VM Service 通过 `reloadSources` 加载。子进程拥有独立进程组，因此 CLI
//! 关闭时可以回收编译器及其后代进程。

const std = @import("std");
const builtin = @import("builtin");

/// 拥有一个增量编译器进程及其 stdin/stdout 管道端点。
///
/// 路径借自调用方，必须比该对象存活更久。方法均为同步调用且限制在 CLI 线程；
/// 即使发生编译或协议失败，也必须调用 `deinit` 终止进程组并关闭两个描述符。
pub const FrontendServer = struct {
    io: std.Io,
    pid: std.c.pid_t,
    stdin_fd: std.posix.fd_t,
    stdout_fd: std.posix.fd_t,
    output_dill: []const u8,
    main_uri: []const u8,
    /// 增量编译状态 (frontend_server 协议)
    boundary: [128]u8 = undefined,
    boundary_len: usize = 0,
    compiled_once: bool = false,

    /// 启动 frontend_server 常驻进程。
    /// flutter_root: Flutter SDK 根。project_dir: app 项目目录 (找 .dart_tool/package_config.json)。
    /// output_dill: 编译产物路径 (kernel dill)。
    pub fn start(gpa: std.mem.Allocator, io: std.Io, flutter_root: []const u8, project_dir: []const u8, output_dill: []const u8, main_uri: []const u8) !FrontendServer {
        // 定位引擎产物
        const engine_dir = try engineArtifactsDir(gpa, flutter_root);
        defer gpa.free(engine_dir);
        const snapshot = try std.fs.path.join(gpa, &.{ engine_dir, hostPlatform(), "frontend_server_aot.dart.snapshot" });
        defer gpa.free(snapshot);
        const dart_rt = try std.fs.path.join(gpa, &.{ flutter_root, "bin", "cache", "dart-sdk", "bin", "dartaotruntime" });
        defer gpa.free(dart_rt);
        const packages = try std.fs.path.join(gpa, &.{ project_dir, ".dart_tool", "package_config.json" });
        defer gpa.free(packages);

        // sdk-root / platform dill: 优先 linux-x64/flutter_patched_sdk, 否则 common/flutter_patched_sdk
        var sdk_root_buf: [4096]u8 = undefined;
        const sdk_root: []const u8 = blk: {
            const linux_patched = try std.fs.path.join(gpa, &.{ engine_dir, hostPlatform(), "flutter_patched_sdk" });
            defer gpa.free(linux_patched);
            if (dirExists(linux_patched)) {
                const n = (try std.fmt.bufPrint(&sdk_root_buf, "{s}/", .{linux_patched})).len;
                break :blk sdk_root_buf[0..n];
            }
            const common_patched = try std.fs.path.join(gpa, &.{ engine_dir, "common", "flutter_patched_sdk" });
            defer gpa.free(common_patched);
            const n = (try std.fmt.bufPrint(&sdk_root_buf, "{s}/", .{common_patched})).len;
            break :blk sdk_root_buf[0..n];
        };
        const platform_dill = try std.fs.path.join(gpa, &.{ sdk_root, "platform_strong.dill" });
        defer gpa.free(platform_dill);

        // 管道: 用 spawn 的 .pipe 模式 (spawn 自己创建/管理, 避免手动 fd 竞争)
        var stdin_pipe: [2]std.posix.fd_t = undefined;
        var stdout_pipe: [2]std.posix.fd_t = undefined;
        _ = std.os.linux.pipe2(&stdin_pipe, .{});
        errdefer _ = std.os.linux.close(stdin_pipe[0]);
        errdefer _ = std.os.linux.close(stdin_pipe[1]);
        _ = std.os.linux.pipe2(&stdout_pipe, .{});
        errdefer _ = std.os.linux.close(stdout_pipe[0]);
        errdefer _ = std.os.linux.close(stdout_pipe[1]);
        // 给 fd 加 CLOEXEC, 防止子进程 exec 时意外继承 (保持引用计数可控)
        _ = std.os.linux.fcntl(stdin_pipe[0], std.os.linux.F.SETFD, 1);
        _ = std.os.linux.fcntl(stdin_pipe[1], std.os.linux.F.SETFD, 1);
        _ = std.os.linux.fcntl(stdout_pipe[0], std.os.linux.F.SETFD, 1);
        _ = std.os.linux.fcntl(stdout_pipe[1], std.os.linux.F.SETFD, 1);

        // spawn: 子进程 stdin = pipe[0], stdout = pipe[1]
        // 注意: 命令行【不能】带 entrypoint (main_uri)!
        // frontend_server 文档: 命令行带 entrypoint → 编译完就退出;
        // 不带 → 常驻等待 stdin 指令 (compile <uri> 通过 stdin 发送)。
        const args = [_][]const u8{
            dart_rt,                              snapshot,        "--sdk-root",        sdk_root,     "--incremental", "--target=flutter",
            "--experimental-emit-debug-metadata", "--output-dill", output_dill,         "--packages", packages,        "--track-widget-creation",
            "--platform",                         platform_dill,   "--verbosity=error",
        };

        const child = try std.process.spawn(io, .{
            .argv = &args,
            .stdin = .{ .file = .{ .handle = stdin_pipe[0], .flags = .{ .nonblocking = false } } },
            .stdout = .{ .file = .{ .handle = stdout_pipe[1], .flags = .{ .nonblocking = false } } },
            .stderr = .inherit,
            .pgid = 0,
        });
        // 父进程关闭不需要的端
        _ = std.os.linux.close(stdin_pipe[0]);
        _ = std.os.linux.close(stdout_pipe[1]);

        return .{
            .io = io,
            .pid = child.id orelse 0,
            .stdin_fd = stdin_pipe[1],
            .stdout_fd = stdout_pipe[0],
            .output_dill = output_dill,
            .main_uri = main_uri,
        };
    }

    /// 编译。首次发 compile(全量), 之后发 recompile(增量, 带 boundary key + 变化文件)。
    /// 成功返回 true。失败 (编译错误) 返回 false, 错误信息在 err_buf。
    pub fn compile(self: *FrontendServer, err_buf: []u8, changed_files: []const []const u8, out_dill_path: ?[]u8) !bool {
        // 发请求
        var req_buf: [16384]u8 = undefined;
        var req: []const u8 = undefined;
        if (!self.compiled_once) {
            req = try std.fmt.bufPrint(&req_buf, "compile {s}\n", .{self.main_uri});
        } else {
            // recompile <uri> <boundary-key>\n<invalidated files>...\n(空行结束)
            const head = try std.fmt.bufPrint(&req_buf, "recompile {s} {s}\n", .{ self.main_uri, self.boundary[0..self.boundary_len] });
            var rest = req_buf[head.len..];
            for (changed_files) |f| {
                if (rest.len < f.len + 1) break;
                @memcpy(rest[0..f.len], f);
                rest[f.len] = '\n';
                rest = rest[f.len + 1 ..];
            }
            // 结束标记 = boundary key 行 (源码: if (string == boundaryKey) 触发 recompileDelta)
            const key_n = self.boundary_len;
            if (rest.len >= key_n + 1) {
                @memcpy(rest[0..key_n], self.boundary[0..key_n]);
                rest[key_n] = '\n';
                rest = rest[key_n + 1 ..];
            }
            req = req_buf[0 .. req_buf.len - rest.len];
        }
        var written: usize = 0;
        while (written < req.len) {
            const n = std.os.linux.write(self.stdin_fd, req[written..].ptr, req.len - written);
            if (n == 0) return error.FrontendServerClosed;
            written += n;
        }

        // 读响应 (行协议)
        var line_buf: [8192]u8 = undefined;
        var line_len: usize = 0;
        var boundary: [128]u8 = undefined;
        var boundary_len: usize = 0;
        var saw_result_line = false;
        var err_count: usize = 0;

        while (true) {
            // 读一行
            line_len = 0;
            while (true) {
                var byte: [1]u8 = undefined;
                const n = std.os.linux.read(self.stdout_fd, &byte, 1);
                if (n == 0 or n > 1) return error.FrontendServerReadFailed;
                if (n == 0) return error.FrontendServerClosed; // 进程退出
                if (byte[0] == '\n') break;
                if (line_len < line_buf.len) {
                    line_buf[line_len] = byte[0];
                    line_len += 1;
                }
            }
            const line = line_buf[0..line_len];

            if (!saw_result_line) {
                // 第一行: "result <boundaryKey>"
                if (std.mem.startsWith(u8, line, "result ")) {
                    const key = line["result ".len..];
                    if (key.len > boundary.len) return error.FrontendServerProtocolError;
                    @memcpy(boundary[0..key.len], key);
                    boundary_len = key.len;
                    saw_result_line = true;
                }
                continue;
            }

            // 结果行: "<boundaryKey> <outputFile> <errorCount>"
            if (boundary_len > 0 and std.mem.startsWith(u8, line, boundary[0..boundary_len]) and line.len > boundary_len) {
                const rest = std.mem.trim(u8, line[boundary_len..], " ");
                // 格式: <outputFile> <errorCount> (或依赖行 "+file:///...")
                if (rest.len > 0 and rest[0] != '+') {
                    const space = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return error.FrontendServerProtocolError;
                    err_count = std.fmt.parseInt(usize, std.mem.trim(u8, rest[space + 1 ..], " "), 10) catch return error.FrontendServerProtocolError;
                    // outputFile = 结果行第二字段 (增量编译时为 <output-dill>.incremental.dill)
                    if (out_dill_path) |dst| {
                        const of = std.mem.trim(u8, rest[0..space], " ");
                        if (of.len < dst.len) {
                            @memcpy(dst[0..of.len], of);
                            dst[of.len] = 0;
                        }
                    }
                    if (err_count > 0) {
                        // 错误诊断行已收集在 err_buf (见下); 追加计数
                        var err_len: usize = 0;
                        while (err_len < err_buf.len and err_buf[err_len] != 0) err_len += 1;
                        const suffix = try std.fmt.bufPrint(err_buf[err_len..], "\n{d} error(s)", .{err_count});
                        if (err_len + suffix.len < err_buf.len) err_buf[err_len + suffix.len] = 0;
                    } else {
                        self.compiled_once = true;
                        if (err_buf.len > 0) err_buf[0] = 0;
                    }
                    return err_count == 0;
                }
            } else if (line.len > 0 and line[0] != '+') {
                // 错误诊断行 (非依赖行): "lib/main.dart:32:21: Error: ..." 等
                // 收集到 err_buf (诊断行在结果行之前)
                var err_len: usize = 0;
                while (err_len < err_buf.len and err_buf[err_len] != 0) err_len += 1;
                if (err_len + line.len + 1 < err_buf.len) {
                    @memcpy(err_buf[err_len..][0..line.len], line);
                    err_buf[err_len + line.len] = '\n';
                    err_buf[err_len + line.len + 1] = 0;
                }
            }
        }
    }

    pub fn stop(self: *FrontendServer) void {
        _ = std.os.linux.close(self.stdin_fd);
        _ = std.os.linux.close(self.stdout_fd);
        if (self.pid == 0) return;

        const pid = self.pid;
        const group = -pid;
        _ = std.os.linux.kill(group, std.posix.SIG.TERM);
        var status: u32 = 0;
        for (0..100) |_| {
            const result = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
            if (result == pid or std.posix.errno(result) == .CHILD) {
                _ = std.os.linux.kill(group, std.posix.SIG.KILL);
                self.pid = 0;
                return;
            }
            std.Io.sleep(self.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .real) catch break;
        }

        _ = std.os.linux.kill(group, std.posix.SIG.KILL);
        _ = std.os.linux.waitpid(pid, &status, 0);
        self.pid = 0;
    }
};

/// 引擎产物目录: <flutter_root>/bin/cache/artifacts/engine (解析符号链接后的真实路径)。
fn engineArtifactsDir(gpa: std.mem.Allocator, flutter_root: []const u8) ![]const u8 {
    const link = try std.fs.path.join(gpa, &.{ flutter_root, "bin", "cache", "artifacts", "engine", hostPlatform(), "frontend_server_aot.dart.snapshot" });
    defer gpa.free(link);
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(io, link, &buf) catch return error.FrontendServerStartFailed;
    var resolved: []const u8 = buf[0..n];
    if (!std.fs.path.isAbsolute(resolved)) {
        const base = std.fs.path.dirname(link) orelse ".";
        resolved = try std.fs.path.resolve(gpa, &.{ base, resolved });
    }
    // resolved 是快照文件路径 → 取 dirname(linux-x64) 的 dirname (engine 目录)
    const snap_dir = std.fs.path.dirname(resolved) orelse return error.FrontendServerStartFailed;
    const engine_dir = std.fs.path.dirname(snap_dir) orelse return error.FrontendServerStartFailed;
    return gpa.dupe(u8, engine_dir);
}

fn dirExists(path: []const u8) bool {
    var dir = std.Io.Dir.openDir(.cwd(), std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    dir.close(std.Io.Threaded.global_single_threaded.io());
    return true;
}

/// Flutter's host cache uses Flutter architecture names, not Zig CPU tags.
fn hostPlatform() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "linux-x64",
        .aarch64 => "linux-arm64",
        else => @compileError("unsupported Flutter host architecture"),
    };
}
