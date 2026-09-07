//! Run command syntax. Only the prefix before `--` is ever given to clap.
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");
const build = @import("build.zig");

pub const description = "Build and run a Fushell application.";
pub const positional_usage = "[project-dir|entry.dart] [output-dir] [-- <application arguments...>]";
pub const params = clap.parseParamsComptime(common.help_spec ++ common.mode_spec ++
    \\--devtools                 Start Dart DevTools after VM Service discovery.
    \\--no-launch-browser        Do not open the DevTools browser (requires --devtools).
    \\--no-hot-reload            Disable automatic hot reload in debug mode.
    \\--vm-service-port <port>   VM Service port, 0..65535; 0 selects an available port.
    \\
++ common.paths_spec);
const parsers = .{ .path = clap.parsers.string, .port = clap.parsers.int(u16, 10) };

pub const Options = struct {
    build: build.Options = .{},
    hot_reload: bool = true,
    devtools: bool = false,
    launch_browser: bool = true,
    vm_service_port: ?u16 = null,
    /// Borrowed verbatim, including empty strings, non-UTF-8 bytes, and more `--`.
    application_args: []const []const u8 = &.{},

    pub fn vmServiceEnabled(self: Options) bool {
        return (self.build.mode == .debug and self.hot_reload) or self.devtools or self.vm_service_port != null;
    }
};

/// Parse Fushell options, never the application's command-line language.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diag: *common.Diagnostic) !?Options {
    const boundary = for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--")) break index;
    } else args.len;
    var iterator = clap.args.SliceIterator{ .args = args[0..boundary] };
    var result = clap.parseEx(clap.Help, &params, parsers, &iterator, .{
        .allocator = allocator,
        .diagnostic = &diag.syntax,
    }) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => return diag.reject("--vm-service-port must be a decimal integer from 0 to 65535", null),
        else => return err,
    };
    defer result.deinit();
    const paths = result.positionals[0];
    if (paths.len > 2) return diag.reject("expected at most a project/entrypoint and an output directory before --", paths[2]);
    if (result.args.help != 0) return null;
    const mode = try common.selectMode(result.args.debug, result.args.profile, result.args.release, diag);
    const devtools = result.args.devtools != 0;
    const no_browser = result.args.@"no-launch-browser" != 0;
    const no_reload = result.args.@"no-hot-reload" != 0;
    if (no_browser and !devtools) return diag.reject("--no-launch-browser requires --devtools", null);
    if (no_reload and mode != .debug) return diag.reject("--no-hot-reload is only valid in debug mode", null);
    if (mode == .release and (devtools or result.args.@"vm-service-port" != null))
        return diag.reject("release mode does not support DevTools or VM Service options", null);
    return .{
        .build = .{
            .mode = mode,
            .input = if (paths.len > 0) paths[0] else ".",
            .output = if (paths.len > 1) paths[1] else null,
        },
        .hot_reload = mode == .debug and !no_reload,
        .devtools = devtools,
        .launch_browser = !no_browser,
        .vm_service_port = result.args.@"vm-service-port",
        .application_args = if (boundary < args.len) args[boundary + 1 ..] else &.{},
    };
}

pub fn help(writer: *std.Io.Writer) !void {
    try common.commandHelp(writer, "run", description, &params, positional_usage);
    try writer.writeAll("\nUse '-- <application arguments...>' after Fushell options/paths.\n" ++
        "Every argument after -- is forwarded unchanged to the application.\n" ++
        "Defaults: debug with hot reload, current project, lib/main.dart,\n" ++
        "          build/linux/<arch>/<mode>. Output is relative to the project.\n" ++
        "VM Service uses localhost with authentication enabled.\n" ++
        "\nExamples:\n" ++
        "  fushell run --debug --devtools ./app\n" ++
        "  fushell run --profile --vm-service-port 8181 ./app\n" ++
        "  fushell run ./app -- open --application-option\n");
}
