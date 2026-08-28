//! 嵌入每个打包 Fushell 应用的入口点。
//!
//! 本 launcher 不定义面向应用的 flag。它相对自身可执行文件定位 bundle，把每个 argv
//! 元素视为不透明应用数据；配置单实例时，会在任何 Flutter、Wayland 或 EGL 初始化
//! 前完成 D-Bus 所有权判定。因此 secondary 进程没有图形副作用，并以 primary 的命令
//! 结果退出。

const std = @import("std");
const player = @import("player.zig");
const signal_shutdown = @import("signal_shutdown.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const runtime_arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(runtime_arena);
    const application_arguments = try runtime_arena.alloc([]const u8, args.len - 1);
    for (args[1..], application_arguments) |argument, *destination| destination.* = argument;
    const cwd = try std.process.currentPathAlloc(init.io, runtime_arena);

    // 自动定位: /proc/self/exe 所在目录 = bundle 根
    // (处理 symlink/改名/相对路径, 比 argv[0] 可靠)
    var exe_path_buf: [4096]u8 = undefined;
    const exe_path_len = std.os.linux.readlink("/proc/self/exe", &exe_path_buf, exe_path_buf.len);
    if (std.os.linux.errno(exe_path_len) != .SUCCESS) {
        std.debug.print("fushell-runner: cannot resolve own executable path.\n", .{});
        std.process.exit(1);
    }
    const exe_path = exe_path_buf[0..exe_path_len];
    const bundle_root = std.fs.path.dirname(exe_path) orelse {
        std.debug.print("fushell-runner: cannot resolve own executable directory.\n", .{});
        std.process.exit(1);
    };

    var signal_watcher = signal_shutdown.Watcher.init() catch |err| {
        std.debug.print("fushell-runner failed to install signal handlers: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer signal_watcher.deinit();

    const exit_status = player.runPlayer(
        gpa,
        init.io,
        bundle_root,
        null,
        signal_watcher.fd,
        application_arguments,
        cwd,
    ) catch |err| {
        if (signal_watcher.triggered()) std.process.exit(130);
        std.debug.print("fushell-runner failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (signal_watcher.triggered()) std.process.exit(130);
    if (exit_status != 0) std.process.exit(exit_status);
}
