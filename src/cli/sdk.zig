//! SDK export syntax; no Flutter toolchain is required to parse or execute it.
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");

pub const description = "Export the Dart SDK embedded in this Fushell executable.";
pub const positional_usage = "[output-dir]";
pub const params = clap.parseParamsComptime(common.help_spec ++
    \\<directory>...  One optional parent directory for the exported fushell package (default: vendor).
    \\
);
const parsers = .{ .directory = clap.parsers.string };

pub const Options = struct { output: []const u8 = "vendor" };

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diag: *common.Diagnostic) !?Options {
    var iterator = clap.args.SliceIterator{ .args = args };
    var result = try clap.parseEx(clap.Help, &params, parsers, &iterator, .{
        .allocator = allocator,
        .diagnostic = &diag.syntax,
    });
    defer result.deinit();
    const paths = result.positionals[0];
    if (paths.len > 1) return diag.reject("sdk accepts at most one output directory", paths[1]);
    if (result.args.help != 0) return null;
    return .{ .output = if (paths.len > 0) paths[0] else "vendor" };
}

pub fn help(writer: *std.Io.Writer) !void {
    try common.commandHelp(writer, "sdk", description, &params, positional_usage);
    try writer.writeAll("\nWrites <directory>/fushell/{pubspec.yaml,lib/fushell.dart,README.md}.\n" ++
        "Example: fushell sdk ./vendor\n");
}
