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

/// spawn 窗口注册表: 主窗口退出时关闭所有子窗口 (共享 Dart VM)。
/// 子窗口线程不 detach: 结束标记 finished, 由复用槽位时 (或主窗口退出时) join
/// 回收资源, 避免 detach/join 竞态 (join 已 detach 线程是未定义行为)。
/// 64 = 单个播放器进程的窗口数上限 (槽位数组大小, 实际窗口数远小于此)。
const max_spawned_windows = 64;
const SpawnEntry = struct {
    active: bool = false,
    /// 线程已结束但尚未 join (等待复用槽位时回收)。
    finished: bool = false,
    thread: std.Thread = undefined,
    host: ?*egl.Host = null,
    /// 键盘事件路由目标 (键盘焦点在 spawn 窗口 surface 时)。
    runner: ?*Runner = null,
};
var spawn_entries: [max_spawned_windows]SpawnEntry = undefined;
var spawn_mutex: std.atomic.Mutex = .unlocked;

/// 进程级共享 DisplayState (单例): 主窗口首次创建, spawn 窗口共享。
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

/// 主窗口 runner (指针路由的目标之一)。
/// 进程级 data-control (系统剪贴板): 主窗口 attach 时创建, 绑定到共享 display。
var global_data_control: ?*data_control.DataControl = null;

var main_runner_host: ?*egl.Host = null;
var main_runner_ref: ?*Runner = null;

/// 键盘输入事件 (主线程 push, 目标窗口线程 drain)。
/// keymap 数据在主线程 mmap 后立即拷贝 (生命周期跨线程)。
const InputEvent = union(enum) {
    keymap: []u8,
    key: struct { keycode: u32, pressed: bool },
    modifiers: struct { depressed: u32, latched: u32, locked: u32, group: u32 },
    focus: bool,
};

/// 主线程 dispatch 键盘事件 → 焦点窗口 runner 的输入队列。
fn displayKeyboardRouter(event: display_state.KeyboardEvent, surface: ?*wl.Surface) void {
    // keymap 在 enter 之前到达 (surface 未知) — 投给主窗口 runner。
    const runner = findRunnerBySurface(surface) orelse main_runner_ref orelse return;
    runner.queueInputEvent(event) catch |err| {
        std.debug.print("[error] queue keyboard event failed: {s}\n", .{@errorName(err)});
    };
}

/// IME 事件路由: 投给键盘焦点窗口 (IME 是全局对象, 事件随焦点窗口)。
/// text_input.Client 的 send_fn: 发 updateEditingState 到对应 runner 的引擎。
/// 简单方案: 路由到键盘焦点窗口 (IME 场景) 或 main_runner (普通输入)。
fn textInputSendCallback(client_id: i64, msg: []const u8) void {
    _ = client_id;
    const target = focusRunnerRef() orelse main_runner_ref orelse return;
    target.sendToEngine("flutter/textinput", msg);
}

fn focusRunnerRef() ?*Runner {
    if (main_runner_ref) |runner| {
        if (runner.keyboard_focused) return runner;
    }
    lockSpawnMutex();
    defer spawn_mutex.unlock();
    for (&spawn_entries) |*entry| {
        if (!entry.active) continue;
        if (entry.runner) |r| {
            if (r.keyboard_focused) return r;
        }
    }
    return null;
}

fn imeEventRouter(event: ime_v3.ImeEvent, ctx: ?*anyopaque) void {
    _ = ctx;
    // enter/leave 事件带 surface → 精确路由到对应窗口的 runner。
    // (不能依赖 keyboard_focused: text_input enter 可能先于 wl_keyboard.enter 到达)
    var surface: ?*wl.Surface = null;
    switch (event) {
        .enter => |e| surface = e.surface,
        .leave => |e| surface = e.surface,
        else => {},
    }
    if (surface) |s| {
        if (findRunnerBySurface(s)) |r| {
            r.handleImeEvent(event);
            return;
        }
    }
    // 无 surface 或找不到: 回退主 runner。
    if (main_runner_ref) |runner| {
        runner.handleImeEvent(event);
        return;
    }
}

fn findRunnerBySurface(surface: ?*wl.Surface) ?*Runner {
    const s = surface orelse return null;
    if (main_runner_ref) |runner| {
        if (main_runner_host) |host| {
            if (host.surface == s) return runner;
        }
    }
    lockSpawnMutex();
    defer spawn_mutex.unlock();
    for (&spawn_entries) |*entry| {
        if (!entry.active) continue;
        if (entry.host) |host| {
            if (host.surface == s) return entry.runner;
        }
    }
    return null;
}

/// 指针路由: 事件 surface → 目标窗口 host → handlePointerEvent。
/// 由主窗口线程调用 (pointer 绑主 queue)。spawn 窗口的指针状态跨线程写入,
/// 但 spawn 线程不读指针状态 (其事件循环只处理自己的 surface 事件), 竞态可接受。
fn displayPointerRouter(event: wl.Pointer.Event, surface: ?*wl.Surface) void {
    const target = findHostBySurface(surface) orelse return;
    target.handlePointerEvent(event);
}

fn findHostBySurface(surface: ?*wl.Surface) ?*egl.Host {
    const s = surface orelse return null;
    if (main_runner_host) |host| {
        if (host.surface == s) return host;
    }
    for (&spawn_entries) |*entry| {
        if (!entry.active) continue;
        if (entry.host) |host| {
            if (host.surface == s) return host;
        }
    }
    return null;
}

/// atomic.Mutex (0.16) 无 lock(), 统一用自旋 tryLock 封装。
fn lockSpawnMutex() void {
    while (!spawn_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn lockDisplayStateMutex() void {
    while (!display_state_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlockSpawnMutex() void {
    spawn_mutex.unlock();
}

/// 停止所有活跃子窗口的事件循环并 join 其线程。
/// 必须在主引擎 FlutterEngineShutdown (销毁共享 VM) 之前调用。
fn shutdownSpawnedWindows() void {
    lockSpawnMutex();
    var threads: [max_spawned_windows]?std.Thread = undefined;
    for (&spawn_entries, 0..) |*entry, i| {
        if (entry.active) {
            if (entry.host) |host| host.running = false;
            threads[i] = entry.thread;
        } else if (entry.finished) {
            // 已结束未回收的线程: join 立即返回, 回收资源
            threads[i] = entry.thread;
            entry.finished = false;
        } else {
            threads[i] = null;
        }
    }
    unlockSpawnMutex();

    for (threads) |maybe_thread| {
        if (maybe_thread) |thread| thread.join();
    }
    std.debug.print("all spawned windows shut down.\n", .{});
}

pub const Role = enum {
    /// 主窗口: 创建共享 DisplayState, runEventLoop 结束后关闭所有 spawn 窗口, 销毁 VM。
    primary,
    /// spawn 窗口: 共享主窗口的 DisplayState 与 Dart VM, 不负责 VM 生命周期。
    spawned,
};

pub const Options = struct {
    engine_library: []const u8,
    bundle_path: []const u8,
    /// 窗口角色 (primary/spawned), 派生 VM 生命周期与共享状态管理。
    role: Role = .primary,
    /// 自定义 Dart entrypoint (custom_dart_entrypoint), 空则用 main。
    entrypoint: ?[]const u8 = null,
    /// 传给 entrypoint 的命令行参数 (dart_entrypoint_argv)。
    entrypoint_argv: ?[]const []const u8 = null,
    /// 外部提供的 Host (spawn 窗口): 主线程需要访问它以触发退出。
    external_host: ?*egl.Host = null,
    /// 启动 VM service (热重载用, 仅 debug/JIT 引擎支持):
    /// 传 --enable-vm-service --vm-service-port=0, URI 从引擎日志解析。
    enable_vm_service: bool = false,

    /// VM 生命周期由角色派生: primary 负责销毁, spawned 共享。
    pub fn shutdownVmWhenDone(self: Options) bool {
        return self.role == .primary;
    }
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
    host: *egl.Host,
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

    // ── 输入 / 文本 / 剪贴板 ──────────────────────
    text_client: text_input.Client = undefined,
    clipboard: clipboard.Clipboard = undefined,
    ime: ?*ime_v3.ImeV3 = null,
    xkb_state: xkb.Xkb = .{},
    keyboard_focused: bool = false,
    // 键盘长按重复 (wl_keyboard.repeat_info): delay 后按 rate 模拟 keydown。
    repeat_delay_ms: u32 = 500,
    repeat_rate_per_sec: u32 = 25,
    repeat_active_key: ?u32 = null,
    repeat_next_time_ns: u64 = 0,
    last_modifiers: u32 = 0,
    input_mutex: std.atomic.Mutex = .unlocked,
    input_events: std.ArrayListUnmanaged(InputEvent) = .empty,

    fn now(self: *Runner) u64 {
        return self.api.get_current_time();
    }

    fn beginMetricsUpdate(self: *Runner) u64 {
        return self.metrics_generation.fetchAdd(1, .release) + 1;
    }

    fn beginRender(self: *Runner) void {
        self.rendering_generation.store(self.metrics_generation.load(.acquire), .release);
    }

    /// 主线程调用: 投递键盘事件到本窗口线程的输入队列。
    fn queueInputEvent(self: *Runner, event: display_state.KeyboardEvent) !void {
        while (!self.input_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.input_mutex.unlock();
        switch (event) {
            .keymap => |km| {
                const copy = try self.gpa.dupe(u8, km.data);
                try self.input_events.append(self.gpa, .{ .keymap = copy });
            },
            .key => |k| try self.input_events.append(self.gpa, .{ .key = .{ .keycode = k.key, .pressed = k.state == .pressed } }),
            .modifiers => |m| try self.input_events.append(self.gpa, .{ .modifiers = .{ .depressed = m.depressed, .latched = m.latched, .locked = m.locked, .group = m.group } }),
            .enter => try self.input_events.append(self.gpa, .{ .focus = true }),
            .leave => try self.input_events.append(self.gpa, .{ .focus = false }),
            .repeat => |r| {
                self.repeat_delay_ms = @intCast(@max(r.delay_ms, 0));
                self.repeat_rate_per_sec = @intCast(@max(r.rate_per_sec, 0));
            },
        }
    }

    /// 窗口线程调用 (事件循环 tick): 处理全部积压的键盘事件。
    /// 键盘长按重复: 到达 repeat 时间点则模拟一次 keydown。
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
        if (self.keyboard_focused and self.text_client.active) {
            _ = self.xkb_state.updateKey(key, true);
            self.sendKeyboardEvent(key, true);
            self.handleKey(key);
        }
    }

    fn drainInputEvents(self: *Runner) void {
        while (true) {
            while (!self.input_mutex.tryLock()) std.atomic.spinLoopHint();
            if (self.input_events.items.len == 0) {
                self.input_mutex.unlock();
                return;
            }
            const event = self.input_events.orderedRemove(0);
            self.input_mutex.unlock();
            defer if (event == .keymap) self.gpa.free(event.keymap);
            self.handleInputEvent(event);
        }
    }

    fn handleInputEvent(self: *Runner, event: InputEvent) void {
        switch (event) {
            .keymap => |km| {
                self.xkb_state.deinit();
                self.xkb_state = xkb.Xkb.init(self.gpa, km) catch |err| {
                    std.debug.print("[error] xkb keymap init failed: {s}\n", .{@errorName(err)});
                    self.xkb_state = .{};
                    return;
                };
                {
                    const path_z: [:0]const u8 = "/tmp/fushell-keymap.xkb";
                    const rc = std.os.linux.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
                    const fd: i32 = @intCast(@min(rc, 1 << 30));
                    if (fd > 0) {
                        _ = std.os.linux.write(fd, km.ptr, km.len);
                        _ = std.os.linux.close(fd);
                    }
                }
            },
            .modifiers => |m| {
                self.last_modifiers = m.depressed;
                self.xkb_state.updateModifiers(m.depressed, m.latched, m.locked, m.group, m.group, m.group);
            },
            .focus => |focused| self.keyboard_focused = focused,
            .key => |k| {
                // 按下/松开都更新 xkb 状态 (修饰键跟踪依赖它)。
                _ = self.xkb_state.updateKey(k.keycode, k.pressed);
                // 无论焦点/文本客户端, 都向 Flutter 发送 RawKeyEvent
                // (EditableText 靠它实现 Ctrl+C/V/A 等快捷键)。
                self.sendKeyboardEvent(k.keycode, k.pressed);
                if (!self.keyboard_focused or !self.text_client.active) return;
                if (k.pressed) {
                    // 启动长按重复计时 (repeat_info 的 delay 后按 rate 重复)。
                    self.repeat_active_key = k.keycode;
                    self.repeat_next_time_ns = nowNs() + @as(u64, self.repeat_delay_ms) * 1_000_000;
                    self.handleKey(k.keycode);
                } else {
                    if (self.repeat_active_key == k.keycode) self.repeat_active_key = null;
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
                    } else {
                        std.debug.print("[diag] submit rect (enter-pointer) ({d:.0},{d:.0})\n", .{ self.host.pointer_x, self.host.pointer_y });
                        ime.setCursorRect(
                            @intFromFloat(@max(self.host.pointer_x, 0)),
                            @intFromFloat(@max(self.host.pointer_y, 0)),
                            4,
                            @intFromFloat(@max(@as(f64, 24) * self.host.activeScale(), 16)),
                        );
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

    var local_host: egl.Host = .{};
    const host: *egl.Host = options.external_host orelse &local_host;
    defer if (options.external_host == null) local_host.deinit();
    // 进程级共享 DisplayState: 主窗口首次创建 (acquire 时 connect),
    // spawn 窗口 acquire 共享。主窗口退出时 shutdownSpawnedWindows 先 join 全部
    // spawn, 再 host.deinit() 使引用归零 → 连接完整清理。
    const state = try getDisplayState(gpa);
    try host.attach(state, options.role == .primary);
    if (options.role == .primary) {
        main_runner_host = host;
        display_state.setPointerEventCallback(displayPointerRouter, null);
        display_state.setKeyboardEventCallback(displayKeyboardRouter, null);
        // 系统剪贴板 (data-control): 主窗口负责绑定, 共享给所有窗口。
        if (global_data_control == null) {
            const dc = gpa.create(data_control.DataControl) catch null;
            if (dc) |d| {
                d.* = data_control.DataControl.init(gpa, state);
                global_data_control = d;
                state.data_control = d;
                // 若 registry 已发现 manager (attachPrimary 前), 补绑定
                if (state.data_control_manager_name != 0) {
                    if (state.registry) |reg| d.bindManager(reg, state.data_control_manager_name, state.data_control_manager_version);
                }
            }
        }
        // IME (text-input-v3): 主窗口创建, 共享 DisplayState; registry 绑定在 attachPrimary 后由 registryListener 完成。
        if (state.ime == null) {
            const ime = gpa.create(ime_v3.ImeV3) catch null;
            if (ime) |i| {
                i.* = .{};
                state.ime = i;
            }
        }
        // registry 事件可能在 ime 创建前已处理 (attachPrimary 先于创建) — 补绑定。
        if (state.ime) |ime| {
            ime.primary_queue = state.primary_queue;
            ime.setCallback(imeEventRouter, null);
            if (state.ime_manager_name != 0) {
                if (state.registry) |reg| {
                    if (state.seat) |seat| ime.bindManager(reg, state.ime_manager_name, state.ime_manager_version, seat);
                }
            }
        }
    }
    try host.initEglBootstrap();
    std.debug.print("Wayland display connected and EGL bootstrap context is ready. Waiting for Dart surface initialization.\n", .{});

    var runner: Runner = .{ .gpa = gpa, .host = host, .api = &api, .platform_thread_id = std.Thread.getCurrentId(), .engine_library = options.engine_library, .bundle_path = options.bundle_path };
    runner.ime = state.ime;
    runner.text_client = text_input.Client.init(gpa);
    runner.text_client.send_fn = textInputSendCallback;
    runner.clipboard = clipboard.Clipboard.init(gpa);
    defer runner.text_client.deinit();
    defer runner.clipboard.deinit();
    defer runner.xkb_state.deinit();
    defer {
        // input_events.deinit 只释放容器: 残留未消费的 keymap 载荷需逐个释放
        for (runner.input_events.items) |ev| {
            if (ev == .keymap) runner.gpa.free(ev.keymap);
        }
        runner.input_events.deinit(gpa);
    }
    if (options.role == .primary) {
        main_runner_ref = &runner;
    } else if (options.external_host) |external| {
        // 注册 spawn runner (键盘路由目标), 退出时注销。
        lockSpawnMutex();
        for (&spawn_entries) |*entry| {
            if (entry.host == external) {
                entry.runner = &runner;
            }
        }
        unlockSpawnMutex();
    }
    defer {
        if (options.role == .primary) {
            main_runner_ref = null;
        } else if (options.external_host) |external| {
            lockSpawnMutex();
            for (&spawn_entries) |*entry| {
                if (entry.host == external) {
                    entry.runner = null;
                }
            }
            unlockSpawnMutex();
        }
    }
    host.setMetricsCallback(metricsCallback, &runner);
    host.setPointerCallback(pointerCallback, &runner);

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
    project_args.shutdown_dart_vm_when_done = options.shutdownVmWhenDone();
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

    // 自定义 entrypoint + argv (多窗口 spawn 用): 分配在 run 的 gpa 上,
    // run 阻塞期间 (engine 运行中) 有效, engine 启动时已消费。
    // argv 独立于 entrypoint 注入: 新窗口用 main 入口, 窗口标识通过 argv 传递
    // (Dart 侧 main(List<String> args) 接收)。
    // run 返回后释放 — 引擎只读这些指针 (消费≠释放), 不负责 free。
    if (options.entrypoint) |entrypoint| {
        const entrypoint_z = try gpa.dupeZ(u8, entrypoint);
        defer gpa.free(entrypoint_z);
        project_args.custom_dart_entrypoint = entrypoint_z.ptr;
    }
    if (options.entrypoint_argv) |argv| {
        const argv_z = try gpa.allocSentinel(?[*:0]const u8, argv.len, null);
        defer gpa.free(argv_z);
        for (argv, 0..) |arg, i| {
            const arg_z = try gpa.dupeZ(u8, arg);
            defer gpa.free(arg_z);
            argv_z[i] = arg_z.ptr;
        }
        project_args.dart_entrypoint_argc = @intCast(argv.len);
        project_args.dart_entrypoint_argv = argv_z.ptr;
    }

    std.debug.print("Starting Flutter engine with bundle assets: {s}\n", .{bundle.assets_path});
    var engine: c.FlutterEngine = null;
    const run_result = api.run(c.FLUTTER_ENGINE_VERSION, &renderer, &project_args, &runner, &engine);
    try flutter.ensureSuccess(run_result, "FlutterEngineRun");
    runner.engine = engine;
    try sendMetrics(&runner, host.metrics());
    std.debug.print("Sent bootstrap Flutter metrics while waiting for Dart surface initialization.\n", .{});
    errdefer if (runner.engine != null) {
        const shutdown_result = api.shutdown(runner.engine);
        if (shutdown_result != c.kSuccess) {
            std.debug.print("[error] FlutterEngineShutdown after startup error failed: {s}\n", .{flutter.resultName(shutdown_result)});
        }
    };

    std.debug.print("Flutter engine is running. Dart must call FushellSurface.init before rendering.\n", .{});
    try host.runEventLoop("Flutter first-frame mode is active.", flutterTaskPumpCallback, &runner);

    // 主窗口关闭: 先关闭所有子窗口引擎 (它们共享 VM), 再销毁 VM。
    // 否则子引擎仍在使用 VM 时销毁 → 崩溃。
    if (options.role == .primary) shutdownSpawnedWindows();

    std.debug.print("Shutting down Flutter engine.\n", .{});
    try flutter.ensureSuccess(api.shutdown(runner.engine), "FlutterEngineShutdown");
    runner.engine = null;
    std.debug.print("engine window thread exited.\n", .{});
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
    runner.drainInputEvents();
    runner.checkKeyRepeat();
    try runner.runDueFlutterTasks();
}

fn sendMetrics(runner: *Runner, host_metrics: egl.Metrics) !void {
    if (runner.engine == null) return;
    const generation = runner.beginMetricsUpdate();
    var metrics: c.FlutterWindowMetricsEvent = std.mem.zeroes(c.FlutterWindowMetricsEvent);
    metrics.struct_size = @sizeOf(c.FlutterWindowMetricsEvent);
    metrics.width = host_metrics.width;
    metrics.height = host_metrics.height;
    metrics.pixel_ratio = host_metrics.pixel_ratio;
    metrics.left = 0;
    metrics.top = 0;
    metrics.view_id = 0;
    _ = generation;
    try flutter.ensureSuccess(runner.api.send_window_metrics(runner.engine, &metrics), "FlutterEngineSendWindowMetricsEvent");
    try flutter.ensureSuccess(runner.api.schedule_frame(runner.engine), "FlutterEngineScheduleFrame");
}

fn metricsCallback(context: ?*anyopaque, host_metrics: egl.Metrics) void {
    const runner = fromUserData(context);
    // 窗口 shutdown 中 (引擎销毁): 主线程 dispatch 的 scale 事件可能触达,
    // 引擎句柄已失效 → 发送即 UAF。
    if (runner.engine == null or runner.host.state == .shutting_down) return;
    sendMetrics(runner, host_metrics) catch |err| {
        std.debug.print("[error] Flutter metrics callback failed: {s}\n", .{@errorName(err)});
    };
}

fn sendPointerEvent(runner: *Runner, host_event: egl.PointerEvent) !void {
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
    event.view_id = 0;
    try flutter.ensureSuccess(runner.api.send_pointer_event(runner.engine, &event, 1), "FlutterEngineSendPointerEvent");
}

fn pointerCallback(context: ?*anyopaque, host_event: egl.PointerEvent) void {
    const runner = fromUserData(context);
    sendPointerEvent(runner, host_event) catch |err| {
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
            } else {
                // fallback: 指针位置 (引擎几何未到)。
                ime.setCursorRect(
                    @intFromFloat(@max(runner.host.pointer_x, 0)),
                    @intFromFloat(@max(runner.host.pointer_y, 0)),
                    4,
                    24,
                );
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

    handleSurfaceRequest(runner, request) catch |err| {
        const code = surfaceRequestErrorCode(err);
        std.debug.print("[error] Fushell surface request failed: {s}\n", .{code});
        sendSurfaceError(runner, message.response_handle, request.id(), code, "fushell surface request failed");
        return;
    };
    sendSurfaceSuccess(runner, message.response_handle, request.id());
}

fn handleSurfaceRequest(runner: *Runner, request: surface_channel.Request) !void {
    switch (request) {
        .init => |init_request| try initializeSurfaceRole(runner, init_request),
        .update_layer => |update_request| try updateLayerSurface(runner, update_request),
        .update_window => |update_request| try updateWindowSurface(runner, update_request),
        .spawn_window => |spawn_request| try spawnWindow(runner, spawn_request),
    }
}

fn initializeSurfaceRole(runner: *Runner, request: surface_channel.InitRequest) !void {
    switch (request.role) {
        .window => |window| {
            try runner.host.initializeWindowRole(window);
            std.debug.print("Fushell surface initialized: window role.\n", .{});
        },
        .layer => |layer| {
            try runner.host.initializeLayerRole(layer);
            std.debug.print("Fushell surface initialized: layer role.\n", .{});
        },
    }
    try sendMetrics(runner, runner.host.metrics());
}

fn updateLayerSurface(runner: *Runner, request: surface_channel.LayerSurfaceUpdateRequest) !void {
    _ = try runner.host.updateLayerRole(request.update);
}

fn updateWindowSurface(runner: *Runner, request: surface_channel.WindowSurfaceUpdateRequest) !void {
    _ = try runner.host.updateWindowRole(request.update);
}

/// window.spawn: 以指定 Dart entrypoint + argv 创建新 engine + 新窗口。
/// 上下文从调用方 gpa 分配 (线程生命周期由 run 的 join 保证)。
fn spawnWindow(runner: *Runner, request: surface_channel.SpawnRequest) !void {
    // 分配注册表槽位 (线程不 detach, 主窗口退出时 join)
    lockSpawnMutex();
    var slot: ?usize = null;
    for (&spawn_entries, 0..) |*entry, i| {
        if (!entry.active) {
            // 复用槽位前回收上一个已结束的线程 (join 已结束线程立即返回)
            if (entry.finished) {
                entry.thread.join();
                entry.finished = false;
            }
            entry.active = true;
            slot = i;
            break;
        }
    }
    unlockSpawnMutex();
    const slot_index = slot orelse {
        std.debug.print("[error] too many spawned windows (max {d})\n", .{max_spawned_windows});
        return error.TooManySpawnedWindows;
    };

    const context = runner.gpa.create(SpawnContext) catch return error.OutOfMemory;
    errdefer runner.gpa.destroy(context);

    context.engine_library = runner.gpa.dupe(u8, runner.engine_library) catch return error.OutOfMemory;
    errdefer runner.gpa.free(context.engine_library);
    context.bundle_path = runner.gpa.dupe(u8, runner.bundle_path) catch return error.OutOfMemory;
    errdefer runner.gpa.free(context.bundle_path);
    context.entrypoint = runner.gpa.dupe(u8, request.entrypoint) catch return error.OutOfMemory;
    errdefer runner.gpa.free(context.entrypoint);
    context.args = runner.gpa.alloc([]const u8, request.args.len + 1) catch return error.OutOfMemory;
    errdefer runner.gpa.free(context.args);
    // argv[0] = 窗口身份 (entrypoint 名), 之后是请求的 args。
    // 新窗口用 main 入口启动 (main 永远在 AOT 快照中), 通过 dart_entrypoint_argv 区分。
    context.args[0] = runner.gpa.dupe(u8, request.entrypoint) catch return error.OutOfMemory;
    for (request.args, 0..) |arg, i| {
        context.args[i + 1] = runner.gpa.dupe(u8, arg) catch return error.OutOfMemory;
    }
    context.slot = slot_index;

    const thread = std.Thread.spawn(.{}, spawnThreadMain, .{ runner.gpa, context }) catch |err| {
        lockSpawnMutex();
        spawn_entries[slot_index].active = false;
        unlockSpawnMutex();
        std.debug.print("[error] failed to spawn window thread: {s}\n", .{@errorName(err)});
        return error.WindowSpawnFailed;
    };
    lockSpawnMutex();
    spawn_entries[slot_index].thread = thread;
    unlockSpawnMutex();
    std.debug.print("spawned window engine (entrypoint: {s})\n", .{request.entrypoint});
}

/// spawn 线程的上下文 (gpa 持有, 线程 join 后由 run 返回前释放)。
const SpawnContext = struct {
    engine_library: []u8,
    bundle_path: []u8,
    entrypoint: []u8,
    args: [][]const u8,
    slot: usize,
};

fn spawnThreadMain(gpa: std.mem.Allocator, context: *SpawnContext) void {
    var host: egl.Host = .{};
    // 注册 host: 主线程用它触发退出 (running = false)
    lockSpawnMutex();
    spawn_entries[context.slot].host = &host;
    unlockSpawnMutex();
    defer {
        // 先注销注册表 (需要 context.slot), 再释放 context — 顺序反了会 use-after-free
        lockSpawnMutex();
        spawn_entries[context.slot].active = false;
        spawn_entries[context.slot].host = null;
        // 标记线程已结束: 下次复用该槽位 (或主窗口退出) 时 join 回收资源。
        // 不能在这里 detach — join 一个已 detach 的线程是未定义行为。
        spawn_entries[context.slot].finished = true;
        unlockSpawnMutex();
        host.deinit();
        gpa.free(context.engine_library);
        gpa.free(context.bundle_path);
        gpa.free(context.entrypoint);
        for (context.args) |arg| gpa.free(arg);
        gpa.free(context.args);
        gpa.destroy(context);
    }
    run(gpa, .{
        .engine_library = context.engine_library,
        .bundle_path = context.bundle_path,
        .role = .spawned,
        // 新窗口用 main 入口 (main 是 AOT tree-shaker 的根, 永远保留);
        // 窗口身份通过 argv[0] 传递, Dart 侧用 PlatformDispatcher.instance.args 区分。
        .entrypoint = null,
        .entrypoint_argv = context.args,
        .external_host = &host,
    }) catch |err| {
        std.debug.print("[error] spawned window engine failed: {s}\n", .{@errorName(err)});
    };
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
    const ready = runner.host.isReady();
    if (!ready and !runner.bootstrap_render_logged) {
        std.debug.print("Flutter requested rendering before FushellSurface.init completed; using EGL bootstrap pbuffer until Dart selects a surface role.\n", .{});
        runner.bootstrap_render_logged = true;
    }
    runner.host.makeCurrent() catch |err| {
        std.debug.print("[error] Flutter make_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    if (ready) runner.beginRender();
    return true;
}

fn clearCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    if (!runner.host.isReady()) return true;
    runner.host.clearCurrent() catch |err| {
        std.debug.print("[error] Flutter clear_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

fn presentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    if (!runner.host.isReady()) {
        if (!runner.bootstrap_present_logged) {
            std.debug.print("[error] Flutter requested present before FushellSurface.init completed; dropping bootstrap frame until Dart selects a surface role.\n", .{});
            runner.bootstrap_present_logged = true;
        }
        return true;
    }
    if (!runner.shouldPresentRenderedFrame()) {
        const skipped = runner.skipped_resize_presents.fetchAdd(1, .monotonic) + 1;
        if (skipped <= 5 or skipped % 30 == 0) {
            std.debug.print("Skipping stale Flutter frame during resize/scale transition ({d} skipped); scheduling fresh frame.\n", .{skipped});
        }
        const schedule_result = runner.api.schedule_frame(runner.engine);
        if (schedule_result != c.kSuccess) {
            std.debug.print("[error] FlutterEngineScheduleFrame after stale resize frame failed: {s}\n", .{flutter.resultName(schedule_result)});
        }
        return true;
    }
    runner.host.swapBuffers() catch |err| {
        std.debug.print("[error] Flutter present callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    if (!runner.first_present_logged) {
        std.debug.print("Flutter presented first frame on initialized Fushell surface.\n", .{});
        runner.first_present_logged = true;
    }
    return true;
}

fn fboCallback(user_data: ?*anyopaque) callconv(.c) u32 {
    const runner = fromUserData(user_data);
    if (!runner.host.isReady()) {
        std.debug.print("Flutter requested FBO before FushellSurface.init completed.\n", .{});
        return 0;
    }
    return runner.host.defaultFramebuffer();
}

fn glProcResolverCallback(user_data: ?*anyopaque, name: [*c]const u8) callconv(.c) ?*anyopaque {
    const runner = fromUserData(user_data);
    const name_z: [*:0]const u8 = @ptrCast(name);
    const proc = runner.host.resolveGlProc(name_z);
    if (proc == null) std.debug.print("Flutter GL proc resolver could not resolve: {s}\n", .{name_z});
    return proc;
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
