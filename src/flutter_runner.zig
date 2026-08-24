const std = @import("std");
// build-verify
const c = @import("c");
const egl = @import("wayland_egl_host.zig");
const flutter = @import("flutter_embedder.zig");
const surface_channel = @import("surface_channel.zig");
const display_state = @import("wl_display_state.zig");
const text_input = @import("text_input.zig");
const clipboard = @import("clipboard.zig");
const data_control = @import("data_control.zig");
const ime_v3 = @import("ime_v3.zig");
const gl_blit = @import("gl_blit.zig");
const xkb = @import("xkb.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;

/// 默认帧间隔 (60Hz)。引擎的 vsync 回调携带实际时间戳, 此值仅用于
/// 无 vsync 驱动的兜底计算; 真实刷新率由 compositor 通过 frame 事件驱动。
const frame_interval_nanos: u64 = 16_666_667;
/// 平台线程任务队列上限。引擎任务突发时临时积压, 满时入队方自旋等待
/// (见 queueFlutterTask), 不会丢任务。1024 足够覆盖单帧引擎任务量。
const max_pending_flutter_tasks = 1024;
const flutter_default_font_family = "Roboto";

/// 进程级共享 DisplayState (单例): 引擎启动时创建, 与引擎同生命周期。
/// 引用计数由 Host.attach/release 管理; 归零时 DisplayState 完整清理。
var global_display_state: ?*display_state.DisplayState = null;
var display_state_mutex: std.atomic.Mutex = .unlocked;

fn getDisplayState(gpa: std.mem.Allocator) !*display_state.DisplayState {
    lockDisplayStateMutex();
    defer display_state_mutex.unlock();
    if (global_display_state == null) {
        const state = try gpa.create(display_state.DisplayState);
        state.* = .{};
        global_display_state = state;
    }
    return global_display_state.?;
}

/// 进程退出时显式释放共享 dc/ime (此刻 state Wayland 仍有效, 清理安全)。
/// ImeV3 持有 Wayland 对象 (text_input 等), 由 state 的 disconnect 统一收尾;
/// 这里只回收 gpa.create 的对象内存 + DataControl 内部 buffer。
fn shutdownShared(gpa: std.mem.Allocator, state: *display_state.DisplayState) void {
    if (state.data_control) |dc| {
        dc.deinit();
        gpa.destroy(dc);
        state.data_control = null;
        if (global_data_control == state.data_control) global_data_control = null;
        global_data_control = null;
    }
    if (state.ime) |ime| {
        ime.deinit();
        gpa.destroy(ime);
        state.ime = null;
    }
}

/// 进程级 data-control (系统剪贴板): 引擎级单例, 绑定到共享 display。
var global_data_control: ?*data_control.DataControl = null;

/// 引擎单例 (输入路由 / host 回调的目标)。由 run() 设置。
var engine_runner: ?*Runner = null;

/// 进程退出请求 (process.exit 平台消息设置): 事件循环检查后退出。
var quit_requested: std.atomic.Value(bool) = .init(false);

/// 进程级窗口注册表: view_id → Host (单引擎多视图)。implicit view (id 0)
/// 不在表内 (无窗口)。槽位内联 Host (稳定地址, 跨线程引用安全)。
const max_windows = 64;
const WindowEntry = struct {
    active: bool = false,
    view_id: i64 = 0,
    parent_view_id: ?i64 = null,
    /// AddView / RemoveView completion 由 engine-managed thread 回调；回调只在
    /// 注册表锁内记录结果，平台线程 tick 才响应 Dart 或销毁 Wayland/EGL 资源。
    add_pending: bool = false,
    add_result_ready: bool = false,
    add_result_added: bool = false,
    remove_pending: bool = false,
    remove_result_ready: bool = false,
    remove_result_removed: bool = false,
    pending_open_response: ?*const c.FlutterPlatformMessageResponseHandle = null,
    pending_open_request_id: i64 = 0,
    pending_close_response: ?*const c.FlutterPlatformMessageResponseHandle = null,
    pending_close_request_id: i64 = 0,
    host: egl.Host = .{},
};
var window_registry: [max_windows]WindowEntry = undefined;
var window_registry_mutex: std.atomic.Mutex = .unlocked;
var next_view_id: i64 = 1;

fn lockWindowRegistry() void {
    while (!window_registry_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlockWindowRegistry() void {
    window_registry_mutex.unlock();
}

/// 按 view_id 查窗口 (隐式 view 0 返回 null)。
fn findWindowEntryByViewId(view_id: i64) ?*WindowEntry {
    for (&window_registry) |*entry| {
        if (entry.active and entry.view_id == view_id) return entry;
    }
    return null;
}

fn findHostBySurface(surface: ?*wl.Surface) ?*egl.Host {
    const s = surface orelse return null;
    for (&window_registry) |*entry| {
        if (!entry.active) continue;
        if (entry.host.surface == s) return &entry.host;
    }
    return null;
}

/// 主线程 dispatch 键盘事件: enter/leave 更新焦点窗口, 事件交给引擎
/// (单引擎: xkb/text_input 为引擎级状态, 焦点窗口由 surface 路由派生)。
fn displayKeyboardRouter(event: display_state.KeyboardEvent, surface: ?*wl.Surface) void {
    const runner = engine_runner orelse return;
    switch (event) {
        .enter => runner.focused_host = findHostBySurface(surface),
        .leave => runner.focused_host = null,
        else => {},
    }
    runner.handleKeyboardEvent(event);
}

/// IME 事件路由: 投给键盘焦点窗口 (IME 是全局对象, 事件随焦点窗口)。
/// text_input.Client 的 send_fn: 发 updateEditingState 到引擎。
fn textInputSendCallback(client_id: i64, msg: []const u8) void {
    _ = client_id;
    const runner = engine_runner orelse return;
    runner.sendToEngine("flutter/textinput", msg);
}

fn imeEventRouter(event: ime_v3.ImeEvent, ctx: ?*anyopaque) void {
    _ = ctx;
    // enter/leave 事件带 surface → 精确路由到对应窗口。
    // (不能依赖 keyboard_focused: text_input enter 可能先于 wl_keyboard.enter 到达)
    var surface: ?*wl.Surface = null;
    switch (event) {
        .enter => |e| surface = e.surface,
        .leave => |e| surface = e.surface,
        else => {},
    }
    const runner = engine_runner orelse return;
    if (surface) |s| {
        // 事件属于某窗口 surface: 只有焦点窗口才处理 (非焦点窗口的 enter
        // 意味着焦点切换, 真正生效的是新焦点窗口)。
        if (findHostBySurface(s)) |host| {
            if (runner.focused_host != host and event == .enter) {
                runner.focused_host = host;
            }
        } else return;
    }
    runner.handleImeEvent(event);
}

/// 指针路由: 事件 surface → 目标窗口 host → handlePointerEvent。
/// 主线程单线程调用 (pointer 绑共享 queue)。
fn displayPointerRouter(event: wl.Pointer.Event, surface: ?*wl.Surface) void {
    const target = findHostBySurface(surface) orelse return;
    target.handlePointerEvent(event);
}

fn lockDisplayStateMutex() void {
    while (!display_state_mutex.tryLock()) std.atomic.spinLoopHint();
}

pub const Options = struct {
    engine_library: []const u8,
    bundle_path: []const u8,
    /// 启动 VM service (热重载用, 仅 debug/JIT 引擎支持):
    /// 传 --enable-vm-service --vm-service-port=0, URI 从引擎日志解析。
    enable_vm_service: bool = false,
};

const Bundle = struct {
    assets_path: [:0]u8,
    icu_data_path: [:0]u8,
    app_so_path: ?[:0]u8 = null,
    overlay_assets_path: ?[]u8 = null,

    fn deinit(self: Bundle, gpa: std.mem.Allocator) void {
        if (self.overlay_assets_path) |overlay_path| {
            deleteTreeBestEffort(overlay_path);
            gpa.free(overlay_path);
        }
        if (self.app_so_path) |app_so| {
            gpa.free(app_so);
        }
        gpa.free(self.assets_path);
        gpa.free(self.icu_data_path);
    }
};

const FontconfigFont = struct {
    family: []u8,
    path: []u8,

    fn deinit(self: FontconfigFont, gpa: std.mem.Allocator) void {
        gpa.free(self.family);
        gpa.free(self.path);
    }
};

const PendingFlutterTask = struct {
    task: c.FlutterTask,
    target_time_nanos: u64,
};

const Runner = struct {
    gpa: std.mem.Allocator,
    /// 进程级共享显示状态 (窗口创建 / IME / 剪贴板用)。
    state: *display_state.DisplayState,
    /// 进程级共享 render context (raster + 全部窗口呈现)。
    render_context: *egl.RenderContext,
    api: *flutter.Api,
    engine_library: []const u8,
    bundle_path: []const u8,
    engine: c.FlutterEngine = null,
    metrics_generation: std.atomic.Value(u64) = .init(0),
    rendering_generation: std.atomic.Value(u64) = .init(0),
    skipped_resize_presents: std.atomic.Value(u32) = .init(0),
    platform_thread_id: std.Thread.Id = undefined,
    task_mutex: std.atomic.Mutex = .unlocked,
    pending_tasks: [max_pending_flutter_tasks]PendingFlutterTask = undefined,
    pending_task_count: usize = 0,
    bootstrap_render_logged: bool = false,
    bootstrap_resource_logged: bool = false,
    bootstrap_present_logged: bool = false,
    first_present_logged: bool = false,

    // ── compositor 呈现路径 ────────────────────────
    /// backing store 纹理 → 窗口 surface 的 GLES2 blit 模块。
    blitter: gl_blit.Blitter = .{},
    compositor_first_present_logged: bool = false,

    // ── 输入 / 文本 / 剪贴板 ──────────────────────
    text_client: text_input.Client = undefined,
    clipboard: clipboard.Clipboard = undefined,
    ime: ?*ime_v3.ImeV3 = null,
    xkb_state: xkb.Xkb = .{},
    /// 键盘焦点窗口 (wl_keyboard.enter 的 surface → 窗口注册表)。
    /// null = 无焦点窗口 (键盘事件被丢弃)。
    focused_host: ?*egl.Host = null,
    // 键盘长按重复 (wl_keyboard.repeat_info): delay 后按 rate 模拟 keydown。
    repeat_delay_ms: u32 = 500,
    repeat_rate_per_sec: u32 = 25,
    repeat_active_key: ?u32 = null,
    repeat_next_time_ns: u64 = 0,
    last_modifiers: u32 = 0,

    fn now(self: *Runner) u64 {
        return self.api.get_current_time();
    }

    fn beginMetricsUpdate(self: *Runner) u64 {
        return self.metrics_generation.fetchAdd(1, .release) + 1;
    }

    fn beginRender(self: *Runner) void {
        self.rendering_generation.store(self.metrics_generation.load(.acquire), .release);
    }

    /// 键盘长按重复 (wl_keyboard.repeat_info): 到达 repeat 时间点则模拟一次
    /// keydown。主线程事件循环 tick 调用 (单线程模型, 无跨线程队列)。
    fn checkKeyRepeat(self: *Runner) void {
        const key = self.repeat_active_key orelse return;
        const now_ns = nowNs();
        if (now_ns < self.repeat_next_time_ns) return;
        // 到达重复点: 间隔 = 1000/rate
        const interval: u64 = if (self.repeat_rate_per_sec > 0)
            @as(u64, 1_000_000_000) / self.repeat_rate_per_sec
        else
            100 * 1_000_000;
        self.repeat_next_time_ns = now_ns + interval;
        if (self.focused_host != null and self.text_client.active) {
            _ = self.xkb_state.updateKey(key, true);
            self.sendKeyboardEvent(key, true);
            self.handleKey(key);
        }
    }

    /// 主线程直接处理键盘事件 (单线程模型, 无队列)。
    fn handleKeyboardEvent(self: *Runner, event: display_state.KeyboardEvent) void {
        switch (event) {
            .keymap => |km| {
                self.xkb_state.deinit();
                self.xkb_state = xkb.Xkb.init(self.gpa, km.data) catch |err| {
                    std.debug.print("[error] xkb keymap init failed: {s}\n", .{@errorName(err)});
                    self.xkb_state = .{};
                    return;
                };
            },
            .modifiers => |m| {
                self.last_modifiers = m.depressed;
                self.xkb_state.updateModifiers(m.depressed, m.latched, m.locked, m.group, m.group, m.group);
            },
            .enter => self.focused_host = null, // 由 displayKeyboardRouter 设置 (surface → host)
            .leave => self.focused_host = null,
            .repeat => |r| {
                self.repeat_delay_ms = @intCast(@max(r.delay_ms, 0));
                self.repeat_rate_per_sec = @intCast(@max(r.rate_per_sec, 0));
            },
            .key => |k| {
                // 按下/松开都更新 xkb 状态 (修饰键跟踪依赖它)。
                _ = self.xkb_state.updateKey(k.key, k.state == .pressed);
                // 无论焦点/文本客户端, 都向 Flutter 发送 RawKeyEvent
                // (EditableText 靠它实现 Ctrl+C/V/A 等快捷键)。
                self.sendKeyboardEvent(k.key, k.state == .pressed);
                if (self.focused_host == null or !self.text_client.active) return;
                const pressed = k.state == .pressed;
                if (pressed) {
                    // 启动长按重复计时 (repeat_info 的 delay 后按 rate 重复)。
                    self.repeat_active_key = k.key;
                    self.repeat_next_time_ns = nowNs() + @as(u64, self.repeat_delay_ms) * 1_000_000;
                    self.handleKey(k.key);
                } else {
                    if (self.repeat_active_key == k.key) self.repeat_active_key = null;
                }
            },
        }
    }

    /// 按键处理: 组合键 / 特殊键 / 可打印字符 → text_client 更新 → 回发引擎。
    /// 发送 RawKeyEvent 到 flutter/keyevent 通道 (GTK 嵌入器同款格式)。
    fn sendKeyboardEvent(self: *Runner, keycode: u32, pressed: bool) void {
        const sym = self.xkb_state.getSym(keycode);
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\{{"type":"{s}","keymap":"linux","keyCode":{d},"modifiers":{d},"unicodeCodePoint":0,"scanCode":{d},"toolkit":"gtk","specifiedLogicalKey":{d},"specifiedPhysicalKey":0}}
        , .{ if (pressed) "keydown" else "keyup", sym, self.xkb_state.getMods(), keycode, sym }) catch return;
        self.sendToEngine("flutter/keyevent", msg);
    }

    /// IME 事件 (text-input-v3): preedit / commit / delete_surrounding。
    /// 在键盘焦点窗口的 runner 上执行 (主线程或 spawn 线程 — 由路由调用处决定)。
    fn handleImeEvent(self: *Runner, event: ime_v3.ImeEvent) void {
        switch (event) {
            .preedit => |p| {
                self.text_client.setComposing(p.text, p.cursor_begin, p.cursor_end) catch |err| {
                    std.debug.print("[error] preedit composing failed: {s}\n", .{@errorName(err)});
                };
            },
            .commit => |text| {
                self.text_client.insertText(text) catch |err| {
                    std.debug.print("[error] ime commit insert failed: {s}\n", .{@errorName(err)});
                };
            },
            .delete_surrounding => |d| {
                self.text_client.deleteSurrounding(d.before, d.after) catch |err| {
                    std.debug.print("[error] ime delete failed: {s}\n", .{@errorName(err)});
                };
            },
            .enter => |e| {
                _ = e;
                // 窗口重新获得 IME 输入焦点。仅当 TextField 已聚焦 (setClient) 才恢复
                // IME 模式; 否则 fcitx5 会在无输入框时弹候选框 (错误行为)。
                if (!self.text_client.active) return;
                if (self.ime) |ime| {
                    // 优先用最近一次引擎几何 (已聚焦过, 输入框未移动时位置≈正确);
                    // 无几何时才用指针位置兜底。避免 fcitx5 在 enable 时用默认位置
                    // 产生"先闪一次再跳正"。
                    if (self.text_client.has_transform and self.text_client.has_marked_rect) {
                        const t = self.text_client.transform;
                        const x = self.text_client.marked_rect_x * t[0] + self.text_client.marked_rect_y * t[4] + t[12];
                        const y = self.text_client.marked_rect_x * t[1] + self.text_client.marked_rect_y * t[5] + t[13];
                        std.debug.print("[diag] submit rect (enter-geom) ({d:.0},{d:.0})\n", .{ x, y });
                        ime.setCursorRect(@intFromFloat(x), @intFromFloat(y), 4, @intFromFloat(@max(self.text_client.marked_rect_h, 16)));
                    } else if (self.focused_host) |focused| {
                        std.debug.print("[diag] submit rect (enter-pointer) ({d:.0},{d:.0})\n", .{ focused.pointer_x, focused.pointer_y });
                        ime.setCursorRect(
                            @intFromFloat(@max(focused.pointer_x, 0)),
                            @intFromFloat(@max(focused.pointer_y, 0)),
                            4,
                            @intFromFloat(@max(@as(f64, 24) * focused.activeScale(), 16)),
                        );
                    } else {
                        ime.setCursorRect(0, 0, 4, 16);
                    }
                    const sel: i32 = @intCast(@max(self.text_client.state.selection_base, 0));
                    ime.setSurrounding(self.text_client.state.text.items, sel, sel);
                    ime.enable(0, 1);
                }
            },
            .leave => |e| {
                _ = e;
                if (self.ime) |ime| ime.disable();
            },
        }
    }

    /// 用引擎提供的 EditableText 几何 (transform + marked rect) 计算光标在
    /// surface (窗口) 中的逻辑坐标, 更新 IME 候选框位置。仿官方 GTK 嵌入器
    /// update_im_cursor_position (fl_text_input_handler.cc)。
    fn updateImeCursorPosition(self: *Runner) void {
        const client = &self.text_client;
        if (!client.has_transform) return;
        if (self.ime == null) return;
        const composing_active = client.state.composing_start >= 0;
        const use_caret = client.has_caret_rect and !composing_active;
        if (!client.has_marked_rect and !use_caret) return;
        const t = client.transform;
        // Flutter 坐标系 = 物理像素。text-input-v3 的 set_cursor_rectangle 期望
        // surface 本地坐标 = buffer 坐标 / buffer_scale; 我们 buffer_scale=1 (viewport),
        // 所以直接传物理坐标 (同 GTK 嵌入器公式)。
        // GTK 嵌入器 (fl_text_input_handler.cc): 行主序 storage,
        // x = rx*T[0][0] + ry*T[1][0] + T[3][0] + w  →  t[0], t[4], t[12]
        // y = rx*T[0][1] + ry*T[1][1] + T[3][1] + h  →  t[1], t[5], t[13]
        // 注意: 不 + width/height! GTK 嵌入器加它们是因为 GTK IM 的 cursor location
        // 语义是"矩形右下角"; 而 text-input-v3 的 set_cursor_rectangle 是整个光标矩形,
        // hyprland 把 popup 显示在矩形正下方 (offset = rect.height)。加了反而偏移。
        const rx = if (use_caret) client.caret_rect_x else client.marked_rect_x;
        const ry = if (use_caret) client.caret_rect_y else client.marked_rect_y;
        const x = rx * t[0] + ry * t[4] + t[12];
        const y = rx * t[1] + ry * t[5] + t[13];
        // 坐标系: setCursorRectangle 的坐标是 surface 本地坐标 = buffer 坐标 / buffer_scale。
        // 我们 buffer_scale=1 (viewport 方案), 所以传 buffer 物理坐标, 不能除 scale!
        // (除以 fractional scale 会导致 rect 偏大 1.54x, popup 位置错误/触发翻转)
        self.ime.?.setCursorRect(
            @intFromFloat(x),
            @intFromFloat(y),
            4,
            24,
        );
    }

    fn handleKey(self: *Runner, keycode: u32) void {
        const sym = self.xkb_state.updateKey(keycode, true);
        _ = self.xkb_state.ctrl;

        // 注意: Ctrl 组合键 (Ctrl+C/V/A 等) 不在此处处理 — keyboard 事件已
        // 发送给 Flutter, 由 EditableText 的快捷键处理 (宿主重复处理会与
        // Flutter 端双重粘贴/全选冲突)。Flutter 端变化通过 setEditingState
        // 回同步到宿主 buffer。

        // 特殊键。
        switch (sym) {
            xkb.KEY_BackSpace => {
                self.text_client.backspace() catch {
                    return;
                };
            },
            xkb.KEY_Delete => self.text_client.deleteForward() catch return,
            xkb.KEY_Return, xkb.KEY_KP_Enter => {
                if (self.text_client.multiline) {
                    self.text_client.insertText("\n") catch return;
                } else {
                    const out = self.sendActionMessage() catch return;
                    _ = out;
                    return;
                }
            },
            xkb.KEY_Left => self.text_client.moveCursor(.left),
            xkb.KEY_Right => self.text_client.moveCursor(.right),
            xkb.KEY_Home => self.text_client.moveCursor(.home),
            xkb.KEY_End => self.text_client.moveCursor(.end),
            else => {
                // 可打印字符 (不含组合/修饰键)。
                var buf: [64]u8 = undefined;
                const n = self.xkb_state.getUtf8(keycode, &buf);
                if (n > 0 and !self.xkb_state.ctrl and !self.xkb_state.alt) {
                    self.text_client.insertText(buf[0..n]) catch |err| {
                        std.debug.print("[error] insertText failed: {s}\n", .{@errorName(err)});
                        return;
                    };
                } else {
                    return;
                }
            },
        }
        self.sendTextInputUpdate();
    }

    fn copySelection(self: *Runner) void {
        // 简化: 复制整个文本内容 (无选区信息时)。
        const text = self.text_client.state.text.items;
        if (text.len == 0) return;
        self.clipboard.setText(text) catch |err| {
            std.debug.print("[error] clipboard set failed: {s}\n", .{@errorName(err)});
        };
    }

    fn pasteClipboard(self: *Runner) void {
        const text = self.clipboard.getText();
        if (text.len == 0) return;
        self.text_client.insertText(text) catch |err| {
            std.debug.print("[error] paste failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.sendTextInputUpdate();
    }

    fn sendTextInputUpdate(self: *Runner) void {
        if (!self.text_client.active) return;
        var buf: [8192]u8 = undefined;
        const escaped = text_input.jsonEscape(self.gpa, self.text_client.state.text.items) catch return;
        defer self.gpa.free(escaped);
        const msg = self.text_client.buildUpdateMessageEscaped(&buf, escaped) catch return;
        self.sendToEngine("flutter/textinput", msg);
    }

    fn sendActionMessage(self: *Runner) !void {
        var buf: [512]u8 = undefined;
        const msg = try self.text_client.buildActionMessage(&buf);
        self.sendToEngine("flutter/textinput", msg);
    }

    fn sendToEngine(self: *Runner, channel: []const u8, message: []const u8) void {
        if (self.engine == null) return;
        var c_message = c.FlutterPlatformMessage{
            .struct_size = @sizeOf(c.FlutterPlatformMessage),
            .channel = channel.ptr,
            .message = message.ptr,
            .message_size = message.len,
            .response_handle = null,
        };
        const result = self.api.send_platform_message(self.engine, &c_message);
        if (result != c.kSuccess) {
            std.debug.print("[error] FlutterEngineSendPlatformMessage failed: {s}\n", .{flutter.resultName(result)});
        }
    }

    fn shouldPresentRenderedFrame(self: *Runner) bool {
        return self.rendering_generation.load(.acquire) == self.metrics_generation.load(.acquire);
    }

    fn queueFlutterTask(self: *Runner, task: c.FlutterTask, target_time_nanos: u64) void {
        // 引擎 post_task_callback 契约: 必须接受任务 (void 返回)。
        // 队列满时不能丢 — 释放锁让消费方 (主事件循环) 有机会出队, 然后重试。
        while (true) {
            self.lockTaskQueue();
            if (self.pending_task_count < self.pending_tasks.len) {
                self.pending_tasks[self.pending_task_count] = .{ .task = task, .target_time_nanos = target_time_nanos };
                self.pending_task_count += 1;
                self.task_mutex.unlock();
                return;
            }
            self.task_mutex.unlock();
            std.Thread.yield() catch {};
        }
    }

    fn popDueFlutterTask(self: *Runner) ?c.FlutterTask {
        const now_nanos = self.now();
        self.lockTaskQueue();
        defer self.task_mutex.unlock();

        var selected: ?usize = null;
        var selected_target: u64 = 0;
        for (self.pending_tasks[0..self.pending_task_count], 0..) |pending, index| {
            if (pending.target_time_nanos > now_nanos) continue;
            if (selected == null or pending.target_time_nanos < selected_target) {
                selected = index;
                selected_target = pending.target_time_nanos;
            }
        }

        const index = selected orelse return null;
        const task = self.pending_tasks[index].task;
        if (index + 1 < self.pending_task_count) {
            std.mem.copyForwards(PendingFlutterTask, self.pending_tasks[index .. self.pending_task_count - 1], self.pending_tasks[index + 1 .. self.pending_task_count]);
        }
        self.pending_task_count -= 1;
        return task;
    }

    fn runDueFlutterTasks(self: *Runner) !void {
        while (self.popDueFlutterTask()) |task| {
            if (self.engine == null) return;
            try flutter.ensureSuccess(self.api.run_task(self.engine, &task), "FlutterEngineRunTask");
        }
    }

    fn lockTaskQueue(self: *Runner) void {
        while (!self.task_mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

pub fn run(gpa: std.mem.Allocator, options: Options) !void {
    var api = try flutter.Api.load(gpa, options.engine_library);
    defer api.deinit();

    // 引擎模式决定启动协议:
    //   AOT 引擎 (release):  libapp.so ELF 快照 → FlutterEngineCreateAOTData
    //   JIT 引擎 (debug):     kernel_blob.bin → assets_path 直接启动
    const is_aot = api.runs_aot_compiled_dart_code();
    var aot_data: c.FlutterEngineAOTData = null;
    var aot_source: c.FlutterEngineAOTDataSource = undefined;

    const bundle = if (is_aot) blk: {
        std.debug.print("Flutter engine reports AOT-only execution; using AOT launch path (libapp.so).\n", .{});
        const aot_bundle = try validateAotBundle(gpa, options.bundle_path);
        aot_source = std.mem.zeroes(c.FlutterEngineAOTDataSource);
        aot_source.type = c.kFlutterEngineAOTDataSourceTypeElfPath;
        aot_source.unnamed_0.elf_path = aot_bundle.app_so_path.?.ptr;
        try flutter.ensureSuccess(api.create_aot_data(&aot_source, &aot_data), "FlutterEngineCreateAOTData");
        break :blk aot_bundle;
    } else try validateJitBundle(gpa, options.bundle_path);
    defer bundle.deinit(gpa);
    defer if (aot_data != null) {
        flutter.ensureSuccess(api.collect_aot_data(aot_data), "FlutterEngineCollectAOTData") catch |err| {
            std.debug.print("[error] FlutterEngineCollectAOTData failed: {s}\n", .{@errorName(err)});
        };
    };

    const state = try getDisplayState(gpa);
    // state 对象销毁必须在 host.deinit 之后 (defer LIFO: 后注册者先执行),
    // 先让 host.deinit 触发 state.deinit 释放 Wayland/EGL, 再回收入口对象。
    // ⚠️ defer 必须是【函数级】, 不能放在 if 块内 — Zig 的 defer 在词法块结束
    // (包括 if 的 }) 时执行, 若放 if 内会在 attach 之前就 destroy state (悬垂引用).
    defer if (global_display_state == state) {
        gpa.destroy(state);
        global_display_state = null;
    };
    var local_host: egl.Host = .{};
    // 无头基座: 这个 host 不初始化任何 surface 角色, 仅作为进程级连接的所有者
    // 与事件循环载体 (单引擎模型下窗口全部由注册表内 Host 承载)。
    const host: *egl.Host = &local_host;
    defer local_host.deinit();

    // 进程级初始化: attach (acquire → 建连接) 后绑单一 event queue 到全部对象。
    try host.attach(state);
    try state.bindGlobals();
    // 进程级单一 EGL render context (raster + 呈现)。
    var render_context: egl.RenderContext = .{};
    defer render_context.deinit();
    try render_context.init(state);
    display_state.setPointerEventCallback(displayPointerRouter, null);
    display_state.setKeyboardEventCallback(displayKeyboardRouter, null);
    // output scale 变化 → 重算全部窗口 scale (注册表遍历)。
    display_state.scale_change_callback = struct {
        fn cb() void {
            lockWindowRegistry();
            defer unlockWindowRegistry();
            for (&window_registry) |*entry| {
                if (entry.active) entry.host.recomputeScale();
            }
        }
    }.cb;
    // 系统剪贴板 (data-control): 引擎级单例, 共享 display。
    if (global_data_control == null) {
        const dc = gpa.create(data_control.DataControl) catch null;
        if (dc) |d| {
            d.* = data_control.DataControl.init(gpa, state);
            global_data_control = d;
            state.data_control = d;
            // 若 registry 已发现 manager (bindGlobals 前), 补绑定
            if (state.data_control_manager_name != 0) {
                if (state.registry) |reg| d.bindManager(reg, state.data_control_manager_name, state.data_control_manager_version);
            }
        }
    }
    // IME (text-input-v3): 引擎级单例, registry 绑定由 registryListener 完成。
    if (state.ime == null) {
        const ime = gpa.create(ime_v3.ImeV3) catch null;
        if (ime) |i| {
            i.* = .{};
            state.ime = i;
        }
    }
    if (state.ime) |ime| {
        ime.shared_queue = state.shared_queue;
        ime.setCallback(imeEventRouter, null);
        if (state.ime_manager_name != 0) {
            if (state.registry) |reg| {
                if (state.seat) |seat| ime.bindManager(reg, state.ime_manager_name, state.ime_manager_version, seat);
            }
        }
    }
    std.debug.print("Wayland display connected and EGL bootstrap context is ready (headless shell).\n", .{});

    var runner: Runner = .{ .gpa = gpa, .state = state, .render_context = &render_context, .api = &api, .platform_thread_id = std.Thread.getCurrentId(), .engine_library = options.engine_library, .bundle_path = options.bundle_path };
    runner.ime = state.ime;
    runner.text_client = text_input.Client.init(gpa);
    runner.text_client.send_fn = textInputSendCallback;
    runner.clipboard = clipboard.Clipboard.init(gpa);
    defer runner.text_client.deinit();
    defer runner.clipboard.deinit();
    defer runner.xkb_state.deinit();
    defer runner.blitter.deinit();
    engine_runner = &runner;
    defer engine_runner = null;

    var renderer: c.FlutterRendererConfig = std.mem.zeroes(c.FlutterRendererConfig);
    renderer.type = c.kOpenGL;
    renderer.unnamed_0.open_gl = std.mem.zeroes(c.FlutterOpenGLRendererConfig);
    renderer.unnamed_0.open_gl.struct_size = @sizeOf(c.FlutterOpenGLRendererConfig);
    renderer.unnamed_0.open_gl.make_current = makeCurrentCallback;
    renderer.unnamed_0.open_gl.clear_current = clearCurrentCallback;
    // make_resource_current 设为 null: 引擎不做异步纹理上传 (用主 context 同步上传)。
    // 共享 resource context 时 io 线程持锁无释放点 (无 present 回调), 会导致 raster 线程死锁。
    renderer.unnamed_0.open_gl.make_resource_current = null;
    renderer.unnamed_0.open_gl.present = presentCallback;
    renderer.unnamed_0.open_gl.fbo_callback = fboCallback;
    renderer.unnamed_0.open_gl.gl_proc_resolver = glProcResolverCallback;

    var platform_task_runner: c.FlutterTaskRunnerDescription = std.mem.zeroes(c.FlutterTaskRunnerDescription);
    platform_task_runner.struct_size = @sizeOf(c.FlutterTaskRunnerDescription);
    platform_task_runner.user_data = &runner;
    platform_task_runner.runs_task_on_current_thread_callback = runsTaskOnCurrentThreadCallback;
    platform_task_runner.post_task_callback = postFlutterTaskCallback;
    platform_task_runner.identifier = @intFromPtr(&runner);

    var custom_task_runners: c.FlutterCustomTaskRunners = std.mem.zeroes(c.FlutterCustomTaskRunners);
    custom_task_runners.struct_size = @sizeOf(c.FlutterCustomTaskRunners);
    custom_task_runners.platform_task_runner = &platform_task_runner;

    var project_args: c.FlutterProjectArgs = std.mem.zeroes(c.FlutterProjectArgs);
    project_args.struct_size = @sizeOf(c.FlutterProjectArgs);
    project_args.assets_path = bundle.assets_path.ptr;
    project_args.icu_data_path = bundle.icu_data_path.ptr;
    project_args.vsync_callback = vsyncCallback;
    project_args.custom_task_runners = &custom_task_runners;
    project_args.platform_message_callback = platformMessageCallback;
    // 单引擎: 本引擎是进程唯一引擎, 负责销毁 VM。
    project_args.shutdown_dart_vm_when_done = true;
    project_args.log_message_callback = logMessageCallback;
    project_args.log_tag = "fushell";
    if (is_aot) project_args.aot_data = aot_data;

    // 热重载 (debug): 启动 VM service。
    // 字符串字面量是静态的, 引擎在 run 返回后已拷贝, 生命周期安全。
    if (options.enable_vm_service) {
        const vm_argv = [_]?[*:0]const u8{
            "fushell".ptr,
            "--enable-vm-service".ptr,
            "--vm-service-port=0".ptr,
        };
        project_args.command_line_argc = vm_argv.len;
        project_args.command_line_argv = &vm_argv;
        std.debug.print("VM service requested (hot reload); waiting for engine to report the service URI.\n", .{});
    }

    // compositor 渲染路径 (multi-view 基础): 引擎产出 layer tree,
    // embedder 负责 backing store 创建/回收与 per-view 呈现。renderer 的
    // present 回调为 no-op (见 presentCallback)。
    var compositor: c.FlutterCompositor = std.mem.zeroes(c.FlutterCompositor);
    compositor.struct_size = @sizeOf(c.FlutterCompositor);
    compositor.user_data = &runner;
    compositor.create_backing_store_callback = createBackingStoreCallback;
    compositor.collect_backing_store_callback = collectBackingStoreCallback;
    compositor.present_view_callback = presentViewCallback;
    project_args.compositor = &compositor;

    std.debug.print("Starting Flutter engine with bundle assets: {s}\n", .{bundle.assets_path});
    var engine: c.FlutterEngine = null;
    const run_result = api.run(c.FLUTTER_ENGINE_VERSION, &renderer, &project_args, &runner, &engine);
    try flutter.ensureSuccess(run_result, "FlutterEngineRun");
    runner.engine = engine;
    errdefer if (runner.engine != null) {
        const shutdown_result = api.shutdown(runner.engine);
        if (shutdown_result != c.kSuccess) {
            std.debug.print("[error] FlutterEngineShutdown after startup error failed: {s}\n", .{flutter.resultName(shutdown_result)});
        }
    };

    std.debug.print("Flutter engine is running (headless). Dart may create windows via FushellWindow.openWindow.\n", .{});
    try host.runEventLoop(&quit_requested, "Engine event loop active (headless shell).", flutterTaskPumpCallback, &runner);

    // 退出序列: 先关引擎 (join 引擎线程 → 不再有 present 回调),
    // 再销毁剩余窗口与共享 dc/ime (此刻 state Wayland 连接仍有效)。
    std.debug.print("Shutting down Flutter engine.\n", .{});
    try flutter.ensureSuccess(api.shutdown(runner.engine), "FlutterEngineShutdown");
    runner.engine = null;
    shutdownAllWindows();
    shutdownShared(gpa, state);
    std.debug.print("engine event loop exited.\n", .{});
}

fn validateJitBundle(gpa: std.mem.Allocator, bundle_path: []const u8) !Bundle {
    if (!try pathExists(gpa, bundle_path)) {
        std.debug.print("Flutter bundle path does not exist: {s}\n", .{bundle_path});
        return error.InvalidFlutterBundle;
    }

    const gtk_assets = try std.fs.path.join(gpa, &.{ bundle_path, "data", "flutter_assets" });
    defer gpa.free(gtk_assets);
    const gtk_icu = try std.fs.path.join(gpa, &.{ bundle_path, "data", "icudtl.dat" });
    defer gpa.free(gtk_icu);
    if (try validateAssetsLayout(gpa, gtk_assets, gtk_icu)) {
        return try prepareBundle(gpa, gtk_assets, gtk_icu, null);
    }

    const raw_assets = try std.fs.path.join(gpa, &.{ bundle_path, "flutter_assets" });
    defer gpa.free(raw_assets);
    const raw_icu = try std.fs.path.join(gpa, &.{ bundle_path, "icudtl.dat" });
    defer gpa.free(raw_icu);
    if (try validateAssetsLayout(gpa, raw_assets, raw_icu)) {
        return try prepareBundle(gpa, raw_assets, raw_icu, null);
    }

    std.debug.print("Flutter debug/JIT bundle is incomplete. Expected either:\n", .{});
    std.debug.print("  {s}/data/flutter_assets/kernel_blob.bin\n", .{bundle_path});
    std.debug.print("  {s}/data/icudtl.dat\n", .{bundle_path});
    std.debug.print("or:\n", .{});
    std.debug.print("  {s}/flutter_assets/kernel_blob.bin\n", .{bundle_path});
    std.debug.print("  {s}/icudtl.dat\n", .{bundle_path});
    return error.InvalidFlutterBundle;
}

/// AOT bundle 校验: 要求 lib/libapp.so (ELF AOT 快照) + assets + icu。
/// 与 JIT 布局相同支持 data/ 与裸两种变体。
fn validateAotBundle(gpa: std.mem.Allocator, bundle_path: []const u8) !Bundle {
    if (!try pathExists(gpa, bundle_path)) {
        std.debug.print("Flutter bundle path does not exist: {s}\n", .{bundle_path});
        return error.InvalidFlutterBundle;
    }

    const gtk_assets = try std.fs.path.join(gpa, &.{ bundle_path, "data", "flutter_assets" });
    defer gpa.free(gtk_assets);
    const gtk_icu = try std.fs.path.join(gpa, &.{ bundle_path, "data", "icudtl.dat" });
    defer gpa.free(gtk_icu);
    const gtk_app = try std.fs.path.join(gpa, &.{ bundle_path, "lib", "libapp.so" });
    defer gpa.free(gtk_app);
    if (try validateAotLayout(gpa, gtk_assets, gtk_icu, gtk_app)) {
        return try prepareBundle(gpa, gtk_assets, gtk_icu, gtk_app);
    }

    const raw_assets = try std.fs.path.join(gpa, &.{ bundle_path, "flutter_assets" });
    defer gpa.free(raw_assets);
    const raw_icu = try std.fs.path.join(gpa, &.{ bundle_path, "icudtl.dat" });
    defer gpa.free(raw_icu);
    if (try validateAotLayout(gpa, raw_assets, raw_icu, gtk_app)) {
        return try prepareBundle(gpa, raw_assets, raw_icu, gtk_app);
    }

    std.debug.print("Flutter AOT bundle is incomplete. Expected:\n", .{});
    std.debug.print("  {s}/lib/libapp.so\n", .{bundle_path});
    std.debug.print("  {s}/data/flutter_assets/\n", .{bundle_path});
    std.debug.print("  {s}/data/icudtl.dat\n", .{bundle_path});
    std.debug.print("Build it with: flutter build bundle --release (libapp.so via gen_snapshot).\n", .{});
    return error.InvalidFlutterBundle;
}

fn validateAotLayout(gpa: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8, app_so_path: []const u8) !bool {
    return try pathExists(gpa, assets_path) and try pathExists(gpa, icu_data_path) and try pathExists(gpa, app_so_path);
}

fn validateAssetsLayout(gpa: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8) !bool {
    const kernel_blob = try std.fs.path.join(gpa, &.{ assets_path, "kernel_blob.bin" });
    defer gpa.free(kernel_blob);
    return try pathExists(gpa, assets_path) and try pathExists(gpa, icu_data_path) and try pathExists(gpa, kernel_blob);
}

fn prepareBundle(gpa: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8, app_so_path: ?[]const u8) !Bundle {
    const injected_assets_path = prepareFontconfigAssetsOverlay(gpa, assets_path) catch |err| switch (err) {
        error.SystemFontUnavailable, error.FontManifestAlreadyProvidesDefault => null,
        else => fallback: {
            std.debug.print("[error] System font asset injection failed: {s}; continuing with original bundle assets.\n", .{@errorName(err)});
            break :fallback null;
        },
    };

    if (injected_assets_path) |overlay_path| {
        std.debug.print("Using fontconfig system font asset overlay: {s}\n", .{overlay_path});
        return .{
            .assets_path = try gpa.dupeZ(u8, overlay_path),
            .icu_data_path = try gpa.dupeZ(u8, icu_data_path),
            .app_so_path = if (app_so_path) |p| try gpa.dupeZ(u8, p) else null,
            .overlay_assets_path = overlay_path,
        };
    }

    return .{
        .assets_path = try gpa.dupeZ(u8, assets_path),
        .icu_data_path = try gpa.dupeZ(u8, icu_data_path),
        .app_so_path = if (app_so_path) |p| try gpa.dupeZ(u8, p) else null,
    };
}

fn pathExists(gpa: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    return std.c.access(path_z.ptr, std.c.F_OK) == 0;
}

fn prepareFontconfigAssetsOverlay(gpa: std.mem.Allocator, assets_path: []const u8) ![]u8 {
    const system_font = try resolveFontconfigSansFont(gpa);
    defer system_font.deinit(gpa);

    const manifest_path = try std.fs.path.join(gpa, &.{ assets_path, "FontManifest.json" });
    defer gpa.free(manifest_path);

    if (readFileAllocC(gpa, manifest_path)) |manifest| {
        defer gpa.free(manifest);
        if (manifestHasFontFamily(manifest, system_font.family) and manifestHasFontFamily(manifest, flutter_default_font_family)) {
            return error.FontManifestAlreadyProvidesDefault;
        }
    } else |_| {}

    const assets_abs = try realPathAlloc(gpa, assets_path);
    defer gpa.free(assets_abs);

    const overlay_path = try makeTempOverlayDir(gpa);
    errdefer {
        deleteTreeBestEffort(overlay_path);
        gpa.free(overlay_path);
    }

    try symlinkTopLevelAssets(gpa, assets_abs, overlay_path);

    const font_dir_name = "fushell_system_fonts";
    const font_dir = try std.fs.path.joinZ(gpa, &.{ overlay_path, font_dir_name });
    defer gpa.free(font_dir);
    if (c.mkdir(font_dir.ptr, 0o700) != 0) return error.CreateOverlayFailed;

    const font_basename = std.fs.path.basename(system_font.path);
    const font_asset = try std.fs.path.join(gpa, &.{ font_dir_name, font_basename });
    defer gpa.free(font_asset);
    const font_link = try std.fs.path.joinZ(gpa, &.{ overlay_path, font_asset });
    defer gpa.free(font_link);
    const system_font_path_z = try gpa.dupeZ(u8, system_font.path);
    defer gpa.free(system_font_path_z);
    if (c.symlink(system_font_path_z.ptr, font_link.ptr) != 0) return error.CreateOverlayFailed;

    try writeInjectedFontManifest(gpa, assets_path, overlay_path, system_font.family, font_asset);
    std.debug.print("Resolved fontconfig sans font for Flutter text fallback: {s} ({s}); registering Flutter default alias {s}\n", .{ system_font.family, system_font.path, flutter_default_font_family });
    return overlay_path;
}

fn resolveFontconfigSansFont(gpa: std.mem.Allocator) !FontconfigFont {
    if (c.FcInit() == 0) return error.SystemFontUnavailable;
    const pattern = c.FcNameParse("sans") orelse return error.SystemFontUnavailable;
    defer c.FcPatternDestroy(pattern);

    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pattern, &result) orelse return error.SystemFontUnavailable;
    defer c.FcPatternDestroy(match);

    var family_value: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FAMILY, 0, &family_value) != c.FcResultMatch or family_value == null) {
        return error.SystemFontUnavailable;
    }

    var file_value: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_value) != c.FcResultMatch or file_value == null) {
        return error.SystemFontUnavailable;
    }

    return .{
        .family = try gpa.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(family_value)))),
        .path = try gpa.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_value)))),
    };
}

fn makeTempOverlayDir(gpa: std.mem.Allocator) ![]u8 {
    const tmp_dir = std.c.getenv("TMPDIR") orelse "/tmp";
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const path = try std.fmt.allocPrint(gpa, "{s}/fushell-flutter-assets-{d}-{d}-{d}", .{ std.mem.span(tmp_dir), c.getpid(), c.time(null), attempt });
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        if (c.mkdir(path_z.ptr, 0o700) == 0) return path;
        gpa.free(path);
    }
    return error.CreateOverlayFailed;
}

fn symlinkTopLevelAssets(gpa: std.mem.Allocator, assets_abs: []const u8, overlay_path: []const u8) !void {
    const assets_abs_z = try gpa.dupeZ(u8, assets_abs);
    defer gpa.free(assets_abs_z);
    const dir = c.opendir(assets_abs_z.ptr) orelse return error.CreateOverlayFailed;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name = direntName(entry);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (std.mem.eql(u8, name, "FontManifest.json")) continue;
        if (std.mem.eql(u8, name, "fushell_system_fonts")) continue;

        const src = try std.fs.path.joinZ(gpa, &.{ assets_abs, name });
        defer gpa.free(src);
        const dst = try std.fs.path.joinZ(gpa, &.{ overlay_path, name });
        defer gpa.free(dst);
        if (c.symlink(src.ptr, dst.ptr) != 0) return error.CreateOverlayFailed;
    }
}

fn writeInjectedFontManifest(gpa: std.mem.Allocator, original_assets_path: []const u8, overlay_path: []const u8, family: []const u8, asset: []const u8) !void {
    const original_manifest_path = try std.fs.path.join(gpa, &.{ original_assets_path, "FontManifest.json" });
    defer gpa.free(original_manifest_path);

    // 区分"缺失"(无 FontManifest 的旧 bundle, 允许降级) 与"读取失败"(真实错误)。
    var original_manifest: ?[]u8 = null;
    if (readFileAllocC(gpa, original_manifest_path)) |manifest| {
        original_manifest = manifest;
    } else |err| {
        if (err != error.FileUnavailable) {
            std.debug.print("[warn] failed to read original FontManifest.json: {s}\n", .{@errorName(err)});
        }
    }
    defer if (original_manifest) |manifest| gpa.free(manifest);

    const generated = try buildFontManifest(gpa, original_manifest, family, asset);
    defer gpa.free(generated);

    const overlay_manifest_path = try std.fs.path.joinZ(gpa, &.{ overlay_path, "FontManifest.json" });
    defer gpa.free(overlay_manifest_path);
    try writeFileC(overlay_manifest_path, generated);
}

fn buildFontManifest(gpa: std.mem.Allocator, original_manifest: ?[]const u8, family: []const u8, asset: []const u8) ![]u8 {
    try validateJsonStringFragment(family);
    try validateJsonStringFragment(flutter_default_font_family);
    try validateJsonStringFragment(asset);

    const injected = if (std.mem.eql(u8, family, flutter_default_font_family))
        try std.fmt.allocPrint(gpa, "{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}}", .{ family, asset, asset })
    else
        try std.fmt.allocPrint(gpa, "{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}},{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}}", .{ family, asset, asset, flutter_default_font_family, asset, asset });
    defer gpa.free(injected);

    if (original_manifest == null) {
        return try std.fmt.allocPrint(gpa, "[{s}]\n", .{injected});
    }

    const original = original_manifest.?;
    var end = original.len;
    while (end > 0 and std.ascii.isWhitespace(original[end - 1])) end -= 1;
    if (end == 0 or original[end - 1] != ']') return try std.fmt.allocPrint(gpa, "[{s}]\n", .{injected});

    var has_existing_entries = false;
    for (original[0 .. end - 1]) |byte| {
        if (!std.ascii.isWhitespace(byte) and byte != '[') {
            has_existing_entries = true;
            break;
        }
    }

    const comma = if (has_existing_entries) "," else "";
    return try std.fmt.allocPrint(gpa, "{s}{s}{s}]\n", .{ original[0 .. end - 1], comma, injected });
}

fn manifestHasFontFamily(manifest: []const u8, family: []const u8) bool {
    const needle = std.fmt.allocPrint(std.heap.c_allocator, "\"family\":\"{s}\"", .{family}) catch return false;
    defer std.heap.c_allocator.free(needle);
    return std.mem.indexOf(u8, manifest, needle) != null;
}

fn validateJsonStringFragment(value: []const u8) !void {
    for (value) |byte| {
        if (byte < 0x20 or byte == '"' or byte == '\\') return error.InvalidFontManifestValue;
    }
}

fn readFileAllocC(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const file = c.fopen(path_z.ptr, "rb") orelse return error.FileUnavailable;
    defer _ = c.fclose(file);

    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.FileUnavailable;
    const length = c.ftell(file);
    if (length < 0 or length > 1024 * 1024) return error.FileUnavailable;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.FileUnavailable;

    const buffer = try gpa.alloc(u8, @intCast(length));
    errdefer gpa.free(buffer);
    const read_count = c.fread(buffer.ptr, 1, buffer.len, file);
    if (read_count != buffer.len) return error.FileUnavailable;
    return buffer;
}

fn writeFileC(path_z: [:0]const u8, bytes: []const u8) !void {
    const file = c.fopen(path_z.ptr, "wb") orelse return error.FileUnavailable;
    defer _ = c.fclose(file);
    if (c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.FileUnavailable;
}

fn realPathAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const resolved = c.realpath(path_z.ptr, null) orelse return error.FileUnavailable;
    defer c.free(resolved);
    return try gpa.dupe(u8, std.mem.span(resolved));
}

fn direntName(entry: *c.struct_dirent) []const u8 {
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.d_name)), 0);
}

fn deleteTreeBestEffort(path: []const u8) void {
    const path_z = std.heap.c_allocator.dupeZ(u8, path) catch return;
    defer std.heap.c_allocator.free(path_z);
    const dir = c.opendir(path_z.ptr) orelse {
        _ = c.unlink(path_z.ptr);
        return;
    };
    while (c.readdir(dir)) |entry| {
        const name = direntName(entry);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = std.fs.path.joinZ(std.heap.c_allocator, &.{ path, name }) catch continue;
        defer std.heap.c_allocator.free(child);
        if (c.unlink(child.ptr) != 0) deleteTreeBestEffort(child);
    }
    _ = c.closedir(dir);
    _ = c.rmdir(path_z.ptr);
}

/// 单调时钟纳秒 (重复计时用)。
fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn fromUserData(user_data: ?*anyopaque) *Runner {
    return @ptrCast(@alignCast(user_data.?));
}

fn runsTaskOnCurrentThreadCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    return std.Thread.getCurrentId() == runner.platform_thread_id;
}

fn postFlutterTaskCallback(task: c.FlutterTask, target_time_nanos: u64, user_data: ?*anyopaque) callconv(.c) void {
    const runner = fromUserData(user_data);
    runner.queueFlutterTask(task, target_time_nanos);
}

fn flutterTaskPumpCallback(user_data: ?*anyopaque) !void {
    const runner = fromUserData(user_data);
    processViewLifecycleResults(runner);
    processCompositorCloseRequests(runner);
    runner.checkKeyRepeat();
    try runner.runDueFlutterTasks();
}

fn sendMetrics(runner: *Runner, host_metrics: egl.Metrics, view_id: i64) !void {
    if (runner.engine == null) return;
    const generation = runner.beginMetricsUpdate();
    var metrics: c.FlutterWindowMetricsEvent = std.mem.zeroes(c.FlutterWindowMetricsEvent);
    metrics.struct_size = @sizeOf(c.FlutterWindowMetricsEvent);
    metrics.width = host_metrics.width;
    metrics.height = host_metrics.height;
    metrics.pixel_ratio = host_metrics.pixel_ratio;
    metrics.left = 0;
    metrics.top = 0;
    metrics.view_id = view_id;
    _ = generation;
    try flutter.ensureSuccess(runner.api.send_window_metrics(runner.engine, &metrics), "FlutterEngineSendWindowMetricsEvent");
    try flutter.ensureSuccess(runner.api.schedule_frame(runner.engine), "FlutterEngineScheduleFrame");
}

fn metricsCallback(context: ?*anyopaque, host_metrics: egl.Metrics) void {
    const host: *egl.Host = @ptrCast(@alignCast(context.?));
    const runner = engine_runner orelse return;
    // 窗口关闭中: 引擎可能已不认这个 view, 发送即 UAF。
    if (runner.engine == null or host.state == .shutting_down) return;
    sendMetrics(runner, host_metrics, host.view_id) catch |err| {
        std.debug.print("[error] Flutter metrics callback failed: {s}\n", .{@errorName(err)});
    };
}

fn sendPointerEvent(runner: *Runner, host_event: egl.PointerEvent, view_id: i64) !void {
    if (runner.engine == null) return;
    var event: c.FlutterPointerEvent = std.mem.zeroes(c.FlutterPointerEvent);
    event.struct_size = @sizeOf(c.FlutterPointerEvent);
    event.phase = switch (host_event.phase) {
        .add => @intCast(c.kAdd),
        .hover => @intCast(c.kHover),
        .remove => @intCast(c.kRemove),
        .down => @intCast(c.kDown),
        .up => @intCast(c.kUp),
        .move => @intCast(c.kMove),
        .scroll => @intCast(c.kHover),
    };
    event.timestamp = if (host_event.time_ms) |time_ms| @as(usize, time_ms) * 1000 else @intCast(runner.now() / 1000);
    event.x = host_event.x;
    event.y = host_event.y;
    event.device = 0;
    event.signal_kind = if (host_event.phase == .scroll) @intCast(c.kFlutterPointerSignalKindScroll) else @intCast(c.kFlutterPointerSignalKindNone);
    event.scroll_delta_x = host_event.scroll_delta_x;
    event.scroll_delta_y = host_event.scroll_delta_y;
    event.device_kind = @intCast(c.kFlutterPointerDeviceKindMouse);
    event.buttons = host_event.buttons;
    event.view_id = view_id;
    try flutter.ensureSuccess(runner.api.send_pointer_event(runner.engine, &event, 1), "FlutterEngineSendPointerEvent");
}

fn pointerCallback(context: ?*anyopaque, host_event: egl.PointerEvent) void {
    const host: *egl.Host = @ptrCast(@alignCast(context.?));
    const runner = engine_runner orelse return;
    sendPointerEvent(runner, host_event, host.view_id) catch |err| {
        std.debug.print("[error] Flutter pointer callback failed: {s}\n", .{@errorName(err)});
    };
}

fn platformMessageCallback(raw_message: [*c]const c.FlutterPlatformMessage, user_data: ?*anyopaque) callconv(.c) void {
    const runner = fromUserData(user_data);
    if (raw_message == null) {
        std.debug.print("Received null Flutter platform message.\n", .{});
        return;
    }
    const message = raw_message.*;
    const channel = if (message.channel == null) "" else std.mem.span(message.channel);
    const payload = if (message.message == null or message.message_size == 0) "" else message.message[0..message.message_size];

    if (std.mem.eql(u8, channel, surface_channel.channel_name)) {
        handleSurfaceChannelMessage(runner, message, payload);
        return;
    }
    if (std.mem.eql(u8, channel, "flutter/textinput")) {
        handleTextInputMessage(runner, message, payload);
        return;
    }
    if (std.mem.eql(u8, channel, "flutter/platform")) {
        handlePlatformChannelMessage(runner, message, payload);
        return;
    }
    std.debug.print("[info] Unsupported Flutter platform channel: {s}\n", .{channel});
    sendEmptyPlatformResponse(runner, message.response_handle);
}

/// 解析 textinput 消息 (setClient/setEditingState/clearClient/show/hide)。
fn handleTextInputMessage(runner: *Runner, message: c.FlutterPlatformMessage, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, runner.gpa, payload, .{}) catch {
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |m| m,
        else => {
            sendEmptyPlatformResponse(runner, message.response_handle);
            return;
        },
    };
    const method = switch (root.get("method") orelse return) {
        .string => |s| s,
        else => return,
    };
    const args = root.get("args");

    if (std.mem.eql(u8, method, "TextInput.setClient")) {
        if (args == null or args.? != .array or args.?.array.items.len < 2) {
            sendEmptyPlatformResponse(runner, message.response_handle);
            return;
        }
        const id = switch (args.?.array.items[0]) {
            .object => |o| switch (o.get("_clientId") orelse return) {
                .integer => |i| i,
                else => return,
            },
            .integer => |i| i,
            else => return,
        };
        const config = args.?.array.items[1];
        var multiline = false;
        var action: []const u8 = "done";
        if (config == .object) {
            if (config.object.get("inputAction")) |ia| {
                if (ia == .string) action = ia.string;
            }
            if (config.object.get("inputType")) |it| {
                if (it == .object) {
                    if (it.object.get("isMultiline")) |ml| {
                        if (ml == .bool) multiline = ml.bool;
                    }
                }
            }
        }
        runner.text_client.clear();
        runner.text_client.client_id = id;
        runner.text_client.active = true;
        runner.text_client.multiline = multiline;
        runner.text_client.input_action = action;
        // TextField 聚焦: 启用 IME + 候选框定位。
        // 优先用引擎提供的 EditableText 几何 (transform + marked rect → 真实光标),
        // 避免 popup 先出现在点击处再跳到光标处的闪烁。
        if (runner.ime) |ime| {
            if (runner.text_client.has_transform and runner.text_client.has_marked_rect) {
                runner.updateImeCursorPosition();
            } else if (runner.focused_host) |focused| {
                // fallback: 焦点窗口的指针位置 (引擎几何未到)。
                ime.setCursorRect(
                    @intFromFloat(@max(focused.pointer_x, 0)),
                    @intFromFloat(@max(focused.pointer_y, 0)),
                    4,
                    24,
                );
            } else {
                ime.setCursorRect(0, 0, 4, 24);
            }
            ime.enable(0, 1);
        }
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.setEditableSizeAndTransform")) {
        // EditableText 局部 → Flutter root 变换矩阵 (官方 GTK 嵌入器同款协议)。
        if (args != null and args.? == .object) {
            if (args.?.object.get("transform")) |tv| {
                if (tv == .array and tv.array.items.len == 16) {
                    var ok = true;
                    for (tv.array.items, 0..) |item, i| {
                        runner.text_client.transform[i] = switch (item) {
                            .float => |f| f,
                            .integer => |iv| @floatFromInt(iv),
                            else => {
                                ok = false;
                                break;
                            },
                        };
                    }
                    if (ok) runner.text_client.has_transform = true;
                }
            }
        }
        // transform 到达不代表 rect 到达; 有 rect 时更新候选框位置。
        if (runner.text_client.has_marked_rect) runner.updateImeCursorPosition();
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.setMarkedTextRect")) {
        // composing 区域 / 光标矩形 (局部坐标, 无 composing 时即光标)。
        if (args != null and args.? == .object) {
            const o = args.?.object;
            const getF = struct {
                fn getv(m: std.json.ObjectMap, key: []const u8) ?f64 {
                    const v = m.get(key) orelse return null;
                    return switch (v) {
                        .float => |fv| fv,
                        .integer => |iv| @floatFromInt(iv),
                        else => null,
                    };
                }
            }.getv;
            if (getF(o, "x")) |x| {
                runner.text_client.marked_rect_x = x;
                runner.text_client.marked_rect_y = getF(o, "y") orelse 0;
                runner.text_client.marked_rect_w = getF(o, "width") orelse 0;
                runner.text_client.marked_rect_h = getF(o, "height") orelse 0;
                runner.text_client.has_marked_rect = true;
                runner.updateImeCursorPosition();
            }
        }
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.setCaretRect")) {
        // 光标矩形 (EditableText 光标移动时发送, Flutter 3.41 独立方法)。
        if (args != null and args.? == .object) {
            const o = args.?.object;
            const getF = struct {
                fn getv(m: std.json.ObjectMap, key: []const u8) ?f64 {
                    const v = m.get(key) orelse return null;
                    return switch (v) {
                        .float => |fv| fv,
                        .integer => |iv| @floatFromInt(iv),
                        else => null,
                    };
                }
            }.getv;
            if (getF(o, "x")) |x| {
                runner.text_client.caret_rect_x = x;
                runner.text_client.caret_rect_y = getF(o, "y") orelse 0;
                runner.text_client.has_caret_rect = true;
                runner.updateImeCursorPosition();
            }
        }
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.setEditingState")) {
        // Flutter 端: invokeMethod('TextInput.setEditingState', value.toJSON())
        // → args 直接是 object (不是 [object] array, 与 setClient 不同)。
        if (args == null or args.? != .object) {
            sendEmptyPlatformResponse(runner, message.response_handle);
            return;
        }
        const state = args.?;
        if (state == .object) {
            var text: []const u8 = "";
            var base: i64 = 0;
            var extent: i64 = 0;
            if (state.object.get("text")) |t| {
                if (t == .string) text = t.string;
            }
            if (state.object.get("selectionBase")) |b| {
                if (b == .integer) base = b.integer;
            }
            if (state.object.get("selectionExtent")) |e| {
                if (e == .integer) extent = e.integer;
            }
            runner.text_client.applyEditingState(text, base, extent) catch |err| {
                std.debug.print("[error] apply editing state failed: {s}\n", .{@errorName(err)});
            };
        }
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.clearClient")) {
        runner.text_client.clear();
        if (runner.ime) |ime| ime.disable();
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    }
    // show / hide / setCaretRect / requestAutofill 等: 空响应即可。
    sendEmptyPlatformResponse(runner, message.response_handle);
}

/// flutter/platform 通道: Clipboard.setData / getData, 其余空响应。
fn handlePlatformChannelMessage(runner: *Runner, message: c.FlutterPlatformMessage, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, runner.gpa, payload, .{}) catch {
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |m| m,
        else => {
            sendEmptyPlatformResponse(runner, message.response_handle);
            return;
        },
    };
    const method = switch (root.get("method") orelse return) {
        .string => |s| s,
        else => return,
    };
    const args = root.get("args");

    if (std.mem.eql(u8, method, "Clipboard.setData")) {
        // args 形状: Flutter 的 Clipboard.setData 发的是 object {"text": ...}
        // (部分版本是 [object] array) — 两种都兼容。
        var text: ?[]const u8 = null;
        if (args != null) {
            switch (args.?) {
                .object => |o| {
                    if (o.get("text")) |t| {
                        if (t == .string) text = t.string;
                    }
                },
                .array => |a| {
                    if (a.items.len >= 1 and a.items[0] == .object) {
                        if (a.items[0].object.get("text")) |t| {
                            if (t == .string) text = t.string;
                        }
                    }
                },
                else => {},
            }
        }
        if (text) |t| {
            runner.clipboard.setText(t) catch |err| {
                std.debug.print("[error] clipboard set failed: {s}\n", .{@errorName(err)});
            };
            // 发布到系统剪贴板 (data-control), 供其他应用读取。
            if (global_data_control) |dc| dc.publish(t);
        } else {
            std.debug.print("[error] Clipboard.setData: no text in args\n", .{});
        }
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "Clipboard.hasStrings")) {
        // Flutter 3.35+: Ctrl+V 前先查剪贴板是否有内容, 期待 {"value": bool}。
        const local_has = runner.clipboard.getText().len > 0;
        const sys_has = if (global_data_control) |dc| dc.hasText() else false;
        const has = local_has or sys_has;
        var buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "[{{\"value\":{}}}]", .{has}) catch {
            sendEmptyPlatformResponse(runner, message.response_handle);
            return;
        };
        sendPlatformResponse(runner, message.response_handle, resp);
        return;
    }
    if (std.mem.eql(u8, method, "Clipboard.getData")) {
        // 系统剪贴板优先 (data-control), 无则回退进程内副本。
        var sys_text: ?[]const u8 = null;
        defer if (sys_text) |t| runner.gpa.free(t);
        if (global_data_control) |dc| sys_text = dc.requestText(runner.gpa);
        const text = sys_text orelse runner.clipboard.getText();
        var buf: [4096]u8 = undefined;
        const escaped = text_input.jsonEscape(runner.gpa, text) catch {
            sendEmptyPlatformResponse(runner, message.response_handle);
            return;
        };
        defer runner.gpa.free(escaped);
        const response = if (text.len == 0)
            "[{\"text\":\"\"}]"
        else
            std.fmt.bufPrint(&buf, "[{{\"text\":\"{s}\"}}]", .{escaped}) catch {
                sendEmptyPlatformResponse(runner, message.response_handle);
                return;
            };
        sendPlatformResponse(runner, message.response_handle, response);
        return;
    }
    // SystemSound / HapticFeedback / SystemChrome 等: 空响应 (引擎不阻塞)。
    sendEmptyPlatformResponse(runner, message.response_handle);
}

fn handleSurfaceChannelMessage(runner: *Runner, message: c.FlutterPlatformMessage, payload: []const u8) void {
    const request = surface_channel.parseRequest(runner.gpa, payload) catch |err| {
        const code = surface_channel.parseErrorCode(err);
        std.debug.print("[error] Invalid fushell surface message: {s}\n", .{code});
        sendSurfaceError(runner, message.response_handle, null, code, "invalid fushell surface request");
        return;
    };
    defer request.deinit(runner.gpa);

    handleSurfaceRequest(runner, message.response_handle, request) catch |err| {
        const code = surfaceRequestErrorCode(err);
        std.debug.print("[error] Fushell surface request failed: {s}\n", .{code});
        sendSurfaceError(runner, message.response_handle, request.id(), code, "fushell surface request failed");
        return;
    };
}

fn handleSurfaceRequest(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.Request) !void {
    switch (request) {
        .open_window => |req| try openWindow(runner, response_handle, req),
        .close_window => |req| try closeWindow(runner, response_handle, req),
        .update_window => |req| try updateWindowSurface(runner, response_handle, req),
        .update_layer => |req| try updateLayerSurface(runner, response_handle, req),
        .exit => |req| try exitProcess(runner, response_handle, req),
    }
}

/// window.open: 创建新窗口 (Wayland role + EGL surface + Flutter view)。
/// 回复在 add_view_callback 确认 added 后发出 (保证 Dart 收到 windowId 时
/// view 已在引擎注册、PlatformDispatcher.views 即将可见)。
fn openWindow(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.OpenWindowRequest) !void {
    lockWindowRegistry();
    defer unlockWindowRegistry();

    // 父窗口解析: 持锁拿父 toplevel (防止父窗口被并发关闭)。
    const parent_toplevel = if (request.parent) |parent_id| blk: {
        const parent_entry = findWindowEntryByViewId(parent_id) orelse return error.ParentWindowNotFound;
        break :blk parent_entry.host.toplevel;
    } else null;

    var slot: ?usize = null;
    for (&window_registry, 0..) |*entry, i| {
        if (!entry.active) {
            slot = i;
            break;
        }
    }
    const slot_index = slot orelse return error.TooManyWindows;
    const view_id = next_view_id;
    next_view_id += 1;
    const entry = &window_registry[slot_index];
    entry.active = true;
    entry.view_id = view_id;
    entry.parent_view_id = request.parent;
    entry.add_pending = true;
    entry.pending_open_response = response_handle;
    entry.pending_open_request_id = request.id;

    // 初始化窗口 (Wayland role + EGL surface)。失败回收槽位。
    const host = &entry.host;
    host.view_id = view_id;
    host.render_context = runner.render_context;
    errdefer {
        host.deinit();
        entry.* = .{};
    }
    try host.attach(runner.state);
    switch (request.role) {
        .window => |w| try host.initializeWindowRole(w, parent_toplevel),
        .layer => |l| try host.initializeLayerRole(l),
    }
    host.setMetricsCallback(metricsCallback, host);
    host.setPointerCallback(pointerCallback, host);

    // FlutterEngineAddView: added 回调 (平台线程) 后回复 Dart。
    const m = host.metrics();
    var view_metrics: c.FlutterWindowMetricsEvent = std.mem.zeroes(c.FlutterWindowMetricsEvent);
    view_metrics.struct_size = @sizeOf(c.FlutterWindowMetricsEvent);
    view_metrics.width = m.width;
    view_metrics.height = m.height;
    view_metrics.pixel_ratio = m.pixel_ratio;
    view_metrics.view_id = view_id;
    var add_info: c.FlutterAddViewInfo = std.mem.zeroes(c.FlutterAddViewInfo);
    add_info.struct_size = @sizeOf(c.FlutterAddViewInfo);
    add_info.view_id = view_id;
    add_info.view_metrics = &view_metrics;
    add_info.user_data = entry;
    add_info.add_view_callback = addViewCallback;
    try flutter.ensureSuccess(runner.api.add_view(runner.engine, &add_info), "FlutterEngineAddView");
    std.debug.print("window.open: view {d} (parent {any})\n", .{ view_id, request.parent });
}

/// Engine-managed thread callback: 仅记录 AddView 结果，资源与 Dart 响应由
/// 平台线程 processViewLifecycleResults 完成。
fn addViewCallback(result: [*c]const c.FlutterAddViewResult) callconv(.c) void {
    const entry: *WindowEntry = @ptrCast(@alignCast(result.*.user_data.?));
    lockWindowRegistry();
    defer unlockWindowRegistry();
    if (!entry.active or !entry.add_pending) return;
    entry.add_result_added = result.*.added;
    entry.add_result_ready = true;
}

/// 提交异步 RemoveView。调用方必须持有窗口注册表锁；失败时回滚 pending 状态。
fn beginWindowRemoval(
    runner: *Runner,
    entry: *WindowEntry,
    response_handle: ?*const c.FlutterPlatformMessageResponseHandle,
    request_id: i64,
) !void {
    if (entry.remove_pending) return error.WindowClosePending;
    entry.remove_pending = true;
    entry.pending_close_response = response_handle;
    entry.pending_close_request_id = request_id;
    errdefer {
        entry.remove_pending = false;
        entry.pending_close_response = null;
        entry.pending_close_request_id = 0;
    }

    var remove_info: c.FlutterRemoveViewInfo = std.mem.zeroes(c.FlutterRemoveViewInfo);
    remove_info.struct_size = @sizeOf(c.FlutterRemoveViewInfo);
    remove_info.view_id = entry.view_id;
    remove_info.user_data = entry;
    remove_info.remove_view_callback = removeViewCallback;
    try flutter.ensureSuccess(runner.api.remove_view(runner.engine, &remove_info), "FlutterEngineRemoveView");
}

/// window.close: RemoveView → removed 回调确认后才销毁 surface。
fn closeWindow(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.CloseWindowRequest) !void {
    lockWindowRegistry();
    defer unlockWindowRegistry();
    const entry = findWindowEntryByViewId(request.window_id) orelse return error.WindowNotFound;
    try beginWindowRemoval(runner, entry, response_handle, request.id);
    std.debug.print("window.close: view {d} (remove pending)\n", .{request.window_id});
}

/// Wayland close listener 只置位；下一次平台线程 tick 在 listener 栈外提交
/// RemoveView，避免回调派发期间销毁 xdg/layer 对象。
fn processCompositorCloseRequests(runner: *Runner) void {
    lockWindowRegistry();
    defer unlockWindowRegistry();
    for (&window_registry) |*entry| {
        if (!entry.active or entry.add_pending or entry.remove_pending or !entry.host.takeCloseRequest()) continue;
        const view_id = entry.view_id;
        beginWindowRemoval(runner, entry, null, 0) catch |err| {
            std.debug.print("[error] compositor close failed for view {d}: {s}\n", .{ view_id, @errorName(err) });
            continue;
        };
        std.debug.print("compositor close: view {d} (remove pending)\n", .{view_id});
    }
}

/// Engine-managed thread callback: 仅记录 RemoveView 结果。即使 removed=true，
/// 也不得在这里触碰 Wayland/EGL；平台线程 tick 才执行销毁。
fn removeViewCallback(result: [*c]const c.FlutterRemoveViewResult) callconv(.c) void {
    const entry: *WindowEntry = @ptrCast(@alignCast(result.*.user_data.?));
    lockWindowRegistry();
    defer unlockWindowRegistry();
    if (!entry.active or !entry.remove_pending) return;
    entry.remove_result_removed = result.*.removed;
    entry.remove_result_ready = true;
}

fn processViewLifecycleResults(runner: *Runner) void {
    const Completion = enum { none, add_succeeded, add_failed, remove_succeeded, remove_failed };

    for (0..window_registry.len) |index| {
        var completion: Completion = .none;
        var handle: ?*const c.FlutterPlatformMessageResponseHandle = null;
        var request_id: i64 = 0;
        var view_id: i64 = 0;

        lockWindowRegistry();
        const entry = &window_registry[index];
        if (entry.active and entry.add_result_ready) {
            handle = entry.pending_open_response;
            request_id = entry.pending_open_request_id;
            view_id = entry.view_id;
            entry.add_result_ready = false;
            entry.add_pending = false;
            entry.pending_open_response = null;
            entry.pending_open_request_id = 0;
            if (entry.add_result_added) {
                completion = .add_succeeded;
            } else {
                entry.host.deinit();
                entry.* = .{};
                completion = .add_failed;
            }
        } else if (entry.active and entry.remove_result_ready) {
            handle = entry.pending_close_response;
            request_id = entry.pending_close_request_id;
            view_id = entry.view_id;
            entry.remove_result_ready = false;
            entry.pending_close_response = null;
            entry.pending_close_request_id = 0;
            if (entry.remove_result_removed) {
                if (runner.focused_host == &entry.host) runner.focused_host = null;
                entry.host.deinit();
                for (&window_registry) |*child| {
                    if (child.active and child.parent_view_id == view_id) child.parent_view_id = null;
                }
                entry.* = .{};
                completion = .remove_succeeded;
            } else {
                entry.remove_pending = false;
                completion = .remove_failed;
            }
        }
        unlockWindowRegistry();

        switch (completion) {
            .none => {},
            .add_succeeded => {
                const response = surface_channel.openSuccessResponse(runner.gpa, request_id, view_id) catch |err| {
                    std.debug.print("[error] Failed to encode window.open response: {s}\n", .{@errorName(err)});
                    continue;
                };
                defer runner.gpa.free(response);
                if (handle) |h| sendPlatformResponse(runner, h, response);
            },
            .add_failed => {
                std.debug.print("[error] FlutterEngineAddView reported added=false for view {d}\n", .{view_id});
                if (handle) |h| sendSurfaceError(runner, h, request_id, "AddViewFailed", "engine rejected the new view");
            },
            .remove_succeeded => {
                if (handle) |h| sendSurfaceSuccess(runner, h, request_id);
                std.debug.print("window.close: view {d} removed and surface destroyed.\n", .{view_id});
            },
            .remove_failed => {
                std.debug.print("[error] FlutterEngineRemoveView reported removed=false for view {d}\n", .{view_id});
                if (handle) |h| sendSurfaceError(runner, h, request_id, "RemoveViewFailed", "engine could not remove the view");
            },
        }
    }
}

fn updateLayerSurface(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.LayerUpdateRequest) !void {
    lockWindowRegistry();
    defer unlockWindowRegistry();
    const entry = findWindowEntryByViewId(request.window_id) orelse return error.WindowNotFound;
    _ = try entry.host.updateLayerRole(request.update);
    sendSurfaceSuccess(runner, response_handle, request.id);
}

fn updateWindowSurface(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.WindowUpdateRequest) !void {
    lockWindowRegistry();
    defer unlockWindowRegistry();
    const entry = findWindowEntryByViewId(request.window_id) orelse return error.WindowNotFound;
    _ = try entry.host.updateWindowRole(request.update);
    sendSurfaceSuccess(runner, response_handle, request.id);
}

/// process.exit: 停止事件循环 → run() 退出序列 (关引擎 → 毁窗口 → 断连接)。
fn exitProcess(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.ExitRequest) !void {
    sendSurfaceSuccess(runner, response_handle, request.id);
    quit_requested.store(true, .release);
    std.debug.print("process.exit({d}) requested; stopping event loop.\n", .{request.code});
}

/// 退出序列: 引擎已关闭 (无 present), 销毁全部剩余窗口。
fn shutdownAllWindows() void {
    lockWindowRegistry();
    defer unlockWindowRegistry();
    for (&window_registry) |*entry| {
        if (!entry.active) continue;
        entry.host.deinit();
        entry.* = .{};
    }
}

fn surfaceRequestErrorCode(err: anyerror) []const u8 {
    return @errorName(err);
}

fn sendSurfaceSuccess(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, id: i64) void {
    const response = surface_channel.successResponse(runner.gpa, id) catch |err| {
        std.debug.print("[error] Failed to encode fushell surface success response: {s}\n", .{@errorName(err)});
        return;
    };
    defer runner.gpa.free(response);
    sendPlatformResponse(runner, response_handle, response);
}

fn sendSurfaceError(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, id: ?i64, code: []const u8, message: []const u8) void {
    const response = surface_channel.errorResponse(runner.gpa, id, code, message) catch |err| {
        std.debug.print("[error] Failed to encode fushell surface error response: {s}\n", .{@errorName(err)});
        return;
    };
    defer runner.gpa.free(response);
    sendPlatformResponse(runner, response_handle, response);
}

fn sendPlatformResponse(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, response: []const u8) void {
    if (response_handle == null) {
        std.debug.print("Flutter platform message had no response handle.\n", .{});
        return;
    }
    if (runner.engine == null) {
        std.debug.print("[error] Cannot reply to Flutter platform message before engine handle is available.\n", .{});
        return;
    }
    const result = runner.api.send_platform_message_response(runner.engine, response_handle, response.ptr, response.len);
    if (result != c.kSuccess) {
        std.debug.print("[error] FlutterEngineSendPlatformMessageResponse failed: {s}\n", .{flutter.resultName(result)});
    }
}

fn sendEmptyPlatformResponse(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
    if (response_handle == null) return;
    if (runner.engine == null) {
        std.debug.print("[error] Cannot reply to unsupported Flutter platform message before engine handle is available.\n", .{});
        return;
    }
    const result = runner.api.send_platform_message_response(runner.engine, response_handle, null, 0);
    if (result != c.kSuccess) {
        std.debug.print("[error] FlutterEngineSendPlatformMessageResponse(empty) failed: {s}\n", .{flutter.resultName(result)});
    }
}

fn makeCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    // raster 渲染目标永远是 bootstrap pbuffer (compositor 路径: 引擎渲进 backing
    // store 纹理, 窗口 surface 只用于呈现)。
    runner.render_context.makeCurrent() catch |err| {
        std.debug.print("[error] Flutter make_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    runner.beginRender();
    return true;
}

fn clearCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    runner.render_context.clearCurrent() catch |err| {
        std.debug.print("[error] Flutter clear_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

fn presentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    // compositor 路径下呈现由 present_view_callback 接管 (官方 GTK 嵌入器同款 no-op)。
    if (!runner.first_present_logged) {
        std.debug.print("renderer present invoked; presentation handled by compositor present_view_callback.\n", .{});
        runner.first_present_logged = true;
    }
    return true;
}

/// compositor: 为引擎 layer 创建 GL 纹理 backing store (kFlutterBackingStoreTypeOpenGL)。
/// 在 raster 线程调用, GL context 已 current。
fn createBackingStoreCallback(config_ptr: [*c]const c.FlutterBackingStoreConfig, backing_store_ptr: [*c]c.FlutterBackingStore, user_data: ?*anyopaque) callconv(.c) bool {
    const config: *const c.FlutterBackingStoreConfig = @ptrCast(config_ptr);
    const backing_store_out: *c.FlutterBackingStore = @ptrCast(backing_store_ptr);
    _ = fromUserData(user_data);
    const width: c.GLsizei = @intFromFloat(@ceil(@max(config.size.width, 1.0)));
    const height: c.GLsizei = @intFromFloat(@ceil(@max(config.size.height, 1.0)));
    var texture: c.GLuint = 0;
    c.glGenTextures(1, &texture);
    if (texture == 0) {
        std.debug.print("[error] glGenTextures failed for backing store {d}x{d}\n", .{ width, height });
        return false;
    }
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    // internalformat 与 format 报告都用 GL_RGBA8 (0x8058): 引擎按 FlutterOpenGLTexture.format
    // 映射 SkColorType, GL_RGBA (6408) 不被支持 ("Cannot convert format 6408")。
    const GL_RGBA8: c.GLint = 0x8058;
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    backing_store_out.* = std.mem.zeroes(c.FlutterBackingStore);
    backing_store_out.struct_size = @sizeOf(c.FlutterBackingStore);
    backing_store_out.type = c.kFlutterBackingStoreTypeOpenGL;
    backing_store_out.unnamed_0.open_gl.type = c.kFlutterOpenGLTargetTypeTexture;
    backing_store_out.unnamed_0.open_gl.unnamed_0.texture.target = c.GL_TEXTURE_2D;
    backing_store_out.unnamed_0.open_gl.unnamed_0.texture.name = texture;
    backing_store_out.unnamed_0.open_gl.unnamed_0.texture.format = 0x8058; // GL_RGBA8
    backing_store_out.unnamed_0.open_gl.unnamed_0.texture.width = @intCast(width);
    backing_store_out.unnamed_0.open_gl.unnamed_0.texture.height = @intCast(height);
    return true;
}

/// compositor: 回收 backing store 纹理。
fn collectBackingStoreCallback(backing_store_ptr: [*c]const c.FlutterBackingStore, user_data: ?*anyopaque) callconv(.c) bool {
    const backing_store: *const c.FlutterBackingStore = @ptrCast(backing_store_ptr);
    _ = user_data;
    if (backing_store.type != c.kFlutterBackingStoreTypeOpenGL) return true;
    const texture = backing_store.unnamed_0.open_gl.unnamed_0.texture;
    if (texture.name != 0) {
        const name = texture.name;
        c.glDeleteTextures(1, &name);
    }
    return true;
}

/// compositor: 将 view 的 layer tree blit 到对应窗口 EGL surface 并 swap。
/// view 0 (implicit, 无头) no-op; 其余按注册表查窗口。
fn presentViewCallback(info_ptr: [*c]const c.FlutterPresentViewInfo) callconv(.c) bool {
    const info: *const c.FlutterPresentViewInfo = @ptrCast(info_ptr);
    if (info.view_id == 0) return true; // 无头 implicit view: 丢弃
    const runner = fromUserData(info.user_data);
    lockWindowRegistry();
    const entry = findWindowEntryByViewId(info.view_id) orelse {
        unlockWindowRegistry();
        return true; // 窗口已关闭
    };
    if (entry.remove_pending) {
        unlockWindowRegistry();
        return true;
    }
    const host = &entry.host;
    const lock_ok = host.present_mutex.tryLock();
    unlockWindowRegistry();
    if (!lock_ok) {
        return true; // resize 中: 跳帧 (引擎会重试下一帧)
    }
    defer host.present_mutex.unlock();

    if (!host.isReady()) return true;
    runner.render_context.makeSurfaceCurrent(host.egl_surface) catch |err| {
        std.debug.print("[error] present_view makeSurfaceCurrent failed: {s}\n", .{@errorName(err)});
        return false;
    };
    const blitter = &runner.blitter;
    blitter.init() catch |err| {
        std.debug.print("[error] blit init failed: {s}\n", .{@errorName(err)});
        return false;
    };
    const metrics = host.metrics();
    const vp_w: f32 = @floatFromInt(metrics.width);
    const vp_h: f32 = @floatFromInt(metrics.height);
    for (0..info.layers_count) |i| {
        const layer: *const c.FlutterLayer = @ptrCast(info.layers[i]);
        switch (layer.type) {
            c.kFlutterLayerContentTypeBackingStore => {
                const bs: *const c.FlutterBackingStore = @ptrCast(layer.unnamed_0.backing_store);
                const texture = bs.unnamed_0.open_gl.unnamed_0.texture;
                blitter.blitLayer(texture.name, @floatCast(layer.offset.x), @floatCast(layer.offset.y), @floatCast(layer.size.width), @floatCast(layer.size.height), vp_w, vp_h);
            },
            else => {
                std.debug.print("unsupported layer type in present: {}\n", .{layer.type});
            },
        }
    }
    runner.render_context.swapBuffers(host.egl_surface) catch |err| {
        std.debug.print("[error] present_view swapBuffers failed: {s}\n", .{@errorName(err)});
        return false;
    };
    if (!runner.compositor_first_present_logged) {
        std.debug.print("Flutter presented first frame via compositor (view {d}).\n", .{info.view_id});
        runner.compositor_first_present_logged = true;
    }
    return true;
}

fn fboCallback(user_data: ?*anyopaque) callconv(.c) u32 {
    _ = user_data;
    // compositor 路径不使用 embedder FBO (引擎渲进 backing store 纹理)。
    return 0;
}

fn glProcResolverCallback(user_data: ?*anyopaque, name: [*c]const u8) callconv(.c) ?*anyopaque {
    const runner = fromUserData(user_data);
    const name_z: [*:0]const u8 = @ptrCast(name);
    // eglGetProcAddress → GLES library fallback (与旧 Host.resolveGlProc 同逻辑,
    // 现由引擎级 state 提供)。
    const proc = c.eglGetProcAddress(name_z);
    if (proc != null) return @ptrCast(@constCast(proc));
    if (runner.state.gles_library) |*gles_library| {
        if (gles_library.lookup(?*anyopaque, std.mem.span(name_z))) |symbol| return symbol;
    }
    std.debug.print("Flutter GL proc resolver could not resolve: {s}\n", .{name_z});
    return null;
}

fn vsyncCallback(user_data: ?*anyopaque, baton: isize) callconv(.c) void {
    const runner = fromUserData(user_data);
    if (runner.engine == null) {
        std.debug.print("[error] Flutter vsync requested before engine handle was available; dropping baton {d}.\n", .{baton});
        return;
    }
    const frame_start = runner.now();
    const frame_target = frame_start + frame_interval_nanos;
    const result = runner.api.on_vsync(runner.engine, baton, frame_start, frame_target);
    if (result != c.kSuccess) {
        std.debug.print("[error] FlutterEngineOnVsync failed: {s}\n", .{flutter.resultName(result)});
    }
}

/// 热重载: 从引擎日志解析出的 VM service URI (http://127.0.0.1:PORT/TOKEN/)。
/// logMessageCallback (主线程) 写入, hot_reload 线程读取 — 带锁共享。
pub const VmServiceState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    uri: [512]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *VmServiceState, value: []const u8) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (value.len > self.uri.len) return;
        @memcpy(self.uri[0..value.len], value);
        self.len = value.len;
    }

    pub fn get(self: *VmServiceState, out: []u8) ?[]const u8 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.len == 0 or self.len > out.len) return null;
        @memcpy(out[0..self.len], self.uri[0..self.len]);
        return out[0..self.len];
    }
};
pub var vm_service: VmServiceState = .{};

fn logMessageCallback(tag: [*c]const u8, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const safe_tag = if (tag == null) "flutter" else std.mem.span(tag);
    const safe_message = if (message == null) "" else std.mem.span(message);
    std.debug.print("[{s}] {s}\n", .{ safe_tag, safe_message });

    // 解析 VM service 地址: "The Dart VM service is listening on http://..."
    {
        const prefix = "The Dart VM service is listening on ";
        if (std.mem.indexOf(u8, safe_message, prefix)) |idx| {
            const rest = safe_message[idx + prefix.len ..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
            if (end > 0) {
                vm_service.set(rest[0..end]);
                std.debug.print("[fushell] VM service URI: {s}\n", .{rest[0..end]});
            }
        }
    }
}
