//! Doctor command syntax only; no probes, filesystem access, or Flutter startup.
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");
pub const description = "Diagnose the Flutter toolchain, Engine, project, and desktop session.";
pub const params = clap.parseParamsComptime(common.help_spec ++
    \\-v, --verbose  Show paths, revisions, and successful check details.
    \\--machine      Emit one schemaVersion 1 JSON report on stdout.
    \\<path>...      Optional project directory; no implicit current-directory project.
    \\
);
const parsers = .{ .path = clap.parsers.string };
pub const Options = struct {
    project: ?[]const u8 = null,
    verbose: bool = false,
    machine: bool = false,
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diag: *common.Diagnostic) !?Options {
    var iterator = clap.args.SliceIterator{ .args = args };
    var result = try clap.parseEx(clap.Help, &params, parsers, &iterator, .{ .allocator = allocator, .diagnostic = &diag.syntax });
    defer result.deinit();
    const paths = result.positionals[0];
    if (paths.len > 1) return diag.reject("doctor accepts at most one project directory", paths[1]);
    if (result.args.help != 0) return null;
    if (paths.len == 1 and paths[0].len == 0) return diag.reject("project directory must not be empty", null);
    return .{ .project = if (paths.len == 1) paths[0] else null, .verbose = result.args.verbose != 0, .machine = result.args.machine != 0 };
}

pub fn help(writer: *std.Io.Writer) !void {
    try common.commandHelp(writer, "doctor", description, &params, "[project-directory]");
    try writer.writeAll("\nNo project directory is inspected unless explicitly supplied.\n" ++
        "Doctor does not install tools, resolve project packages, build, open windows,\n" ++
        "repair caches, or download Engine binaries. It may query remote metadata;\n" ++
        "Flutter itself may initialize SDK caches during its version query.\n" ++
        "Warnings return 0; failed checks return 1; invalid arguments return 2.\n" ++
        "\nExamples:\n  fushell doctor\n  fushell doctor -v\n  fushell doctor --machine ./my_app\n");
}
