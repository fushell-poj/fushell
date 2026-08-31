//! 进程级 Wayland 连接、EGL display 与协议全局对象所有权。
//!
//! 全部 Flutter view 共享一个 wl_display、一个 EGLDisplay、一条 event queue，以及
//! compositor、xdg_wm_base、seat、data-control、text-input 等 registry global 的单个
//! 实例。只有平台线程分发 Wayland；raster/resource 线程通过受控 host callback 访问
//! EGL。引用计数让连接持续存活，直到 Runner 与每个 Host 都释放它。

const std = @import("std");

const wayland = @import("wayland");
const data_control = @import("data_control.zig");
const ime_v3 = @import("ime_v3.zig");
const mouse_cursor = @import("mouse_cursor.zig");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;
const zwp = wayland.client.zwp;
const c = @import("c");

/// Input and scale callbacks carry explicit owner context so DisplayState does
/// not depend on process-global runner pointers.
pub const KeyboardEvent = union(enum) {
    keymap: struct { format: wl.Keyboard.KeymapFormat, data: []const u8 },
    enter: struct { surface: ?*wl.Surface, keys: ?*wl.Array },
    leave: struct { surface: ?*wl.Surface },
    key: struct { serial: u32, time: u32, key: u32, state: wl.Keyboard.KeyState },
    modifiers: struct { depressed: u32, latched: u32, locked: u32, group: u32 },
    repeat: struct { delay_ms: i32, rate_per_sec: i32 },
};

pub const KeyboardEventCallback = *const fn (event: KeyboardEvent, surface: ?*wl.Surface, context: ?*anyopaque) void;
pub const PointerEventCallback = *const fn (event: wl.Pointer.Event, surface: ?*wl.Surface, context: ?*anyopaque) void;
pub const ScaleChangeCallback = *const fn (context: ?*anyopaque) void;

/// 一个活动 wl_output 的 registry 标识与最新整数 scale。
/// `name=0` 表示未使用槽；surface membership 存储 registry name 而非 proxy 地址，
/// 使 output 移除时可以确定性地让 membership 失效。
pub const OutputState = struct {
    name: u32 = 0,
    output: ?*wl.Output = null,
    scale: i32 = 1,
};

/// 一个 Fushell 进程的共享 native display 状态。
///
/// 除 callback context 外，本值拥有所有字段。创建窗口 role 前必须完成
/// `bindGlobals`；所有 Host 与共享 service 释放引用本连接的协议对象后，才能执行
/// `deinit`。
pub const DisplayState = struct {
    allocator: std.mem.Allocator = undefined,
    display: ?*wl.Display = null,
    registry: ?*wl.Registry = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    viewporter: ?*wp.Viewporter = null,
    fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    cursor_shape_unavailable_logged: bool = false,
    seat: ?*wl.Seat = null,
    /// wl_seat 宣告的 capability。只有对应 bit 存在时才创建 pointer/keyboard proxy；
    /// 无头 compositor 可能宣告一个两项 capability 都没有的 seat，此时无条件调用
    /// get_pointer/get_keyboard 会产生协议错误。
    seat_capabilities: wl.Seat.Capability = .{},

    keyboard_event_callback: ?KeyboardEventCallback = null,
    keyboard_event_context: ?*anyopaque = null,
    current_keyboard_surface: ?*wl.Surface = null,
    pointer_event_callback: ?PointerEventCallback = null,
    pointer_event_context: ?*anyopaque = null,
    current_pointer_surface: ?*wl.Surface = null,
    /// cursor-shape-v1 与 wl_pointer.set_cursor 都要求最新 pointer.enter serial；
    /// pointer leave 或 capability 移除后旧 serial 不得复用。
    pointer_enter_serial: ?u32 = null,
    scale_change_callback: ?ScaleChangeCallback = null,
    scale_change_context: ?*anyopaque = null,
    pointer: ?*wl.Pointer = null,
    /// 由 cursor_shape_manager 和 pointer 共同派生，必须先于 pointer 销毁。
    cursor_shape_device: ?*wp.CursorShapeDeviceV1 = null,
    keyboard: ?*wl.Keyboard = null,
    data_control: ?*data_control.DataControl = null,
    ime: ?*ime_v3.ImeV3 = null,
    data_control_manager_name: u32 = 0,
    data_control_manager_version: u32 = 0,
    ime_manager_name: u32 = 0,
    ime_manager_version: u32 = 0,
    outputs: std.ArrayListUnmanaged(OutputState) = .empty,

    egl_display: c.EGLDisplay = null,
    gles_library: ?std.DynLib = null,

    ref_count: usize = 0,
    /// 进程级单一 event queue — 全部对象 (全局 + 所有窗口 surface/xdg) 绑定它,
    /// 由主线程单一事件循环 dispatch (单线程模型, 无 per-window queue)。
    shared_queue: ?*wl.EventQueue = null,
    // ── 初始化 / 生命周期 ──────────────────────────────

    /// 首次获取时建立连接。返回是否首次 (新连接)。
    pub fn acquire(self: *DisplayState, allocator: std.mem.Allocator) !bool {
        if (self.ref_count == 0) {
            self.allocator = allocator;
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
        for (self.outputs.items) |output_state| {
            std.debug.print("output {d} scale={d}\n", .{ output_state.name, output_state.scale });
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
        self.destroyPointer();
        if (self.keyboard) |keyboard| keyboard.release();
        if (self.seat) |seat| seat.release();
        for (self.outputs.items) |output_state| {
            if (output_state.output) |output| output.release();
        }
        self.outputs.deinit(self.allocator);
        self.outputs = .empty;
        if (self.layer_shell) |layer_shell| layer_shell.destroy();
        if (self.cursor_shape_manager) |manager| manager.destroy();
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
        self.cursor_shape_manager = null;
        self.seat = null;
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
        if (self.cursor_shape_manager) |manager| manager.setQueue(queue);
        for (self.outputs.items) |output_state| {
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
        if (!self.seat_capabilities.pointer) {
            self.destroyPointer();
            return;
        }
        if (self.pointer == null) {
            const seat = self.seat orelse return;
            self.pointer = seat.getPointer() catch {
                std.debug.print("wl_seat.get_pointer failed.\n", .{});
                return;
            };
            self.pointer.?.setListener(*DisplayState, pointerListener, self);
            if (self.shared_queue) |queue| self.pointer.?.setQueue(queue);
        }
        self.ensureCursorShapeDevice();
    }

    fn ensureCursorShapeDevice(self: *DisplayState) void {
        if (self.cursor_shape_device != null) return;
        const manager = self.cursor_shape_manager orelse return;
        const pointer = self.pointer orelse return;
        self.cursor_shape_device = manager.getPointer(pointer) catch {
            std.debug.print("wp_cursor_shape_manager_v1.get_pointer failed.\n", .{});
            return;
        };
        if (self.shared_queue) |queue| self.cursor_shape_device.?.setQueue(queue);
    }

    fn destroyPointer(self: *DisplayState) void {
        if (self.cursor_shape_device) |device| device.destroy();
        self.cursor_shape_device = null;
        if (self.pointer) |pointer| pointer.release();
        self.pointer = null;
        self.current_pointer_surface = null;
        self.pointer_enter_serial = null;
    }

    /// 返回 false 表示 compositor 没有 cursor-shape-v1，调用方应以空 platform
    /// response 告知 Flutter OptionalMethodChannel。当前无 pointer focus 时请求已被接受，
    /// 但不会用过期 serial 发送 Wayland request。
    pub fn activateCursorShape(self: *DisplayState, shape: mouse_cursor.Shape) bool {
        if (self.cursor_shape_manager == null) {
            if (!self.cursor_shape_unavailable_logged) {
                std.debug.print("[info] Wayland compositor does not support cursor-shape-v1; keeping its default cursor.\n", .{});
                self.cursor_shape_unavailable_logged = true;
            }
            return false;
        }
        const serial = self.pointer_enter_serial orelse return true;
        if (shape == .hidden) {
            const pointer = self.pointer orelse return true;
            pointer.setCursor(serial, null, 0, 0);
        } else {
            const device = self.cursor_shape_device orelse return false;
            device.setShape(serial, waylandCursorShape(shape));
        }
        self.flush();
        return true;
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

    fn addOutput(self: *DisplayState, state: OutputState) !void {
        try self.outputs.append(self.allocator, state);
    }

    pub fn outputSlotByName(self: *DisplayState, name: u32) ?*OutputState {
        for (self.outputs.items) |*slot| {
            if (slot.name == name) return slot;
        }
        return null;
    }

    pub fn outputSlotByObject(self: *DisplayState, output: *wl.Output) ?*OutputState {
        for (self.outputs.items) |*slot| {
            if (slot.output == output) return slot;
        }
        return null;
    }

    fn removeOutput(self: *DisplayState, name: u32) bool {
        for (self.outputs.items, 0..) |slot, index| {
            if (slot.name != name) continue;
            if (slot.output) |output| output.release();
            _ = self.outputs.swapRemove(index);
            return true;
        }
        return false;
    }

    // ── flush ──────────────────────────────────────────

    /// All Wayland protocol operations run on the platform thread.
    pub fn flush(self: *DisplayState) void {
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
                self.addOutput(.{ .name = global.name, .output = output }) catch |err| {
                    std.debug.print("Unable to track Wayland output {d}: {}\n", .{ global.name, err });
                    output.release();
                    return;
                };
                output.setListener(*DisplayState, outputListener, self);
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
            } else if (bindGlobal(registry, global, wp.CursorShapeManagerV1)) |manager| {
                self.cursor_shape_manager = manager;
                if (self.shared_queue) |queue| manager.setQueue(queue);
                self.ensureCursorShapeDevice();
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
            _ = self.removeOutput(global_remove.name);
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
                if (self.scale_change_callback) |callback| callback(self.scale_change_context);
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
            self.flush();
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

/// enter 事件带 surface → 目标窗口由 runner 层路由。keymap 的 fd 在
/// 回调内完成 mmap/读取并立即释放。
pub fn setKeyboardEventCallback(self: *DisplayState, callback: KeyboardEventCallback, context: ?*anyopaque) void {
    self.keyboard_event_callback = callback;
    self.keyboard_event_context = context;
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *DisplayState) void {
    const surface = switch (event) {
        .enter => |enter| blk: {
            self.current_keyboard_surface = enter.surface;
            break :blk enter.surface;
        },
        .leave => |leave| blk: {
            self.current_keyboard_surface = null;
            break :blk leave.surface;
        },
        else => self.current_keyboard_surface,
    };
    if (self.keyboard_event_callback) |callback| {
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
                    callback(.{ .keymap = .{ .format = km.format, .data = map } }, surface, self.keyboard_event_context);
                    _ = std.posix.munmap(map);
                }
                _ = std.os.linux.close(fd);
            },
            .enter => |enter| callback(.{ .enter = .{ .surface = enter.surface, .keys = enter.keys } }, surface, self.keyboard_event_context),
            .leave => |leave| callback(.{ .leave = .{ .surface = leave.surface } }, surface, self.keyboard_event_context),
            .key => |key| callback(.{
                .key = .{ .serial = key.serial, .time = key.time, .key = key.key, .state = key.state },
            }, surface, self.keyboard_event_context),
            .modifiers => |mods| callback(.{
                .modifiers = .{ .depressed = mods.mods_depressed, .latched = mods.mods_latched, .locked = mods.mods_locked, .group = mods.group },
            }, surface, self.keyboard_event_context),
            .repeat_info => |ri| {
                callback(.{ .repeat = .{ .delay_ms = ri.delay, .rate_per_sec = ri.rate } }, surface, self.keyboard_event_context);
            },
        }
    }
}

fn waylandCursorShape(shape: mouse_cursor.Shape) wp.CursorShapeDeviceV1.Shape {
    return switch (shape) {
        .hidden, .default => .default,
        .context_menu => .context_menu,
        .help => .help,
        .pointer => .pointer,
        .progress => .progress,
        .wait => .wait,
        .cell => .cell,
        .crosshair => .crosshair,
        .text => .text,
        .vertical_text => .vertical_text,
        .alias => .alias,
        .copy => .copy,
        .move => .move,
        .no_drop => .no_drop,
        .not_allowed => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .all_scroll => .all_scroll,
        .col_resize => .col_resize,
        .row_resize => .row_resize,
        .n_resize => .n_resize,
        .e_resize => .e_resize,
        .s_resize => .s_resize,
        .w_resize => .w_resize,
        .ne_resize => .ne_resize,
        .nw_resize => .nw_resize,
        .se_resize => .se_resize,
        .sw_resize => .sw_resize,
        .ew_resize => .ew_resize,
        .ns_resize => .ns_resize,
        .nesw_resize => .nesw_resize,
        .nwse_resize => .nwse_resize,
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
    };
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, self: *DisplayState) void {
    const surface = switch (event) {
        .enter => |enter| blk: {
            self.current_pointer_surface = enter.surface;
            self.pointer_enter_serial = enter.serial;
            break :blk enter.surface;
        },
        .leave => |leave| blk: {
            self.current_pointer_surface = null;
            self.pointer_enter_serial = null;
            break :blk leave.surface;
        },
        else => self.current_pointer_surface,
    };
    if (self.pointer_event_callback) |callback| callback(event, surface, self.pointer_event_context);
}

pub fn setPointerEventCallback(self: *DisplayState, callback: PointerEventCallback, context: ?*anyopaque) void {
    self.pointer_event_callback = callback;
    self.pointer_event_context = context;
}

pub fn setScaleChangeCallback(self: *DisplayState, callback: ScaleChangeCallback, context: ?*anyopaque) void {
    self.scale_change_callback = callback;
    self.scale_change_context = context;
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
