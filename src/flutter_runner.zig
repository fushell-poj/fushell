//! 拥有一个 Flutter 引擎，并协调 Fushell 的平台线程运行时。
//!
//! 引擎以无头方式启动并禁用 implicit view。Dart 通过 platform channel 创建和移除
//! 显式 view；每个 view 映射到 [WindowRegistry] 中的一个 Wayland Host，而全部
//! view 共享同一个 isolate、compositor、输入状态与事件泵。平台回调、D-Bus dispatch
//! 和生命周期迁移均在本线程串行执行。raster 回调可能并发进入 compositor，因此只能
//! 接触已同步的渲染状态。
//!
//! 关闭顺序是刻意规定的：先停止引擎，再销毁 view 与共享 Wayland 服务，最后释放
//! display 和动态加载的引擎。改变顺序可能让回调继续指向已释放的 Host。

const std = @import("std");
const platform_event_loop = @import("platform_event_loop.zig");
const frame_clock = @import("frame_clock.zig");
const owned_arguments = @import("owned_arguments.zig");
const process_exit = @import("process_exit.zig");
const c = @import("c");
const egl = @import("wayland_egl_host.zig");
const flutter = @import("flutter_embedder.zig");
const surface_channel = @import("surface_channel.zig");
const display_state = @import("wl_display_state.zig");
const text_input = @import("text_input.zig");
const platform_channels = @import("platform_channels.zig");
const clipboard_service = @import("clipboard_service.zig");
const data_control = @import("data_control.zig");
const ime_v3 = @import("ime_v3.zig");
const gl_blit = @import("gl_blit.zig");
const xkb = @import("xkb.zig");
const flutter_task_queue = @import("flutter_task_queue.zig");
const flutter_compositor = @import("flutter_compositor.zig");
const window_registry = @import("window_registry.zig");
const bundle_loader = @import("bundle_loader.zig");
const application_broker = @import("application_broker.zig");
const application_output = @import("application_output.zig");
const service_uri = @import("service_uri.zig");
const WindowEntry = window_registry.Entry;
const WindowRegistry = window_registry.Registry;
const wayland = @import("wayland");
const wl = wayland.client.wl;

/// 进程退出时显式释放共享 dc/ime (此刻 state Wayland 仍有效, 清理安全)。
/// ImeV3 持有 Wayland 对象 (text_input 等), 由 state 的 disconnect 统一收尾;
/// 这里只回收 gpa.create 的对象内存 + DataControl 内部 buffer。
fn shutdownShared(gpa: std.mem.Allocator, state: *display_state.DisplayState) void {
    if (state.data_control) |dc| {
        dc.deinit();
        gpa.destroy(dc);
        state.data_control = null;
    }
    if (state.ime) |ime| {
        ime.deinit();
        gpa.destroy(ime);
        state.ime = null;
    }
}

fn applyPhysicalKeyTransition(state: anytype, keycode: u32, pressed: bool) u32 {
    return state.updateKey(keycode, pressed);
}

fn dispatchKeyRepeat(handler: anytype, key: u32) void {
    handler.sendKeyboardEvent(key, true);
    handler.applyTextKey(key);
}

fn runnerFromContext(context: ?*anyopaque) *Runner {
    return @ptrCast(@alignCast(context orelse @panic("runner callback context is null")));
}

/// 主线程 dispatch 键盘事件: enter/leave 更新焦点窗口, 事件交给引擎
/// (单引擎: xkb/text_input 为引擎级状态, 焦点窗口由 surface 路由派生)。
fn displayKeyboardRouter(event: display_state.KeyboardEvent, surface: ?*wl.Surface, context: ?*anyopaque) void {
    const runner = runnerFromContext(context);
    switch (event) {
        .enter => runner.focused_host = runner.registry.findHostBySurfaceLocked(surface),
        .leave => runner.focused_host = null,
        else => {},
    }
    runner.handleKeyboardEvent(event);
}

/// IME 事件路由: 投给键盘焦点窗口 (IME 是全局对象, 事件随焦点窗口)。
/// text_input.Client 的 send_fn: 发 updateEditingState 到引擎。
fn textInputSendCallback(client_id: i64, msg: []const u8, context: ?*anyopaque) void {
    _ = client_id;
    runnerFromContext(context).sendToEngine("flutter/textinput", msg);
}

fn imeEventRouter(event: ime_v3.ImeEvent, ctx: ?*anyopaque) void {
    // enter/leave 事件带 surface → 精确路由到对应窗口。
    // (不能依赖 keyboard_focused: text_input enter 可能先于 wl_keyboard.enter 到达)
    var surface: ?*wl.Surface = null;
    switch (event) {
        .enter => |e| surface = e.surface,
        .leave => |e| surface = e.surface,
        else => {},
    }
    const runner = runnerFromContext(ctx);
    if (surface) |s| {
        // 事件属于某窗口 surface: 只有焦点窗口才处理 (非焦点窗口的 enter
        // 意味着焦点切换, 真正生效的是新焦点窗口)。
        if (runner.registry.findHostBySurfaceLocked(s)) |host| {
            if (runner.focused_host != host and event == .enter) {
                runner.focused_host = host;
            }
        } else return;
    }
    runner.handleImeEvent(event);
}

const PointerFocusAction = enum { enter, leave, current };

fn pointerFocusTarget(comptime T: type, focus: *?*T, action: PointerFocusAction, entered: ?*T) ?*T {
    return switch (action) {
        .enter => blk: {
            focus.* = entered;
            break :blk entered;
        },
        .leave => blk: {
            const target = focus.*;
            focus.* = null;
            break :blk target;
        },
        .current => focus.*,
    };
}

/// Wayland 只有 enter/leave 携带 surface；其余事件必须沿用最近一次 enter 建立的
/// Host 引用。该引用只由平台线程读写，并在 Host 释放前清除。
fn displayPointerRouter(event: wl.Pointer.Event, surface: ?*wl.Surface, context: ?*anyopaque) void {
    const runner = runnerFromContext(context);
    const action: PointerFocusAction = switch (event) {
        .enter => .enter,
        .leave => .leave,
        else => .current,
    };
    const entered = if (action == .enter) runner.registry.findHostBySurfaceLocked(surface) else null;
    const target = pointerFocusTarget(egl.Host, &runner.pointer_focused_host, action, entered) orelse return;
    target.handlePointerEvent(event);
}

const PendingClipboardRead = struct {
    destination: enum { platform, text_input },
    response_handle: ?*const c.FlutterPlatformMessageResponseHandle = null,
    deadline_ns: u64,
};

const PendingApplicationWriteResponse = struct {
    id: u64,
    response_handle: ?*const c.FlutterPlatformMessageResponseHandle,
};

/// 构造 Flutter 引擎时使用的不可变进程配置。
///
/// 所有路径与参数切片在 `run` 期间均为借用。shutdown 描述符和可选 broker 仍由
/// 进程入口拥有；runner 清理时不会关闭或反初始化它们。
pub const Options = struct {
    io: std.Io,
    /// 使用 `dlopen` 加载的绝对路径或相对 bundle 的引擎库路径。
    engine_library: []const u8,
    /// 包含 `data/flutter_assets` 以及可选 AOT 库的 bundle 根目录。
    bundle_path: []const u8,
    /// null disables VM Service; 0 requests a random localhost port.
    vm_service_port: ?u16 = null,
    /// SIGINT/SIGTERM notification owned by the process entry point.
    shutdown_fd: c_int = -1,
    /// Optional single-instance D-Bus broker owned by the process entry point.
    application_broker: ?*application_broker.Broker = null,
    /// Opaque application argv delivered to Dart main in multiple-instance mode.
    /// Single-instance mode leaves this empty and uses the application channel.
    dart_entrypoint_arguments: []const []const u8 = &.{},
};

/// 引擎与全部进程级运行时服务的平台线程所有者。
///
/// `registry` 是 view 生命周期的唯一权威；只有对应 registry 状态允许时才能借用
/// 原始 Host 指针。`broker` 为可选值，因此多实例应用无需承担 D-Bus 运行时成本。
pub const FatalReason = enum {
    platform_response_failed,
    platform_response_encoding_failed,
    platform_message_failed,
    application_broker_failed,
};

pub fn responseFailureIsFatal(result: platform_channels.ResponseSendResult) bool {
    return platform_channels.responseSendIsFatal(result);
}

fn completionResponseAllowsDispatch(result: platform_channels.ResponseSendResult) bool {
    return result == .sent;
}

pub const CompletionBarrierError = error{ CompletionResponseFailed, CompletionDispatchFailed };

/// 统一执行 complete → response → next dispatch；response 未送达时绝不推进队列。
pub fn runCompletionBarrier(coordinator: anytype) !void {
    try coordinator.complete();
    if (!completionResponseAllowsDispatch(coordinator.sendResponse())) {
        return error.CompletionResponseFailed;
    }
    coordinator.dispatch() catch return error.CompletionDispatchFailed;
}

const Runner = struct {
    gpa: std.mem.Allocator,
    /// 进程级共享显示状态 (窗口创建 / IME / 剪贴板用)。
    state: *display_state.DisplayState,
    registry: *WindowRegistry,
    quit_requested: std.atomic.Value(bool) = .init(false),
    fatal_reason: ?FatalReason = null,
    /// 进程级共享 render context (raster + 全部窗口呈现)。
    render_context: *egl.RenderContext,
    api: *flutter.Api,
    engine_library: []const u8,
    bundle_path: []const u8,
    engine: c.FlutterEngine = null,
    platform_thread_id: std.Thread.Id = undefined,
    task_queue: *flutter_task_queue.TaskQueue,
    bootstrap_render_logged: bool = false,
    bootstrap_resource_logged: bool = false,
    bootstrap_present_logged: bool = false,
    first_present_logged: bool = false,
    /// Stack-owned guard for the synchronous platform message currently being dispatched.
    active_platform_response: ?*platform_channels.Response = null,
    /// 同一时刻只允许一个 native EAGAIN 对应的 Dart write response。
    pending_application_write_response: ?PendingApplicationWriteResponse = null,
    application_broker: ?*application_broker.Broker = null,
    application_ready: bool = false,
    /// A command handler may request process exit before its D-Bus reply is sent.
    /// Defer the event-loop stop until applicationComplete flushes that reply.
    exit_after_application_command: bool = false,
    exit_status: process_exit.Status = .{},
    frame_clock: frame_clock.Clock,

    // ── compositor 呈现路径 ────────────────────────
    /// Context-owned GLES3 compositor; each presentation isolates a complete frame.
    blitter: gl_blit.Blitter = .{},
    compositor_first_present_logged: bool = false,

    // ── 输入 / 文本 / 剪贴板 ──────────────────────
    text_client: text_input.Client = undefined,
    clipboard: clipboard_service.Service = undefined,
    pending_clipboard_read: ?PendingClipboardRead = null,
    ime: ?*ime_v3.ImeV3 = null,
    xkb_state: xkb.Xkb = .{},
    /// 键盘焦点窗口 (wl_keyboard.enter 的 surface → 窗口注册表)。
    /// null = 无焦点窗口 (键盘事件被丢弃)。
    focused_host: ?*egl.Host = null,
    /// 指针 enter 建立的窗口焦点；motion/button/axis 本身不携带 surface。
    pointer_focused_host: ?*egl.Host = null,
    // 键盘长按重复 (wl_keyboard.repeat_info): delay 后按 rate 模拟 keydown。
    repeat_delay_ms: u32 = 500,
    repeat_rate_per_sec: u32 = 25,
    repeat_active_key: ?u32 = null,
    repeat_next_time_ns: u64 = 0,
    last_modifiers: u32 = 0,

    fn now(self: *Runner) u64 {
        return self.api.get_current_time();
    }

    fn requestFatal(self: *Runner, reason: FatalReason) void {
        if (self.fatal_reason == null) self.fatal_reason = reason;
        self.quit_requested.store(true, .release);
    }

    pub fn fatalReason(self: *const Runner) ?FatalReason {
        return self.fatal_reason;
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
            // Repeat reuses the already-pressed key state. A repeat is not another
            // physical XKB transition and must not call updateKey again.
            dispatchKeyRepeat(self, key);
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
                _ = applyPhysicalKeyTransition(&self.xkb_state, k.key, k.state == .pressed);
                // 无论焦点/文本客户端, 都向 Flutter 发送 RawKeyEvent
                // (EditableText 靠它实现 Ctrl+C/V/A 等快捷键)。
                self.sendKeyboardEvent(k.key, k.state == .pressed);
                if (self.focused_host == null or !self.text_client.active) return;
                const pressed = k.state == .pressed;
                if (pressed) {
                    // 启动长按重复计时 (repeat_info 的 delay 后按 rate 重复)。
                    self.repeat_active_key = k.key;
                    self.repeat_next_time_ns = nowNs() + @as(u64, self.repeat_delay_ms) * 1_000_000;
                    self.applyTextKey(k.key);
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
                        ime.setCursorRect(@intFromFloat(x), @intFromFloat(y), 4, @intFromFloat(@max(self.text_client.marked_rect_h, 16)));
                    } else if (self.focused_host) |focused| {
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
    pub fn updateImeCursorPosition(self: *Runner) void {
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

    /// Applies the text-editing effect of a key whose physical XKB transition
    /// was already processed by handleKeyboardEvent.
    fn applyTextKey(self: *Runner, keycode: u32) void {
        const sym = self.xkb_state.getSym(keycode);

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
        if (self.pending_clipboard_read != null) return;
        const start = self.clipboard.beginReadText() catch |err| {
            std.debug.print("[error] clipboard read failed: {s}\n", .{@errorName(err)});
            return;
        };
        switch (start) {
            .immediate => |text| {
                defer self.gpa.free(text);
                if (text.len == 0) return;
                self.text_client.insertText(text) catch |err| {
                    std.debug.print("[error] paste failed: {s}\n", .{@errorName(err)});
                    return;
                };
                self.sendTextInputUpdate();
            },
            .pending => self.pending_clipboard_read = .{
                .destination = .text_input,
                .deadline_ns = nowNs() + clipboard_service.read_timeout_ns,
            },
        }
    }

    fn sendTextInputUpdate(self: *Runner) void {
        if (self.text_client.active) self.text_client.sendUpdate();
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
            self.requestFatal(.platform_message_failed);
        }
    }

    fn queueFlutterTask(self: *Runner, task: c.FlutterTask, target_time_nanos: u64) void {
        self.task_queue.post(task, target_time_nanos);
    }

    fn runDueFlutterTasks(self: *Runner) !void {
        if (self.task_queue.hasFailed()) return error.FlutterTaskQueueFailed;
        try self.pumpClipboardRead();
        while (self.task_queue.popDue(self.now())) |task| {
            if (self.engine == null) return;
            try flutter.ensureSuccess(self.api.run_task(self.engine, &task), "FlutterEngineRunTask");
        }
    }

    fn completeClipboardRead(self: *Runner, pending: PendingClipboardRead, text: ?[]const u8, failure: ?anyerror) void {
        switch (pending.destination) {
            .text_input => if (failure == null) {
                if (text) |content| {
                    if (content.len > 0) {
                        self.text_client.insertText(content) catch |err| {
                            std.debug.print("[error] clipboard paste failed: {s}\n", .{@errorName(err)});
                            return;
                        };
                        self.sendTextInputUpdate();
                    }
                }
            },
            .platform => {
                if (failure) |err| {
                    const message_text = std.fmt.allocPrint(self.gpa, "clipboard read failed: {s}", .{@errorName(err)}) catch {
                        self.sendEmptyPlatformResponse(pending.response_handle);
                        return;
                    };
                    defer self.gpa.free(message_text);
                    self.sendPlatformMethodError(pending.response_handle, "ClipboardReadFailed", message_text);
                    return;
                }
                const response = platform_channels.encodeClipboardText(self.gpa, text orelse "") catch |err| {
                    std.debug.print("[error] clipboard getData response allocation failed: {s}\n", .{@errorName(err)});
                    self.sendEmptyPlatformResponse(pending.response_handle);
                    return;
                };
                defer self.gpa.free(response);
                self.sendPlatformResponse(pending.response_handle, response);
            },
        }
    }

    fn pumpClipboardRead(self: *Runner) !void {
        const pending = self.pending_clipboard_read orelse return;
        const progress = self.clipboard.pumpReadText() catch |err| {
            self.pending_clipboard_read = null;
            self.completeClipboardRead(pending, null, err);
            return;
        };
        switch (progress) {
            .pending => {
                if (nowNs() < pending.deadline_ns) return;
                self.clipboard.cancelReadText();
                self.pending_clipboard_read = null;
                self.completeClipboardRead(pending, null, error.ClipboardReadTimedOut);
            },
            .complete => |text| {
                defer if (text) |content| self.gpa.free(content);
                self.pending_clipboard_read = null;
                self.completeClipboardRead(pending, text, null);
            },
        }
    }

    pub fn handleSurfaceRequest(self: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.Request) !void {
        return runnerHandleSurfaceRequest(self, response_handle, request);
    }

    pub fn surfaceRequestErrorCode(self: *Runner, err: anyerror) []const u8 {
        return runnerSurfaceRequestErrorCode(self, err);
    }

    pub fn sendSurfaceError(self: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, id: ?i64, code: []const u8, message: []const u8) void {
        runnerSendSurfaceError(self, response_handle, id, code, message);
    }

    pub fn sendPlatformMethodError(self: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, code: []const u8, message: []const u8) void {
        _ = runnerSendPlatformMethodError(self, response_handle, code, message);
    }

    pub fn sendPlatformResponse(self: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, response: []const u8) void {
        _ = runnerSendPlatformResponse(self, response_handle, response);
    }

    pub fn sendEmptyPlatformResponse(self: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
        runnerSendEmptyPlatformResponse(self, response_handle);
    }

    fn nextPollTimeoutMs(self: *Runner) i32 {
        var timeout = self.task_queue.timeoutMs(self.now());
        const frame_timeout = self.frame_clock.timeoutMs(self.now());
        if (frame_timeout >= 0 and (timeout < 0 or frame_timeout < timeout)) timeout = frame_timeout;
        if (self.pending_clipboard_read) |pending| {
            const now_nanos = nowNs();
            const clipboard_timeout: i32 = if (pending.deadline_ns <= now_nanos)
                0
            else
                @intCast(@min((pending.deadline_ns - now_nanos + 999_999) / 1_000_000, @as(u64, std.math.maxInt(i32))));
            if (timeout < 0 or clipboard_timeout < timeout) timeout = clipboard_timeout;
        }
        if (self.repeat_active_key != null) {
            const now_nanos = nowNs();
            const repeat_timeout: i32 = if (self.repeat_next_time_ns <= now_nanos)
                0
            else
                @intCast(@min((self.repeat_next_time_ns - now_nanos + 999_999) / 1_000_000, @as(u64, std.math.maxInt(i32))));
            if (timeout < 0 or repeat_timeout < timeout) timeout = repeat_timeout;
        }
        if (self.application_broker) |broker| {
            const application_timeout = broker.nextTimeoutMs();
            if (application_timeout >= 0 and (timeout < 0 or application_timeout < timeout)) timeout = application_timeout;
        }
        return timeout;
    }

    pub fn notifyWindowClosed(self: *Runner, window_id: i64) void {
        const payload = platform_channels.encodeWindowClosedEvent(self.gpa, window_id) catch |err| {
            std.debug.print("[error] failed to encode window close event: {s}\n", .{@errorName(err)});
            return;
        };
        defer self.gpa.free(payload);
        self.sendToEngine(platform_channels.window_events_channel_name, payload);
    }

    pub fn applicationSetReady(self: *Runner) void {
        self.application_ready = true;
        self.dispatchNextApplicationInvocation() catch |err| {
            std.debug.print("[error] failed to dispatch application invocation: {s}\n", .{@errorName(err)});
            self.requestFatal(.application_broker_failed);
        };
    }

    pub const ApplicationWriteAction = enum { committed, detached, pending, failed };

    pub fn applicationWrite(
        self: *Runner,
        response_handle: ?*const c.FlutterPlatformMessageResponseHandle,
        id: u64,
        stream: application_output.Stream,
        payload: []const u8,
    ) ApplicationWriteAction {
        const broker = self.application_broker orelse {
            self.requestFatal(.application_broker_failed);
            self.sendPlatformMethodError(response_handle, "ApplicationBroker", "application broker is unavailable");
            return .failed;
        };
        const outcome = broker.write(id, stream, payload) catch |err| {
            const code = switch (err) {
                error.NoActiveInvocation, error.InvocationIdMismatch => "ApplicationInvocationStale",
                error.ApplicationCancelled => "ApplicationCancelled",
                error.OutputClosed => "ApplicationOutputClosed",
                error.OutputLimitExceeded => "ApplicationOutputLimit",
                error.PendingWrite => "ApplicationWriteBusy",
                else => blk: {
                    self.requestFatal(.application_broker_failed);
                    break :blk "ApplicationOutputProtocol";
                },
            };
            self.sendPlatformMethodError(response_handle, code, @errorName(err));
            return .failed;
        };
        return switch (outcome) {
            .committed => .committed,
            .detached => .detached,
            .pending => .pending,
        };
    }

    pub fn applicationComplete(
        self: *Runner,
        response_handle: ?*const c.FlutterPlatformMessageResponseHandle,
        id: u64,
        exit_code: i32,
    ) void {
        const broker = self.application_broker orelse {
            self.requestFatal(.application_broker_failed);
            self.sendPlatformMethodError(response_handle, "ApplicationBroker", "application broker is unavailable");
            return;
        };
        const Coordinator = struct {
            runner: *Runner,
            broker: *application_broker.Broker,
            response_handle: ?*const c.FlutterPlatformMessageResponseHandle,
            id: u64,
            exit_code: i32,

            fn complete(coordinator: *@This()) !void {
                try coordinator.broker.complete(coordinator.id, .{ .exit_code = coordinator.exit_code });
            }
            fn sendResponse(coordinator: *@This()) platform_channels.ResponseSendResult {
                return runnerSendPlatformResponse(coordinator.runner, coordinator.response_handle, "[null]");
            }
            fn dispatch(coordinator: *@This()) !void {
                if (coordinator.runner.exit_after_application_command) {
                    coordinator.runner.exit_after_application_command = false;
                    coordinator.runner.quit_requested.store(true, .release);
                    return;
                }
                try coordinator.runner.dispatchNextApplicationInvocation();
            }
        };
        var coordinator = Coordinator{
            .runner = self,
            .broker = broker,
            .response_handle = response_handle,
            .id = id,
            .exit_code = exit_code,
        };
        runCompletionBarrier(&coordinator) catch |err| {
            if (err == error.CompletionResponseFailed) {
                self.requestFatal(.platform_response_failed);
                return;
            }
            if (err == error.CompletionDispatchFailed) {
                std.debug.print("[error] failed to dispatch queued application invocation\n", .{});
                self.requestFatal(.application_broker_failed);
                return;
            }
            std.debug.print("[error] failed to complete application invocation: {s}\n", .{@errorName(err)});
            if (err != error.NoActiveInvocation and err != error.InvocationIdMismatch) self.requestFatal(.application_broker_failed);
            const error_result = runnerSendPlatformMethodError(self, response_handle, @errorName(err), @errorName(err));
            if (error_result != .sent) self.requestFatal(.platform_response_failed);
        };
    }

    pub fn deferApplicationWriteResponse(self: *Runner, handle: ?*const c.FlutterPlatformMessageResponseHandle, id: u64) void {
        if (self.pending_application_write_response != null) {
            self.requestFatal(.application_broker_failed);
            return;
        }
        self.pending_application_write_response = .{ .id = id, .response_handle = handle };
    }

    fn flushApplicationWriteResponse(self: *Runner) void {
        const pending = self.pending_application_write_response orelse return;
        const broker = self.application_broker orelse {
            self.pending_application_write_response = null;
            self.requestFatal(.application_broker_failed);
            self.sendPlatformMethodError(pending.response_handle, "ApplicationBroker", "application broker is unavailable");
            return;
        };
        if (broker.fatalReason() != null) {
            self.pending_application_write_response = null;
            self.requestFatal(.application_broker_failed);
            self.sendPlatformMethodError(pending.response_handle, "ApplicationOutputProtocol", "application broker entered fatal state");
            return;
        }
        const outcome = broker.takePendingWriteOutcome() orelse return;
        if (outcome.id != pending.id) {
            self.requestFatal(.application_broker_failed);
            self.pending_application_write_response = null;
            self.sendPlatformMethodError(pending.response_handle, "ApplicationInvocationStale", "stale application output response");
            return;
        }
        self.pending_application_write_response = null;
        switch (outcome.result) {
            .committed, .detached => self.sendPlatformResponse(pending.response_handle, "[null]"),
            .cancelled => self.sendPlatformMethodError(pending.response_handle, "ApplicationCancelled", "application invocation was cancelled"),
            .fatal => {
                self.requestFatal(.application_broker_failed);
                self.sendPlatformMethodError(pending.response_handle, "ApplicationOutputProtocol", "application output failed");
            },
        }
    }

    fn dispatchNextApplicationInvocation(self: *Runner) !void {
        if (!self.application_ready or self.engine == null) return;
        const broker = self.application_broker orelse return;
        const invocation = broker.nextInvocation() orelse return;
        const payload = try encodeApplicationInvocation(self.gpa, invocation);
        defer self.gpa.free(payload);
        self.sendToEngine(platform_channels.application_channel_name, payload);
    }

    fn sendApplicationCancellation(self: *Runner, id: u64) void {
        var buffer: [96]u8 = undefined;
        const payload = encodeApplicationCancellation(&buffer, id);
        self.sendToEngine(platform_channels.application_channel_name, payload);
    }
};

fn encodeApplicationCancellation(buffer: *[96]u8, id: u64) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{{\"method\":\"cancel\",\"args\":{{\"id\":{d}}}}}",
        .{id},
    ) catch unreachable;
}

fn appendHex(gpa: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    try output.ensureUnusedCapacity(gpa, bytes.len * 2);
    for (bytes) |byte| {
        output.appendAssumeCapacity(alphabet[byte >> 4]);
        output.appendAssumeCapacity(alphabet[byte & 0x0f]);
    }
}

fn encodeApplicationInvocation(gpa: std.mem.Allocator, invocation: *const application_broker.InvocationData) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(gpa);

    try output.appendSlice(gpa, "{\"method\":\"dispatch\",\"args\":{\"id\":");
    var id_buffer: [32]u8 = undefined;
    try output.appendSlice(gpa, try std.fmt.bufPrint(&id_buffer, "{d}", .{invocation.id}));
    try output.appendSlice(gpa, ",\"isInitial\":");
    try output.appendSlice(gpa, if (invocation.is_initial) "true" else "false");
    try output.appendSlice(gpa, ",\"cwdHex\":\"");
    try appendHex(gpa, &output, invocation.cwd);
    try output.appendSlice(gpa, "\",\"argumentsHex\":[");
    for (invocation.arguments, 0..) |argument, index| {
        if (index != 0) try output.append(gpa, ',');
        try output.append(gpa, '"');
        try appendHex(gpa, &output, argument);
        try output.append(gpa, '"');
    }
    try output.appendSlice(gpa, "]}}\n");
    return output.toOwnedSlice(gpa);
}

/// 运行打包应用，直到 Dart 请求退出、收到终止信号，或 compositor/session bus 断开。
///
/// 调用方必须在进入本函数前完成单实例所有权判定；若传入 primary broker，其所有权
/// 仍由 player 拥有；Runner 只借用，player 在引擎关闭后释放它。
pub fn run(gpa: std.mem.Allocator, options: Options) !u8 {
    vm_service.clear(options.io);
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
        const aot_bundle = try bundle_loader.loadAot(gpa, options.bundle_path);
        errdefer aot_bundle.deinit(gpa);
        aot_source = std.mem.zeroes(c.FlutterEngineAOTDataSource);
        aot_source.type = c.kFlutterEngineAOTDataSourceTypeElfPath;
        aot_source.unnamed_0.elf_path = aot_bundle.app_so_path.?.ptr;
        try flutter.ensureSuccess(api.create_aot_data(&aot_source, &aot_data), "FlutterEngineCreateAOTData");
        break :blk aot_bundle;
    } else try bundle_loader.loadJit(gpa, options.bundle_path);
    defer bundle.deinit(gpa);
    defer if (aot_data != null) {
        flutter.ensureSuccess(api.collect_aot_data(aot_data), "FlutterEngineCollectAOTData") catch |err| {
            std.debug.print("[error] FlutterEngineCollectAOTData failed: {s}\n", .{@errorName(err)});
        };
    };

    var state_storage: display_state.DisplayState = .{};
    const state = &state_storage;
    var registry = WindowRegistry.init(gpa, options.io);
    defer registry.deinit();
    // Own the process connection independently of any window Host.
    _ = try state.acquire(gpa);
    defer state.release();
    defer shutdownShared(gpa, state);
    try state.bindGlobals();
    // 进程级单一 EGL render context (raster + 呈现)。
    var render_context: egl.RenderContext = .{};
    defer render_context.deinit();
    try render_context.init(state);
    // 系统剪贴板 (data-control): 引擎级单例, 共享 display。
    const dc = try gpa.create(data_control.DataControl);
    dc.* = data_control.DataControl.init(gpa, state);
    state.data_control = dc;
    if (state.data_control_manager_name != 0) {
        if (state.registry) |reg| dc.bindManager(reg, state.data_control_manager_name, state.data_control_manager_version);
    }
    // IME (text-input-v3): 引擎级单例, registry 绑定由 registryListener 完成。
    if (state.ime == null) {
        const ime = try gpa.create(ime_v3.ImeV3);
        ime.* = .{};
        state.ime = ime;
    }
    if (state.ime) |ime| {
        ime.shared_queue = state.shared_queue;
        if (state.ime_manager_name != 0) {
            if (state.registry) |reg| {
                if (state.seat) |seat| ime.bindManager(reg, state.ime_manager_name, state.ime_manager_version, seat);
            }
        }
    }
    std.debug.print("Wayland display connected and EGL bootstrap context is ready (headless shell).\n", .{});

    var task_queue = try flutter_task_queue.TaskQueue.init(gpa, options.io);
    defer task_queue.deinit();
    var runner: Runner = .{ .gpa = gpa, .frame_clock = .{ .io = options.io }, .state = state, .registry = &registry, .render_context = &render_context, .api = &api, .platform_thread_id = std.Thread.getCurrentId(), .task_queue = &task_queue, .engine_library = options.engine_library, .bundle_path = options.bundle_path, .application_broker = options.application_broker };
    runner.ime = state.ime;
    runner.text_client = text_input.Client.init(gpa);
    runner.text_client.send_fn = textInputSendCallback;
    runner.text_client.send_context = &runner;
    display_state.setPointerEventCallback(state, displayPointerRouter, &runner);
    display_state.setKeyboardEventCallback(state, displayKeyboardRouter, &runner);
    display_state.setScaleChangeCallback(state, struct {
        fn cb(context: ?*anyopaque) void {
            const callback_runner = runnerFromContext(context);
            callback_runner.registry.lock();
            defer callback_runner.registry.unlock();
            for (callback_runner.registry.entries.items) |entry| {
                if (entry.lifecycle != .removing) entry.host.recomputeScale();
            }
        }
    }.cb, &runner);
    if (state.ime) |ime| ime.setCallback(imeEventRouter, &runner);
    runner.clipboard = clipboard_service.Service.init(gpa, state);
    defer runner.text_client.deinit();
    defer runner.clipboard.deinit();
    defer runner.clipboard.cancelReadText();
    defer runner.xkb_state.deinit();

    var renderer: c.FlutterRendererConfig = std.mem.zeroes(c.FlutterRendererConfig);
    renderer.type = c.kOpenGL;
    renderer.unnamed_0.open_gl = std.mem.zeroes(c.FlutterOpenGLRendererConfig);
    renderer.unnamed_0.open_gl.struct_size = @sizeOf(c.FlutterOpenGLRendererConfig);
    renderer.unnamed_0.open_gl.make_current = makeCurrentCallback;
    renderer.unnamed_0.open_gl.clear_current = clearCurrentCallback;
    renderer.unnamed_0.open_gl.make_resource_current = makeResourceCurrentCallback;
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

    var owned_argv = try owned_arguments.Arguments.init(gpa, options.dart_entrypoint_arguments);
    defer owned_argv.deinit();
    const dart_argument_strings = owned_argv.strings;

    var dart_argument_pointers = try gpa.alloc([*c]const u8, dart_argument_strings.len);
    defer gpa.free(dart_argument_pointers);
    for (dart_argument_strings, 0..) |argument, index| dart_argument_pointers[index] = argument.ptr;

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
    if (dart_argument_pointers.len > 0) {
        project_args.dart_entrypoint_argc = @intCast(dart_argument_pointers.len);
        project_args.dart_entrypoint_argv = dart_argument_pointers.ptr;
    }
    if (is_aot) project_args.aot_data = aot_data;

    // The Flutter tool enables checked mode for debug engines. Without this
    // switch the VM still exposes service RPCs, but DevTools classifies the JIT
    // application as profile and hides the Inspector and Debugger panels.
    // VM Service remains localhost-only with authentication enabled. Port 0 asks
    // the Dart VM to choose an available port. These buffers outlive engine run.
    var vm_service_port_arg: [64]u8 = undefined;
    var vm_argv: [4]?[*:0]const u8 = undefined;
    var vm_argc: usize = 0;
    vm_argv[vm_argc] = "fushell".ptr;
    vm_argc += 1;
    if (!is_aot) {
        vm_argv[vm_argc] = "--enable-checked-mode".ptr;
        vm_argc += 1;
    }
    if (options.vm_service_port) |port| {
        const port_arg = try std.fmt.bufPrintZ(&vm_service_port_arg, "--vm-service-port={d}", .{port});
        vm_argv[vm_argc] = "--enable-vm-service".ptr;
        vm_argc += 1;
        vm_argv[vm_argc] = port_arg.ptr;
        vm_argc += 1;
        std.debug.print("VM service requested on port {d}; waiting for engine URI.\n", .{port});
    }
    if (vm_argc > 1) {
        project_args.command_line_argc = @intCast(vm_argc);
        project_args.command_line_argv = &vm_argv;
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
    errdefer if (runner.engine != null) shutdownEngine(&runner);

    std.debug.print("Flutter engine is running (headless). Dart may create windows via FushellWindow.openWindow.\n", .{});
    var event_loop_error: ?anyerror = null;
    platform_event_loop.run(state, gpa, &runner.quit_requested, "Engine event loop active (headless shell).", .{
        .fd = task_queue.wake_fd,
        .context = &runner,
        .tick = flutterTaskPumpCallback,
        .timeout_ms = flutterTaskTimeoutCallback,
        .consume_wake = flutterTaskWakeCallback,
        .auxiliary_fd = clipboardReadFdCallback,
        .external_fd_count = applicationPollFdCountCallback,
        .fill_external_fds = applicationPollFdsCallback,
        .handle_external_fds = applicationPollReadyCallback,
        .shutdown_fd = options.shutdown_fd,
    }) catch |err| {
        event_loop_error = err;
        std.debug.print("[error] engine event loop stopped: {s}\n", .{@errorName(err)});
    };

    if (runner.application_broker) |broker| broker.failPending();
    runner.flushApplicationWriteResponse();
    if (runner.fatal_reason != null and event_loop_error == null) event_loop_error = error.FatalRuntime;

    if (runner.pending_clipboard_read) |pending| {
        runner.clipboard.cancelReadText();
        runner.pending_clipboard_read = null;
        runner.completeClipboardRead(pending, null, error.EngineShuttingDown);
    }

    // Every exit path uses the same teardown order, including signals and a
    // compositor disconnect: stop engine callbacks first, then destroy window
    // resources while the display is still owned by the headless host.
    std.debug.print("Shutting down Flutter engine.\n", .{});
    shutdownEngine(&runner);
    shutdownAllWindows(&runner);
    shutdownShared(gpa, state);
    std.debug.print("engine event loop exited.\n", .{});
    if (event_loop_error) |err| return err;
    return runner.exit_status.value();
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
    const context = user_data orelse {
        std.debug.print("[error] Flutter task-runner thread check received null context\n", .{});
        return false;
    };
    const runner: *Runner = @ptrCast(@alignCast(context));
    return std.Thread.getCurrentId() == runner.platform_thread_id;
}

fn clipboardReadFdCallback(context: ?*anyopaque) c_int {
    const runner = runnerFromContext(context);
    return runner.clipboard.requestFd() orelse -1;
}

fn applicationPollFdCountCallback(context: ?*anyopaque) usize {
    const runner = runnerFromContext(context);
    const broker = runner.application_broker orelse return 0;
    return broker.pollFdCount();
}

fn applicationPollFdsCallback(context: ?*anyopaque, destination: []std.posix.pollfd) usize {
    const runner = runnerFromContext(context);
    const broker = runner.application_broker orelse return 0;
    return broker.fillPollFds(destination);
}

fn applicationPollReadyCallback(context: ?*anyopaque, ready: []const std.posix.pollfd) !void {
    const runner = runnerFromContext(context);
    const broker = runner.application_broker orelse return;
    broker.handlePollFds(ready) catch |err| {
        std.debug.print("[error] application broker poll failed: {s}\n", .{@errorName(err)});
        runner.requestFatal(.application_broker_failed);
        return;
    };
    if (broker.fatalReason() != null) runner.requestFatal(.application_broker_failed);
}

fn postFlutterTaskCallback(task: c.FlutterTask, target_time_nanos: u64, user_data: ?*anyopaque) callconv(.c) void {
    const context = user_data orelse {
        std.debug.print("[error] Flutter task post received null context\n", .{});
        return;
    };
    const runner: *Runner = @ptrCast(@alignCast(context));
    runner.queueFlutterTask(task, target_time_nanos);
}

test "application cancellation message carries invocation id" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"method\":\"cancel\",\"args\":{\"id\":42}}",
        encodeApplicationCancellation(&buffer, 42),
    );
}

test "platform response failure classification is injectable" {
    try std.testing.expect(!responseFailureIsFatal(.sent));
    try std.testing.expect(!responseFailureIsFatal(.not_requested));
    try std.testing.expect(responseFailureIsFatal(.engine_unavailable));
    try std.testing.expect(responseFailureIsFatal(.engine_failed));
}

test "completion barrier rejects dispatch after an unsent response" {
    try std.testing.expect(completionResponseAllowsDispatch(.sent));
    try std.testing.expect(!completionResponseAllowsDispatch(.engine_unavailable));
    try std.testing.expect(!completionResponseAllowsDispatch(.engine_failed));
    try std.testing.expect(!completionResponseAllowsDispatch(.not_requested));
    try std.testing.expect(!completionResponseAllowsDispatch(.already_completed));
}

test "completion barrier records complete response dispatch order" {
    const Fake = struct {
        order: *[3]u8,
        index: *usize,
        response: platform_channels.ResponseSendResult,
        dispatch_count: *usize,

        fn record(fake: *@This(), value: u8) void {
            fake.order[fake.index.*] = value;
            fake.index.* += 1;
        }
        fn complete(fake: *@This()) !void {
            fake.record('c');
        }
        fn sendResponse(fake: *@This()) platform_channels.ResponseSendResult {
            fake.record('r');
            return fake.response;
        }
        fn dispatch(fake: *@This()) !void {
            fake.record('d');
            fake.dispatch_count.* += 1;
        }
    };

    var order = [_]u8{ 0, 0, 0 };
    var index: usize = 0;
    var dispatch_count: usize = 0;
    var fake = Fake{ .order = &order, .index = &index, .response = .sent, .dispatch_count = &dispatch_count };
    try runCompletionBarrier(&fake);
    try std.testing.expectEqualSlices(u8, "crd", &order);
    try std.testing.expectEqual(@as(usize, 1), dispatch_count);

    for ([_]platform_channels.ResponseSendResult{ .engine_failed, .not_requested, .already_completed }) |response| {
        order = .{ 0, 0, 0 };
        index = 0;
        dispatch_count = 0;
        fake.response = response;
        try std.testing.expectError(error.CompletionResponseFailed, runCompletionBarrier(&fake));
        try std.testing.expectEqualSlices(u8, "cr", order[0..index]);
        try std.testing.expectEqual(@as(usize, 0), dispatch_count);
    }
}

test "Flutter task callbacks reject null context" {
    try std.testing.expect(!runsTaskOnCurrentThreadCallback(null));
    postFlutterTaskCallback(std.mem.zeroes(c.FlutterTask), 0, null);
}

fn flutterTaskPumpCallback(user_data: ?*anyopaque) !void {
    const runner = fromUserData(user_data);
    if (runner.application_broker) |broker| {
        broker.pump() catch |err| {
            std.debug.print("[error] application broker pump failed: {s}\n", .{@errorName(err)});
            runner.requestFatal(.application_broker_failed);
            return;
        };
        runner.flushApplicationWriteResponse();
        if (broker.fatalReason() != null) {
            runner.requestFatal(.application_broker_failed);
            return;
        }
        if (runner.fatal_reason != null) return;
        if (broker.takeCancellationRequest()) |id|
            runner.sendApplicationCancellation(id);
        if (broker.recoveryExitRequested()) {
            std.debug.print("Application command ignored cancellation; restarting daemon.\n", .{});
            runner.quit_requested.store(true, .release);
        } else {
            runner.dispatchNextApplicationInvocation() catch |err| {
                std.debug.print("[error] failed to dispatch queued application invocation: {s}\n", .{@errorName(err)});
                runner.requestFatal(.application_broker_failed);
                return;
            };
        }
    }
    processViewLifecycleResults(runner);
    processCompositorCloseRequests(runner);
    runner.checkKeyRepeat();
    try runner.runDueFlutterTasks();
    processPendingWindowRemovals(runner);
    while (try runner.frame_clock.takeDue(runner.now())) |frame| {
        if (runner.engine == null) return error.EngineUnavailable;
        try flutter.ensureSuccess(runner.api.on_vsync(runner.engine, frame.baton, frame.start, frame.target), "FlutterEngineOnVsync");
    }
}

fn flutterTaskTimeoutCallback(user_data: ?*anyopaque) i32 {
    return fromUserData(user_data).nextPollTimeoutMs();
}

fn flutterTaskWakeCallback(user_data: ?*anyopaque) void {
    fromUserData(user_data).task_queue.drainWake();
}

fn sendMetrics(runner: *Runner, host_metrics: egl.Metrics, view_id: i64) !void {
    if (runner.engine == null) return;
    var metrics: c.FlutterWindowMetricsEvent = std.mem.zeroes(c.FlutterWindowMetricsEvent);
    metrics.struct_size = @sizeOf(c.FlutterWindowMetricsEvent);
    metrics.width = host_metrics.width;
    metrics.height = host_metrics.height;
    metrics.pixel_ratio = host_metrics.pixel_ratio;
    metrics.left = 0;
    metrics.top = 0;
    metrics.view_id = view_id;
    try flutter.ensureSuccess(runner.api.send_window_metrics(runner.engine, &metrics), "FlutterEngineSendWindowMetricsEvent");
    try flutter.ensureSuccess(runner.api.schedule_frame(runner.engine), "FlutterEngineScheduleFrame");
}

fn metricsCallback(host: *egl.Host, context: ?*anyopaque, host_metrics: egl.Metrics) void {
    const runner = runnerFromContext(context);
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

fn pointerCallback(host: *egl.Host, context: ?*anyopaque, host_event: egl.PointerEvent) void {
    const runner = runnerFromContext(context);
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

    switch (platform_channels.classify(channel)) {
        .surface => platform_channels.handleSurfaceChannelMessage(runner, message, payload),
        .text_input => platform_channels.handleTextInputMessage(runner, message, payload, sendGuardedPlatformResponse),
        .platform => platform_channels.handlePlatformChannelMessage(runner, message, payload, sendGuardedPlatformResponse),
        .mouse_cursor => platform_channels.handleMouseCursorMessage(runner, message, payload, sendGuardedPlatformResponse),
        .application => platform_channels.handleApplicationChannelMessage(runner, message, payload),
        .unsupported => {
            std.debug.print("[info] Unsupported Flutter platform channel: {s}\n", .{channel});
            runner.sendPlatformResponse(message.response_handle, "");
        },
    }
}

/// Execute one parsed fushell/window or fushell/process lifecycle request.
fn runnerHandleSurfaceRequest(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.Request) !void {
    switch (request) {
        .open_window => |req| try openWindow(runner, response_handle, req),
        .close_window => |req| try closeWindow(runner, response_handle, req),
        .update_window => |req| try updateWindowSurface(runner, response_handle, req),
        .reposition_popup => |req| {
            const host = try runner.registry.activeHostForPlatform(req.window_id);
            try host.repositionPopup(req.positioner);
            sendSurfaceSuccess(runner, response_handle, req.id);
        },
        .update_layer => |req| try updateLayerSurface(runner, response_handle, req),
        .exit => |req| try exitProcess(runner, response_handle, req),
    }
}

/// window.open: 创建新窗口 (Wayland role + EGL surface + Flutter view)。
/// 回复在 add_view_callback 确认 added 后发出 (保证 Dart 收到 windowId 时
/// view 已在引擎注册、PlatformDispatcher.views 即将可见)。
pub fn openWindow(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.OpenWindowRequest) !void {
    runner.registry.lock();
    const parent_host = if (request.parent) |parent_id| blk: {
        const parent_entry = runner.registry.findByViewIdLocked(parent_id) orelse {
            runner.registry.unlock();
            return error.ParentWindowNotFound;
        };
        if (parent_entry.lifecycle != .active or parent_entry.close_requested) {
            runner.registry.unlock();
            return error.ParentWindowNotReady;
        }
        if (request.role == .popup) {
            _ = runner.registry.popupParentLocked(parent_id) catch |err| {
                runner.registry.unlock();
                return err;
            };
        }
        break :blk &parent_entry.host;
    } else null;
    if (request.role == .popup and parent_host == null) {
        runner.registry.unlock();
        return error.ParentWindowNotFound;
    }
    const entry = runner.registry.reserveLocked(request.parent) catch |err| {
        runner.registry.unlock();
        return err;
    };
    const view_id = entry.view_id;
    if (request.role == .popup) entry.popup_parent_view_id = request.parent;
    entry.lifecycle_notification = .{ .context = runner.task_queue, .wake = wakeWindowLifecycle };
    entry.pending_open_response = response_handle;
    entry.pending_open_request_id = request.id;
    runner.registry.unlock();

    // Wayland lifecycle runs exclusively on the platform thread. Registry
    // callbacks may run synchronously inside AddView, so never call engine APIs
    // while holding the registry mutex.
    const host = &entry.host;
    host.view_id = view_id;
    host.render_context = runner.render_context;
    errdefer {
        runner.registry.lock();
        entry.lifecycle = .removing;
        runner.registry.unindexSurfaceLocked(entry);
        runner.registry.unlock();
        host.present_mutex.lockUncancelable(runner.registry.io);
        host.deinit();
        host.present_mutex.unlock(runner.registry.io);
        runner.registry.lock();
        runner.registry.releaseLocked(entry);
        runner.registry.unlock();
    }
    try host.attach(runner.state, runner.task_queue.io, runner.gpa);
    switch (request.role) {
        .window => |w| try host.initializeWindowRole(w, if (parent_host) |parent| parent.toplevel else null),
        .layer => |l| try host.initializeLayerRole(l),
        .popup => |p| try host.initializePopupRole(p, parent_host.?),
    }
    runner.registry.lock();
    runner.registry.indexSurfaceLocked(entry) catch |err| {
        runner.registry.unlock();
        return err;
    };
    runner.registry.unlock();
    host.setMetricsCallback(metricsCallback, runner);
    host.setPointerCallback(pointerCallback, runner);

    const m = host.metricsSnapshot();
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

fn wakeWindowLifecycle(context: *anyopaque) void {
    const task_queue: *flutter_task_queue.TaskQueue = @ptrCast(@alignCast(context));
    task_queue.notify();
}

/// Engine-managed thread callback: only record the AddView result. The
/// platform thread owns all Wayland/EGL and response work.
fn addViewCallback(result: [*c]const c.FlutterAddViewResult) callconv(.c) void {
    const entry: *WindowEntry = @ptrCast(@alignCast(result.*.user_data.?));
    const registry = entry.registry;
    if (registry.completeAdd(entry, result.*.added)) |notification| notification.notify();
}

/// Queue ownership-aware removal. Engine calls happen on the platform tick
/// outside the registry lock because callbacks may run synchronously.
fn beginWindowRemoval(
    runner: *Runner,
    entry: *WindowEntry,
    response_handle: ?*const c.FlutterPlatformMessageResponseHandle,
    request_id: i64,
) !void {
    runner.registry.lock();
    defer runner.registry.unlock();
    if (entry.lifecycle == .removing or entry.close_requested) return error.WindowClosePending;
    if (entry.lifecycle != .active) return error.WindowNotReady;
    entry.pending_close_response = response_handle;
    entry.pending_close_request_id = request_id;
    runner.registry.requestCloseTreeLocked(entry);
    // Submit leaves after AddView results. Parents keep rendering until all
    // owned children have completed RemoveView and native host cleanup.
}

fn submitWindowRemoval(runner: *Runner, entry: *WindowEntry) !void {
    runner.registry.lock();
    std.debug.assert(entry.lifecycle == .active and entry.close_requested);
    std.debug.assert(runner.registry.popupChildLocked(entry.view_id) == null);
    entry.lifecycle = .removing;
    const view_id = entry.view_id;
    runner.registry.unlock();

    var remove_info: c.FlutterRemoveViewInfo = std.mem.zeroes(c.FlutterRemoveViewInfo);
    remove_info.struct_size = @sizeOf(c.FlutterRemoveViewInfo);
    remove_info.view_id = view_id;
    remove_info.user_data = entry;
    remove_info.remove_view_callback = removeViewCallback;
    flutter.ensureSuccess(runner.api.remove_view(runner.engine, &remove_info), "FlutterEngineRemoveView") catch |err| {
        runner.registry.lock();
        if (entry.remove_result == null) entry.lifecycle = .active;
        runner.registry.unlock();
        return err;
    };
}

/// Fail waiting ancestors too: never strand a closing parent or destroy it
/// around a surviving popup when Flutter refuses to remove that popup.
fn cancelWindowCloseChain(runner: *Runner, first: *WindowEntry, code: []const u8) void {
    var cursor: ?*WindowEntry = first;
    while (cursor) |entry| {
        runner.registry.lock();
        entry.close_requested = false;
        const handle = entry.pending_close_response;
        const request_id = entry.pending_close_request_id;
        entry.pending_close_response = null;
        entry.pending_close_request_id = 0;
        cursor = if (entry.popup_parent_view_id) |id| runner.registry.findByViewIdLocked(id) else null;
        runner.registry.unlock();
        if (handle) |h| runnerSendSurfaceError(runner, h, request_id, code, "popup descendant could not be removed");
    }
}

fn processPendingWindowRemovals(runner: *Runner) void {
    while (true) {
        runner.registry.lock();
        const entry = runner.registry.nextRemovalLocked();
        runner.registry.unlock();
        const candidate = entry orelse break;
        submitWindowRemoval(runner, candidate) catch |err| {
            std.debug.print("[error] deferred view removal failed: {s}\n", .{@errorName(err)});
            cancelWindowCloseChain(runner, candidate, @errorName(err));
        };
    }
}

/// window.close: RemoveView → removed 回调确认后才销毁 surface。
pub fn closeWindow(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.CloseWindowRequest) !void {
    runner.registry.lock();
    const entry = runner.registry.findByViewIdLocked(request.window_id) orelse {
        runner.registry.unlock();
        return error.WindowNotFound;
    };
    runner.registry.unlock();
    try beginWindowRemoval(runner, entry, response_handle, request.id);
    std.debug.print("window.close: view {d} (remove pending)\n", .{request.window_id});
}

/// Wayland close listeners only set a flag. The next platform-thread tick
/// submits RemoveView outside the listener stack.
fn processCompositorCloseRequests(runner: *Runner) void {
    for (0..runner.registry.entries.items.len) |index| {
        runner.registry.lock();
        const entry = runner.registry.entries.items[index];
        const should_close = entry.lifecycle == .active and !entry.close_requested and entry.host.takeCloseRequest();
        const view_id = entry.view_id;
        runner.registry.unlock();
        if (!should_close) continue;

        beginWindowRemoval(runner, entry, null, 0) catch |err| {
            std.debug.print("[error] compositor close failed for view {d}: {s}\n", .{ view_id, @errorName(err) });
            continue;
        };
        std.debug.print("compositor close: view {d} (remove pending)\n", .{view_id});
    }
}

/// Engine-managed thread callback: only record the RemoveView result. Even
/// after success, the platform thread must perform all Wayland/EGL cleanup.
fn removeViewCallback(result: [*c]const c.FlutterRemoveViewResult) callconv(.c) void {
    const entry: *WindowEntry = @ptrCast(@alignCast(result.*.user_data.?));
    const registry = entry.registry;
    if (registry.completeRemove(entry, result.*.removed)) |notification| notification.notify();
}

const ViewLifecycleCompletion = enum {
    none,
    add_succeeded,
    add_failed,
    remove_succeeded,
    remove_failed,
};

fn emitsWindowClosed(completion: ViewLifecycleCompletion) bool {
    return completion == .remove_succeeded;
}

fn processViewLifecycleResults(runner: *Runner) void {
    var index: usize = 0;
    while (true) {
        var completion: ViewLifecycleCompletion = .none;
        var handle: ?*const c.FlutterPlatformMessageResponseHandle = null;
        var request_id: i64 = 0;
        var view_id: i64 = 0;
        var release_entry = false;

        runner.registry.lock();
        if (index >= runner.registry.entries.items.len) {
            runner.registry.unlock();
            break;
        }
        const entry = runner.registry.entries.items[index];
        if (entry.lifecycle == .adding and entry.add_result != null) {
            handle = entry.pending_open_response;
            request_id = entry.pending_open_request_id;
            view_id = entry.view_id;
            const added = entry.add_result.?;
            entry.add_result = null;
            entry.pending_open_response = null;
            entry.pending_open_request_id = 0;
            if (added) {
                entry.lifecycle = .active;
                completion = .add_succeeded;
            } else {
                entry.lifecycle = .removing;
                runner.registry.unindexSurfaceLocked(entry);
                release_entry = true;
                completion = .add_failed;
            }
        } else if (entry.lifecycle == .removing and entry.remove_result != null) {
            handle = entry.pending_close_response;
            request_id = entry.pending_close_request_id;
            view_id = entry.view_id;
            const removed = entry.remove_result.?;
            entry.remove_result = null;
            entry.pending_close_response = null;
            entry.pending_close_request_id = 0;
            if (removed) {
                runner.registry.unindexSurfaceLocked(entry);
                release_entry = true;
                completion = .remove_succeeded;
            } else {
                entry.lifecycle = .active;
                completion = .remove_failed;
            }
        }
        if (!release_entry) index += 1;
        runner.registry.unlock();

        if (release_entry) {
            if (runner.focused_host == &entry.host) runner.focused_host = null;
            if (runner.pointer_focused_host == &entry.host) runner.pointer_focused_host = null;
            // A presentation may have acquired the host before it was marked
            // removing. Wait for it before destroying the surface or entry.
            entry.host.present_mutex.lockUncancelable(runner.registry.io);
            entry.host.deinit();
            entry.host.present_mutex.unlock(runner.registry.io);
            runner.registry.lock();
            if (completion == .remove_succeeded) runner.registry.detachChildrenLocked(view_id);
            runner.registry.releaseLocked(entry);
            runner.registry.unlock();
        }

        switch (completion) {
            .none => {},
            .add_succeeded => {
                const response = surface_channel.openSuccessResponse(runner.gpa, request_id, view_id) catch |err| {
                    std.debug.print("[error] Failed to encode window.open response: {s}\n", .{@errorName(err)});
                    runner.requestFatal(.platform_response_encoding_failed);
                    break;
                };
                defer runner.gpa.free(response);
                if (handle) |h| _ = runnerSendPlatformResponse(runner, h, response);
            },
            .add_failed => {
                std.debug.print("[error] FlutterEngineAddView reported added=false for view {d}\n", .{view_id});
                if (handle) |h| runnerSendSurfaceError(runner, h, request_id, "AddViewFailed", "engine rejected the new view");
            },
            .remove_succeeded => {
                if (handle) |h| sendSurfaceSuccess(runner, h, request_id);
                std.debug.print("window.close: view {d} removed and surface destroyed.\n", .{view_id});
            },
            .remove_failed => {
                cancelWindowCloseChain(runner, entry, "RemoveViewFailed");
                std.debug.print("[error] FlutterEngineRemoveView reported removed=false for view {d}\n", .{view_id});
                if (handle) |h| runnerSendSurfaceError(runner, h, request_id, "RemoveViewFailed", "engine could not remove the view");
            },
        }

        if (emitsWindowClosed(completion)) runner.notifyWindowClosed(view_id);
    }
}

test "window close notification requires successful RemoveView completion" {
    try std.testing.expect(!emitsWindowClosed(.none));
    try std.testing.expect(!emitsWindowClosed(.add_succeeded));
    try std.testing.expect(!emitsWindowClosed(.add_failed));
    try std.testing.expect(emitsWindowClosed(.remove_succeeded));
    try std.testing.expect(!emitsWindowClosed(.remove_failed));
}

pub fn updateLayerSurface(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.LayerUpdateRequest) !void {
    const host = try runner.registry.activeHostForPlatform(request.window_id);
    _ = try host.updateLayerRole(request.update);
    sendSurfaceSuccess(runner, response_handle, request.id);
}

pub fn updateWindowSurface(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.WindowUpdateRequest) !void {
    const host = try runner.registry.activeHostForPlatform(request.window_id);
    _ = try host.updateWindowRole(request.update);
    sendSurfaceSuccess(runner, response_handle, request.id);
}

/// process.exit: 停止事件循环 → run() 退出序列 (关引擎 → 毁窗口 → 断连接)。
pub fn exitProcess(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.ExitRequest) !void {
    try runner.exit_status.request(request.code);
    sendSurfaceSuccess(runner, response_handle, request.id);
    if (runner.application_broker) |broker| {
        if (broker.hasActiveInvocation()) {
            runner.exit_after_application_command = true;
            std.debug.print("process.exit({d}) requested; deferring shutdown until the active command reply is sent.\n", .{request.code});
            return;
        }
    }
    runner.quit_requested.store(true, .release);
    std.debug.print("process.exit({d}) requested; stopping event loop.\n", .{request.code});
}

/// Engine shutdown joins callbacks before their registry entries, wake queue, or
/// context-owned GL objects can be destroyed. Failure cannot safely unwind.
fn shutdownEngine(runner: *Runner) void {
    flutter.ensureSuccess(runner.api.shutdown(runner.engine), "FlutterEngineShutdown") catch |err| {
        std.debug.panic("FlutterEngineShutdown failed: {s}; callback targets must remain alive", .{@errorName(err)});
    };
    runner.engine = null;
    // A VAO is local to the raster context, even when textures are shared.
    runner.render_context.makeCurrent() catch |err| {
        std.debug.panic("Cannot bind raster context for blitter teardown: {s}", .{@errorName(err)});
    };
    runner.blitter.deinit();
    runner.render_context.clearCurrent() catch |err| {
        std.debug.panic("Cannot release raster context after blitter teardown: {s}", .{@errorName(err)});
    };
}

/// Engine callbacks have stopped; destroy the remaining platform windows.
fn shutdownAllWindows(runner: *Runner) void {
    while (true) {
        runner.registry.lock();
        const entry = runner.registry.newestEntryLocked() orelse {
            runner.registry.unlock();
            return;
        };
        runner.registry.unindexSurfaceLocked(entry);
        runner.registry.unlock();

        entry.host.deinit();
        runner.registry.lock();
        runner.registry.releaseLocked(entry);
        runner.registry.unlock();
    }
}

fn runnerSurfaceRequestErrorCode(_: *Runner, err: anyerror) []const u8 {
    return @errorName(err);
}

pub fn sendSurfaceSuccess(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, id: i64) void {
    const response = surface_channel.successResponse(runner.gpa, id) catch |err| {
        std.debug.print("[error] Failed to encode fushell surface success response: {s}\n", .{@errorName(err)});
        runner.requestFatal(.platform_response_encoding_failed);
        return;
    };
    defer runner.gpa.free(response);
    _ = runnerSendPlatformResponse(runner, response_handle, response);
}

fn runnerSendSurfaceError(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, id: ?i64, code: []const u8, message: []const u8) void {
    const response = surface_channel.errorResponse(runner.gpa, id, code, message) catch |err| {
        std.debug.print("[error] Failed to encode fushell surface error response: {s}\n", .{@errorName(err)});
        runner.requestFatal(.platform_response_encoding_failed);
        return;
    };
    defer runner.gpa.free(response);
    _ = runnerSendPlatformResponse(runner, response_handle, response);
}

fn runnerSendPlatformMethodError(
    runner: *Runner,
    response_handle: ?*const c.FlutterPlatformMessageResponseHandle,
    code: []const u8,
    message: []const u8,
) platform_channels.ResponseSendResult {
    const response = platform_channels.encodeMethodError(runner.gpa, code, message) catch |err| {
        std.debug.print("[error] Failed to encode Flutter method error: {s}\n", .{@errorName(err)});
        runner.requestFatal(.platform_response_encoding_failed);
        return .engine_failed;
    };
    defer runner.gpa.free(response);
    return runnerSendPlatformResponse(runner, response_handle, response);
}

fn sendGuardedPlatformResponse(
    context: *anyopaque,
    response_handle: ?*const c.FlutterPlatformMessageResponseHandle,
    response: []const u8,
) platform_channels.ResponseSendResult {
    const runner: *Runner = @ptrCast(@alignCast(context));
    return sendRawPlatformResponse(runner, response_handle, response);
}

fn runnerSendPlatformResponse(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, response: []const u8) platform_channels.ResponseSendResult {
    if (runner.active_platform_response) |reply| {
        if (reply.handle == response_handle) {
            if (reply.completed) return .already_completed;
            reply.completed = true;
        }
    }
    return sendRawPlatformResponse(runner, response_handle, response);
}

pub fn sendRawPlatformResponse(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, response: []const u8) platform_channels.ResponseSendResult {
    if (response_handle == null) {
        std.debug.print("Flutter platform message had no response handle.\n", .{});
        return .not_requested;
    }
    if (runner.engine == null) {
        std.debug.print("[error] Cannot reply to Flutter platform message before engine handle is available.\n", .{});
        runner.requestFatal(.platform_response_failed);
        return .engine_unavailable;
    }
    const result = runner.api.send_platform_message_response(runner.engine, response_handle, response.ptr, response.len);
    if (result != c.kSuccess) {
        std.debug.print("[error] FlutterEngineSendPlatformMessageResponse failed: {s}\n", .{flutter.resultName(result)});
        runner.requestFatal(.platform_response_failed);
        return .engine_failed;
    }
    return .sent;
}

fn runnerSendEmptyPlatformResponse(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
    _ = runnerSendPlatformResponse(runner, response_handle, "");
}

fn makeCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    // raster 渲染目标永远是 bootstrap pbuffer (compositor 路径: 引擎渲进 backing
    // store 纹理, 窗口 surface 只用于呈现)。
    runner.render_context.makeCurrent() catch |err| {
        std.debug.print("[error] Flutter make_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

fn makeResourceCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    runner.render_context.makeResourceCurrent() catch |err| {
        std.debug.print("[error] Flutter make_resource_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
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
    _ = user_data;
    const config: *const c.FlutterBackingStoreConfig = @ptrCast(config_ptr);
    const output: *c.FlutterBackingStore = @ptrCast(backing_store_ptr);
    flutter_compositor.createBackingStore(config, output) catch |err| {
        std.debug.print("[error] create_backing_store failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

/// compositor: 回收 backing store 纹理。
fn collectBackingStoreCallback(backing_store_ptr: [*c]const c.FlutterBackingStore, user_data: ?*anyopaque) callconv(.c) bool {
    _ = user_data;
    const backing_store: *const c.FlutterBackingStore = @ptrCast(backing_store_ptr);
    flutter_compositor.collectBackingStore(backing_store) catch |err| {
        std.debug.print("[error] collect_backing_store failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

/// compositor: 将 view 的 layer tree blit 到对应窗口 EGL surface 并 swap。
/// view 0 (implicit, 无头) no-op; 其余按注册表查窗口。
fn presentViewCallback(info_ptr: [*c]const c.FlutterPresentViewInfo) callconv(.c) bool {
    const info: *const c.FlutterPresentViewInfo = @ptrCast(info_ptr);
    if (info.view_id == 0) return true; // 无头 implicit view: 丢弃

    const runner = fromUserData(info.user_data);
    runner.registry.lock();
    const entry = runner.registry.findByViewIdLocked(info.view_id) orelse {
        runner.registry.unlock();
        return true; // 窗口已关闭
    };
    if (entry.lifecycle == .removing) {
        runner.registry.unlock();
        return true;
    }
    const host = &entry.host;
    // Platform mutations do not call Flutter or dispatch Wayland while holding
    // this lock. Wait rather than silently dropping a static frame.
    host.present_mutex.lockUncancelable(host.io);
    runner.registry.unlock();
    defer host.present_mutex.unlock(host.io);

    if (!host.isReady()) return true;
    runner.render_context.makeSurfaceCurrent(host.egl_surface) catch |err| {
        std.debug.print("[error] present_view makeSurfaceCurrent failed: {s}\n", .{@errorName(err)});
        return false;
    };
    // RemoveView completion may destroy the native window once this lock drops.
    defer runner.render_context.makeCurrent() catch |err| {
        std.debug.panic("Cannot release view drawable after presentation: {s}", .{@errorName(err)});
    };
    const metrics = host.presentationMetricsLocked();
    flutter_compositor.presentFrame(&runner.blitter, info, @intCast(metrics.width), @intCast(metrics.height)) catch |err| {
        std.debug.print("[error] present_view frame failed: {s}\n", .{@errorName(err)});
        return false;
    };
    runner.render_context.swapBuffers(host.egl_surface) catch |err| {
        std.debug.print("[error] present_view swapBuffers failed: {s}\n", .{@errorName(err)});
        return false;
    };
    host.has_presented_buffer = true;
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

/// Queue requested frames; the event pump supplies the software timing fallback.
/// This intentionally does not claim synchronization with a physical display.
fn vsyncCallback(user_data: ?*anyopaque, baton: isize) callconv(.c) void {
    const runner = fromUserData(user_data);
    runner.frame_clock.request(baton, runner.now());
    runner.task_queue.notify();
}

/// VM Service URI published by the engine log callback for development tools.
pub var vm_service: service_uri.State = .{};

fn logMessageCallback(tag: [*c]const u8, message: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
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
                const runner = fromUserData(user_data);
                vm_service.set(runner.task_queue.io, rest[0..end]);
                std.debug.print("[fushell] VM service URI: {s}\n", .{rest[0..end]});
            }
        }
    }
}

test "pointer focus survives surface-less events and clears before reuse" {
    var first: u8 = 1;
    var second: u8 = 2;
    var focus: ?*u8 = null;

    try std.testing.expectEqual(&first, pointerFocusTarget(u8, &focus, .enter, &first).?);
    try std.testing.expectEqual(&first, pointerFocusTarget(u8, &focus, .current, null).?);
    try std.testing.expectEqual(&first, pointerFocusTarget(u8, &focus, .leave, null).?);
    try std.testing.expect(focus == null);
    try std.testing.expect(pointerFocusTarget(u8, &focus, .current, null) == null);
    try std.testing.expectEqual(&second, pointerFocusTarget(u8, &focus, .enter, &second).?);
}

test "physical key transition is applied exactly once" {
    const FakeXkb = struct {
        transitions: usize = 0,

        fn updateKey(self: *@This(), _: u32, _: bool) u32 {
            self.transitions += 1;
            return 0;
        }
    };

    var state: FakeXkb = .{};
    _ = applyPhysicalKeyTransition(&state, 30, true);
    try std.testing.expectEqual(@as(usize, 1), state.transitions);
}

test "key repeat reuses held key without xkb transition" {
    const FakeXkb = struct {
        transitions: usize = 0,

        fn updateKey(self: *@This(), _: u32, _: bool) u32 {
            self.transitions += 1;
            return 0;
        }
    };
    const FakeHandler = struct {
        repeats: usize = 0,
        text_updates: usize = 0,

        fn sendKeyboardEvent(self: *@This(), _: u32, pressed: bool) void {
            if (pressed) self.repeats += 1;
        }

        fn applyTextKey(self: *@This(), _: u32) void {
            self.text_updates += 1;
        }
    };

    var state: FakeXkb = .{};
    var handler: FakeHandler = .{};
    _ = applyPhysicalKeyTransition(&state, 30, true);
    dispatchKeyRepeat(&handler, 30);
    dispatchKeyRepeat(&handler, 30);
    try std.testing.expectEqual(@as(usize, 1), state.transitions);
    try std.testing.expectEqual(@as(usize, 2), handler.repeats);
    try std.testing.expectEqual(@as(usize, 2), handler.text_updates);
}
