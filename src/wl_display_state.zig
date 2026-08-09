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
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;
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
    pointer: ?*wl.Pointer = null,
    outputs: [max_outputs]OutputState = [_]OutputState{.{}} ** max_outputs,

    egl_display: c.EGLDisplay = null,
    gles_library: ?std.DynLib = null,

    ref_count: usize = 0,
    /// 主窗口的 event queue — 全局对象 (registry/output/seat/pointer) 绑定它,
    /// 由主窗口线程 dispatch。spawn 窗口只 dispatch 自己的 queue。
    primary_queue: ?*wl.EventQueue = null,
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

        // 诊断: roundtrip 后再同步一次 (output bind 的 scale 事件可能稍后到达)
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
        if (self.primary_queue) |queue| queue.destroy();
        self.primary_queue = null;
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

    // ── 主窗口 attach: 绑定全局对象到主 queue + 输入 ────

    /// 主窗口调用: 创建主 queue, 把全局对象 (registry/output/seat/pointer)
    /// 绑定到主 queue, 并获取 seat/pointer。spawn 窗口不要调用。
    pub fn attachPrimary(self: *DisplayState, queue: *wl.EventQueue) !void {
        self.primary_queue = queue;
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
        if (self.seat) |seat| seat.setQueue(queue);
        if (self.pointer) |pointer| pointer.setQueue(queue);
        self.ensurePointer();
    }

    fn ensurePointer(self: *DisplayState) void {
        const seat = self.seat orelse return;
        if (self.pointer != null) return;
        self.pointer = seat.getPointer() catch {
            std.debug.print("wl_seat.get_pointer failed.\n", .{});
            return;
        };
        self.pointer.?.setListener(*DisplayState, pointerListener, self);
        if (self.primary_queue) |queue| self.pointer.?.setQueue(queue);
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
        while (!self.flush_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.flush_mutex.unlock();
        if (self.display) |display| _ = display.flush();
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
            } else if (bindGlobal(registry, global, xdg.WmBase)) |wm_base| {
                self.wm_base = wm_base;
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
        .capabilities => |capabilities| {
            if (capabilities.capabilities.pointer) {
                self.ensurePointer();
            }
        },
        .name => {},
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
