//! Correlates mouse presses with their exact Flutter event, never with a
//! process-global "last serial". Platform-thread owned; no native pointers escape.
const std = @import("std");

pub const max_token: u64 = (1 << 53) - 1;
pub const lifetime_ns: u64 = 5 * std.time.ns_per_s;
pub const Fingerprint = struct { view_id: i64, time_us: u64, device: i32, buttons: i64 };
pub const Seat = struct { identity: usize, epoch: u64 };
pub const Lease = struct { token: u64, parent: i64, seat: Seat, serial: u32, raw_button: u32, source_surface: usize };
const Record = struct {
    fingerprint: Fingerprint,
    lease: Lease,
    created_ns: u64,
    valid: bool = true,
    captured: bool = false,
    consumed: bool = false,
};

pub const Tracker = struct {
    records: [64]?Record = @splat(null),
    next_slot: usize = 0,
    next_token: u64 = 1,

    /// Every new press supersedes previous credentials, including unsupported
    /// buttons and chords. The caller records only an actual first-button down.
    pub fn invalidate(self: *Tracker) void {
        for (&self.records) |*slot| if (slot.*) |*entry| {
            entry.valid = false;
        };
    }

    pub fn invalidateView(self: *Tracker, view_id: i64) void {
        for (&self.records) |*slot| if (slot.*) |*entry| {
            if (entry.lease.parent == view_id) entry.valid = false;
        };
    }

    pub fn record(self: *Tracker, fingerprint: Fingerprint, seat: Seat, serial: u32, raw_button: u32, source_surface: usize, now_ns: u64) void {
        if (seat.identity == 0 or self.next_token > max_token) return;
        self.records[self.next_slot] = .{
            .fingerprint = fingerprint,
            .lease = .{ .token = self.next_token, .parent = fingerprint.view_id, .seat = seat, .serial = serial, .raw_button = raw_button, .source_surface = source_surface },
            .created_ns = now_ns,
        };
        self.next_slot = (self.next_slot + 1) % self.records.len;
        self.next_token += 1;
    }

    pub fn capture(self: *Tracker, fingerprint: Fingerprint, seat: Seat, now_ns: u64) !u64 {
        var found: ?*Record = null;
        for (&self.records) |*slot| if (slot.*) |*candidate| {
            if (std.meta.eql(candidate.fingerprint, fingerprint)) {
                // Invalidated records still participate: identical millisecond
                // timestamps must not silently select a different native press.
                if (found != null) return error.PopupInputAmbiguous;
                found = candidate;
            }
        };
        const candidate = found orelse return error.PopupInputUnavailable;
        try validate(candidate, seat, now_ns);
        if (candidate.captured) return error.PopupInputAlreadyCaptured;
        candidate.captured = true;
        return candidate.lease.token;
    }

    pub fn consume(self: *Tracker, token: u64, parent: i64, seat: Seat, now_ns: u64) !Lease {
        const candidate = self.find(token) orelse return error.PopupInputUnavailable;
        try validate(candidate, seat, now_ns);
        if (candidate.lease.parent != parent) return error.PopupInputParentMismatch;
        if (!candidate.captured) return error.PopupInputUnavailable;
        if (candidate.consumed) return error.PopupInputConsumed;
        candidate.consumed = true;
        return candidate.lease;
    }

    /// Recheck a consumed lease immediately before sending grab, after any
    /// nested Wayland dispatch during host initialization.
    pub fn validateLease(self: *Tracker, lease: Lease, seat: Seat, now_ns: u64) !void {
        const candidate = self.find(lease.token) orelse return error.PopupInputUnavailable;
        try validate(candidate, seat, now_ns);
        if (!candidate.consumed or !std.meta.eql(candidate.lease, lease)) return error.PopupInputUnavailable;
    }

    fn find(self: *Tracker, token: u64) ?*Record {
        for (&self.records) |*slot| if (slot.*) |*candidate| {
            if (candidate.lease.token == token) return candidate;
        };
        return null;
    }

    fn validate(candidate: *const Record, seat: Seat, now_ns: u64) !void {
        if (!candidate.valid) return error.PopupInputUnavailable;
        if (seat.identity == 0 or !std.meta.eql(candidate.lease.seat, seat)) return error.PopupInputSeatChanged;
        if (now_ns < candidate.created_ns or now_ns - candidate.created_ns >= lifetime_ns) return error.PopupInputExpired;
    }
};

const press: Fingerprint = .{ .view_id = 7, .time_us = 12000, .device = 0, .buttons = 2 };
const test_seat: Seat = .{ .identity = 1, .epoch = 3 };

test "capture and consumption bind exact event, parent, serial and seat" {
    const seat = test_seat;
    var tracker: Tracker = .{};
    tracker.record(press, seat, 999, 0x111, 17, 100);
    var wrong = press;
    wrong.time_us += 1;
    try std.testing.expectError(error.PopupInputUnavailable, tracker.capture(wrong, seat, 101));
    const token = try tracker.capture(press, seat, 101);
    try std.testing.expectError(error.PopupInputAlreadyCaptured, tracker.capture(press, seat, 102));
    try std.testing.expectError(error.PopupInputParentMismatch, tracker.consume(token, 8, seat, 102));
    const lease = try tracker.consume(token, 7, seat, 102);
    try std.testing.expectEqual(@as(u32, 999), lease.serial);
    try std.testing.expectEqual(@as(u32, 0x111), lease.raw_button);
    try std.testing.expectEqual(@as(usize, 17), lease.source_surface);
    var forged = lease;
    forged.raw_button = 0x110;
    try std.testing.expectError(error.PopupInputUnavailable, tracker.validateLease(forged, seat, 103));
    try std.testing.expectError(error.PopupInputConsumed, tracker.consume(token, 7, seat, 103));
    try tracker.validateLease(lease, seat, 103);
    tracker.invalidate();
    try std.testing.expectError(error.PopupInputUnavailable, tracker.validateLease(lease, seat, 104));
}

test "same timestamp duplicates remain ambiguous after invalidation" {
    const seat = test_seat;
    var tracker: Tracker = .{};
    tracker.record(press, seat, 5, 0x111, 17, 100);
    tracker.invalidate();
    tracker.record(press, seat, 6, 0x111, 17, 101);
    try std.testing.expectError(error.PopupInputAmbiguous, tracker.capture(press, seat, 102));
}

test "expiry, seat replacement and parent destruction invalidate credentials" {
    const seat = test_seat;
    var tracker: Tracker = .{};
    tracker.record(press, seat, 1, 0x111, 17, 100);
    try std.testing.expectError(error.PopupInputExpired, tracker.capture(press, seat, 100 + lifetime_ns));
    try std.testing.expectError(error.PopupInputSeatChanged, tracker.capture(press, .{ .identity = 1, .epoch = 4 }, 101));
    tracker.invalidateView(7);
    try std.testing.expectError(error.PopupInputUnavailable, tracker.capture(press, seat, 102));
}

test "bounded history evicts credentials without reusing tokens" {
    const seat = test_seat;
    var tracker: Tracker = .{};
    tracker.record(press, seat, 1, 0x111, 17, 0);
    const token = try tracker.capture(press, seat, 1);
    for (0..64) |n| {
        var other = press;
        other.time_us += n + 1;
        tracker.record(other, seat, 2, 0x111, 17, 2);
    }
    try std.testing.expectError(error.PopupInputUnavailable, tracker.consume(token, 7, seat, 3));
    tracker.next_token = max_token;
    tracker.record(press, seat, 3, 0x111, 17, 4);
    try std.testing.expectEqual(max_token, try tracker.capture(press, seat, 5));
    tracker.record(press, seat, 4, 0x111, 17, 6);
    try std.testing.expectEqual(max_token + 1, tracker.next_token);
}
