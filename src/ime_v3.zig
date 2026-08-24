//! text-input-v3 输入法客户端 (IME v3)。
//! 通过 DisplayState 共享的 manager 创建, 每个窗口一个实例。
//! 生命周期: enable(聚焦) / disable(失焦) / commit(状态生效)。

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const display_state = @import("wl_display_state.zig");

pub const ImeEvent = union(enum) {
    /// 组合文本更新 (preedit)。text 可能为 null (清除组合)。
    preedit: struct {
        text: ?[]const u8,
        cursor_begin: i32,
        cursor_end: i32,
    },
    /// 上屏文本。
    commit: []const u8,
    /// 窗口重新获得输入焦点 (enter)。带 surface (IME 焦点窗口)。
    enter: struct { surface: ?*wl.Surface },
    /// 输入焦点离开 (leave)。带 surface。
    leave: struct { surface: ?*wl.Surface },
    /// 删除光标前 before 字节 / 后 after 字节 (UTF-8)。
    delete_surrounding: struct { before: u32, after: u32 },
};

pub const ImeCallback = *const fn (event: ImeEvent, ctx: ?*anyopaque) void;

pub const ImeV3 = struct {
    text_input: ?*zwp.TextInputV3 = null,
    manager: ?*zwp.TextInputManagerV3 = null,
    callback: ?ImeCallback = null,
    callback_ctx: ?*anyopaque = null,
    shared_queue: ?*wl.EventQueue = null,
    // cursor rect 持久状态: hyprland 的 box.updated 只在带 cursor rect 的 commit 里为 true,
    // 后续 commit (surrounding/preedit) 会清掉 → 候选框 fallback 到窗口左下角。
    // 所有 commit 前重发 cursor rect 保持状态。
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_w: i32 = 0,
    cursor_h: i32 = 0,
    has_cursor: bool = false,

    /// registry 里发现 text_input_manager 时绑定 (由 DisplayState 调用)。
    pub fn bindManager(self: *ImeV3, global: *wl.Registry, name: u32, version: u32, seat: *wl.Seat) void {
        var v = version;
        if (v > 1) v = 1; // manager 接口版本 1
        const manager = wl.Registry.bind(global, name, zwp.TextInputManagerV3, v) catch {
            return;
        };
        // 保存 manager 引用供 deinit 释放 (registry.bind 创建的 proxy 需显式 destroy)。
        self.manager = manager;
        if (self.text_input) |old| old.destroy();
        self.text_input = manager.getTextInput(seat) catch {
            return;
        };
        // 事件绑定: listener + primary queue (否则事件进 default queue 无人 dispatch)。
        if (self.text_input) |ti| {
            ti.setListener(*ImeV3, listener, self);
            if (self.shared_queue) |q| ti.setQueue(q);
        }
    }

    /// 释放 proxy (manager/text_input)。shutdownShared 调用。
    pub fn deinit(self: *ImeV3) void {
        if (self.text_input) |ti| ti.destroy();
        self.text_input = null;
        if (self.manager) |m| m.destroy();
        self.manager = null;
    }

    pub fn setCallback(self: *ImeV3, callback: ImeCallback, ctx: ?*anyopaque) void {
        self.callback = callback;
        self.callback_ctx = ctx;
        if (self.text_input) |ti| {
            ti.setListener(*ImeV3, listener, self);
            if (self.shared_queue) |q| ti.setQueue(q);
        }
    }

    /// TextField 聚焦。
    pub fn enable(self: *ImeV3, hint: u32, purpose: u32) void {
        _ = hint;
        _ = purpose;
        if (self.text_input) |ti| {
            ti.enable();
            // ContentHint/ContentPurpose 是 packed struct — 默认全 false。
            ti.setContentType(.{}, .normal);
            ti.commit();
        } else {}
    }

    /// TextField 失焦。
    pub fn disable(self: *ImeV3) void {
        if (self.text_input) |ti| {
            ti.disable();
            self.commitWithCursor();
        }
    }

    /// 光标矩形 (窗口坐标, 物理像素)。持久: 后续 commit 都会带上。
    pub fn setCursorRect(self: *ImeV3, x: i32, y: i32, w: i32, h: i32) void {
        self.cursor_x = x;
        self.cursor_y = y;
        self.cursor_w = w;
        self.cursor_h = h;
        self.has_cursor = true;
        self.commitWithCursor();
    }

    /// 所有 commit 的入口: 若设置了 cursor rect 则重发 (hyprland box.updated 语义)。
    fn commitWithCursor(self: *ImeV3) void {
        if (self.text_input) |ti| {
            if (self.has_cursor) {
                ti.setCursorRectangle(self.cursor_x, self.cursor_y, self.cursor_w, self.cursor_h);
            }
            ti.commit();
        }
    }

    /// 同步环绕文本 (供 IME 取词/联想)。cursor/anchor 为 UTF-8 字节偏移。
    pub fn setSurrounding(self: *ImeV3, text: []const u8, cursor_byte: i32, anchor_byte: i32) void {
        if (self.text_input) |ti| {
            var t = text;
            if (t.len > 1024) t = t[0..1024];
            var buf: [1025]u8 = undefined;
            @memcpy(buf[0..t.len], t);
            buf[t.len] = 0;
            ti.setSurroundingText(buf[0..t.len :0], cursor_byte, anchor_byte);
            self.commitWithCursor();
        }
    }

    /// 光标位置 (UTF-8 字节, 相对输入文本起点; 无 surrounding 时可省略)。
    pub fn updateCursor(self: *ImeV3, cursor_byte: i32) void {
        if (self.text_input) |ti| {
            ti.setSurroundingText("", cursor_byte, cursor_byte);
            self.commitWithCursor();
        }
    }

    fn listener(_ti: *zwp.TextInputV3, event: zwp.TextInputV3.Event, data: *ImeV3) void {
        _ = _ti;
        switch (event) {
            .preedit_string => |p| {
                const text: ?[]const u8 = if (p.text) |t| std.mem.span(t) else null;
                if (data.callback) |cb| cb(.{ .preedit = .{
                    .text = text,
                    .cursor_begin = p.cursor_begin,
                    .cursor_end = p.cursor_end,
                } }, data.callback_ctx);
            },
            .commit_string => |c| {
                if (c.text) |t| {
                    if (data.callback) |cb| cb(.{ .commit = std.mem.span(t) }, data.callback_ctx);
                }
            },
            .delete_surrounding_text => |d| {
                if (data.callback) |cb| cb(.{ .delete_surrounding = .{
                    .before = d.before_length,
                    .after = d.after_length,
                } }, data.callback_ctx);
            },
            .enter => |e| {
                if (data.callback) |cb| cb(.{ .enter = .{ .surface = e.surface } }, data.callback_ctx);
            },
            .leave => |e| {
                if (data.callback) |cb| cb(.{ .leave = .{ .surface = e.surface } }, data.callback_ctx);
            },
            .done => {
                // 事件序列结束: 客户端应 commit() 确认 (可选, 让 IME 知道已处理)。
                data.commitWithCursor();
            },
            else => {},
        }
    }
};
