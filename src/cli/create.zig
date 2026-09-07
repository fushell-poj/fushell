//! Creation syntax only. Interactive input and project I/O belong to the command.
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");

pub const description = "Create a new Linux/Wayland Fushell project.";
pub const params = clap.parseParamsComptime(common.help_spec ++
    \\--project-name <str>    Dart package name (defaults to the directory name).
    \\--org <str>             Organization identifier (default: com.example).
    \\--description <str>     Project description.
    \\--application-id <str>  Application ID (defaults to <org>.<project-name>).
    \\--single-instance       Generate a native D-Bus single-instance application.
    \\--interactive           Ask for options not supplied on the command line.
    \\--no-pub                Skip the final flutter pub get, not SDK initialization.
    \\<path>...               One output directory; omit it to open the terminal wizard.
    \\
);
const parsers = .{ .str = clap.parsers.string, .path = clap.parsers.string };

/// Optional values distinguish CLI overrides from answers yet to be prompted.
/// Strings borrow argv. Creation never overwrites a nonempty directory.
pub const Options = struct {
    output: ?[]const u8 = null,
    project_name: ?[]const u8 = null,
    organization: ?[]const u8 = null,
    description: ?[]const u8 = null,
    application_id: ?[]const u8 = null,
    single_instance: ?bool = null,
    interactive: bool = false,
    pub_get: bool = true,
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diag: *common.Diagnostic) !?Options {
    var iterator = clap.args.SliceIterator{ .args = args };
    var result = try clap.parseEx(clap.Help, &params, parsers, &iterator, .{
        .allocator = allocator,
        .diagnostic = &diag.syntax,
    });
    defer result.deinit();
    const paths = result.positionals[0];
    if (paths.len > 1) return diag.reject("create accepts at most one output directory", paths[1]);
    if (result.args.help != 0) return null;
    inline for (.{ "project-name", "org", "application-id" }) |name| {
        if (@field(result.args, name)) |value| {
            if (value.len == 0) return diag.reject("--" ++ name ++ " must not be empty", null);
        }
    }
    if (paths.len > 0 and paths[0].len == 0) return diag.reject("output directory must not be empty", null);
    return .{
        .output = if (paths.len == 1) paths[0] else null,
        .project_name = result.args.@"project-name",
        .organization = result.args.org,
        .description = result.args.description,
        .application_id = result.args.@"application-id",
        .single_instance = if (result.args.@"single-instance" != 0) true else null,
        .interactive = result.args.interactive != 0,
        .pub_get = result.args.@"no-pub" == 0,
    };
}

pub fn help(writer: *std.Io.Writer) !void {
    try common.commandHelp(writer, "create", description, &params, "[output-directory]");
    try writer.writeAll("\nWith a directory: create immediately using flags and defaults.\n" ++
        "Without one: ask in a terminal; non-interactive input is rejected.\n" ++
        "Only missing or empty directories are accepted (including '.').\n" ++
        "No overwrite/force mode. The official Linux runner is not retained.\n" ++
        "The SDK is exported to vendor/fushell; Engine is fetched at build time.\n" ++
        "\nExamples:\n" ++
        "  fushell create my_app\n" ++
        "  fushell create --single-instance --org dev.example my_app\n" ++
        "  fushell create --interactive --no-pub my_app\n");
}
