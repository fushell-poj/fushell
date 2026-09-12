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
    input_action: []const u8 = "TextInputAction.done",
    owned_input_action: ?[]u8 = null,
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
        if (self.owned_input_action) |action| self.gpa.free(action);
        self.state.text.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }

    pub fn sendUpdate(self: *Client) void {
        const msg = self.buildUpdateMessageAlloc() catch |err| {
            std.log.scoped(.input).err("Failed to encode text-input update: {s}", .{@errorName(err)});
            return;
        };
        defer self.gpa.free(msg);
        if (self.send_fn) |send| send(self.client_id, msg, self.send_context);
    }

    /// Copy configuration strings before their parsed JSON owner is released.
    pub fn setInputAction(self: *Client, action: []const u8) !void {
        const owned = try self.gpa.dupe(u8, action);
        if (self.owned_input_action) |old| self.gpa.free(old);
        self.owned_input_action = owned;
        self.input_action = owned;
    }

    pub fn clear(self: *Client) void {
        if (self.owned_input_action) |action| self.gpa.free(action);
        self.state.text.clearRetainingCapacity();
        self.* = .{
            .gpa = self.gpa,
            .send_fn = self.send_fn,
            .send_context = self.send_context,
            .state = .{ .text = self.state.text },
        };
    }

    /// 应用引擎发来的 setEditingState (程序化赋值 / 初始状态)。
    pub fn applyEditingState(self: *Client, text: []const u8, base: i64, extent: i64) !void {
        return self.applyEditingStateWithComposing(text, base, extent, -1, -1);
    }

    pub fn applyEditingStateWithComposing(
        self: *Client,
        text: []const u8,
        base: i64,
        extent: i64,
        composing_base: i64,
        composing_extent: i64,
    ) !void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        // Stage the replacement so allocation failure and aliased input are safe.
        var replacement: std.ArrayListUnmanaged(u8) = .empty;
        try replacement.appendSlice(self.gpa, text);
        self.state.text.deinit(self.gpa);
        self.state.text = replacement;
        // Flutter 的 selection 是 UTF-16 code unit, 转成字节偏移存储。
        self.state.selection_base = utf16ToByte(self.state.text.items, base);
        self.state.selection_extent = utf16ToByte(self.state.text.items, extent);
        const composing_start = utf16ToByte(self.state.text.items, composing_base);
        const composing_end = utf16ToByte(self.state.text.items, composing_extent);
        // Reject reversed, out-of-bounds, and split-surrogate composition ranges.
        if (composing_base >= 0 and composing_extent >= composing_base and
            byteToUtf16(self.state.text.items, composing_start) == composing_base and
            byteToUtf16(self.state.text.items, composing_end) == composing_extent)
        {
            self.state.composing_start = composing_start;
            self.state.composing_end = composing_end;
        } else {
            self.endComposing();
        }
    }

    /// Flutter 的 selection 是 UTF-16 code unit 偏移, 宿主 buffer 是 UTF-8 字节。
    /// UTF-16 code unit 偏移 → UTF-8 字节偏移。
    fn utf16ToByte(text: []const u8, utf16_off: i64) i64 {
        if (utf16_off < 0) return -1;
        if (utf16_off == 0) return 0;
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
        if (byte_off < 0) return -1;
        if (byte_off == 0) return 0;
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
        if (text) |t| {
            if (!std.unicode.utf8ValidateSlice(t)) return error.InvalidUtf8;
            const sel = self.replacementRange();
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
            const sel = self.replacementRange();
            if (self.state.composing_start >= 0 and self.state.composing_end >= self.state.composing_start and
                self.state.composing_end <= self.state.text.items.len)
            {
                try self.state.text.replaceRange(self.gpa, sel.start, sel.end - sel.start, "");
                self.state.selection_base = @intCast(sel.start);
                self.state.selection_extent = @intCast(sel.start);
            }
            self.endComposing();
        }
        self.sendUpdate();
    }

    /// Preedit and commit replace the whole composition in one fallible operation.
    fn replacementRange(self: *const Client) struct { start: usize, end: usize } {
        const len: i64 = @intCast(self.state.text.items.len);
        if (self.state.composing_start >= 0 and
            self.state.composing_end >= self.state.composing_start and
            self.state.composing_end <= len)
        {
            return .{
                .start = @intCast(self.state.composing_start),
                .end = @intCast(self.state.composing_end),
            };
        }
        const sel = self.selectionRange();
        return .{ .start = sel.start, .end = sel.end };
    }

    fn endComposing(self: *Client) void {
        self.state.composing_start = -1;
        self.state.composing_end = -1;
    }

    /// IME delete_surrounding: 按 UTF-8 字节删除光标前 before / 后 after。
    pub fn deleteSurrounding(self: *Client, before: u32, after: u32) !void {
        const len = self.state.text.items.len;
        const pos: usize = @intCast(@min(@max(self.state.selection_base, 0), @as(i64, @intCast(len))));
        const start = pos -| @as(usize, before);
        const end = @min(pos +| @as(usize, after), len);
        // Wayland offsets are bytes, but must not split a UTF-8 code point.
        if ((start < len and (self.state.text.items[start] & 0xC0) == 0x80) or
            (end < len and (self.state.text.items[end] & 0xC0) == 0x80)) return error.InvalidRange;
        try self.state.text.replaceRange(self.gpa, start, end - start, "");
        self.endComposing();
        const s: i64 = @intCast(start);
        self.state.selection_base = s;
        self.state.selection_extent = s;
        self.sendUpdate();
    }

    pub fn insertText(self: *Client, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const sel = self.replacementRange();
        try self.state.text.replaceRange(self.gpa, sel.start, sel.end - sel.start, bytes);
        self.endComposing();
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
            self.endComposing();
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
        self.endComposing();
        const pos: i64 = @intCast(i);
        self.state.selection_base = pos;
        self.state.selection_extent = pos;
    }

    /// Delete: 删除选中区域或光标后一个字符。
    pub fn deleteForward(self: *Client) !void {
        const sel = self.selectionRange();
        if (sel.start != sel.end) {
            try self.state.text.replaceRange(self.gpa, sel.start, sel.end - sel.start, "");
            self.endComposing();
            const pos: i64 = @intCast(sel.start);
            self.state.selection_base = pos;
            self.state.selection_extent = pos;
            return;
        }
        if (sel.end >= self.state.text.items.len) return;
        var i = sel.end + 1;
        while (i < self.state.text.items.len and (self.state.text.items[i] & 0xC0) == 0x80) : (i += 1) {}
        try self.state.text.replaceRange(self.gpa, sel.end, i - sel.end, "");
        self.endComposing();
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
        var writer = std.Io.Writer.fixed(out);
        std.json.Stringify.value(.{
            .method = "TextInputClient.performAction",
            .args = .{ self.client_id, self.input_action },
        }, .{}, &writer) catch return error.NoSpaceLeft;
        return writer.buffered();
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

test "action ownership survives source reuse, self assignment, and clear" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    var source = "TextInputAction.search".*;
    try client.setInputAction(&source);
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("TextInputAction.search", client.input_action);
    try client.setInputAction(client.input_action);
    try std.testing.expectEqualStrings("TextInputAction.search", client.input_action);
    // Public literal assignments must not change which allocation gets freed.
    client.input_action = "TextInputAction.next";
    client.clear();
    client.clear();
    try std.testing.expectEqualStrings("TextInputAction.done", client.input_action);
    try std.testing.expect(client.owned_input_action == null);
}

test "action encoding escapes JSON and reports insufficient output" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    client.client_id = 42;
    try client.setInputAction("quote\" slash\\ newline\n");
    var out: [256]u8 = undefined;
    const msg = try client.buildActionMessage(&out);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, msg, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("args").?.array.items;
    try std.testing.expectEqual(@as(i64, 42), args[0].integer);
    try std.testing.expectEqualStrings(client.input_action, args[1].string);
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, client.buildActionMessage(&tiny));
}

test "clear resets composition and geometry while preserving transport" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    const callback = struct {
        fn send(_: i64, _: []const u8, _: ?*anyopaque) void {}
    }.send;
    client.send_fn = callback;
    client.send_context = &client;
    client.active = true;
    client.multiline = true;
    client.client_id = 9;
    client.has_transform = true;
    client.transform[0] = 2;
    client.has_caret_rect = true;
    client.caret_rect_x = 10;
    try client.setComposing("你", 0, 0);
    const capacity = client.state.text.capacity;
    client.clear();
    try std.testing.expect(!client.active and !client.multiline);
    try std.testing.expectEqual(@as(i64, -1), client.client_id);
    try std.testing.expect(!client.has_transform and !client.has_caret_rect);
    try std.testing.expectEqual(@as(f64, 0), client.transform[0]);
    try std.testing.expectEqual(@as(f64, 0), client.caret_rect_x);
    try std.testing.expectEqual(@as(i64, -1), client.state.composing_start);
    try std.testing.expectEqual(@as(i64, -1), client.state.composing_end);
    try std.testing.expectEqual(capacity, client.state.text.capacity);
    try std.testing.expectEqual(@as(usize, 0), client.state.text.items.len);
    try std.testing.expect(client.send_fn == callback);
    try std.testing.expect(client.send_context == @as(?*anyopaque, &client));
}

test "UTF16 offsets round trip supplementary characters and invalid selection" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    try client.applyEditingState("a😀你z", 3, 4);
    try std.testing.expectEqual(@as(i64, 5), client.state.selection_base);
    try std.testing.expectEqual(@as(i64, 8), client.state.selection_extent);
    const msg = try client.buildUpdateMessageAlloc();
    defer std.testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, msg, .{});
    defer parsed.deinit();
    const state = parsed.value.object.get("args").?.array.items[1].object;
    try std.testing.expectEqual(@as(i64, 3), state.get("selectionBase").?.integer);
    try std.testing.expectEqual(@as(i64, 4), state.get("selectionExtent").?.integer);
    try client.applyEditingState("😀", -1, -1);
    try std.testing.expectEqual(@as(i64, -1), client.state.selection_base);
    try std.testing.expectEqual(@as(i64, -1), Client.byteToUtf16("😀", -1));
    // An offset within a surrogate pair snaps to the next code point boundary.
    try std.testing.expectEqual(@as(i64, 4), Client.utf16ToByte("😀", 1));
    try std.testing.expectEqual(@as(i64, 4), Client.utf16ToByte("😀", 100));
}

test "keyboard deletion preserves complete UTF8 characters and clears composition" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    try client.applyEditingState("a你😀z", 4, 4);
    try client.backspace();
    try std.testing.expectEqualStrings("a你z", client.state.text.items);
    try client.backspace();
    try std.testing.expectEqualStrings("az", client.state.text.items);
    try client.applyEditingState("a你😀z", 1, 1);
    try client.deleteForward();
    try std.testing.expectEqualStrings("a😀z", client.state.text.items);
    try client.deleteForward();
    try std.testing.expectEqualStrings("az", client.state.text.items);
    try client.applyEditingState("a你😀z", 4, 1);
    try client.backspace();
    try std.testing.expectEqualStrings("az", client.state.text.items);
    try client.setComposing("你", 0, 0);
    try client.backspace();
    try std.testing.expectEqualStrings("az", client.state.text.items);
    try std.testing.expectEqual(@as(i64, -1), client.state.composing_end);
}

test "surrounding deletion rejects split UTF8 and clamps stale cursor" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    try client.applyEditingState("a你z", 2, 2);
    try std.testing.expectError(error.InvalidRange, client.deleteSurrounding(1, 0));
    try std.testing.expectEqualStrings("a你z", client.state.text.items);
    try client.deleteSurrounding(3, 1);
    try std.testing.expectEqualStrings("a", client.state.text.items);
    client.state.selection_base = 100;
    try client.deleteSurrounding(1, 0);
    try std.testing.expectEqualStrings("", client.state.text.items);
}

test "preedit update and cancellation replace only the composing range" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    try client.applyEditingState("az", 1, 1);
    try client.setComposing("ni", 0, 0);
    try client.setComposing("你", 0, 0);
    try std.testing.expectEqualStrings("a你z", client.state.text.items);
    try client.setComposing(null, 0, 0);
    try std.testing.expectEqualStrings("az", client.state.text.items);
    try std.testing.expectEqual(@as(i64, 1), client.state.selection_base);
    try std.testing.expectEqual(@as(i64, -1), client.state.composing_start);
    try client.setComposing("", 0, 0);
    try client.insertText("好");
    try std.testing.expectEqualStrings("a好z", client.state.text.items);
}

test "allocation failure preserves action, text, selection, and preedit" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var client = Client.init(failing.allocator());
    defer client.deinit();
    try client.setInputAction("TextInputAction.search");
    try client.applyEditingState("az", 1, 1);
    try client.setComposing("ni", 0, 0);
    const old_state = client.state;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, client.setInputAction("TextInputAction.next"));
    try std.testing.expectEqualStrings("TextInputAction.search", client.input_action);
    try std.testing.expectError(error.OutOfMemory, client.applyEditingState("replacement", 0, 0));
    const long = "x" ** 1024;
    try std.testing.expectError(error.OutOfMemory, client.setComposing(long, 0, 0));
    try std.testing.expectError(error.OutOfMemory, client.insertText(long));
    try std.testing.expectEqualStrings("aniz", client.state.text.items);
    try std.testing.expectEqual(old_state.selection_base, client.state.selection_base);
    try std.testing.expectEqual(old_state.selection_extent, client.state.selection_extent);
    try std.testing.expectEqual(old_state.composing_start, client.state.composing_start);
    try std.testing.expectEqual(old_state.composing_end, client.state.composing_end);
}

test "invalid UTF8 input is rejected before changing state" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    try client.applyEditingState("ok", 1, 1);
    try std.testing.expectError(error.InvalidUtf8, client.applyEditingState("\xf0", 0, 0));
    try std.testing.expectError(error.InvalidUtf8, client.setComposing("\x80", 0, 0));
    try std.testing.expectError(error.InvalidUtf8, client.insertText("\xff"));
    try std.testing.expectEqualStrings("ok", client.state.text.items);
}

test "composition rejects reversed, out of bounds, and split surrogate ranges" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    try client.applyEditingStateWithComposing("A😀中Z", 3, 4, 1, 4);
    try std.testing.expectEqual(@as(i64, 1), client.state.composing_start);
    try std.testing.expectEqual(@as(i64, 8), client.state.composing_end);
    for ([_][2]i64{ .{ -1, -1 }, .{ 4, 1 }, .{ 0, 20 }, .{ 2, 4 } }) |range| {
        try client.applyEditingStateWithComposing("A😀中Z", 3, 4, range[0], range[1]);
        try std.testing.expectEqual(@as(i64, -1), client.state.composing_start);
        try std.testing.expectEqual(@as(i64, -1), client.state.composing_end);
    }
}

test "editing state can reuse its own text while preserving composition" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();
    try client.applyEditingState("A😀中Z", 0, 0);
    try client.applyEditingStateWithComposing(client.state.text.items, 3, 4, 1, 4);
    try std.testing.expectEqualStrings("A😀中Z", client.state.text.items);
    try std.testing.expectEqual(@as(i64, 5), client.state.selection_base);
    try std.testing.expectEqual(@as(i64, 8), client.state.selection_extent);
    try std.testing.expectEqual(@as(i64, 1), client.state.composing_start);
    try std.testing.expectEqual(@as(i64, 8), client.state.composing_end);
}
