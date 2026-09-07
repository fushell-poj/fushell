//! Fushell process entry point: parse a typed command, then execute it.
//! Parsing and help never discover Flutter or perform project I/O.
const std = @import("std");
const cli = @import("cli");
const build_command = @import("commands/build.zig");
const run_command = @import("commands/run.zig");
const sdk_command = @import("commands/sdk.zig");

pub fn main(init: std.process.Init) void {
    // Return through execute() before exiting so all command defers run.
    const status = execute(init) catch |err| {
        std.log.err("fushell failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    if (status != 0) std.process.exit(status);
}

fn execute(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(arena);
    const command_args = if (process_args.len == 0) process_args else process_args[1..];
    const args = try arena.alloc([]const u8, command_args.len);
    for (command_args, args) |arg, *destination| destination.* = arg;

    var diagnostic: cli.Diagnostic = .{};
    const command = cli.parse(init.gpa, args, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stderr().writer(init.io, &buffer);
        try diagnostic.report(&writer.interface, err);
        try writer.interface.flush();
        return 2;
    };
    return dispatch(init, command) catch |err| {
        if (err == error.UserInterrupt) return 130;
        std.log.err("fushell {s} failed: {s}", .{ @tagName(command), @errorName(err) });
        return 1;
    };
}

fn dispatch(init: std.process.Init, command: cli.Command) !u8 {
    switch (command) {
        .help => |topic| {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writer(init.io, &buffer);
            try cli.help(&writer.interface, topic);
            try writer.interface.flush();
        },
        .build => |options| try build_command.execute(init, options),
        .run => |options| return run_command.execute(init, options),
        .sdk => |options| try sdk_command.execute(init, options),
    }
    return 0;
}

// Keep the tests that moved with the command implementations reachable.
test {
    _ = run_command;
    _ = sdk_command;
}
