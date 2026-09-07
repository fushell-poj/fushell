//! Typed, side-effect-free Fushell command parser backed by pinned zig-clap.
//! Strings and application argv borrow the input. All clap allocations are freed
//! before returning; callers retain only ordinary command-specific values.
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");
pub const build = @import("build.zig");
pub const run = @import("run.zig");
pub const sdk = @import("sdk.zig");
pub const Mode = common.Mode;
pub const Topic = common.Topic;
pub const Diagnostic = common.Diagnostic;

pub const Command = union(enum) {
    help: Topic,
    build: build.Options,
    run: run.Options,
    sdk: sdk.Options,
};
const CommandName = std.meta.Tag(Command);
const root_params = clap.parseParamsComptime(common.help_spec ++
    \\<command>  The command to execute. Use help <command> for command-specific usage.
    \\
);
const help_params = clap.parseParamsComptime(common.help_spec ++
    \\<command>...  One optional command to describe.
    \\
);
const parsers = .{ .command = clap.parsers.string };

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diag: *Diagnostic) !Command {
    diag.* = .{};
    var iterator = clap.args.SliceIterator{ .args = args };
    var result = try clap.parseEx(clap.Help, &root_params, parsers, &iterator, .{
        .allocator = allocator,
        .diagnostic = &diag.syntax,
        .terminating_positional = 0,
    });
    defer result.deinit();
    const name = result.positionals[0] orelse return .{ .help = .root };
    const command = std.meta.stringToEnum(CommandName, name) orelse
        return diag.reject("unknown command", name);
    const rest = args[iterator.index..];
    if (command == .help) return .{ .help = try parseHelp(allocator, rest, diag) };
    diag.topic = switch (command) {
        .build => .build,
        .run => .run,
        .sdk => .sdk,
        .help => unreachable,
    };
    if (result.args.help != 0) {
        if (rest.len != 0) return diag.reject("unexpected argument after help target", rest[0]);
        return .{ .help = diag.topic };
    }
    return switch (command) {
        .build => if (try build.parse(allocator, rest, diag)) |options| .{ .build = options } else .{ .help = .build },
        .run => if (try run.parse(allocator, rest, diag)) |options| .{ .run = options } else .{ .help = .run },
        .sdk => if (try sdk.parse(allocator, rest, diag)) |options| .{ .sdk = options } else .{ .help = .sdk },
        .help => unreachable,
    };
}

fn parseHelp(allocator: std.mem.Allocator, args: []const []const u8, diag: *Diagnostic) !Topic {
    var iterator = clap.args.SliceIterator{ .args = args };
    var result = try clap.parseEx(clap.Help, &help_params, parsers, &iterator, .{
        .allocator = allocator,
        .diagnostic = &diag.syntax,
    });
    defer result.deinit();
    const names = result.positionals[0];
    if (names.len > 1) return diag.reject("help accepts at most one command", names[1]);
    if (names.len == 0) return .root;
    const name = std.meta.stringToEnum(CommandName, names[0]) orelse return diag.reject("unknown command", names[0]);
    return switch (name) {
        .help => .root,
        .build => .build,
        .run => .run,
        .sdk => .sdk,
    };
}

pub fn help(writer: *std.Io.Writer, topic: Topic) !void {
    switch (topic) {
        .build => return build.help(writer),
        .run => return run.help(writer),
        .sdk => return sdk.help(writer),
        .root => {},
    }
    try writer.writeAll("Fushell - Flutter applications on Linux/Wayland.\n\nUsage: fushell [options] [command] [arguments...]");
    try writer.writeAll("\n\nCommands:\n");
    inline for (.{ build, run, sdk }, .{ "build", "run", "sdk" }) |module, name|
        try writer.print("  {s:<8} {s}\n", .{ name, module.description });
    try writer.writeAll("  help     Show general or command-specific help.\n\n");
    try clap.help(writer, clap.Help, &root_params, common.help_options);
    try writer.writeAll("\n\nRun 'fushell <command> --help' for more information.\n");
}

test {
    _ = @import("tests.zig");
}
