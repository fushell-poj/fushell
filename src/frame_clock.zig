//! Bounded software frame-clock fallback. This is NOT compositor VSync: it paces
//! requested frames at 60 Hz until a display-timing backend is implemented.
const std = @import("std");

pub const interval_ns: u64 = 16_666_667;

pub const Clock = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    batons: [32]isize = undefined,
    count: usize = 0,
    deadline: ?u64 = null,
    failed: bool = false,

    pub const Frame = struct { baton: isize, start: u64, target: u64 };

    /// Queue a baton without calling Flutter reentrantly from its VSync callback.
    /// Excess requests become a visible fatal state, never silent dropped work.
    pub fn request(self: *Clock, baton: isize, now: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == self.batons.len) {
            self.failed = true;
            return;
        }
        self.batons[self.count] = baton;
        self.count += 1;
        if (self.deadline == null) self.deadline = now +| interval_ns;
    }

    /// Take one due baton on the platform thread, then invoke Flutter unlocked.
    pub fn takeDue(self: *Clock, now: u64) !?Frame {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failed) return error.VsyncQueueOverflow;
        const deadline = self.deadline orelse return null;
        if (now < deadline) return null;
        const baton = self.batons[0];
        self.count -= 1;
        std.mem.copyForwards(isize, self.batons[0..self.count], self.batons[1 .. self.count + 1]);
        if (self.count == 0) self.deadline = null;
        return .{ .baton = baton, .start = now, .target = now +| interval_ns };
    }

    /// A pending baton supplies a poll deadline; idle engines do not wake at 60 Hz.
    pub fn timeoutMs(self: *Clock, now: u64) i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failed) return 0;
        const deadline = self.deadline orelse return -1;
        if (deadline <= now) return 0;
        return @intCast(@min(((deadline - now) +| 999_999) / 1_000_000, std.math.maxInt(i32)));
    }
};

test "frame requests wait for a deadline and idle clocks do not poll" {
    var clock: Clock = .{ .io = std.testing.io };
    try std.testing.expectEqual(@as(i32, -1), clock.timeoutMs(0));
    clock.request(42, 100);
    try std.testing.expect((try clock.takeDue(100)) == null);
    try std.testing.expect(clock.timeoutMs(100) > 0);
    const frame = (try clock.takeDue(100 + interval_ns)).?;
    try std.testing.expectEqual(@as(isize, 42), frame.baton);
    try std.testing.expect(frame.target > frame.start);
    try std.testing.expectEqual(@as(i32, -1), clock.timeoutMs(frame.start));
    clock.request(43, frame.start);
    try std.testing.expect((try clock.takeDue(frame.start)) == null);
}

test "batons preserve order and overflow is explicit" {
    var clock: Clock = .{ .io = std.testing.io };
    clock.request(1, 0);
    clock.request(2, 0);
    try std.testing.expectEqual(@as(isize, 1), (try clock.takeDue(interval_ns)).?.baton);
    try std.testing.expectEqual(@as(isize, 2), (try clock.takeDue(interval_ns)).?.baton);
    for (0..33) |n| clock.request(@intCast(n), interval_ns);
    try std.testing.expectError(error.VsyncQueueOverflow, clock.takeDue(2 * interval_ns));
}
