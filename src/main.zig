const std = @import("std");
const player = @import("player.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const runtime_arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(runtime_arena);

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        printUsage();
        return;
    }
    if (args.len != 1) {
        printUsage();
        std.process.exit(1);
    }

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

    player.runPlayer(gpa, bundle_root, false) catch |err| {
        std.debug.print("fushell-runner failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn printUsage() void {
    std.debug.print("usage: fushell-runner\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Plays the Fushell app bundle located in the same directory as this executable.\n", .{});
    std.debug.print("The Flutter engine belongs to the app bundle.\n", .{});
    std.debug.print("The app starts headless (no window); windows are created by Dart\n", .{});
    std.debug.print("via FushellWindow.openWindow (one Flutter view per window). The process\n", .{});
    std.debug.print("runs until the app calls FushellProcess.exit (closing all windows does\n", .{});
    std.debug.print("not exit the process).\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("required bundle layout (same directory as this executable):\n", .{});
    std.debug.print("  <dir>/lib/libflutter_engine.so\n", .{});
    std.debug.print("  <dir>/data/icudtl.dat\n", .{});
    std.debug.print("  debug/JIT: <dir>/data/flutter_assets/kernel_blob.bin\n", .{});
    std.debug.print("  release/AOT: <dir>/lib/libapp.so\n", .{});
}
