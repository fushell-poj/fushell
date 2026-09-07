//! Process termination status is distinct from individual command results.
const std = @import("std");

pub const Status = struct {
    requested: ?u8 = null,

    /// Record the first valid process exit request, including a deferred exit.
    pub fn request(self: *Status, code: i64) !void {
        if (code < 0 or code > 255) return error.InvalidExitCode;
        if (self.requested == null) self.requested = @intCast(code);
    }

    /// Normal completion without an explicit exit request succeeds.
    pub fn value(self: Status) u8 {
        return self.requested orelse 0;
    }
};

test "process exit retains a nonzero code across deferred completion" {
    var status: Status = .{};
    try std.testing.expectEqual(@as(u8, 0), status.value());
    try status.request(7);
    try status.request(0);
    try std.testing.expectEqual(@as(u8, 7), status.value());
    try std.testing.expectError(error.InvalidExitCode, status.request(256));
    try std.testing.expectError(error.InvalidExitCode, status.request(-1));
}
