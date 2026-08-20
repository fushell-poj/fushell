//! flutter/platform 通道的剪贴板实现。
//!
//! 引擎 → 宿主 (flutter/platform channel):
//!   Clipboard.setData  {"text": "..."}
//!   Clipboard.getData  {"format": "text/plain"}
//!
//! 宿主响应 (JSON 字符串, 非 {method,args} 格式):
//!   setData 成功 → ""
//!   getData 成功 → {"text": "..."} ; 空剪贴板 → {}

const std = @import("std");

pub const Clipboard = struct {
    gpa: std.mem.Allocator,
    /// 进程内剪贴板副本 (data-control 可用时同步系统, 不可用时兜底)。
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
