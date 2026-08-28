//! 由分配器拥有的进程内剪贴板存储，以及旧版 Flutter JSON 辅助函数。
//!
//! Wayland data-control 不可用时，ClipboardService 使用该存储作为确定性 fallback。
//! JSON 辅助函数只描述 flutter/platform 载荷，不执行协议 I/O，也不能代替系统剪贴板。

const std = @import("std");

/// 由单个分配器拥有的可变 UTF-8 剪贴板值。
///
/// `getText` 返回的切片借用内部缓冲区，下次 `setText` 或 `deinit` 后立即失效。
/// 该类型不包含同步机制，由 ClipboardService 保证只在平台线程使用。
pub const Clipboard = struct {
    gpa: std.mem.Allocator,
    /// 进程本地副本，既作为读取 fallback，也作为发布到 Wayland 的数据源。
    text: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Clipboard {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Clipboard) void {
        self.text.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }

    pub fn setText(self: *Clipboard, bytes: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, bytes);
    }

    pub fn getText(self: *const Clipboard) []const u8 {
        return self.text.items;
    }

    /// 解析 Clipboard.setData 参数 {"text": "..."} → 文本。返回 false = 无 text 字段。
    pub fn parseSetData(gpa: std.mem.Allocator, payload: []const u8) ?[]const u8 {
        var stream = std.json.Scanner.initCompleteInput(gpa, payload);
        defer stream.deinit();
        const value = std.json.parseFromTokenSource(std.json.Value, gpa, &stream, .{}) catch return null;
        defer value.deinit();
        const map = switch (value.value) {
            .object => |m| m,
            else => return null,
        };
        const text = map.get("text") orelse return null;
        return switch (text) {
            .string => |s| s,
            else => null,
        };
    }

    /// 构造 Clipboard.getData 响应 {"text": "..."} (空剪贴板返回 "{}")。
    pub fn buildGetDataResponse(self: *const Clipboard, out: []u8) ![]const u8 {
        if (self.text.items.len == 0) return "{}";
        return std.fmt.bufPrint(out,
            \\{{"text":"{s}"}}
        , .{self.text.items});
    }
};
