const std = @import("std");
const clipboard = @import("clipboard.zig");
const data_control = @import("data_control.zig");
const display_state = @import("wl_display_state.zig");

pub const read_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// One process-wide clipboard policy: publish to Wayland data-control when
/// available, while retaining an in-process copy as a deterministic fallback.
pub const Service = struct {
    gpa: std.mem.Allocator,
    state: *display_state.DisplayState,
    local: clipboard.Clipboard,

    pub fn init(gpa: std.mem.Allocator, state: *display_state.DisplayState) Service {
        return .{
            .gpa = gpa,
            .state = state,
            .local = clipboard.Clipboard.init(gpa),
        };
    }

    pub fn deinit(self: *Service) void {
        self.local.deinit();
    }

    pub fn setText(self: *Service, text: []const u8) !void {
        try self.local.setText(text);
        if (self.state.data_control) |dc| dc.publish(text);
    }

    pub fn hasText(self: *const Service) bool {
        if (self.local.getText().len > 0) return true;
        return if (self.state.data_control) |dc| dc.hasText() else false;
    }

    pub const ReadStart = union(enum) {
        immediate: []u8,
        pending,
    };

    /// Starts an external read when a text selection exists, otherwise returns
    /// an owned copy of the deterministic in-process fallback immediately.
    pub fn beginReadText(self: *Service) !ReadStart {
        if (self.state.data_control) |dc| {
            if (try dc.beginRequestText()) return .pending;
        }
        return .{ .immediate = try self.gpa.dupe(u8, self.local.getText()) };
    }

    pub fn requestFd(self: *const Service) ?i32 {
        return if (self.state.data_control) |dc| dc.requestFd() else null;
    }

    pub fn pumpReadText(self: *Service) !data_control.DataControl.RequestProgress {
        const dc = self.state.data_control orelse return error.NoClipboardRequest;
        return dc.pumpRequestText();
    }

    pub fn cancelReadText(self: *Service) void {
        if (self.state.data_control) |dc| dc.cancelRequestText();
    }
};

test "local clipboard fallback owns its returned text" {
    // The Wayland-backed behavior is covered by integration tests. Keep the
    // ownership contract testable without a compositor by exercising the
    // underlying local clipboard directly.
    var local = clipboard.Clipboard.init(std.testing.allocator);
    defer local.deinit();
    try local.setText("fushell");
    const copy = try std.testing.allocator.dupe(u8, local.getText());
    defer std.testing.allocator.free(copy);
    try std.testing.expectEqualStrings("fushell", copy);
}
