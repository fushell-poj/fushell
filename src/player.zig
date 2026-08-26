//! 播放器入口: 由 fushell-runner 和 fushell CLI 的 run 子命令共用。
//! fushell-runner 只播放 bundle；fushell run 在进程内播放刚打包的 bundle。

const std = @import("std");
const flutter_runner = @import("flutter_runner.zig");

comptime {
    _ = @import("surface_channel.zig");
}

/// 播放一个 bundle (阻塞直到程序退出)。
/// vm_service_port 为 null 时关闭 VM Service；0 表示随机本地端口。
pub fn runPlayer(gpa: std.mem.Allocator, io: std.Io, bundle_path: []const u8, vm_service_port: ?u16, shutdown_fd: c_int) !void {
    const engine_library = try resolveBundleEngineLibrary(gpa, bundle_path);
    defer gpa.free(engine_library);

    try flutter_runner.run(gpa, .{
        .io = io,
        .engine_library = engine_library,
        .bundle_path = bundle_path,
        .vm_service_port = vm_service_port,
        .shutdown_fd = shutdown_fd,
    });
}

fn resolveBundleEngineLibrary(gpa: std.mem.Allocator, bundle_path: []const u8) ![]const u8 {
    const engine_library = try std.fs.path.join(gpa, &.{ bundle_path, "lib", "libflutter_engine.so" });
    errdefer gpa.free(engine_library);

    if (!try pathExists(gpa, engine_library)) {
        std.debug.print("Flutter engine library is missing from the app bundle.\n", .{});
        std.debug.print("Expected: {s}\n", .{engine_library});
        return error.MissingFlutterEngineLibrary;
    }

    return engine_library;
}

fn pathExists(gpa: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    return std.c.access(path_z.ptr, std.c.F_OK) == 0;
}
