//! Build command syntax. Returned strings borrow the original argv.
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");

pub const description = "Build a Flutter project into a Fushell bundle.";
pub const positional_usage = "[project-dir|entry.dart] [output-dir]";
const symbols_spec =
    \\--symbols  Archive matching AOT symbols separately from the runtime bundle.
    \\
;
pub const params = clap.parseParamsComptime(common.help_spec ++ common.mode_spec ++ symbols_spec ++ common.paths_spec);
const parsers = .{ .path = clap.parsers.string };

pub const Options = struct {
    mode: common.Mode = .debug,
    input: []const u8 = ".",
    output: ?[]const u8 = null,
    symbols: bool = false,
};

/// A null result requests help. Filesystem interpretation belongs to execution.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diag: *common.Diagnostic) !?Options {
    var iterator = clap.args.SliceIterator{ .args = args };
    var result = try clap.parseEx(clap.Help, &params, parsers, &iterator, .{
        .allocator = allocator,
        .diagnostic = &diag.syntax,
    });
    defer result.deinit();
    const paths = result.positionals[0];
    if (paths.len > 2) return diag.reject("expected at most a project/entrypoint and an output directory", paths[2]);
    if (result.args.help != 0) return null;
    const mode = try common.selectMode(result.args.debug, result.args.profile, result.args.release, diag);
    if (result.args.symbols != 0 and mode == .debug)
        return diag.reject("--symbols requires --profile or --release", null);
    return .{
        .mode = mode,
        .symbols = result.args.symbols != 0,
        .input = if (paths.len > 0) paths[0] else ".",
        .output = if (paths.len > 1) paths[1] else null,
    };
}

pub fn help(writer: *std.Io.Writer) !void {
    try common.commandHelp(writer, "build", description, &params, positional_usage);
    try writer.writeAll("\nDefaults: current project, lib/main.dart, build/linux/<arch>/<mode>.\n" ++
        "An explicit output path is relative to the selected project directory.\n" ++
        "--symbols archives AOT diagnostics under build/fushell_debug_info/archives; never in the runtime bundle.\n" ++
        "\nExample: fushell build --release ./app\n");
}

test "symbols are opt-in and require an AOT mode" {
    var diag: common.Diagnostic = .{};
    const defaults = (try parse(std.testing.allocator, &.{}, &diag)).?;
    try std.testing.expect(!defaults.symbols);
    const selected = (try parse(std.testing.allocator, &.{ "--release", "--symbols" }, &diag)).?;
    try std.testing.expect(selected.symbols);
    try std.testing.expectError(error.InvalidCommandLine, parse(std.testing.allocator, &.{"--symbols"}, &diag));
}
