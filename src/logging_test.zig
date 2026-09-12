//! Standalone, non-GUI regression: zig run src/logging_test.zig -O <mode>
//! Run in Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
//! This needs its own root: zig test replaces std_options.logFn with its runner.
const std = @import("std");
const builtin = @import("builtin");
const logging = @import("logging.zig");

// Exercise std.log dispatch with the production policy, but no stderr output.
pub const std_options: std.Options = blk: {
    var options = logging.options;
    options.logFn = capture;
    break :blk options;
};

var counts: [4]usize = @splat(0);

fn capture(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buffer: [128]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    counts[@intFromEnum(level)] += 1;
}

pub fn main() !void {
    try checkScopedFiltering();
    checkDisabledFormatting();
}

fn checkScopedFiltering() !void {
    const diagnostic_enabled = builtin.mode == .Debug;
    inline for (.{ .window, .render, .input, .engine, .wayland, .platform, .application }) |scope| {
        try std.testing.expectEqual(diagnostic_enabled, std.log.logEnabled(.debug, scope));
        try std.testing.expectEqual(diagnostic_enabled, std.log.logEnabled(.info, scope));
        try std.testing.expect(std.log.logEnabled(.warn, scope));
        try std.testing.expect(std.log.logEnabled(.err, scope));

        counts = @splat(0);
        const log = std.log.scoped(scope);
        log.debug("routine {d}", .{1});
        log.info("informational {d}", .{2});
        log.warn("warning {d}", .{3});
        log.err("failure {d}", .{4});
        try std.testing.expectEqual(@as(usize, 1), counts[@intFromEnum(std.log.Level.err)]);
        try std.testing.expectEqual(@as(usize, 1), counts[@intFromEnum(std.log.Level.warn)]);
        const expected: usize = if (diagnostic_enabled) 1 else 0;
        try std.testing.expectEqual(expected, counts[@intFromEnum(std.log.Level.info)]);
        try std.testing.expectEqual(expected, counts[@intFromEnum(std.log.Level.debug)]);
    }
}

fn checkDisabledFormatting() void {
    if (comptime builtin.mode != .Debug) {
        // This cannot be formatted as an integer: compilation succeeds only if
        // std.log discards the diagnostic before instantiating the log sink.
        std.log.scoped(.render).debug("{d}", .{struct {}{}});
    }
}
