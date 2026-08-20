//! build.zig 各 step (pull-flutter / build-engine) 的公共运行时辅助:
//! 子进程执行、环境构造、路径解析、幂等文件写入。

const std = @import("std");

/// 与 fushell 配对的 Flutter SDK (nixpkgs 3.41.9) 的 engine commit。
pub const engine_commit = "42d3d75a56efe1a2e9902f52dc8006099c45d937";

/// 读取单个环境变量 (从 /proc/self/environ, 纯 zig, 不依赖 libc)。
/// 未设置返回 null。
pub fn getEnvVar(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(
        std.Io.Threaded.global_single_threaded.io(),
        "/proc/self/environ",
        .{},
    ) catch return null;
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var buf: [65536]u8 = undefined;
    const n = file.readPositional(std.Io.Threaded.global_single_threaded.io(), &.{&buf}, 0) catch return null;

    var it = std.mem.splitScalar(u8, buf[0..n], 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.startsWith(u8, entry, name) and entry.len > name.len and entry[name.len] == '=') {
            return allocator.dupe(u8, entry[name.len + 1 ..]) catch null;
        }
    }
    return null;
}

/// 解析引擎工作区 (无默认值, 必须显式指定), 优先级:
///   ① -Dflutter-workspace=X   (命令行, 最高)
///   ② FLUTTER_ENGINE_DIR      (环境变量)
///   ③ ./flutter_engine_dir    (项目文件, 第一行 = 路径, 相对项目根)
/// 解析出的路径做绝对化, 并验证目录存在; 否则报错并列出全部三种指定方式。
pub fn resolveWorkspaceConfig(io: std.Io, allocator: std.mem.Allocator, opt_cli: ?[]const u8) ![]const u8 {
    const dir_file_abs = try resolveWorkspace(io, allocator, "flutter_engine_dir");

    // 按优先级取原始值: -D > FLUTTER_ENGINE_DIR > ./flutter_engine_dir (第一行)
    const raw: ?[]const u8 = if (opt_cli) |cli| cli else blk: {
        if (getEnvVar(allocator, "FLUTTER_ENGINE_DIR")) |value| break :blk value;
        if (readSmallFile(io, dir_file_abs)) |content| {
            defer std.heap.page_allocator.free(content);
            const line = std.mem.trim(u8, firstLine(content), " \t\r\n");
            if (line.len > 0) break :blk try allocator.dupe(u8, line);
        }
        break :blk null;
    };

    if (raw == null) {
        std.debug.print("error: no Flutter engine workspace specified. Use one of:\n", .{});
        printWorkspaceOptions();
        return error.NoFlutterEngineWorkspace;
    }
    const trimmed = std.mem.trim(u8, raw.?, " \t\r\n");
    if (trimmed.len == 0) {
        std.debug.print("error: Flutter engine workspace is empty. Specify it via one of:\n", .{});
        printWorkspaceOptions();
        return error.NoFlutterEngineWorkspace;
    }
    const resolved = try resolveWorkspace(io, allocator, trimmed);
    if (!dirExists(io, resolved)) {
        std.debug.print("error: Flutter engine workspace does not exist: {s}\n", .{resolved});
        std.debug.print("  Create it manually (e.g. ln -s /disk/data/fushell-engine {s}) or fix the path.\n", .{trimmed});
        printWorkspaceOptions();
        return error.WorkspaceMissing;
    }
    return resolved;
}

fn printWorkspaceOptions() void {
    std.debug.print("  - zig build -Dflutter-workspace=<path>\n", .{});
    std.debug.print("  - export FLUTTER_ENGINE_DIR=<path>\n", .{});
    std.debug.print("  - echo <path> > flutter_engine_dir  (project file, relative to project root)\n", .{});
}

fn firstLine(content: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    return content[0..end];
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// 解析绝对路径 (相对路径基于当前目录)。
pub fn resolveWorkspace(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

/// 在指定目录运行命令: 继承环境变量 (含 http_proxy), 输出透传, 非零退出码传播。
/// prefix 用于诊断输出标识 (如 "[flutter-pull]")。cwd 为 null 时继承当前目录。
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    cwd: ?[]const u8,
    argv: []const []const u8,
) !void {
    std.debug.print("{s} $", .{prefix});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n", .{});

    var owned = try allocator.alloc([:0]const u8, argv.len);
    defer allocator.free(owned);
    for (argv, 0..) |arg, i| owned[i] = try allocator.dupeZ(u8, arg);

    var child = try std.process.spawn(io, .{
        .argv = owned,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("{s} command failed with exit code {d}: {s}\n", .{ prefix, code, argv[0] });
                return error.CommandFailed;
            }
        },
        else => {
            std.debug.print("{s} command terminated abnormally: {s}\n", .{ prefix, argv[0] });
            return error.CommandFailed;
        },
    }
}

/// 文件不存在或内容不同时写入 (幂等)。
pub fn writeIfChanged(io: std.Io, prefix: []const u8, path: []const u8, content: []const u8) !void {
    if (readSmallFile(io, path)) |old| {
        defer std.heap.page_allocator.free(old);
        if (std.mem.eql(u8, old, content)) return;
    }
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
    std.debug.print("{s} wrote {s}\n", .{ prefix, path });
}

/// 读小文件 (page_allocator 分配, 调用方 free)。文件不存在/失败返回 null。
pub fn readSmallFile(io: std.Io, path: []const u8) ?[]u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    const n = file.readPositional(io, &.{&buf}, 0) catch return null;
    return std.heap.page_allocator.dupe(u8, buf[0..n]) catch null;
}
