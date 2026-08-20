//! 播放器入口: 由 fushell (main.zig) 和 fushell-build (run 子命令) 共用。
//! fushell 是发行版播放器 (只播 bundle); fushell-build 是开发工具,
//! run 子命令在进程内调用这里直接播放刚打包的 bundle。

const std = @import("std");
const flutter_runner = @import("flutter_runner.zig");

comptime {
    _ = @import("surface_channel.zig");
}

/// 播放一个 bundle (阻塞直到窗口关闭)。
/// enable_vm_service: 启动 VM service (热重载, 仅 debug/JIT 引擎)。
pub fn runPlayer(gpa: std.mem.Allocator, bundle_path: []const u8, enable_vm_service: bool) !void {
    const engine_library = try resolveBundleEngineLibrary(gpa, bundle_path);
    defer gpa.free(engine_library);

    try flutter_runner.run(gpa, .{
        .engine_library = engine_library,
        .bundle_path = bundle_path,
        .role = .primary,
        .enable_vm_service = enable_vm_service,
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
