//! Owned C-compatible argv storage with one cleanup path.
const std = @import("std");

pub const Arguments = struct {
    allocator: std.mem.Allocator,
    strings: [][:0]u8,
    initialized: usize = 0,

    /// Copy arguments; any partial allocation is reclaimed on failure.
    pub fn init(allocator: std.mem.Allocator, values: []const []const u8) !Arguments {
        var result: Arguments = .{ .allocator = allocator, .strings = try allocator.alloc([:0]u8, values.len) };
        errdefer result.deinit();
        for (values, 0..) |value, index| {
            result.strings[index] = try allocator.dupeZ(u8, value);
            result.initialized += 1;
        }
        return result;
    }

    /// Release both the initialized strings and their container exactly once.
    pub fn deinit(self: *Arguments) void {
        for (self.strings[0..self.initialized]) |value| self.allocator.free(value);
        self.allocator.free(self.strings);
        self.* = undefined;
    }
};

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var values = try Arguments.init(allocator, &.{ "one", "two", "" });
    defer values.deinit();
    try std.testing.expectEqualStrings("two", values.strings[1]);
}

test "argv is reclaimed on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
