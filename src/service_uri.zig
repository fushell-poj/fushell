//! 带认证 Dart VM Service URI 的线程安全交接。
//!
//! 引擎日志回调发布 URI，CLI worker 线程轮询它以启动热重载、Flutter attach 或
//! DevTools。固定缓冲区避免在回调内分配。超大值会被拒绝而不是截断，因为不完整的
//! 认证 token 无法使用。

const std = @import("std");

/// 由 runtime I/O mutex 保护的单 URI 槽。
///
/// `get` 把内容复制到调用方存储，调用方不会持有指向可变共享状态的视图。启动后或
/// clear 后，零长度表示“尚不可用”。
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
