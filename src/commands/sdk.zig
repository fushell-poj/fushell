//! Export the canonical embedded Dart SDK without discovering Flutter.
const std = @import("std");
const cli = @import("cli");
const embedded_sdk_pubspec = @embedFile("fushell_sdk_pubspec");
const embedded_sdk_lib = @embedFile("fushell_sdk_lib");
const embedded_sdk_readme = @embedFile("fushell_sdk_readme");
const library_files = .{ "icons", "windows", "tray", "src/tray/host", "src/tray/item", "src/tray/menu", "src/tray/watcher", "workspace", "src/workspace/workspace", "src/workspace/transport", "src/workspace/protocol" };
const support_files = .{ "protocols/wayland.xml", "protocols/ext-workspace-v1.xml", "protocols/README.md", "tool/workspace/generate.dart", "tool/workspace/generate_test.dart", "tool/workspace/README.md" };

pub fn execute(init: std.process.Init, options: cli.sdk.Options) !void {
    const target = try exportPackage(init.gpa, init.io, options.output);
    defer init.gpa.free(target);
    std.debug.print("fushell SDK released to {s}\n", .{target});
    std.debug.print("add to your project pubspec.yaml:\n", .{});
    std.debug.print("  dependencies:\n", .{});
    std.debug.print("    fushell:\n", .{});
    std.debug.print("      path: {s}\n", .{target});
}

/// `sdk` 子命令: 释放内嵌的 fushell 包到 <dir>/fushell (默认 ./vendor/fushell)。
/// 外部项目通过 path 依赖导入: pubspec → fushell: { path: <dir>/fushell }
/// 返回的导出目录由调用方释放；此函数不打印，便于复用和测试。
pub fn exportPackage(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ![]u8 {
    const target = try std.fs.path.join(gpa, &.{ dir, "fushell" });
    errdefer gpa.free(target);
    const lib_dir = try std.fs.path.join(gpa, &.{ target, "lib" });
    defer gpa.free(lib_dir);

    // 创建目录 (幂等: createDirPath 会递归创建不存在的路径)
    std.Io.Dir.cwd().createDirPath(io, lib_dir) catch return error.SdkReleaseDirCreateFailed;

    // 写 pubspec.yaml
    const pubspec_path = try std.fs.path.join(gpa, &.{ target, "pubspec.yaml" });
    defer gpa.free(pubspec_path);
    var pubspec_file = try std.Io.Dir.cwd().createFile(io, pubspec_path, .{});
    defer pubspec_file.close(io);
    try pubspec_file.writeStreamingAll(io, embedded_sdk_pubspec);

    // 写 lib/fushell.dart
    const lib_path = try std.fs.path.join(gpa, &.{ lib_dir, "fushell.dart" });
    defer gpa.free(lib_path);
    var lib_file = try std.Io.Dir.cwd().createFile(io, lib_path, .{});
    defer lib_file.close(io);
    try lib_file.writeStreamingAll(io, embedded_sdk_lib);

    inline for (library_files) |file| {
        const path = try std.fs.path.join(gpa, &.{ lib_dir, file ++ ".dart" });
        defer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        var output = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer output.close(io);
        try output.writeStreamingAll(io, @embedFile("fushell_sdk_" ++ file));
    }

    inline for (support_files) |file| {
        const path = try std.fs.path.join(gpa, &.{ target, file });
        defer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        var output = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer output.close(io);
        try output.writeStreamingAll(io, @embedFile("fushell_sdk_support_" ++ file));
    }

    // 写 README.md
    const readme_path = try std.fs.path.join(gpa, &.{ target, "README.md" });
    defer gpa.free(readme_path);
    var readme_file = try std.Io.Dir.cwd().createFile(io, readme_path, .{});
    defer readme_file.close(io);
    try readme_file.writeStreamingAll(io, embedded_sdk_readme);

    return target;
}

test "released SDK matches the canonical embedded package byte-for-byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(output_root);

    const exported = try exportPackage(std.testing.allocator, std.testing.io, output_root);
    defer std.testing.allocator.free(exported);

    const pubspec = try tmp.dir.readFileAlloc(
        std.testing.io,
        "fushell/pubspec.yaml",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(pubspec);
    const library = try tmp.dir.readFileAlloc(
        std.testing.io,
        "fushell/lib/fushell.dart",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(library);
    const readme = try tmp.dir.readFileAlloc(
        std.testing.io,
        "fushell/README.md",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(readme);

    try std.testing.expectEqualSlices(u8, embedded_sdk_pubspec, pubspec);
    try std.testing.expectEqualSlices(u8, embedded_sdk_lib, library);
    try std.testing.expectEqualSlices(u8, embedded_sdk_readme, readme);
    inline for (library_files) |file| {
        const content = try tmp.dir.readFileAlloc(
            std.testing.io,
            "fushell/lib/" ++ file ++ ".dart",
            std.testing.allocator,
            .limited(1024 * 1024),
        );
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualSlices(u8, @embedFile("fushell_sdk_" ++ file), content);
    }
    inline for (support_files) |file| {
        const content = try tmp.dir.readFileAlloc(
            std.testing.io,
            "fushell/" ++ file,
            std.testing.allocator,
            .limited(1024 * 1024),
        );
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualSlices(u8, @embedFile("fushell_sdk_support_" ++ file), content);
    }
}
