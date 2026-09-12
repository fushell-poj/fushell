//! Physical button accounting is independent of Flutter's supported button mask.
//! Unsupported buttons still make a press a chord, so they cannot mint grab input.
const std = @import("std");

pub const Buttons = struct {
    held: [32]u32 = undefined,
    owners: [32]usize = undefined,
    count: usize = 0,
    overflow: bool = false,

    /// Returns true only for a genuine zero-buttons -> one-button transition.
    pub fn update(self: *Buttons, code: u32, pressed: bool, owner: usize) bool {
        const found = std.mem.indexOfScalar(u32, self.held[0..self.count], code);
        if (!pressed) {
            if (found) |index| {
                self.count -= 1;
                self.held[index] = self.held[self.count];
                self.owners[index] = self.owners[self.count];
            }
            return false;
        }
        if (found != null or self.overflow) return false;
        if (self.count == self.held.len) {
            // Cannot establish that every untracked button was released. Remain
            // ineligible until the native pointer/seat resets, rather than guess.
            self.overflow = true;
            return false;
        }
        const first = self.count == 0;
        self.held[self.count] = code;
        self.owners[self.count] = owner;
        self.count += 1;
        return first;
    }

    /// A destroyed source cannot deliver its remaining releases. Retire only its
    /// known buttons; overflow remains fail-closed until a pointer/seat reset.
    pub fn retireSurface(self: *Buttons, owner: usize) void {
        var index: usize = 0;
        while (index < self.count) {
            if (self.owners[index] == owner) {
                self.count -= 1;
                self.held[index] = self.held[self.count];
                self.owners[index] = self.owners[self.count];
            } else {
                index += 1;
            }
        }
    }

    /// Transfer only the still-held trigger selected by a validated grab lease.
    /// A released trigger or a code owned by another surface is a no-op.
    pub fn transfer(self: *Buttons, code: u32, source: usize, target: usize) void {
        const index = std.mem.indexOfScalar(u32, self.held[0..self.count], code) orelse return;
        if (self.owners[index] == source) self.owners[index] = target;
    }

    pub fn reset(self: *Buttons) void {
        self.* = .{};
    }
};

test "unsupported held button prevents first-button input credentials" {
    var buttons: Buttons = .{};
    try std.testing.expect(buttons.update(0x113, true, 1));
    try std.testing.expect(!buttons.update(0x111, true, 2));
    _ = buttons.update(0x113, false, 2);
    _ = buttons.update(0x111, false, 1);
    try std.testing.expect(buttons.update(0x111, true, 1));
    try std.testing.expect(!buttons.update(0x111, true, 2));
}

test "untracked button overflow fails closed until pointer or seat reset" {
    var buttons: Buttons = .{};
    for (0..33) |code| _ = buttons.update(@intCast(code), true, 1);
    for (0..33) |code| _ = buttons.update(@intCast(code), false, 1);
    buttons.retireSurface(1);
    try std.testing.expect(!buttons.update(0x111, true, 2));
    buttons.reset();
    try std.testing.expect(buttons.update(0x111, true, 2));
}

test "retiring a held source recovers without a release and preserves live owners" {
    var buttons: Buttons = .{};
    try std.testing.expect(buttons.update(0x110, true, 1));
    buttons.retireSurface(1);
    try std.testing.expect(buttons.update(0x111, true, 2));
    // Another live source remains held across retirement and focus changes.
    try std.testing.expect(!buttons.update(0x113, true, 3));
    buttons.retireSurface(2);
    buttons.retireSurface(99);
    try std.testing.expect(!buttons.update(0x111, true, 2));
    _ = buttons.update(0x113, false, 2);
    _ = buttons.update(0x111, false, 3);
    try std.testing.expect(buttons.update(0x111, true, 2));
}
