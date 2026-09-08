//! Typed, side-effect-free Fushell command parser backed by pinned zig-clap.
//! Strings and application argv borrow the input. All clap allocations are freed
//! before returning; callers retain only ordinary command-specific values.
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");
pub const build = @import("build.zig");
pub const run = @import("run.zig");
pub const sdk = @import("sdk.zig");
pub const create = @import("create.zig");
pub const doctor = @import("doctor.zig");
pub const Mode = common.Mode;
pub const Topic = common.Topic;
pub const Diagnostic = common.Diagnostic;

pub const Command = union(enum) {
    build: build.Options,
    run: run.Options,
    sdk: sdk.Options,
    create: create.Options,
    doctor: doctor.Options,
};
/// Help is a parsing outcome, never an executable subcommand.
pub const ParseResult = union(enum) {
    help: Topic,
    command: Command,
};

const CommandName = std.meta.Tag(Command);
const root_params = clap.parseParamsComptime(common.help_spec ++
    \\<command>  The command to execute. Use <command> --help for command-specific usage.
    \\
);
const parsers = .{ .command = clap.parsers.string };

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diag: *Diagnostic) !ParseResult {
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
    diag.topic = switch (command) {
        .build => .build,
        .run => .run,
        .sdk => .sdk,
        .create => .create,
        .doctor => .doctor,
    };
    if (result.args.help != 0) {
        if (rest.len != 0) return diag.reject("unexpected argument after help target", rest[0]);
        return .{ .help = diag.topic };
    }
    return switch (command) {
        .build => if (try build.parse(allocator, rest, diag)) |options| .{ .command = .{ .build = options } } else .{ .help = .build },
        .run => if (try run.parse(allocator, rest, diag)) |options| .{ .command = .{ .run = options } } else .{ .help = .run },
        .sdk => if (try sdk.parse(allocator, rest, diag)) |options| .{ .command = .{ .sdk = options } } else .{ .help = .sdk },
        .doctor => if (try doctor.parse(allocator, rest, diag)) |options| .{ .command = .{ .doctor = options } } else .{ .help = .doctor },
        .create => if (try create.parse(allocator, rest, diag)) |options| .{ .command = .{ .create = options } } else .{ .help = .create },
    };
}

pub fn help(writer: *std.Io.Writer, topic: Topic) !void {
    switch (topic) {
        .build => return build.help(writer),
        .run => return run.help(writer),
        .sdk => return sdk.help(writer),
        .create => return create.help(writer),
        .doctor => return doctor.help(writer),
        .root => {},
    }
    try writer.writeAll("Fushell - Flutter applications on Linux/Wayland.\n\nUsage: fushell [options] [command] [arguments...]");
    try writer.writeAll("\n\nCommands:\n");
    inline for (.{ build, run, sdk, create, doctor }, .{ "build", "run", "sdk", "create", "doctor" }) |module, name|
        try writer.print("  {s:<8} {s}\n", .{ name, module.description });
    try writer.writeByte('\n');
    try clap.help(writer, clap.Help, &root_params, common.help_options);
    try writer.writeAll("\n\nRun 'fushell <command> --help' for more information.\n");
}

test {
    _ = @import("tests.zig");
}
