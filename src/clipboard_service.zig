//! 连接 Flutter 与 Wayland data-control 的进程级剪贴板策略。
//!
//! 写入先更新进程内自有值，再在 wlr-data-control 可用时发布给 compositor。
//! 读取优先采用当前外部 selection，并把其管道作为 EventPump 描述符暴露；任何
//! platform-channel 回调都不会执行阻塞 I/O。无头 compositor 或其他客户端未提供
//! 支持的文本 MIME 时，本地值仍能提供确定性行为。

const std = @import("std");
const clipboard = @import("clipboard.zig");
const data_control = @import("data_control.zig");
const display_state = @import("wl_display_state.zig");

pub const read_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// 拥有 fallback 剪贴板，并借用 DisplayState 的 data-control 客户端。
///
/// 该类型只能由平台线程调用。外部读取在 `pumpReadText` 完成或
/// `cancelReadText` 执行前始终由 DataControl 拥有；关闭期间必须先取消读取，
/// 再销毁 DisplayState。
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

    /// 启动读取的结果。`immediate` 由调用方分配器拥有；`pending` 表示
    /// EventPump 必须监视 `requestFd()` 并持续泵送直至完成。
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
