//! Shared CLI vocabulary and presentation; no filesystem or process operations.
const std = @import("std");
const clap = @import("clap");

pub const Mode = enum { debug, profile, release };
pub const Topic = enum { root, build, run, sdk };

pub const help_spec =
    \\-h, --help  Show this command's help and exit.
    \\
;
pub const mode_spec =
    \\--debug    Build a JIT bundle (default).
    \\--profile  Build an AOT bundle for profiling.
    \\--release  Build an AOT bundle for distribution.
    \\
;
pub const paths_spec =
    \\<path>...  Up to two paths: project directory or Dart entrypoint, then output directory.
    \\
;

/// All fields borrow argv or static declarations, never clap's temporary storage.
pub const Diagnostic = struct {
    topic: Topic = .root,
    syntax: clap.Diagnostic = .{},
    message: ?[]const u8 = null,
    argument: ?[]const u8 = null,

    pub fn reject(self: *Diagnostic, message: []const u8, argument: ?[]const u8) error{InvalidCommandLine} {
        self.message = message;
        self.argument = argument;
        return error.InvalidCommandLine;
    }

    /// Render syntax errors from clap and command-specific semantic errors alike.
    pub fn report(self: Diagnostic, writer: *std.Io.Writer, err: anyerror) !void {
        try writer.writeAll("error: ");
        if (self.message) |message| {
            try writer.writeAll(message);
            if (self.argument) |argument| try writer.print(": '{s}'", .{argument});
            try writer.writeByte('\n');
        } else {
            try self.syntax.report(writer, err);
        }
        if (self.topic == .root) {
            try writer.writeAll("Run 'fushell --help' for usage.\n");
        } else {
            try writer.print("Run 'fushell {s} --help' for usage.\n", .{@tagName(self.topic)});
        }
    }
};

/// Repeated mode flags are rejected as well as different mutually exclusive modes.
pub fn selectMode(debug: u8, profile: u8, release: u8, diag: *Diagnostic) !Mode {
    if (@as(usize, debug) + profile + release > 1)
        return diag.reject("choose at most one of --debug, --profile, and --release", null);
    return if (release != 0) .release else if (profile != 0) .profile else .debug;
}

pub const help_options: clap.HelpOptions = .{
    .description_on_new_line = false,
    .description_indent = 2,
    .indent = 2,
    .spacing_between_parameters = 0,
    .max_width = 88,
};

/// Render command metadata and clap option help together. Positional arity is
/// validated by each command; clap itself only collects the positional list.
pub fn commandHelp(writer: *std.Io.Writer, name: []const u8, description: []const u8, params: []const clap.Param(clap.Help), positional_usage: []const u8) !void {
    try writer.print("{s}\n\nUsage: fushell {s} [options] {s}", .{ description, name, positional_usage });
    try writer.writeAll("\n\n");
    try clap.help(writer, clap.Help, params, help_options);
    try writer.writeByte('\n');
}
