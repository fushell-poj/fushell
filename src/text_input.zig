//! Flutter `flutter/textinput` 编辑状态机。
//!
//! Flutter 以 UTF-16 code-unit offset 报告 selection/composing range，本模块则在
//! UTF-8 文本中存储 byte offset，并在每个协议边界转换。物理按键与 IME
//! preedit/commit 都修改同一个 `Client`，随后由它发送
//! `TextInputClient.updateEditingState` 消息。每个 native 窗口拥有一个 client，view
//! 之间不共享状态。

const std = @import("std");

/// 使用 byte index 表示 selection 与 composing range 的 UTF-8 编辑缓冲区。
/// composing range 为 `-1, -1` 表示当前没有活动 IME composition。
pub const EditingState = struct {
    text: std.ArrayListUnmanaged(u8) = .empty,
    selection_base: i64 = 0,
    selection_extent: i64 = 0,
    composing_start: i64 = -1,
    composing_end: i64 = -1,
};

pub const SendFn = *const fn (client_id: i64, msg: []const u8, context: ?*anyopaque) void;

/// 每个 view 独立的 text-input 状态与 framework 消息回调。
///
/// 所有修改都限制在平台线程。geometry 以 Flutter 根坐标缓存，以便 scale 或 view
/// 位置变化时重新计算 Wayland IME cursor rectangle。`deinit` 释放可增长文本缓冲区。
pub const Client = struct {
    gpa: std.mem.Allocator,
    client_id: i64 = -1,
    send_fn: ?SendFn = null,
    send_context: ?*anyopaque = null,
    active: bool = false,
    multiline: bool = false,
    input_action: []const u8 = "done",
    state: EditingState = .{},
    // EditableText 几何 (引擎 TextInput.setEditableSizeAndTransform 提供):
    // 局部 → Flutter root 变换矩阵 (行主序 16 个 double)。
    has_transform: bool = false,
    transform: [16]f64 = [_]f64{0} ** 16,
    // composing/光标矩形 (引擎 TextInput.setMarkedTextRect 提供, 局部坐标)。
    has_marked_rect: bool = false,
    marked_rect_x: f64 = 0,
    marked_rect_y: f64 = 0,
    marked_rect_w: f64 = 0,
    marked_rect_h: f64 = 0,
    has_caret_rect: bool = false,
    caret_rect_x: f64 = 0,
    caret_rect_y: f64 = 0,

    pub fn init(gpa: std.mem.Allocator) Client {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Client) void {
        self.state.text.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }

    pub fn sendUpdate(self: *Client) void {
        const msg = self.buildUpdateMessageAlloc() catch |err| {
            std.debug.print("[error] Failed to encode text-input update: {s}\n", .{@errorName(err)});
            return;
        };
        defer self.gpa.free(msg);
        if (self.send_fn) |send| send(self.client_id, msg, self.send_context);
    }

    pub fn clear(self: *Client) void {
        self.active = false;
        self.client_id = -1;
        self.multiline = false;
        self.input_action = "done";
        self.state.text.clearRetainingCapacity();
        self.state.selection_base = 0;
        self.state.selection_extent = 0;
    }

    /// 应用引擎发来的 setEditingState (程序化赋值 / 初始状态)。
    pub fn applyEditingState(self: *Client, text: []const u8, base: i64, extent: i64) !void {
        self.state.text.clearRetainingCapacity();
        try self.state.text.appendSlice(self.gpa, text);
        // Flutter 的 selection 是 UTF-16 code unit, 转成字节偏移存储。
        self.state.selection_base = utf16ToByte(self.state.text.items, base);
        self.state.selection_extent = utf16ToByte(self.state.text.items, extent);
        // text 被覆盖 — 旧组合区失效。
        self.state.composing_start = -1;
        self.state.composing_end = -1;
    }

    /// Flutter 的 selection 是 UTF-16 code unit 偏移, 宿主 buffer 是 UTF-8 字节。
    /// UTF-16 code unit 偏移 → UTF-8 字节偏移。
    fn utf16ToByte(text: []const u8, utf16_off: i64) i64 {
        if (utf16_off <= 0) return 0;
        var byte: i64 = 0;
        var units: i64 = 0;
        while (byte < text.len and units < utf16_off) {
            const n = std.unicode.utf8ByteSequenceLength(text[@intCast(byte)]) catch 1;
            units += if (n == 4) 2 else 1; // 增补平面 = 2 个 UTF-16 unit
            byte += n;
        }
        return byte;
    }

    /// UTF-8 字节偏移 → UTF-16 code unit 偏移。
    fn byteToUtf16(text: []const u8, byte_off: i64) i64 {
        if (byte_off <= 0) return 0;
        var byte: i64 = 0;
        var units: i64 = 0;
        while (byte < byte_off and byte < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[@intCast(byte)]) catch 1;
            units += if (n == 4) 2 else 1;
            byte += n;
        }
        return units;
    }

    fn selectionRange(self: *const Client) struct { start: usize, end: usize } {
        const len: i64 = @intCast(self.state.text.items.len);
        var start = @min(self.state.selection_base, self.state.selection_extent);
        var end = @max(self.state.selection_base, self.state.selection_extent);
        start = @min(@max(start, 0), len);
        end = @min(@max(end, 0), len);
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    /// 插入文本到 selection 处 (替换选中区域), 光标移到插入点后。
    /// IME preedit: 设置组合区 (composing)。text=null 清除组合。
    pub fn setComposing(self: *Client, text: ?[]const u8, cursor_begin: i32, cursor_end: i32) !void {
        // 先移除旧组合区 (preedit 更新是替换, 不是追加)。
        _ = try self.removeComposingRegion();
        if (text) |t| {
            // 第一段 preedit 必须替换当前 selection；selection_base 可能位于
            // 选区末端（例如 Ctrl+A 的反向 selection），不能直接当插入点。
            const sel = self.selectionRange();
            try self.state.text.replaceRange(self.gpa, sel.start, sel.end - sel.start, t);
            const base = sel.start;
            const end: i64 = @intCast(base + t.len);
            self.state.selection_base = end;
            self.state.selection_extent = end;
            // 组合高亮区 = 插入的 preedit 文本。
            self.state.composing_start = @intCast(base);
            self.state.composing_end = end;
            _ = cursor_begin;
            _ = cursor_end;
        } else {
            self.state.composing_start = -1;
            self.state.composing_end = -1;
        }
        self.sendUpdate();
    }

    /// 删除当前组合区 (若有), selection 回退到组合区起点。返回删除的字节数。
    fn removeComposingRegion(self: *Client) !usize {
        if (self.state.composing_start < 0 or self.state.composing_end <= self.state.composing_start) return 0;
        // clamp 到文本长度 — applyEditingState (Flutter setEditingState 回传)
        // 可能重置 text 但残留旧 composing 偏移。
        const len = self.state.text.items.len;
        const cs = @min(@as(usize, @intCast(@max(self.state.composing_start, 0))), len);
        const ce = @min(@as(usize, @intCast(@max(self.state.composing_end, 0))), len);
        if (ce <= cs) {
            self.state.composing_start = -1;
            self.state.composing_end = -1;
            return 0;
        }
        try self.state.text.replaceRange(self.gpa, cs, ce - cs, "");
        self.state.composing_start = -1;
        self.state.composing_end = -1;
        // selection 在组合区之后 → 前移; 在组合区内 → 移到起点。
        if (self.state.selection_base >= @as(i64, @intCast(ce))) {
            self.state.selection_base -= @intCast(ce - cs);
            self.state.selection_extent -= @intCast(ce - cs);
        } else if (self.state.selection_base > @as(i64, @intCast(cs))) {
            self.state.selection_base = @intCast(cs);
            self.state.selection_extent = @intCast(cs);
        }
        return ce - cs;
    }

    /// IME delete_surrounding: 按 UTF-8 字节删除光标前 before / 后 after。
    pub fn deleteSurrounding(self: *Client, before: u32, after: u32) !void {
        const pos: usize = @intCast(@max(self.state.selection_base, 0));
        const start = pos -| @as(usize, before);
        const end = @min(pos + @as(usize, after), self.state.text.items.len);
        try self.state.text.replaceRange(self.gpa, start, end - start, "");
        const s: i64 = @intCast(start);
        self.state.selection_base = s;
        self.state.selection_extent = s;
        self.sendUpdate();
    }

    pub fn insertText(self: *Client, bytes: []const u8) !void {
        // IME commit: 先移除组合区 (preedit 文本被提交文本替换)。
        _ = try self.removeComposingRegion();
        // selectionRange() 已 clamp 到 [0, len] — 防止 applyEditingState
        // 的 UTF-16 转换在竞态下产生越界偏移。
        const sel = self.selectionRange();
        try self.state.text.replaceRange(self.gpa, sel.start, sel.end - sel.start, bytes);
        const pos: i64 = @intCast(sel.start + bytes.len);
        self.state.selection_base = pos;
        self.state.selection_extent = pos;
        self.sendUpdate();
    }

    /// Backspace: 删除选中区域, 或光标前一个 UTF-8 字符。
    pub fn backspace(self: *Client) !void {
        const sel = self.selectionRange();
        if (sel.start != sel.end) {
            try self.state.text.replaceRange(self.gpa, sel.start, sel.end - sel.start, "");
            const pos: i64 = @intCast(sel.start);
            self.state.selection_base = pos;
            self.state.selection_extent = pos;
            return;
        }
        if (sel.start == 0) return;
        // 向前找 UTF-8 字符边界 (连续字节 10xxxxxx 是 continuation)。
        // 注意: 不能用 `while (i > 0) : (i -= 1)` — break 时 continue 表达式不执行,
        // i 停在原位导致 replaceRange 删 0 个字符。改为循环体内递减。
        var i = sel.start;
        while (i > 0) {
            i -= 1;
            if ((self.state.text.items[i] & 0xC0) != 0x80) break;
        }
        try self.state.text.replaceRange(self.gpa, i, sel.start - i, "");
        const pos: i64 = @intCast(i);
        self.state.selection_base = pos;
        self.state.selection_extent = pos;
    }

    /// Delete: 删除选中区域或光标后一个字符。
    pub fn deleteForward(self: *Client) !void {
        const sel = self.selectionRange();
        if (sel.start != sel.end) {
            try self.state.text.replaceRange(self.gpa, sel.start, sel.end - sel.start, "");
            const pos: i64 = @intCast(sel.start);
            self.state.selection_base = pos;
            self.state.selection_extent = pos;
            return;
        }
        if (sel.end >= self.state.text.items.len) return;
        var i = sel.end + 1;
        while (i < self.state.text.items.len and (self.state.text.items[i] & 0xC0) == 0x80) : (i += 1) {}
        try self.state.text.replaceRange(self.gpa, sel.end, i - sel.end, "");
        const pos: i64 = @intCast(sel.end);
        self.state.selection_base = pos;
        self.state.selection_extent = pos;
    }

    pub fn moveCursor(self: *Client, direction: enum { left, right, home, end }) void {
        const len: i64 = @intCast(self.state.text.items.len);
        var pos = @min(@max(self.state.selection_base, 0), len);
        switch (direction) {
            .left => {
                if (pos > 0) {
                    var i = pos;
                    while (i > 0) {
                        i -= 1;
                        if ((self.state.text.items[@intCast(i)] & 0xC0) != 0x80) break;
                    }
                    pos = i;
                }
            },
            .right => {
                if (pos < len) {
                    const n = std.unicode.utf8ByteSequenceLength(self.state.text.items[@intCast(pos)]) catch 1;
                    pos += n;
                }
            },
            .home => pos = 0,
            .end => pos = len,
        }
        self.state.selection_base = pos;
        self.state.selection_extent = pos;
    }

    /// 构造 updateEditingState 消息 (JSON, 调用方负责释放返回值)。
    /// Flutter 的 TextEditingValue.fromJSON 使用扁平 selection 字段。
    pub fn buildUpdateMessageAlloc(self: *const Client) ![]u8 {
        const text = self.state.text.items;
        const escaped = try jsonEscape(self.gpa, text);
        defer self.gpa.free(escaped);
        const sel_base = byteToUtf16(text, self.state.selection_base);
        const sel_ext = byteToUtf16(text, self.state.selection_extent);
        const comp_base = if (self.state.composing_start >= 0) byteToUtf16(text, self.state.composing_start) else -1;
        const comp_ext = if (self.state.composing_end >= 0) byteToUtf16(text, self.state.composing_end) else -1;
        return std.fmt.allocPrint(self.gpa,
            \\{{"method":"TextInputClient.updateEditingState","args":[{d},{{"text":"{s}","selectionBase":{d},"selectionExtent":{d},"selectionAffinity":"downstream","selectionIsDirectional":false,"composingBase":{d},"composingExtent":{d}}}]}}
        , .{ self.client_id, escaped, sel_base, sel_ext, comp_base, comp_ext });
    }

    /// 构造 performAction 消息。
    pub fn buildActionMessage(self: *const Client, out: []u8) ![]const u8 {
        return std.fmt.bufPrint(out,
            \\{{"method":"TextInputClient.performAction","args":[{d},"{s}"]}}
        , .{ self.client_id, self.input_action });
    }
};

/// JSON 中字符串转义 (updateEditingState 里 text 可能含引号/反斜杠/换行)。
pub fn jsonEscape(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (input) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            0...0x1F => {
                var hexbuf: [8]u8 = undefined;
                const hex = try std.fmt.bufPrint(&hexbuf, "\\u{x:0>4}", .{ch});
                try out.appendSlice(gpa, hex);
            },
            else => try out.append(gpa, ch),
        }
    }
    return out.toOwnedSlice(gpa);
}

test "IME preedit replaces forward selection" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    try client.applyEditingState("existing text", 0, 13);
    try client.setComposing("ni", 0, 0);

    try std.testing.expectEqualStrings("ni", client.state.text.items);
    try std.testing.expectEqual(@as(i64, 0), client.state.composing_start);
    try std.testing.expectEqual(@as(i64, 2), client.state.composing_end);
}

test "IME preedit replaces reverse selection and commit replaces preedit" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    try client.applyEditingState("existing text", 13, 0);
    try client.setComposing("ni", 0, 0);
    try client.insertText("你");

    try std.testing.expectEqualStrings("你", client.state.text.items);
    try std.testing.expectEqual(@as(i64, 3), client.state.selection_base);
    try std.testing.expectEqual(@as(i64, 3), client.state.selection_extent);
    try std.testing.expectEqual(@as(i64, -1), client.state.composing_start);
    try std.testing.expectEqual(@as(i64, -1), client.state.composing_end);
}
