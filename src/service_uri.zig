const std = @import("std");

pub const State = struct {
    mutex: std.Io.Mutex = .init,
    uri: [512]u8 = undefined,
    len: usize = 0,

    pub fn clear(self: *State, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.len = 0;
    }

    pub fn set(self: *State, io: std.Io, value: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (value.len > self.uri.len) return;
        @memcpy(self.uri[0..value.len], value);
        self.len = value.len;
    }

    pub fn get(self: *State, io: std.Io, out: []u8) ?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.len == 0 or self.len > out.len) return null;
        @memcpy(out[0..self.len], self.uri[0..self.len]);
        return out[0..self.len];
    }
};

test "service URI state copies values across callers" {
    var state: State = .{};
    state.set(std.testing.io, "http://127.0.0.1:8181/token=/");
    var output: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8181/token=/",
        state.get(std.testing.io, &output).?,
    );
    state.clear(std.testing.io);
    try std.testing.expect(state.get(std.testing.io, &output) == null);
}
