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
const input_provenance = @import("input_provenance.zig");
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

fn encodeKeyboardEvent(buffer: []u8, evdev_code: u32, keysym: u32, modifiers: u32, pressed: bool) ![]u8 {
    const scan_code = std.math.add(u32, evdev_code, 8) catch return error.InvalidKeyboardCode;
    return std.fmt.bufPrint(buffer,
        \\{{"type":"{s}","keymap":"linux","keyCode":{d},"modifiers":{d},"unicodeScalarValues":{d},"scanCode":{d},"toolkit":"gtk"}}
    , .{ if (pressed) "keydown" else "keyup", keysym, modifiers, xkb.keysymToUtf32(keysym), scan_code });
}
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
fn activeKeyboardHost(runner: *Runner, surface: ?*wl.Surface) ?*egl.Host {
    const host = runner.registry.findHostBySurfaceLocked(surface) orelse return null;
    return runner.registry.activeHostForPlatform(host.view_id) catch null;
}

fn setKeyboardFocus(runner: *Runner, next: ?*egl.Host) void {
    const previous = runner.focused_host;
    if (previous == next) return;
    runner.focused_host = next;
    runner.repeat_active_key = null;
    if (runner.engine == null) return;
    if (previous) |host| sendViewFocus(runner, host.view_id, false);
    if (next) |host| sendViewFocus(runner, host.view_id, true);
}

fn sendViewFocus(runner: *Runner, view_id: i64, focused: bool) void {
    var event: c.FlutterViewFocusEvent = std.mem.zeroes(c.FlutterViewFocusEvent);
    event.struct_size = @sizeOf(c.FlutterViewFocusEvent);
    event.view_id = view_id;
    event.state = if (focused) c.kFocused else c.kUnfocused;
    event.direction = c.kUndefined;
    flutter.ensureSuccess(runner.api.send_view_focus(runner.engine, &event), "FlutterEngineSendViewFocusEvent") catch |err| {
        std.log.scoped(.input).err("View focus failed: {s}", .{@errorName(err)});
    };
}

fn invalidateInputOnKeyboardEvent(tracker: *input_provenance.Tracker, event: display_state.KeyboardEvent) void {
    switch (event) {
        .key => |key| if (key.state == .pressed) {
            tracker.invalidate();
        },
        else => {},
    }
}

fn displayKeyboardRouter(event: display_state.KeyboardEvent, surface: ?*wl.Surface, context: ?*anyopaque) void {
    const runner = runnerFromContext(context);
    invalidateInputOnKeyboardEvent(&runner.input_tracker, event);
    switch (event) {
        .enter => setKeyboardFocus(runner, activeKeyboardHost(runner, surface)),
        .leave => setKeyboardFocus(runner, null),
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
            if (event == .enter) runner.ime_focused_host = host;
            if (event == .leave) runner.ime_focused_host = null;
        } else return;
    }
    runner.handleImeEvent(event);
}

/// Wayland 只有 enter/leave 携带 surface；其余事件必须沿用最近一次 enter 建立的
/// Host 引用。该引用只由平台线程读写，并在 Host 释放前清除。
fn inputSeat(runner: *const Runner) input_provenance.Seat {
    return .{
        .identity = if (runner.state.pointer != null and runner.state.seat_capabilities.pointer)
            if (runner.state.seat) |seat| @intFromPtr(seat) else 0
        else
            0,
        .epoch = runner.state.pointer_epoch,
    };
}

const GrabContext = struct { runner: *Runner, lease: input_provenance.Lease };

fn preparePopupGrab(context: *anyopaque, parent: *egl.Host, popup: *egl.Host) !void {
    const grab: *GrabContext = @ptrCast(@alignCast(context));
    const active = try grab.runner.registry.activeHostForPlatform(grab.lease.parent);
    if (active != parent or parent.surface == null or @intFromPtr(parent.surface.?) != grab.lease.source_surface) return error.PopupInputParentMismatch;
    try grab.runner.input_tracker.validateLease(grab.lease, inputSeat(grab.runner), nowNs());
    // No dispatch or fallible work between this ownership transfer and grab.
    grab.runner.physical_buttons.transfer(grab.lease.raw_button, grab.lease.source_surface, @intFromPtr(popup.surface.?));
}

/// A compositor may focus an unmapped popup as soon as grab is requested.
/// Replay the latest native location only when its Flutter view becomes active.
fn syncPointerFocus(runner: *Runner) void {
    const next = if (runner.state.pointer != null and runner.state.pointer_enter_serial != null)
        activeKeyboardHost(runner, runner.state.current_pointer_surface)
    else
        null;
    const target = if (next) |host| if (host.state == .ready and !host.close_requested and !host.popup_dismissed) host else null else null;
    if (runner.pointer_focused_host == target) return;
    if (runner.pointer_focused_host) |previous| previous.leavePointerFocus();
    runner.pointer_focused_host = target;
    if (target) |host| host.enterPointerFocus(runner.state.pointer_surface_x, runner.state.pointer_surface_y);
}

fn displaySurfaceRetired(surface: *wl.Surface, context: ?*anyopaque) void {
    const runner = runnerFromContext(context);
    runner.physical_buttons.retireSurface(@intFromPtr(surface));
    if (runner.pointer_focused_host) |host| {
        if (host.surface == surface) {
            host.leavePointerFocus();
            runner.pointer_focused_host = null;
        }
    }
}

fn displayPointerReset(context: ?*anyopaque) void {
    const runner = runnerFromContext(context);
    runner.input_tracker.invalidate();
    runner.physical_buttons.reset();
    runner.physical_pointer_epoch = runner.state.pointer_epoch;
    if (runner.pointer_focused_host) |previous| previous.leavePointerFocus();
    runner.pointer_focused_host = null;
}

fn displayPointerRouter(event: wl.Pointer.Event, surface: ?*wl.Surface, context: ?*anyopaque) void {
    const runner = runnerFromContext(context);
    if (runner.physical_pointer_epoch != runner.state.pointer_epoch) {
        displayPointerReset(context);
    }
    const first_press = switch (event) {
        .button => |button| blk: {
            const pressed = button.state == .pressed;
            if (pressed) runner.input_tracker.invalidate();
            // A queued press after native focus was retired has no source that
            // could later release or retire it. Releases still clear by code.
            if (pressed and surface == null) break :blk false;
            break :blk runner.physical_buttons.update(button.button, pressed, if (surface) |source| @intFromPtr(source) else 0);
        },
        else => false,
    };
    syncPointerFocus(runner);
    switch (event) {
        .enter, .leave => return, // Focus transitions were delivered by the synchronization.
        else => {},
    }
    const target = runner.pointer_focused_host orelse return;
    target.handlePointerEvent(event, first_press);
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
    /// IME enter can precede keyboard enter; it never changes keyboard focus.
    ime_focused_host: ?*egl.Host = null,
    /// 指针 enter 建立的窗口焦点；motion/button/axis 本身不携带 surface。
    pointer_focused_host: ?*egl.Host = null,
    input_tracker: input_provenance.Tracker = .{},
    physical_buttons: @import("pointer_buttons.zig").Buttons = .{},
    physical_pointer_epoch: u64 = 0,
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
                    std.log.scoped(.input).err("xkb keymap init failed: {s}", .{@errorName(err)});
                    self.xkb_state = .{};
                    return;
                };
            },
            .modifiers => |m| {
                self.last_modifiers = m.depressed;
                self.xkb_state.updateModifiers(m.depressed, m.latched, m.locked, m.group, m.group, m.group);
            },
            // The router owns the selected Host; do not erase it on enter.
            .enter, .leave => self.repeat_active_key = null,
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

    /// Keysyms are translated by Flutter GTK maps; they are not logical key IDs.
    /// 发送 RawKeyEvent 到 flutter/keyevent 通道 (GTK 嵌入器同款格式)。
    fn sendKeyboardEvent(self: *Runner, keycode: u32, pressed: bool) void {
        const sym = self.xkb_state.getSym(keycode);
        var buf: [512]u8 = undefined;
        const msg = encodeKeyboardEvent(&buf, keycode, sym, self.xkb_state.getMods(), pressed) catch return;
        self.sendToEngine("flutter/keyevent", msg);
    }

    /// IME 事件 (text-input-v3): preedit / commit / delete_surrounding。
    /// 在键盘焦点窗口的 runner 上执行 (主线程或 spawn 线程 — 由路由调用处决定)。
    fn handleImeEvent(self: *Runner, event: ime_v3.ImeEvent) void {
        switch (event) {
            .preedit => |p| {
                self.text_client.setComposing(p.text, p.cursor_begin, p.cursor_end) catch |err| {
                    std.log.scoped(.input).err("preedit composing failed: {s}", .{@errorName(err)});
                };
            },
            .commit => |text| {
                self.text_client.insertText(text) catch |err| {
                    std.log.scoped(.input).err("ime commit insert failed: {s}", .{@errorName(err)});
                };
            },
            .delete_surrounding => |d| {
                self.text_client.deleteSurrounding(d.before, d.after) catch |err| {
                    std.log.scoped(.input).err("ime delete failed: {s}", .{@errorName(err)});
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
                    } else if (self.ime_focused_host) |focused| {
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
                        std.log.scoped(.input).err("insertText failed: {s}", .{@errorName(err)});
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
            std.log.scoped(.input).err("clipboard set failed: {s}", .{@errorName(err)});
        };
    }

    fn pasteClipboard(self: *Runner) void {
        if (self.pending_clipboard_read != null) return;
        const start = self.clipboard.beginReadText() catch |err| {
            std.log.scoped(.input).err("clipboard read failed: {s}", .{@errorName(err)});
            return;
        };
        switch (start) {
            .immediate => |text| {
                defer self.gpa.free(text);
                if (text.len == 0) return;
                self.text_client.insertText(text) catch |err| {
                    std.log.scoped(.input).err("paste failed: {s}", .{@errorName(err)});
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
            std.log.scoped(.engine).err("FlutterEngineSendPlatformMessage failed: {s}", .{flutter.resultName(result)});
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
                            std.log.scoped(.input).err("clipboard paste failed: {s}", .{@errorName(err)});
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
                    std.log.scoped(.input).err("clipboard getData response allocation failed: {s}", .{@errorName(err)});
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
            std.log.scoped(.window).err("failed to encode window close event: {s}", .{@errorName(err)});
            return;
        };
        defer self.gpa.free(payload);
        self.sendToEngine(platform_channels.window_events_channel_name, payload);
    }

    pub fn applicationSetReady(self: *Runner) void {
        self.application_ready = true;
        self.dispatchNextApplicationInvocation() catch |err| {
            std.log.scoped(.application).err("failed to dispatch application invocation: {s}", .{@errorName(err)});
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
                std.log.scoped(.application).err("failed to dispatch queued application invocation", .{});
                self.requestFatal(.application_broker_failed);
                return;
            }
            std.log.scoped(.application).err("failed to complete application invocation: {s}", .{@errorName(err)});
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
        std.log.scoped(.engine).debug("Flutter engine reports AOT-only execution; using AOT launch path (libapp.so).", .{});
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
            std.log.scoped(.engine).err("FlutterEngineCollectAOTData failed: {s}", .{@errorName(err)});
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
    std.log.scoped(.engine).debug("Wayland display connected and EGL bootstrap context is ready (headless shell).", .{});

    var task_queue = try flutter_task_queue.TaskQueue.init(gpa, options.io);
    defer task_queue.deinit();
    var runner: Runner = .{ .gpa = gpa, .frame_clock = .{ .io = options.io }, .state = state, .registry = &registry, .render_context = &render_context, .api = &api, .platform_thread_id = std.Thread.getCurrentId(), .task_queue = &task_queue, .engine_library = options.engine_library, .bundle_path = options.bundle_path, .application_broker = options.application_broker };
    runner.ime = state.ime;
    runner.text_client = text_input.Client.init(gpa);
    runner.text_client.send_fn = textInputSendCallback;
    runner.text_client.send_context = &runner;
    display_state.setPointerEventCallback(state, displayPointerRouter, &runner);
    state.pointer_reset_callback = displayPointerReset;
    state.surface_retired_callback = displaySurfaceRetired;
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
        std.log.scoped(.engine).debug("VM service requested on port {d}; waiting for engine URI.", .{port});
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

    std.log.scoped(.engine).debug("Starting Flutter engine with bundle assets: {s}", .{bundle.assets_path});
    var engine: c.FlutterEngine = null;
    const run_result = api.run(c.FLUTTER_ENGINE_VERSION, &renderer, &project_args, &runner, &engine);
    try flutter.ensureSuccess(run_result, "FlutterEngineRun");
    runner.engine = engine;
    errdefer if (runner.engine != null) shutdownEngine(&runner);

    std.log.scoped(.window).debug("Flutter engine is running (headless). Dart may create windows via FushellWindow.openWindow.", .{});
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
        std.log.scoped(.engine).err("engine event loop stopped: {s}", .{@errorName(err)});
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
    std.log.scoped(.engine).debug("Shutting down Flutter engine.", .{});
    shutdownEngine(&runner);
    shutdownAllWindows(&runner);
    shutdownShared(gpa, state);
    std.log.scoped(.engine).debug("engine event loop exited.", .{});
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
        std.log.scoped(.engine).warn("Flutter task-runner thread check rejected null context", .{});
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
        std.log.scoped(.application).err("application broker poll failed: {s}", .{@errorName(err)});
        runner.requestFatal(.application_broker_failed);
        return;
    };
    if (broker.fatalReason() != null) runner.requestFatal(.application_broker_failed);
}

fn postFlutterTaskCallback(task: c.FlutterTask, target_time_nanos: u64, user_data: ?*anyopaque) callconv(.c) void {
    const context = user_data orelse {
        std.log.scoped(.engine).warn("Flutter task post rejected null context", .{});
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
            std.log.scoped(.application).err("application broker pump failed: {s}", .{@errorName(err)});
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
            std.log.scoped(.application).warn("Application command ignored cancellation; restarting daemon.", .{});
            runner.quit_requested.store(true, .release);
        } else {
            runner.dispatchNextApplicationInvocation() catch |err| {
                std.log.scoped(.application).err("failed to dispatch queued application invocation: {s}", .{@errorName(err)});
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
        std.log.scoped(.engine).err("Flutter metrics callback failed: {s}", .{@errorName(err)});
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
    if (host_event.press_serial) |serial| {
        runner.input_tracker.record(.{
            .view_id = host.view_id,
            .time_us = @as(u64, host_event.time_ms.?) * 1000,
            .device = 0,
            .buttons = host_event.buttons,
        }, inputSeat(runner), serial, host_event.press_button.?, @intFromPtr(host.surface.?), nowNs());
    }
    sendPointerEvent(runner, host_event, host.view_id) catch |err| {
        std.log.scoped(.input).err("Flutter pointer callback failed: {s}", .{@errorName(err)});
    };
}

fn platformMessageCallback(raw_message: [*c]const c.FlutterPlatformMessage, user_data: ?*anyopaque) callconv(.c) void {
    const runner = fromUserData(user_data);
    if (raw_message == null) {
        std.log.scoped(.platform).warn("Received null Flutter platform message.", .{});
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
            std.log.scoped(.platform).debug("Unsupported Flutter platform channel: {s}", .{channel});
            runner.sendPlatformResponse(message.response_handle, "");
        },
    }
}

/// Execute one parsed fushell/window or fushell/process lifecycle request.
fn runnerHandleSurfaceRequest(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, request: surface_channel.Request) !void {
    switch (request) {
        .capture_input => |req| {
            _ = try runner.registry.activeHostForPlatform(req.window_id);
            const token = try runner.input_tracker.capture(.{
                .view_id = req.window_id,
                .time_us = req.time_us,
                .device = req.device,
                .buttons = req.buttons,
            }, inputSeat(runner), nowNs());
            const response = try std.fmt.allocPrint(runner.gpa, "{{\"id\":{d},\"ok\":true,\"inputToken\":{d}}}", .{ req.id, token });
            defer runner.gpa.free(response);
            if (response_handle) |handle| _ = runnerSendPlatformResponse(runner, handle, response);
        },
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
    const grab_token = switch (request.role) {
        .popup => |popup| popup.grab_token,
        else => null,
    };
    var grab_context: ?GrabContext = if (grab_token) |token| .{
        .runner = runner,
        .lease = try runner.input_tracker.consume(token, request.parent orelse return error.ParentWindowNotFound, inputSeat(runner), nowNs()),
    } else null;
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
        .popup => |p| try host.initializePopupRole(p, parent_host.?, if (grab_context) |*ctx| .{
            .seat = runner.state.seat orelse return error.PopupInputSeatChanged,
            .serial = ctx.lease.serial,
            .context = ctx,
            .prepare = preparePopupGrab,
        } else null),
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
    std.log.scoped(.window).debug("window.open: view {d} (parent {any})", .{ view_id, request.parent });
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
    runner.input_tracker.invalidateView(entry.view_id);
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
            std.log.scoped(.window).err("deferred view removal failed: {s}", .{@errorName(err)});
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
    std.log.scoped(.window).debug("window.close: view {d} (remove pending)", .{request.window_id});
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
            std.log.scoped(.window).err("compositor close failed for view {d}: {s}", .{ view_id, @errorName(err) });
            continue;
        };
        std.log.scoped(.window).debug("compositor close: view {d} (remove pending)", .{view_id});
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
            runner.input_tracker.invalidateView(view_id);
            if (runner.focused_host == &entry.host) runner.focused_host = null;
            if (runner.ime_focused_host == &entry.host) runner.ime_focused_host = null;
            if (runner.pointer_focused_host == &entry.host) runner.pointer_focused_host = null;
            if (runner.state.current_pointer_surface == entry.host.surface) {
                runner.state.current_pointer_surface = null;
                runner.state.pointer_enter_serial = null;
            }
            if (runner.state.current_keyboard_surface == entry.host.surface) runner.state.current_keyboard_surface = null;
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
                // Initial configure dispatch may have delivered keyboard.enter
                // before AddView and surface indexing completed.
                setKeyboardFocus(runner, activeKeyboardHost(runner, runner.state.current_keyboard_surface));
                syncPointerFocus(runner);
                const response = surface_channel.openSuccessResponse(runner.gpa, request_id, view_id) catch |err| {
                    std.log.scoped(.window).err("Failed to encode window.open response: {s}", .{@errorName(err)});
                    runner.requestFatal(.platform_response_encoding_failed);
                    break;
                };
                defer runner.gpa.free(response);
                if (handle) |h| _ = runnerSendPlatformResponse(runner, h, response);
            },
            .add_failed => {
                std.log.scoped(.window).err("FlutterEngineAddView reported added=false for view {d}", .{view_id});
                if (handle) |h| runnerSendSurfaceError(runner, h, request_id, "AddViewFailed", "engine rejected the new view");
            },
            .remove_succeeded => {
                if (handle) |h| sendSurfaceSuccess(runner, h, request_id);
                std.log.scoped(.window).debug("window.close: view {d} removed and surface destroyed.", .{view_id});
            },
            .remove_failed => {
                cancelWindowCloseChain(runner, entry, "RemoveViewFailed");
                std.log.scoped(.window).err("FlutterEngineRemoveView reported removed=false for view {d}", .{view_id});
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
            std.log.scoped(.engine).debug("process.exit({d}) requested; deferring shutdown until the active command reply is sent.", .{request.code});
            return;
        }
    }
    runner.quit_requested.store(true, .release);
    std.log.scoped(.engine).debug("process.exit({d}) requested; stopping event loop.", .{request.code});
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
    runner.state.pointer_reset_callback = null;
    runner.state.surface_retired_callback = null;
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
        std.log.scoped(.window).err("Failed to encode fushell surface success response: {s}", .{@errorName(err)});
        runner.requestFatal(.platform_response_encoding_failed);
        return;
    };
    defer runner.gpa.free(response);
    _ = runnerSendPlatformResponse(runner, response_handle, response);
}

fn runnerSendSurfaceError(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, id: ?i64, code: []const u8, message: []const u8) void {
    const response = surface_channel.errorResponse(runner.gpa, id, code, message) catch |err| {
        std.log.scoped(.window).err("Failed to encode fushell surface error response: {s}", .{@errorName(err)});
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
        std.log.scoped(.platform).err("Failed to encode Flutter method error: {s}", .{@errorName(err)});
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
        std.log.scoped(.platform).debug("Flutter platform message had no response handle.", .{});
        return .not_requested;
    }
    if (runner.engine == null) {
        std.log.scoped(.platform).err("Cannot reply to Flutter platform message before engine handle is available.", .{});
        runner.requestFatal(.platform_response_failed);
        return .engine_unavailable;
    }
    const result = runner.api.send_platform_message_response(runner.engine, response_handle, response.ptr, response.len);
    if (result != c.kSuccess) {
        std.log.scoped(.engine).err("FlutterEngineSendPlatformMessageResponse failed: {s}", .{flutter.resultName(result)});
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
        std.log.scoped(.render).err("Flutter make_current callback failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn makeResourceCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    runner.render_context.makeResourceCurrent() catch |err| {
        std.log.scoped(.render).err("Flutter make_resource_current callback failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn clearCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    runner.render_context.clearCurrent() catch |err| {
        std.log.scoped(.render).err("Flutter clear_current callback failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn presentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    // compositor 路径下呈现由 present_view_callback 接管 (官方 GTK 嵌入器同款 no-op)。
    if (!runner.first_present_logged) {
        std.log.scoped(.render).debug("renderer present invoked; presentation handled by compositor present_view_callback.", .{});
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
        std.log.scoped(.render).err("create_backing_store failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

/// compositor: 回收 backing store 纹理。
fn collectBackingStoreCallback(backing_store_ptr: [*c]const c.FlutterBackingStore, user_data: ?*anyopaque) callconv(.c) bool {
    _ = user_data;
    const backing_store: *const c.FlutterBackingStore = @ptrCast(backing_store_ptr);
    flutter_compositor.collectBackingStore(backing_store) catch |err| {
        std.log.scoped(.render).err("collect_backing_store failed: {s}", .{@errorName(err)});
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
        std.log.scoped(.render).err("present_view makeSurfaceCurrent failed: {s}", .{@errorName(err)});
        return false;
    };
    // RemoveView completion may destroy the native window once this lock drops.
    defer runner.render_context.makeCurrent() catch |err| {
        std.debug.panic("Cannot release view drawable after presentation: {s}", .{@errorName(err)});
    };
    const metrics = host.presentationMetricsLocked();
    flutter_compositor.presentFrame(&runner.blitter, info, @intCast(metrics.width), @intCast(metrics.height)) catch |err| {
        std.log.scoped(.render).err("present_view frame failed: {s}", .{@errorName(err)});
        return false;
    };
    runner.render_context.swapBuffers(host.egl_surface) catch |err| {
        std.log.scoped(.render).err("present_view swapBuffers failed: {s}", .{@errorName(err)});
        return false;
    };
    host.has_presented_buffer = true;
    if (!runner.compositor_first_present_logged) {
        std.log.scoped(.render).debug("Flutter presented first frame via compositor (view {d}).", .{info.view_id});
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
    std.log.scoped(.render).debug("Flutter GL proc resolver could not resolve: {s}", .{name_z});
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
    // The embedder callback has no severity field: preserve Dart prints, engine
    // failures, and service announcements verbatim in every build mode.
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

test "early native pointer focus replays only the latest live active view" {
    const Mode = enum { activate, leave, seat_loss, close, transfer, retire_pending, retire_active };
    const Fixed = @TypeOf(@as(wl.Pointer.Event, .{ .enter = undefined }).enter.surface_x);
    const Recorder = struct {
        events: [16]egl.PointerEvent = undefined,
        count: usize = 0,
        fn pointer(_: *egl.Host, context: ?*anyopaque, event: egl.PointerEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.events[self.count] = event;
            self.count += 1;
        }
    };
    for ([_]Mode{ .activate, .leave, .seat_loss, .close, .transfer, .retire_pending, .retire_active }) |mode| {
        var registry = WindowRegistry.init(std.testing.allocator, std.testing.io);
        defer registry.deinit();
        const entry = try registry.reserveLocked(null);
        defer registry.releaseLocked(entry);
        const surface: *wl.Surface = @ptrFromInt(1);
        const other: *wl.Surface = @ptrFromInt(2);
        var recorder: Recorder = .{};
        entry.host.surface = surface;
        entry.host.view_id = entry.view_id;
        entry.host.state = .ready;
        entry.host.setPointerCallback(Recorder.pointer, &recorder);
        var state: display_state.DisplayState = .{ .pointer = @ptrFromInt(3), .pointer_event_callback = displayPointerRouter, .pointer_reset_callback = displayPointerReset, .surface_retired_callback = displaySurfaceRetired };
        var runner: Runner = undefined;
        runner.registry = &registry;
        runner.state = &state;
        runner.pointer_focused_host = null;
        runner.input_tracker = .{};
        runner.physical_buttons = .{};
        runner.physical_pointer_epoch = 0;
        state.pointer_event_context = &runner;
        // A pre-commit grab can send enter before native surface indexing.
        display_state.routePointerEvent(&state, .{ .enter = .{ .serial = 1, .surface = surface, .surface_x = Fixed.fromDouble(10), .surface_y = Fixed.fromDouble(20) } });
        display_state.routePointerEvent(&state, .{ .motion = .{ .time = 1, .surface_x = Fixed.fromDouble(30), .surface_y = Fixed.fromDouble(40) } });
        display_state.routePointerEvent(&state, .{ .button = .{ .serial = 2, .time = 2, .button = 0x111, .state = .pressed } });
        try std.testing.expectEqual(@as(usize, 0), recorder.count);
        try registry.indexSurfaceLocked(entry);
        syncPointerFocus(&runner); // Indexed, but AddView is still pending.
        display_state.routePointerEvent(&state, .{ .motion = .{ .time = 3, .surface_x = Fixed.fromDouble(45), .surface_y = Fixed.fromDouble(55) } });
        try std.testing.expectEqual(@as(usize, 0), recorder.count);
        switch (mode) {
            .activate, .retire_active => {},
            .retire_pending => {
                state.retireSurfaceInput(surface);
                try std.testing.expectEqual(@as(usize, 0), runner.physical_buttons.count);
            },
            .leave => display_state.routePointerEvent(&state, .{ .leave = .{ .serial = 3, .surface = surface } }),
            .seat_loss => {
                state.resetPointerInput();
                state.pointer = null;
            },
            .close => entry.close_requested = true,
            .transfer => display_state.routePointerEvent(&state, .{ .enter = .{ .serial = 3, .surface = other, .surface_x = Fixed.fromDouble(1), .surface_y = Fixed.fromDouble(2) } }),
        }
        entry.lifecycle = .active;
        syncPointerFocus(&runner); // The same completion hook used by AddView.
        if (mode != .activate and mode != .retire_active) {
            try std.testing.expectEqual(@as(usize, 0), recorder.count);
            try std.testing.expect(runner.pointer_focused_host == null);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 2), recorder.count);
        try std.testing.expectEqual(egl.PointerPhase.add, recorder.events[0].phase);
        try std.testing.expectEqual(egl.PointerPhase.hover, recorder.events[1].phase);
        try std.testing.expectEqual(@as(f64, 45), recorder.events[1].x);
        try std.testing.expectEqual(@as(f64, 55), recorder.events[1].y);
        // Drop release of the old pre-activation press; future clicks work.
        display_state.routePointerEvent(&state, .{ .button = .{ .serial = 4, .time = 4, .button = 0x111, .state = .released } });
        try std.testing.expectEqual(@as(usize, 2), recorder.count);
        display_state.routePointerEvent(&state, .{ .button = .{ .serial = 5, .time = 5, .button = 0x110, .state = .pressed } });
        display_state.routePointerEvent(&state, .{ .button = .{ .serial = 6, .time = 6, .button = 0x110, .state = .released } });
        try std.testing.expectEqual(egl.PointerPhase.down, recorder.events[2].phase);
        try std.testing.expectEqual(egl.PointerPhase.up, recorder.events[3].phase);
        // A stale leave for a different surface cannot erase current focus.
        display_state.routePointerEvent(&state, .{ .leave = .{ .serial = 7, .surface = other } });
        try std.testing.expect(runner.pointer_focused_host == &entry.host);
        // Loss while A holds a button must emit remove immediately, even if
        // the next native enter targets that same window and coordinates.
        display_state.routePointerEvent(&state, .{ .button = .{ .serial = 8, .time = 8, .button = 0x110, .state = .pressed } });
        if (mode == .retire_active) {
            // Escape destroys the source while held; its outside release never
            // reaches this client. The next enter/press must be eligible.
            state.retireSurfaceInput(surface);
        } else {
            state.resetPointerInput();
        }
        try std.testing.expectEqual(@as(usize, 6), recorder.count);
        try std.testing.expectEqual(egl.PointerPhase.remove, recorder.events[5].phase);
        try std.testing.expect(runner.pointer_focused_host == null);
        try std.testing.expectEqual(@as(usize, 0), runner.physical_buttons.count);
        try std.testing.expectEqual(@as(i64, 0), entry.host.pointer_buttons);
        state.pointer = @ptrFromInt(4);
        display_state.routePointerEvent(&state, .{ .enter = .{ .serial = 9, .surface = surface, .surface_x = Fixed.fromDouble(45), .surface_y = Fixed.fromDouble(55) } });
        try std.testing.expectEqual(egl.PointerPhase.add, recorder.events[6].phase);
        try std.testing.expectEqual(egl.PointerPhase.hover, recorder.events[7].phase);
        display_state.routePointerEvent(&state, .{ .button = .{ .serial = 10, .time = 10, .button = 0x110, .state = .pressed } });
        try std.testing.expectEqual(egl.PointerPhase.down, recorder.events[8].phase);
        try std.testing.expectEqual(@as(?u32, 10), recorder.events[8].press_serial);
        display_state.routePointerEvent(&state, .{ .button = .{ .serial = 11, .time = 11, .button = 0x110, .state = .released } });
        display_state.routePointerEvent(&state, .{ .leave = .{ .serial = 12, .surface = surface } });
        syncPointerFocus(&runner);
        try std.testing.expectEqual(@as(usize, 11), recorder.count);
        try std.testing.expectEqual(egl.PointerPhase.remove, recorder.events[10].phase);
        try std.testing.expect(runner.pointer_focused_host == null);
    }
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

test "native keyboard focus survives enter and is forwarded to the correct view" {
    const Fake = struct {
        var views: [4]i64 = undefined;
        var states: [4]c.FlutterViewFocusState = undefined;
        var count: usize = 0;
        fn focus(_: c.FlutterEngine, event: *const c.FlutterViewFocusEvent) callconv(.c) c.FlutterEngineResult {
            views[count] = event.view_id;
            states[count] = event.state;
            count += 1;
            return c.kSuccess;
        }
    };
    Fake.count = 0;
    var api: flutter.Api = undefined;
    api.send_view_focus = Fake.focus;
    var runner: Runner = undefined;
    runner.api = &api;
    runner.engine = @ptrFromInt(1);
    runner.focused_host = null;
    runner.repeat_active_key = 30;
    var first: egl.Host = .{ .view_id = 7 };
    var second: egl.Host = .{ .view_id = 8 };
    setKeyboardFocus(&runner, &first);
    runner.handleKeyboardEvent(.{ .enter = .{ .surface = undefined, .keys = undefined } });
    try std.testing.expect(runner.focused_host == &first);
    try std.testing.expect(runner.repeat_active_key == null);
    setKeyboardFocus(&runner, &second);
    setKeyboardFocus(&runner, &second);
    setKeyboardFocus(&runner, null);
    try std.testing.expectEqual(@as(usize, 4), Fake.count);
    try std.testing.expectEqualSlices(i64, &.{ 7, 7, 8, 8 }, &Fake.views);
    try std.testing.expectEqualSlices(c.FlutterViewFocusState, &.{ c.kFocused, c.kUnfocused, c.kFocused, c.kUnfocused }, &Fake.states);
}

test "physical keyboard press invalidates mouse credentials but release does not" {
    var tracker: input_provenance.Tracker = .{};
    const fingerprint: input_provenance.Fingerprint = .{ .view_id = 7, .time_us = 1000, .device = 0, .buttons = 2 };
    const seat: input_provenance.Seat = .{ .identity = 1, .epoch = 0 };
    tracker.record(fingerprint, seat, 4, 0x111, 1, 0);
    invalidateInputOnKeyboardEvent(&tracker, .{ .key = .{ .serial = 5, .time = 2, .key = 1, .state = .released } });
    const token = try tracker.capture(fingerprint, seat, 1);
    invalidateInputOnKeyboardEvent(&tracker, .{ .key = .{ .serial = 6, .time = 3, .key = 1, .state = .pressed } });
    try std.testing.expectError(error.PopupInputUnavailable, tracker.consume(token, 7, seat, 2));
}

test "IME enter cannot suppress keyboard focus or deferred AddView synchronization" {
    var registry = WindowRegistry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const entry = try registry.reserveLocked(null);
    defer registry.releaseLocked(entry);
    var stub: u8 = 0;
    const surface: *wl.Surface = @ptrCast(&stub);
    entry.host.surface = surface;
    entry.host.view_id = entry.view_id;
    try registry.indexSurfaceLocked(entry);
    var state: display_state.DisplayState = .{ .current_keyboard_surface = surface };
    var runner: Runner = undefined;
    runner.registry = &registry;
    runner.state = &state;
    runner.engine = null;
    runner.focused_host = null;
    runner.ime_focused_host = null;
    runner.text_client.active = false;
    runner.repeat_active_key = null;
    // The popup exists natively but AddView has not completed.
    imeEventRouter(.{ .enter = .{ .surface = surface } }, &runner);
    try std.testing.expect(runner.ime_focused_host == &entry.host);
    try std.testing.expect(runner.focused_host == null);
    setKeyboardFocus(&runner, activeKeyboardHost(&runner, state.current_keyboard_surface));
    try std.testing.expect(runner.focused_host == null);
    entry.lifecycle = .active;
    setKeyboardFocus(&runner, activeKeyboardHost(&runner, state.current_keyboard_surface));
    try std.testing.expect(runner.focused_host == &entry.host);
    // A later normal IME-first keyboard transition also retains the notification.
    setKeyboardFocus(&runner, null);
    imeEventRouter(.{ .enter = .{ .surface = surface } }, &runner);
    displayKeyboardRouter(.{ .enter = .{ .surface = surface, .keys = undefined } }, surface, &runner);
    try std.testing.expect(runner.focused_host == &entry.host);
}

test "GTK keyboard messages use keysyms and XKB scan codes without logical overrides" {
    for ([_]struct { evdev: u32, sym: u32 }{ .{ .evdev = 1, .sym = 0xff1b }, .{ .evdev = 105, .sym = 0xff51 } }) |key| {
        var buffer: [512]u8 = undefined;
        const message = try encodeKeyboardEvent(&buffer, key.evdev, key.sym, 0, true);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, message, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqual(@as(i64, key.evdev + 8), object.get("scanCode").?.integer);
        try std.testing.expectEqual(@as(i64, key.sym), object.get("keyCode").?.integer);
        try std.testing.expect(!object.contains("specifiedLogicalKey"));
        try std.testing.expect(!object.contains("specifiedPhysicalKey"));
    }
}

test "GTK printable payload retains Unicode with Shift and Control" {
    for ([_]struct { sym: u32, mods: u32, scalar: u32 }{
        .{ .sym = 'a', .mods = 0, .scalar = 'a' },
        .{ .sym = 'A', .mods = 1, .scalar = 'A' },
        .{ .sym = 0x01004e2d, .mods = 0, .scalar = 0x4e2d },
        .{ .sym = 'c', .mods = 4, .scalar = 'c' },
    }) |key| {
        var buffer: [512]u8 = undefined;
        const message = try encodeKeyboardEvent(&buffer, 30, key.sym, key.mods, true);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, message, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, key.scalar), parsed.value.object.get("unicodeScalarValues").?.integer);
        try std.testing.expect(!parsed.value.object.contains("unicodeCodePoint"));
        try std.testing.expectEqual(@as(i64, key.mods), parsed.value.object.get("modifiers").?.integer);
    }
}

test "pointer leave and button release preserve originating credentials and physical state" {
    var state: display_state.DisplayState = .{};
    var runner: Runner = undefined;
    runner.state = &state;
    runner.pointer_focused_host = null;
    runner.input_tracker = .{};
    runner.physical_buttons = .{};
    runner.physical_pointer_epoch = 0;
    const fingerprint: input_provenance.Fingerprint = .{ .view_id = 7, .time_us = 1000, .device = 0, .buttons = 2 };
    const seat: input_provenance.Seat = .{ .identity = 1, .epoch = 0 };
    runner.input_tracker.record(fingerprint, seat, 4, 0x111, 1, 0);
    _ = runner.physical_buttons.update(0x111, true, 1);
    const surface: *wl.Surface = @ptrFromInt(1);
    displayPointerRouter(.{ .leave = .{ .serial = 5, .surface = surface } }, surface, &runner);
    try std.testing.expectEqual(@as(usize, 1), runner.physical_buttons.count);
    displayPointerRouter(.{ .button = .{ .serial = 6, .time = 2, .button = 0x111, .state = .released } }, null, &runner);
    try std.testing.expectEqual(@as(usize, 0), runner.physical_buttons.count);
    const token = try runner.input_tracker.capture(fingerprint, seat, 1);
    const lease = try runner.input_tracker.consume(token, 7, seat, 2);
    displayPointerRouter(.{ .button = .{ .serial = 7, .time = 3, .button = 0x111, .state = .pressed } }, null, &runner);
    try std.testing.expectError(error.PopupInputUnavailable, runner.input_tracker.validateLease(lease, seat, 3));
}

test "grab preparation transfers only the validated still-held trigger" {
    const Mode = enum { held, released, foreign_owner, non_grab, invalid_lease, nested };
    for ([_]Mode{ .held, .released, .foreign_owner, .non_grab, .invalid_lease, .nested }) |mode| {
        var registry = WindowRegistry.init(std.testing.allocator, std.testing.io);
        defer registry.deinit();
        const parent = try registry.reserveLocked(null);
        defer registry.releaseLocked(parent);
        const child = try registry.reserveLocked(parent.view_id);
        defer registry.releaseLocked(child);
        parent.host.surface = @ptrFromInt(11);
        parent.host.view_id = parent.view_id;
        parent.host.state = .ready;
        parent.lifecycle = .active;
        child.host.surface = @ptrFromInt(12);
        child.host.view_id = child.view_id;
        child.host.state = .ready;
        child.lifecycle = .active;
        var state: display_state.DisplayState = .{ .seat = @ptrFromInt(20), .pointer = @ptrFromInt(21), .seat_capabilities = .{ .pointer = true }, .surface_retired_callback = displaySurfaceRetired };
        var runner: Runner = undefined;
        runner.registry = &registry;
        runner.state = &state;
        runner.pointer_focused_host = null;
        runner.input_tracker = .{};
        runner.physical_buttons = .{};
        state.pointer_event_context = &runner;
        const fingerprint: input_provenance.Fingerprint = .{ .view_id = parent.view_id, .time_us = 1000, .device = 0, .buttons = 2 };
        const seat = inputSeat(&runner);
        const timestamp = nowNs();
        runner.input_tracker.record(fingerprint, seat, 31, 0x111, 11, timestamp);
        const token = try runner.input_tracker.capture(fingerprint, seat, timestamp);
        var context: GrabContext = .{ .runner = &runner, .lease = try runner.input_tracker.consume(token, parent.view_id, seat, timestamp) };
        _ = runner.physical_buttons.update(0x111, true, if (mode == .foreign_owner) 99 else 11);
        if (mode == .released) _ = runner.physical_buttons.update(0x111, false, 0);
        // An unrelated held code is never cleared or reassigned by transfer.
        _ = runner.physical_buttons.update(0x113, true, 99);
        const held_count = runner.physical_buttons.count;
        if (mode == .invalid_lease) {
            runner.input_tracker.invalidate();
            try std.testing.expectError(error.PopupInputUnavailable, preparePopupGrab(&context, &parent.host, &child.host));
        } else if (mode != .non_grab) {
            try preparePopupGrab(&context, &parent.host, &child.host);
        }
        try std.testing.expectEqual(held_count, runner.physical_buttons.count);
        if (mode == .nested) {
            // Release the root trigger, then use a fresh child press for its child.
            _ = runner.physical_buttons.update(0x111, false, 12);
            _ = runner.physical_buttons.update(0x113, false, 12);
            try std.testing.expect(runner.physical_buttons.update(0x110, true, 12));
            var nested_fingerprint = fingerprint;
            nested_fingerprint.view_id = child.view_id;
            nested_fingerprint.time_us = 2000;
            nested_fingerprint.buttons = 1;
            runner.input_tracker.invalidate();
            runner.input_tracker.record(nested_fingerprint, seat, 32, 0x110, 12, timestamp);
            const nested_token = try runner.input_tracker.capture(nested_fingerprint, seat, timestamp);
            context.lease = try runner.input_tracker.consume(nested_token, child.view_id, seat, timestamp);
            var grandchild: egl.Host = .{ .surface = @ptrFromInt(13) };
            try preparePopupGrab(&context, &child.host, &grandchild);
            state.retireSurfaceInput(child.host.surface.?);
            try std.testing.expectEqual(@as(usize, 1), runner.physical_buttons.count);
            state.retireSurfaceInput(grandchild.surface.?);
            try std.testing.expect(runner.physical_buttons.update(0x110, true, 11));
            continue;
        }
        state.retireSurfaceInput(child.host.surface.?);
        // The foreign code still prevents a new first press after child removal.
        try std.testing.expect(!runner.physical_buttons.update(0x110, true, 11));
        _ = runner.physical_buttons.update(0x110, false, 0);
        _ = runner.physical_buttons.update(0x113, false, 0);
        const transferred = mode == .held or mode == .released;
        try std.testing.expectEqual(transferred, runner.physical_buttons.update(0x111, true, 11));
    }
}

test "orphaned presses invalidate leases without creating unretirable held state" {
    var registry = WindowRegistry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    var state: display_state.DisplayState = .{ .pointer = @ptrFromInt(3) };
    var runner: Runner = undefined;
    runner.registry = &registry;
    runner.state = &state;
    runner.pointer_focused_host = null;
    runner.input_tracker = .{};
    runner.physical_buttons = .{};
    runner.physical_pointer_epoch = 0;
    displayPointerRouter(.{ .button = .{ .serial = 1, .time = 1, .button = 0x111, .state = .pressed } }, null, &runner);
    try std.testing.expectEqual(@as(usize, 0), runner.physical_buttons.count);
    const surface: *wl.Surface = @ptrFromInt(1);
    // Non-null pre-index input must still count, including unsupported chords.
    displayPointerRouter(.{ .button = .{ .serial = 2, .time = 2, .button = 0x113, .state = .pressed } }, surface, &runner);
    try std.testing.expectEqual(@as(usize, 1), runner.physical_buttons.count);
    try std.testing.expect(!runner.physical_buttons.update(0x111, true, 1));
    displayPointerRouter(.{ .button = .{ .serial = 3, .time = 3, .button = 0x113, .state = .released } }, null, &runner);
    displayPointerRouter(.{ .button = .{ .serial = 4, .time = 4, .button = 0x111, .state = .released } }, null, &runner);
    try std.testing.expect(runner.physical_buttons.update(0x111, true, 1));
}
