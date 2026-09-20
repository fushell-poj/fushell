//! Export the canonical embedded Dart SDK without discovering Flutter.
const std = @import("std");
const cli = @import("cli");
const sdk_manifest = @import("../sdk_manifest.zig");

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
    std.Io.Dir.cwd().createDirPath(io, target) catch return error.SdkReleaseDirCreateFailed;

    inline for (sdk_manifest.files) |file| {
        const path = try std.fs.path.join(gpa, &.{ target, file });
        defer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        var output = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer output.close(io);
        try output.writeStreamingAll(io, @embedFile("fushell_sdk_" ++ file));
    }

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

    inline for (sdk_manifest.files) |file| {
        const content = try tmp.dir.readFileAlloc(
            std.testing.io,
            "fushell/" ++ file,
            std.testing.allocator,
            .limited(1024 * 1024),
        );
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualSlices(u8, @embedFile("fushell_sdk_" ++ file), content);
    }
}
