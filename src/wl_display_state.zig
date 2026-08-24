//! 进程级共享 Wayland 连接 + EGL display (多窗口共享)。
//!
//! 多窗口架构中,每个窗口不再独占 wl_display/EGL display,而是共享
//! 这一个 DisplayState:
//!   - 单一 wl_display 连接 (唯一 fd)
//!   - 单一 EGLDisplay (由 wl_display 派生)
//!   - 全局对象 (registry/compositor/wm_base/.../seat/pointer) 唯一
//!   - 引用计数: 主窗口 + 每个 spawn 窗口各持有 1, 归零时完整清理
//!
//! 线程模型: 全局对象绑定主窗口的 event queue, 由主窗口线程 dispatch;
//! 每个窗口的 surface 对象绑自己的 queue。连接级 flush 用互斥锁保护。

const std = @import("std");

/// atomic.Mutex (0.16) 无 lock(), 统一用自旋 tryLock 封装。
fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
const wayland = @import("wayland");
const data_control = @import("data_control.zig");
const ime_v3 = @import("ime_v3.zig");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;
const zwp = wayland.client.zwp;
const c = @import("c");

pub const max_outputs = 16;

pub const OutputState = struct {
    name: u32 = 0,
    output: ?*wl.Output = null,
    entered: bool = false,
    scale: i32 = 1,
};

/// 进程级共享显示状态 (单例)。
pub const DisplayState = struct {
    display: ?*wl.Display = null,
    registry: ?*wl.Registry = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    viewporter: ?*wp.Viewporter = null,
    fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
    seat: ?*wl.Seat = null,
    /// seat 通告的输入能力 (capabilities 事件)。无能力时不 get_pointer/get_keyboard
    /// — 无头 compositor (cage + 无输入设备) 下 seat 无 pointer/keyboard,
    /// 无条件调用会触发协议错误 (wl_seat.get_pointer called when no pointer capability)。
    seat_capabilities: wl.Seat.Capability = .{},
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    data_control: ?*data_control.DataControl = null,
    ime: ?*ime_v3.ImeV3 = null,
    data_control_manager_name: u32 = 0,
    data_control_manager_version: u32 = 0,
    ime_manager_name: u32 = 0,
    ime_manager_version: u32 = 0,
    outputs: [max_outputs]OutputState = [_]OutputState{.{}} ** max_outputs,

    egl_display: c.EGLDisplay = null,
    gles_library: ?std.DynLib = null,

    ref_count: usize = 0,
    /// 进程级单一 event queue — 全部对象 (全局 + 所有窗口 surface/xdg) 绑定它,
    /// 由主线程单一事件循环 dispatch (单线程模型, 无 per-window queue)。
    shared_queue: ?*wl.EventQueue = null,
    /// 连接级 flush 互斥 (多个窗口线程共享同一连接写)。
    flush_mutex: std.atomic.Mutex = .unlocked,

    // ── 初始化 / 生命周期 ──────────────────────────────

    /// 首次获取时建立连接。返回是否首次 (新连接)。
    pub fn acquire(self: *DisplayState) !bool {
        if (self.ref_count == 0) {
            try self.init();
        }
        self.ref_count += 1;
        return self.ref_count == 1;
    }

    pub fn isAcquired(self: *const DisplayState) bool {
        return self.ref_count > 0;
    }

    pub fn release(self: *DisplayState) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count == 0) self.deinit();
    }

    fn init(self: *DisplayState) !void {
        if (std.c.getenv("WAYLAND_DISPLAY") == null) {
            std.debug.print("WAYLAND_DISPLAY is not set; start a Wayland compositor or run from a Wayland session.\n", .{});
            return error.WaylandDisplayUnavailable;
        }

        self.display = wl.Display.connect(null) catch {
            std.debug.print("wl_display_connect failed for WAYLAND_DISPLAY.\n", .{});
            return error.WaylandDisplayUnavailable;
        };

        self.registry = self.display.?.getRegistry() catch return error.WaylandRegistryUnavailable;
        self.registry.?.setListener(*DisplayState, registryListener, self);
        if (self.display.?.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;

        // xdg_wm_base 全局共享: ping 应答绑定在 DisplayState (多窗口共享一个 wm_base)
        if (self.wm_base) |wm_base| wm_base.setListener(*DisplayState, wmBaseListener, self);

        if (self.compositor == null) {
            std.debug.print("Wayland global missing: wl_compositor\n", .{});
            return error.MissingWaylandGlobal;
        }
        if (self.wm_base == null) {
            std.debug.print("Wayland global missing: xdg_wm_base\n", .{});
            return error.MissingWaylandGlobal;
        }

        // 第二次 roundtrip: bind wl_output 后, compositor 的 geometry/scale 事件
        // 在后续 roundtrip 中到达 (协议保证: bind 请求之后的同步点必然收到已绑定
        // 对象的全部当前属性事件)。没有这一步, output.scale 会停在 1, 窗口按
        // 1x 渲染 → 在 2x 屏幕上模糊。
        if (self.display.?.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
        for (&self.outputs) |*output_state| {
            if (output_state.output != null) {
                std.debug.print("output {d} scale={d}\n", .{ output_state.name, output_state.scale });
            }
        }

        self.egl_display = c.eglGetDisplay(@ptrCast(self.display.?));
        if (self.egl_display == c.EGL_NO_DISPLAY) return eglError("eglGetDisplay");
        if (c.eglInitialize(self.egl_display, null, null) != c.EGL_TRUE) return eglError("eglInitialize");
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE) return eglError("eglBindAPI");
    }

    fn deinit(self: *DisplayState) void {
        if (self.egl_display != null and self.egl_display != c.EGL_NO_DISPLAY) {
            _ = c.eglTerminate(self.egl_display);
            self.egl_display = null;
        }
        if (self.gles_library) |*gles_library| {
            gles_library.close();
            self.gles_library = null;
        }
        if (self.pointer) |pointer| pointer.release();
        if (self.keyboard) |keyboard| keyboard.release();
        if (self.seat) |seat| seat.release();
        for (&self.outputs) |*output_state| {
            if (output_state.output) |output| output.release();
            output_state.* = .{};
        }
        if (self.layer_shell) |layer_shell| layer_shell.destroy();
        if (self.fractional_scale_manager) |manager| manager.destroy();
        if (self.viewporter) |viewporter| viewporter.destroy();
        if (self.wm_base) |wm_base| wm_base.destroy();
        if (self.registry) |registry| registry.destroy();
        if (self.shared_queue) |queue| queue.destroy();
        self.shared_queue = null;
        if (self.display) |display| display.disconnect();
        self.display = null;
        self.compositor = null;
        self.wm_base = null;
        self.layer_shell = null;
        self.viewporter = null;
        self.fractional_scale_manager = null;
        self.seat = null;
        self.pointer = null;
    }

    // ── 进程级初始化: 单一 queue 绑定全部对象 + 输入 ──────

    /// 启动时调用一次: 创建进程级单一 event queue, 把全局对象
    /// (registry/output/seat/pointer) 与后续所有窗口对象都绑到它,
    /// 并获取 seat 的 pointer/keyboard (按能力)。
    pub fn bindGlobals(self: *DisplayState) !void {
        if (self.shared_queue != null) return; // 幂等
        const queue = try self.display.?.createQueue();
        self.shared_queue = queue;
        // 全部全局对象绑主 queue: 主线程 dispatch 主 queue 时统一处理。
        // 漏掉任何一个 (如 wm_base) → 其事件 (ping) 留在 default queue 无人处理
        // → compositor 报窗口未响应。
        if (self.registry) |registry| registry.setQueue(queue);
        if (self.wm_base) |wm_base| wm_base.setQueue(queue);
        if (self.layer_shell) |layer_shell| layer_shell.setQueue(queue);
        if (self.viewporter) |viewporter| viewporter.setQueue(queue);
        if (self.fractional_scale_manager) |manager| manager.setQueue(queue);
        for (&self.outputs) |*output_state| {
            if (output_state.output) |output| output.setQueue(queue);
        }
        if (self.seat) |seat| {
            seat.setQueue(queue);
            if (self.data_control) |dc| dc.bindDevice(seat);
        }
        if (self.pointer) |pointer| pointer.setQueue(queue);
        if (self.keyboard) |keyboard| keyboard.setQueue(queue);
        self.ensurePointer();
        self.ensureKeyboard();
    }

    fn ensurePointer(self: *DisplayState) void {
        const seat = self.seat orelse return;
        if (self.pointer != null) return;
        if (!self.seat_capabilities.pointer) return; // 无头 compositor: seat 无 pointer 能力
        self.pointer = seat.getPointer() catch {
            std.debug.print("wl_seat.get_pointer failed.\n", .{});
            return;
        };
        self.pointer.?.setListener(*DisplayState, pointerListener, self);
        if (self.shared_queue) |queue| self.pointer.?.setQueue(queue);
    }

    fn ensureKeyboard(self: *DisplayState) void {
        const seat = self.seat orelse return;
        if (self.keyboard != null) return;
        if (!self.seat_capabilities.keyboard) return; // 无头 compositor: seat 无 keyboard 能力
        self.keyboard = seat.getKeyboard() catch {
            std.debug.print("wl_seat.get_keyboard failed.\n", .{});
            return;
        };
        self.keyboard.?.setListener(*DisplayState, keyboardListener, self);
        if (self.shared_queue) |queue| self.keyboard.?.setQueue(queue);
    }

    // ── 输出 / scale ──────────────────────────────────

    pub fn activeScale120(self: *const DisplayState) u32 {
        var scale: u32 = 0;
        for (&self.outputs) |*output_state| {
            if (output_state.entered and output_state.scale > scale) scale = @intCast(output_state.scale);
        }
        return if (scale == 0) 120 else scale * 120;
    }

    pub fn emptyOutputSlot(self: *DisplayState) ?*OutputState {
        for (&self.outputs) |*slot| {
            if (slot.output == null) return slot;
        }
        return null;
    }

    pub fn outputSlotByName(self: *DisplayState, name: u32) ?*OutputState {
        for (&self.outputs) |*slot| {
            if (slot.name == name) return slot;
        }
        return null;
    }

    pub fn outputSlotByObject(self: *DisplayState, output: *wl.Output) ?*OutputState {
        for (&self.outputs) |*slot| {
            if (slot.output == output) return slot;
        }
        return null;
    }

    // ── flush (连接级互斥) ────────────────────────────

    pub fn flushLocked(self: *DisplayState) void {
        self.lockFlush();
        defer self.unlockFlush();
        if (self.display) |display| _ = display.flush();
    }

    /// 手动锁/解锁 flush 互斥 (跨多次 marshal 时用, 如 data-control receive)。
    pub fn lockFlush(self: *DisplayState) void {
        lockMutex(&self.flush_mutex);
    }

    pub fn unlockFlush(self: *DisplayState) void {
        self.flush_mutex.unlock();
    }

    // ── GL 库 (共享) ──────────────────────────────────

    pub fn openGlesLibrary(self: *DisplayState) void {
        if (self.gles_library != null) return;
        self.gles_library = std.DynLib.open("libGLESv2.so.2") catch std.DynLib.open("libGLESv2.so") catch |err| {
            std.debug.print("Unable to open libGLESv2 for GL symbol fallback: {s}\n", .{@errorName(err)});
            return;
        };
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *DisplayState) void {
    switch (event) {
        .global => |global| {
            if (bindGlobal(registry, global, wl.Compositor)) |compositor| {
                self.compositor = compositor;
            } else if (bindGlobal(registry, global, wl.Output)) |output| {
                if (self.emptyOutputSlot()) |slot| {
                    slot.* = .{ .name = global.name, .output = output };
                    output.setListener(*DisplayState, outputListener, self);
                } else {
                    std.debug.print("Ignoring Wayland output {d}: output tracking slots are full.\n", .{global.name});
                    output.release();
                }
            } else if (bindGlobal(registry, global, wl.Seat)) |seat| {
                if (self.seat == null) {
                    self.seat = seat;
                    seat.setListener(*DisplayState, seatListener, self);
                    if (self.data_control) |dc| dc.bindDevice(seat);
                    if (self.ime) |ime| {
                        if (self.ime_manager_name != 0) {
                            if (self.registry) |reg| ime.bindManager(reg, self.ime_manager_name, self.ime_manager_version, seat);
                        }
                    }
                } else {
                    std.debug.print("Ignoring additional Wayland seat {d}; only one seat is supported in this MVP.\n", .{global.name});
                    seat.release();
                }
            } else if (bindGlobal(registry, global, wp.Viewporter)) |viewporter| {
                self.viewporter = viewporter;
            } else if (bindGlobal(registry, global, wp.FractionalScaleManagerV1)) |manager| {
                self.fractional_scale_manager = manager;
            } else if (bindGlobal(registry, global, zwlr.LayerShellV1)) |layer_shell| {
                self.layer_shell = layer_shell;
            } else if (bindGlobal(registry, global, zwlr.DataControlManagerV1)) |manager| {
                _ = manager;
                self.data_control_manager_name = global.name;
                self.data_control_manager_version = global.version;
                if (self.data_control) |dc| dc.bindManager(registry, global.name, global.version);
            } else if (bindGlobal(registry, global, xdg.WmBase)) |wm_base| {
                self.wm_base = wm_base;
            } else if (std.mem.eql(u8, std.mem.span(global.interface), "zwp_text_input_manager_v3")) {
                // bindGlobal 会用 generated_version (2), 但 hyprland 只支持 1 —
                // 手动 bind 并按 compositor 版本 clamp。seat 可能未到, 记录后补绑。
                self.ime_manager_name = global.name;
                self.ime_manager_version = global.version;
                if (self.ime) |ime| {
                    if (self.seat) |seat| ime.bindManager(registry, global.name, global.version, seat);
                }
            }
        },
        .global_remove => |global_remove| {
            if (self.outputSlotByName(global_remove.name)) |slot| {
                if (slot.output) |output| output.release();
                slot.* = .{};
            }
        },
    }
}

fn outputListener(output: *wl.Output, event: wl.Output.Event, self: *DisplayState) void {
    const slot = self.outputSlotByObject(output) orelse return;
    switch (event) {
        .scale => |scale| {
            const factor = @max(scale.factor, 1);
            if (slot.scale != factor) {
                slot.scale = factor;
                if (scale_change_callback) |callback| callback();
            }
        },
        .done => {},
        .geometry => {},
        .mode => {},
        .name => {},
        .description => {},
    }
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, self: *DisplayState) void {
    switch (event) {
        .ping => |ping| {
            wm_base.pong(ping.serial);
            self.flushLocked();
        },
    }
}

fn seatListener(_: *wl.Seat, event: wl.Seat.Event, self: *DisplayState) void {
    switch (event) {
        .capabilities => |caps| {
            self.seat_capabilities = caps.capabilities;
            // 热插拔: 能力晚于 bindGlobals 出现时补绑 (仅当主 queue 已就绪)。
            // 过早绑定会把 keymap 等事件排进 default queue, setQueue 后不转移 →
            // keymap 永久丢失 → xkb 无法翻译按键。
            if (self.shared_queue != null) {
                self.ensurePointer();
                self.ensureKeyboard();
            }
        },
        .name => {},
    }
}

// ── 键盘事件 ──────────────────────────────────────

/// 键盘事件由主窗口线程 dispatch (keyboard 绑主 queue)。
/// enter 事件带 surface → 目标窗口由 runner 层路由 (同 pointer)。
/// keymap 事件的 fd 需要 mmap 读取 (生命周期: 回调内处理完毕即 munmap)。
pub const KeyboardEvent = union(enum) {
    keymap: struct { format: wl.Keyboard.KeymapFormat, data: []const u8 },
    enter: struct { surface: ?*wl.Surface, keys: ?*wl.Array },
    leave: struct { surface: ?*wl.Surface },
    key: struct { serial: u32, time: u32, key: u32, state: wl.Keyboard.KeyState },
    modifiers: struct { depressed: u32, latched: u32, locked: u32, group: u32 },
    repeat: struct { delay_ms: i32, rate_per_sec: i32 },
};

pub const KeyboardEventCallback = *const fn (event: KeyboardEvent, surface: ?*wl.Surface) void;

var keyboard_event_callback: ?KeyboardEventCallback = null;
var keyboard_event_context: ?*anyopaque = null;

pub fn setKeyboardEventCallback(callback: KeyboardEventCallback, context: ?*anyopaque) void {
    keyboard_event_callback = callback;
    keyboard_event_context = context;
}

var current_keyboard_surface: ?*wl.Surface = null;
fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, _: *DisplayState) void {
    const surface = switch (event) {
        .enter => |enter| blk: {
            current_keyboard_surface = enter.surface;
            break :blk enter.surface;
        },
        .leave => |leave| blk: {
            current_keyboard_surface = null;
            break :blk leave.surface;
        },
        else => current_keyboard_surface,
    };
    if (keyboard_event_callback) |callback| {
        switch (event) {
            .keymap => |km| {
                // fd 是 MAP_PRIVATE 只读映射 (v7+)。读取后立即关闭/解除。
                const fd = km.fd;
                if (fd >= 0 and km.size > 0) {
                    const map = std.posix.mmap(
                        null,
                        km.size,
                        .{ .READ = true },
                        .{ .TYPE = .PRIVATE },
                        fd,
                        0,
                    ) catch {
                        _ = std.os.linux.close(fd);
                        return;
                    };
                    callback(.{ .keymap = .{ .format = km.format, .data = map } }, surface);
                    _ = std.posix.munmap(map);
                }
                _ = std.os.linux.close(fd);
            },
            .enter => |enter| callback(.{ .enter = .{ .surface = enter.surface, .keys = enter.keys } }, surface),
            .leave => |leave| callback(.{ .leave = .{ .surface = leave.surface } }, surface),
            .key => |key| callback(.{
                .key = .{ .serial = key.serial, .time = key.time, .key = key.key, .state = key.state },
            }, surface),
            .modifiers => |mods| callback(.{
                .modifiers = .{ .depressed = mods.mods_depressed, .latched = mods.mods_latched, .locked = mods.mods_locked, .group = mods.group },
            }, surface),
            .repeat_info => |ri| {
                callback(.{ .repeat = .{ .delay_ms = ri.delay, .rate_per_sec = ri.rate } }, surface);
            },
        }
    }
}

/// 指针事件由主窗口线程 dispatch (pointer 绑主 queue)。
/// 事件里的 surface 决定目标窗口: 主窗口 or spawn 窗口 (由 runner 层路由)。
var current_pointer_surface: ?*wl.Surface = null;
fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, _: *DisplayState) void {
    const surface = switch (event) {
        .enter => |enter| blk: {
            current_pointer_surface = enter.surface;
            break :blk enter.surface;
        },
        .leave => |leave| blk: {
            current_pointer_surface = null;
            break :blk leave.surface;
        },
        else => current_pointer_surface,
    };
    if (pointer_event_callback) |callback| callback(event, surface);
}

pub const PointerEventCallback = *const fn (event: wl.Pointer.Event, surface: ?*wl.Surface) void;

var pointer_event_callback: ?PointerEventCallback = null;
var pointer_event_context: ?*anyopaque = null;

/// output scale 变化回调 (主窗口 Host 注册: recomputeScale)。
pub var scale_change_callback: ?*const fn () void = null;

/// 主窗口线程设置: 指针事件转发目标 (runner 层路由)。
pub fn setPointerEventCallback(callback: PointerEventCallback, context: ?*anyopaque) void {
    pointer_event_callback = callback;
    pointer_event_context = context;
}

fn bindGlobal(registry: *wl.Registry, global: @FieldType(wl.Registry.Event, "global"), comptime T: type) ?*T {
    const iface: []const u8 = std.mem.span(global.interface);
    const want: []const u8 = std.mem.span(T.interface.name);
    if (!std.mem.eql(u8, iface, want)) return null;
    // 用生成代码的最大版本绑定 (surface.setBufferScale 等需要 version >= 3)
    return registry.bind(global.name, T, T.generated_version) catch null;
}

fn eglError(comptime step: []const u8) error{EglFailed} {
    std.debug.print("{s} failed: EGL error 0x{x}\n", .{ step, c.eglGetError() });
    return error.EglFailed;
}
