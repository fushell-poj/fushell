//! 用于 Wayland 按键翻译的最小 libxkbcommon 绑定。
//!
//! compositor 提供 keymap 与 modifier 快照。物理按键迁移在查询 keysym/UTF-8 前
//! 必须且只能更新一次 `Xkb`；repeat 事件复用已经解析的逻辑按键，不得再次修改
//! xkb 状态。libxkbcommon 对象所有权由 `Xkb.deinit` 封装。

const std = @import("std");

pub const KEYMAP_FORMAT_TEXT_V1: c_int = 1;
pub const KEYMAP_COMPILE_NO_FLAGS: u32 = 0;
pub const CONTEXT_NO_FLAGS: u32 = 0;

pub const KEY_DOWN: c_int = 1;
pub const KEY_UP: c_int = 0;

// 常用 keysym 常量 (xkbcommon keysymdef.h 标准值)。
pub const KEY_BackSpace: u32 = 0xff08;
pub const KEY_Tab: u32 = 0xff09;
pub const KEY_Return: u32 = 0xff0d;
pub const KEY_KP_Enter: u32 = 0xff8d;
pub const KEY_Left: u32 = 0xff51;
pub const KEY_Up: u32 = 0xff52;
pub const KEY_Right: u32 = 0xff53;
pub const KEY_Down: u32 = 0xff54;
pub const KEY_Home: u32 = 0xff50;
pub const KEY_End: u32 = 0xff57;
pub const KEY_Delete: u32 = 0xffff;
pub const KEY_a: u32 = 0x61;
pub const KEY_c: u32 = 0x63;
pub const KEY_v: u32 = 0x76;
pub const KEY_x: u32 = 0x78;
pub const KEY_z: u32 = 0x7a;
pub const KEY_Shift_L: u32 = 0xffe1;
pub const KEY_Shift_R: u32 = 0xffe2;
pub const KEY_Control_L: u32 = 0xffe3;
pub const KEY_Control_R: u32 = 0xffe4;
pub const KEY_Alt_L: u32 = 0xffe9;
pub const KEY_Alt_R: u32 = 0xffea;
pub const KEY_Super_L: u32 = 0xffeb;
pub const KEY_Super_R: u32 = 0xffec;

extern "c" fn xkb_context_new(flags: u32) ?*anyopaque;
extern "c" fn xkb_context_unref(context: ?*anyopaque) void;
extern "c" fn xkb_keymap_new_from_string(context: ?*anyopaque, string: [*:0]const u8, format: c_int, flags: u32) ?*anyopaque;
extern "c" fn xkb_keymap_unref(keymap: ?*anyopaque) void;
extern "c" fn xkb_state_new(keymap: ?*anyopaque) ?*anyopaque;
extern "c" fn xkb_state_unref(state: ?*anyopaque) void;
extern "c" fn xkb_state_update_key(state: ?*anyopaque, key: u32, direction: c_int) void;
extern "c" fn xkb_state_update_mask(
    state: ?*anyopaque,
    depressed_mods: u32,
    latched_mods: u32,
    locked_mods: u32,
    depressed_layout: u32,
    latched_layout: u32,
    locked_layout: u32,
) void;
extern "c" fn xkb_state_key_get_utf8(state: ?*anyopaque, key: u32, buffer: [*]u8, size: usize) c_int;
extern "c" fn xkb_state_key_get_one_sym(state: ?*anyopaque, key: u32) u32;
extern "c" fn xkb_state_serialize_mods(state: ?*anyopaque, components: u32) u32;
pub const XKB_STATE_MODS_DEPRESSED: u32 = 1 << 0;
pub const XKB_STATE_MODS_LATCHED: u32 = 1 << 1;
pub const XKB_STATE_MODS_LOCKED: u32 = 1 << 2;
extern "c" fn xkb_keysym_to_utf8(keysym: u32, buffer: [*]u8, size: usize) c_int;
extern "c" fn xkb_keymap_min_keycode(keymap: ?*anyopaque) u32;
extern "c" fn xkb_keymap_max_keycode(keymap: ?*anyopaque) u32;

/// compositor 当前 keymap 对应的自有 xkb context/keymap/state 三元组。
///
/// `setKeymap` 原子替换由 keymap 派生的对象；编译失败时保留旧状态。所有方法均限制
/// 在平台线程调用。
pub const Xkb = struct {
    context: ?*anyopaque = null,
    keymap: ?*anyopaque = null,
    state: ?*anyopaque = null,
    min_keycode: u32 = 8,
    max_keycode: u32 = 255,
    /// 修饰符按下状态 (Ctrl/Shift/Alt/Super), 由 keysym 跟踪。
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super_: bool = false,

    pub fn init(gpa: std.mem.Allocator, keymap_str: []const u8) !Xkb {
        var self = Xkb{};
        self.context = xkb_context_new(CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
        errdefer xkb_context_unref(self.context);
        const str_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{keymap_str}, 0);
        defer gpa.free(str_z);
        self.keymap = xkb_keymap_new_from_string(self.context, str_z, KEYMAP_FORMAT_TEXT_V1, KEYMAP_COMPILE_NO_FLAGS) orelse
            return error.XkbKeymapFailed;
        errdefer xkb_keymap_unref(self.keymap);
        self.state = xkb_state_new(self.keymap) orelse return error.XkbStateFailed;
        self.min_keycode = xkb_keymap_min_keycode(self.keymap);
        self.max_keycode = xkb_keymap_max_keycode(self.keymap);
        return self;
    }

    pub fn deinit(self: *Xkb) void {
        if (self.state) |s| xkb_state_unref(s);
        if (self.keymap) |m| xkb_keymap_unref(m);
        if (self.context) |c| xkb_context_unref(c);
        self.* = .{};
    }

    /// key 事件更新 (pressed=true 按下)。返回 keysym。
    /// wayland key 事件携带 evdev scancode;xkb 需要 xkb keycode (scancode + 8)。
    fn xkbKeycode(scancode: u32) u32 {
        return scancode + 8;
    }

    /// 查询当前 keysym (不更新状态)。
    /// 当前生效修饰键 (实时, 不等 modifiers 事件)。
    pub fn getMods(self: *Xkb) u32 {
        return if (self.state) |s| xkb_state_serialize_mods(s, XKB_STATE_MODS_DEPRESSED | XKB_STATE_MODS_LATCHED | XKB_STATE_MODS_LOCKED) else 0;
    }

    pub fn getSym(self: *Xkb, keycode: u32) u32 {
        if (self.state) |s| return xkb_state_key_get_one_sym(s, xkbKeycode(keycode));
        return 0;
    }

    pub fn updateKey(self: *Xkb, keycode: u32, pressed: bool) u32 {
        const xk = xkbKeycode(keycode);
        if (self.state) |s| xkb_state_update_key(s, xk, if (pressed) KEY_DOWN else KEY_UP);
        const sym = if (self.state) |s| xkb_state_key_get_one_sym(s, xk) else 0;
        // 修饰符跟踪 (基于 keysym, 与 layout 无关)。
        switch (sym) {
            KEY_Control_L, KEY_Control_R => self.ctrl = pressed,
            KEY_Shift_L, KEY_Shift_R => self.shift = pressed,
            KEY_Alt_L, KEY_Alt_R => self.alt = pressed,
            KEY_Super_L, KEY_Super_R => self.super_ = pressed,
            else => {},
        }
        return sym;
    }

    /// modifiers 事件更新 (depressed/latched/locked + group)。
    pub fn updateModifiers(self: *Xkb, depressed: u32, latched: u32, locked: u32, d_group: u32, l_group: u32, k_group: u32) void {
        if (self.state) |s| xkb_state_update_mask(s, depressed, latched, locked, d_group, l_group, k_group);
    }

    /// keycode → UTF-8 字符 (不含组合键; 返回字节数, 0 = 无字符)。
    pub fn getUtf8(self: *Xkb, keycode: u32, buffer: []u8) usize {
        if (self.state) |s| {
            const n = xkb_state_key_get_utf8(s, xkbKeycode(keycode), buffer.ptr, buffer.len);
            if (n > 0) return @intCast(n);
        }
        return 0;
    }

    /// keysym → UTF-8 (备用, 不经 state)。
    pub fn keysymToUtf8(keysym: u32, buffer: []u8) usize {
        const n = xkb_keysym_to_utf8(keysym, buffer.ptr, buffer.len);
        if (n > 0) return @intCast(n);
        return 0;
    }
};
