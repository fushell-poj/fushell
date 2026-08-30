//! 每个 view 独立的 Wayland role、EGL surface、输入与 metrics Host。
//!
//! 每个 Host 借用进程级 DisplayState、共享 Wayland 事件队列与 RenderContext，
//! 但拥有自己的 wl_surface role 对象和 EGL 窗口 surface。Wayland 配置在平台线程
//! 执行；raster 呈现可在 Flutter raster 线程执行，并通过 `present_mutex` 与 resize
//! 串行化。绝不在协议 listener 调用栈内销毁 role 对象。

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;
const c = @import("c");
const surface_channel = @import("surface_channel.zig");
const display_state = @import("wl_display_state.zig");

const default_width = 800;
const default_height = 600;
const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;

/// 单个 view 上报给 Flutter 的物理 backing-store 尺寸与逻辑到物理缩放比。
/// width 和 height 始终使用像素尺寸。
pub const Metrics = struct {
    width: usize,
    height: usize,
    pixel_ratio: f64,
};

pub const PointerPhase = enum {
    add,
    hover,
    remove,
    down,
    up,
    move,
    scroll,
};

pub const PointerEvent = struct {
    phase: PointerPhase,
    x: f64,
    y: f64,
    buttons: i64,
    scroll_delta_x: f64 = 0,
    scroll_delta_y: f64 = 0,
    time_ms: ?u32 = null,
};

pub const MetricsCallback = *const fn (host: *Host, context: ?*anyopaque, metrics: Metrics) void;
pub const PointerCallback = *const fn (host: *Host, context: ?*anyopaque, event: PointerEvent) void;
/// 平台循环用来消费 Flutter task 与可选子系统描述符的适配器，不取得其状态所有权。
///
/// 回调顺序具有语义：producer 在同一 tick 内必须以相同顺序 report/fill/handle
/// 外部描述符。即使 readiness 来自其他线程，所有回调仍在平台线程执行。
pub const EventLoopSource = struct {
    fd: c_int,
    context: ?*anyopaque,
    tick: *const fn (context: ?*anyopaque) anyerror!void,
    timeout_ms: *const fn (context: ?*anyopaque) i32,
    consume_wake: *const fn (context: ?*anyopaque) void,
    /// Optional dynamically-owned descriptor. A negative descriptor disables it.
    /// The next loop tick consumes readiness, keeping subsystem state on the
    /// platform thread instead of introducing worker-thread completion races.
    auxiliary_fd: ?*const fn (context: ?*anyopaque) c_int = null,
    /// Optional event sources (for example D-Bus watches) owned by the same
    /// platform thread. The count/fill/handle callbacks MUST preserve descriptor order.
    external_fd_count: ?*const fn (context: ?*anyopaque) usize = null,
    fill_external_fds: ?*const fn (context: ?*anyopaque, destination: []std.posix.pollfd) usize = null,
    handle_external_fds: ?*const fn (context: ?*anyopaque, ready: []const std.posix.pollfd) anyerror!void = null,
    /// Process shutdown notification (SIGINT/SIGTERM). A negative descriptor
    /// disables it; readiness makes the event loop stop without dispatching
    /// further Wayland work.
    shutdown_fd: c_int = -1,
};

pub const State = enum {
    uninitialized,
    initializing,
    ready,
    failed,
    shutting_down,
};

const OutputMembership = struct {
    names: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *OutputMembership, allocator: std.mem.Allocator) void {
        self.names.deinit(allocator);
        self.* = .{};
    }

    fn enter(self: *OutputMembership, allocator: std.mem.Allocator, name: u32) !void {
        if (name == 0 or self.contains(name)) return;
        try self.names.append(allocator, name);
    }

    fn leave(self: *OutputMembership, name: u32) void {
        const index = std.mem.indexOfScalar(u32, self.names.items, name) orelse return;
        _ = self.names.swapRemove(index);
    }

    fn contains(self: *const OutputMembership, name: u32) bool {
        return std.mem.indexOfScalar(u32, self.names.items, name) != null;
    }
};

fn initialLayerDimension(requested: ?i32) i32 {
    return requested orelse 0;
}

fn integerScaleForMembership(membership: *const OutputMembership, outputs: []const display_state.OutputState) i32 {
    var scale: i32 = 1;
    for (outputs) |output_state| {
        if (output_state.name != 0 and membership.contains(output_state.name) and output_state.scale > scale) {
            scale = output_state.scale;
        }
    }
    return scale;
}

/// raster、resource 与 presentation 共用的进程级 EGL 对象命名空间。
///
/// Flutter raster 线程使用 `egl_context` 在 bootstrap pbuffer 上渲染 backing-store
/// 纹理，再把每个窗口 surface 绑定到同一 context 完成合成。resource 线程使用独立但
/// 共享对象的 context/pbuffer，既避免并发占用 raster context，又保留纹理可见性。
/// 反初始化本对象前必须先销毁每个 Host 的 EGL surface。
pub const RenderContext = struct {
    display_state: *display_state.DisplayState = undefined,
    egl_config: c.EGLConfig = null,
    egl_context: c.EGLContext = null,
    bootstrap_surface: c.EGLSurface = null,
    resource_context: c.EGLContext = null,
    resource_surface: c.EGLSurface = null,

    pub fn init(self: *RenderContext, state: *display_state.DisplayState) !void {
        self.display_state = state;
        std.debug.assert(state.egl_display != null);
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE) return eglError("eglBindAPI");

        const config_attribs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT | c.EGL_PBUFFER_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_NONE,
        };
        var config_count: c.EGLint = 0;
        if (c.eglChooseConfig(state.egl_display, &config_attribs, &self.egl_config, 1, &config_count) != c.EGL_TRUE or config_count == 0) {
            return eglError("eglChooseConfig");
        }

        const context_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_CLIENT_VERSION, 2,
            c.EGL_NONE,
        };
        self.egl_context = c.eglCreateContext(state.egl_display, self.egl_config, c.EGL_NO_CONTEXT, &context_attribs);
        if (self.egl_context == c.EGL_NO_CONTEXT) return eglError("eglCreateContext");

        const pbuffer_attribs = [_]c.EGLint{
            c.EGL_WIDTH,  1,
            c.EGL_HEIGHT, 1,
            c.EGL_NONE,
        };
        self.bootstrap_surface = c.eglCreatePbufferSurface(state.egl_display, self.egl_config, &pbuffer_attribs);
        if (self.bootstrap_surface == c.EGL_NO_SURFACE) return eglError("eglCreatePbufferSurface(bootstrap)");

        // Flutter performs asynchronous texture uploads on its resource thread.
        // Give that thread a dedicated pbuffer/context sharing the raster context's
        // object namespace, so it never contends for the raster EGL context.
        self.resource_context = c.eglCreateContext(state.egl_display, self.egl_config, self.egl_context, &context_attribs);
        if (self.resource_context == c.EGL_NO_CONTEXT) return eglError("eglCreateContext(resource)");
        self.resource_surface = c.eglCreatePbufferSurface(state.egl_display, self.egl_config, &pbuffer_attribs);
        if (self.resource_surface == c.EGL_NO_SURFACE) return eglError("eglCreatePbufferSurface(resource)");

        state.openGlesLibrary();
        try self.makeCurrent();
        try self.clearCurrent();
    }

    pub fn deinit(self: *RenderContext) void {
        if (self.display_state.egl_display != null and self.display_state.egl_display != c.EGL_NO_DISPLAY) {
            if (self.resource_surface != null and self.resource_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.display_state.egl_display, self.resource_surface);
            if (self.resource_context != null and self.resource_context != c.EGL_NO_CONTEXT) _ = c.eglDestroyContext(self.display_state.egl_display, self.resource_context);
            if (self.bootstrap_surface != null and self.bootstrap_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.display_state.egl_display, self.bootstrap_surface);
            if (self.egl_context != null and self.egl_context != c.EGL_NO_CONTEXT) _ = c.eglDestroyContext(self.display_state.egl_display, self.egl_context);
        }
        self.* = .{};
    }

    /// raster 渲染目标: bootstrap pbuffer。
    pub fn makeCurrent(self: *RenderContext) !void {
        if (c.eglMakeCurrent(self.display_state.egl_display, self.bootstrap_surface, self.bootstrap_surface, self.egl_context) != c.EGL_TRUE) {
            return eglError("eglMakeCurrent");
        }
    }

    pub fn makeResourceCurrent(self: *RenderContext) !void {
        if (c.eglMakeCurrent(self.display_state.egl_display, self.resource_surface, self.resource_surface, self.resource_context) != c.EGL_TRUE) {
            return eglError("eglMakeCurrent(resource)");
        }
    }

    pub fn clearCurrent(self: *RenderContext) !void {
        if (c.eglMakeCurrent(self.display_state.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT) != c.EGL_TRUE) {
            return eglError("eglMakeCurrent(clear)");
        }
    }

    /// 呈现目标: 某窗口的 EGL surface (同 context, 换 surface)。
    pub fn makeSurfaceCurrent(self: *RenderContext, surface: c.EGLSurface) !void {
        if (surface == null or surface == c.EGL_NO_SURFACE) return error.EglFailed;
        if (c.eglMakeCurrent(self.display_state.egl_display, surface, surface, self.egl_context) != c.EGL_TRUE) {
            return eglError("eglMakeCurrent(window)");
        }
    }

    pub fn swapBuffers(self: *RenderContext, surface: c.EGLSurface) !void {
        if (c.eglSwapBuffers(self.display_state.egl_display, surface) != c.EGL_TRUE) return eglError("eglSwapBuffers");
    }
};

/// 恰好对应一个 Flutter view 的 native 呈现与输入端点。
///
/// Host 只会拥有 xdg_toplevel 或 layer-shell role 之一，绝不会同时拥有两者。它借用
/// 进程级 connection/context，并拥有全部 surface 级 Wayland/EGL 对象。只有 Flutter
/// 确认 RemoveView 后才能执行 `deinit`，否则 raster 回调可能访问已销毁的 EGL surface。
pub const Host = struct {
    /// 共享进程连接（wl_display、EGL display 与 globals）；仅借用。
    display_state: *display_state.DisplayState = undefined,
    /// 进程级单一 event queue (引用, 不拥有): 窗口对象 (surface/xdg/toplevel)
    /// 与全局对象都绑它, 由主线程单一事件循环 dispatch。
    event_queue: ?*wl.EventQueue = null,
    state: State = .uninitialized,
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    toplevel: ?*xdg.Toplevel = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    viewport: ?*wp.Viewport = null,
    fractional_scale: ?*wp.FractionalScaleV1 = null,
    egl_window: ?*c.struct_wl_egl_window = null,
    egl_window_width: i32 = 0,
    egl_window_height: i32 = 0,

    /// 共享 render context/config；本 Host 只拥有 `egl_surface`。
    render_context: *RenderContext = undefined,
    egl_surface: c.EGLSurface = null,
    /// Flutter view ID；零保留给无头 implicit view。
    view_id: i64 = 0,
    /// 把平台线程 resize 与 raster 线程 presentation 串行化。这里刻意使用阻塞
    /// mutex；跳过任一操作都会破坏 EGL 状态。
    io: std.Io = undefined,
    present_mutex: std.Io.Mutex = .init,
    configured: bool = false,
    /// 由 xdg close listener 设置，并在下一个平台 tick 消费。不能在协议回调内开始
    /// 移除，因为只有 Flutter 异步回调完成后才会销毁 listener 自己的 Wayland 对象。
    close_requested: bool = false,
    width: i32 = default_width,
    height: i32 = default_height,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    scale: i32 = 1,
    fractional_scale_120: u32 = 0,
    entered_outputs: OutputMembership = .{},

    pointer_focused: bool = false,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_buttons: i64 = 0,

    metrics_callback: ?MetricsCallback = null,
    metrics_context: ?*anyopaque = null,
    pointer_callback: ?PointerCallback = null,
    pointer_context: ?*anyopaque = null,

    /// 获取共享 display 生命周期，并采用当前 output scale。
    ///
    /// 进程启动建立连接时，`attach` 可能早于 global binding。role 初始化稍后刷新共享
    /// queue；只有 EGL/global 初始化成功后，调用方才能注入 RenderContext。
    pub fn attach(self: *Host, state: *display_state.DisplayState, io: std.Io, allocator: std.mem.Allocator) !void {
        self.display_state = state;
        self.io = io;
        _ = try state.acquire(allocator);
        self.event_queue = state.shared_queue;
        self.adoptProvisionalScaleFromOutputs();
    }

    pub fn initializeWindowRole(self: *Host, window: surface_channel.WindowRole, parent_toplevel: ?*xdg.Toplevel) !void {
        try self.beginRoleInitialization();
        errdefer self.state = .failed;

        if (window.width) |width| self.width = width;
        if (window.height) |height| self.height = height;

        try self.createBaseSurface();
        self.xdg_surface = self.display_state.wm_base.?.getXdgSurface(self.surface.?) catch return error.XdgSurfaceCreateFailed;
        self.xdg_surface.?.setQueue(self.event_queue.?);
        self.xdg_surface.?.setListener(*Host, xdgSurfaceListener, self);

        self.toplevel = self.xdg_surface.?.getToplevel() catch return error.XdgToplevelCreateFailed;
        self.toplevel.?.setQueue(self.event_queue.?);
        self.toplevel.?.setListener(*Host, xdgToplevelListener, self);

        // 父子绑定: 首次 commit 前 set_parent (xdg transient 语义, 子堆叠父之上;
        // 父销毁时 compositor 自动解除绑定)。
        if (parent_toplevel) |parent| self.toplevel.?.setParent(parent);

        const title_z = try std.heap.c_allocator.dupeZ(u8, window.title);
        defer std.heap.c_allocator.free(title_z);
        const app_id_z = try std.heap.c_allocator.dupeZ(u8, window.app_id);
        defer std.heap.c_allocator.free(app_id_z);
        self.toplevel.?.setTitle(title_z);
        self.toplevel.?.setAppId(app_id_z);

        self.applyBufferScale();
        self.surface.?.commit();
        self.display_state.flush();
        try self.waitForInitialConfigure();
        try self.attachEglWindowSurface();
        self.state = .ready;
    }

    pub fn initializeLayerRole(self: *Host, layer: surface_channel.LayerRole) !void {
        try self.beginRoleInitialization();
        errdefer self.state = .failed;
        if (self.display_state.layer_shell == null) return error.LayerShellUnavailable;

        // layer-shell 以 0 表示由相对两侧 anchor 决定尺寸；不能沿用
        // xdg window Host 的默认宽高，否则 left+right/top+bottom 不会拉伸。
        self.width = initialLayerDimension(layer.width);
        self.height = initialLayerDimension(layer.height);

        try self.createBaseSurface();
        const namespace_z = try std.heap.c_allocator.dupeZ(u8, layer.namespace);
        defer std.heap.c_allocator.free(namespace_z);
        self.layer_surface = self.display_state.layer_shell.?.getLayerSurface(self.surface.?, null, mapLayer(layer.layer), namespace_z) catch return error.LayerSurfaceCreateFailed;
        self.layer_surface.?.setQueue(self.event_queue.?);
        self.layer_surface.?.setListener(*Host, layerSurfaceListener, self);
        self.layer_surface.?.setSize(@intCast(@max(self.width, 0)), @intCast(@max(self.height, 0)));
        self.layer_surface.?.setAnchor(mapAnchor(layer.anchors));
        self.layer_surface.?.setMargin(layer.margins.top, layer.margins.right, layer.margins.bottom, layer.margins.left);
        self.layer_surface.?.setExclusiveZone(layer.exclusive_zone);
        self.layer_surface.?.setKeyboardInteractivity(mapKeyboardInteractivity(layer.keyboard_interactivity));

        self.applyBufferScale();
        self.surface.?.commit();
        self.display_state.flush();
        try self.waitForInitialConfigure();
        try self.attachEglWindowSurface();
        self.state = .ready;
    }

    pub fn updateLayerRole(self: *Host, update: surface_channel.LayerSurfaceUpdate) !bool {
        try self.requireReadyLayerRole();
        if (update.isEmpty()) return false;
        // 布局变更时与 present 互斥 (同 resizeWindow)。
        if (update.affectsLayout()) {
            self.present_mutex.lock(self.io) catch unreachable;
            defer self.present_mutex.unlock(self.io);
        }

        const layer_surface = self.layer_surface.?;
        var layout_changed = false;

        if (update.width != null or update.height != null) {
            const next_width = update.width orelse self.width;
            const next_height = update.height orelse self.height;
            layer_surface.setSize(@intCast(@max(next_width, 0)), @intCast(@max(next_height, 0)));
            if (update.width) |width| self.width = width;
            if (update.height) |height| self.height = height;
            layout_changed = true;
        }
        if (update.anchors) |anchors| {
            layer_surface.setAnchor(mapAnchor(anchors));
            layout_changed = true;
        }
        if (update.margins) |margins| {
            layer_surface.setMargin(margins.top, margins.right, margins.bottom, margins.left);
            layout_changed = true;
        }
        if (update.exclusive_zone) |exclusive_zone| {
            layer_surface.setExclusiveZone(exclusive_zone);
            layout_changed = true;
        }
        if (update.keyboard_interactivity) |keyboard_interactivity| {
            layer_surface.setKeyboardInteractivity(mapKeyboardInteractivity(keyboard_interactivity));
        }

        self.applyBufferScale();
        if (layout_changed) self.configured = false;
        self.surface.?.commit();
        self.display_state.flush();
        if (layout_changed) {
            const got_configure = try self.waitForUpdateConfigure();
            if (!got_configure) self.emitMetrics();
            return true;
        }
        return false;
    }

    pub fn updateWindowRole(self: *Host, update: surface_channel.WindowSurfaceUpdate) !bool {
        try self.requireReadyWindowRole();
        if (update.isEmpty()) return false;

        const toplevel = self.toplevel.?;
        if (update.title) |title| {
            const title_z = try std.heap.c_allocator.dupeZ(u8, title);
            defer std.heap.c_allocator.free(title_z);
            toplevel.setTitle(title_z);
        }
        if (update.app_id) |app_id| {
            const app_id_z = try std.heap.c_allocator.dupeZ(u8, app_id);
            defer std.heap.c_allocator.free(app_id_z);
            toplevel.setAppId(app_id_z);
        }
        self.display_state.flush();
        return false;
    }

    pub fn waitForInitialConfigure(self: *Host) !void {
        while (!self.configured) {
            if (self.dispatchQueue() != .SUCCESS) return error.WaylandDispatchFailed;
            self.display_state.flush();
            var fds = [_]c.struct_pollfd{.{
                .fd = self.display_state.display.?.getFd(),
                .events = c.POLLIN,
                .revents = 0,
            }};
            const poll_result = c.poll(&fds, fds.len, 8);
            if (poll_result < 0) return error.WaylandDispatchFailed;
            if (poll_result > 0 and (fds[0].revents & c.POLLIN) != 0) {
                if (self.display_state.display.?.prepareReadQueue(self.event_queue.?)) {
                    if (self.display_state.display.?.readEvents() != .SUCCESS) return error.WaylandDispatchFailed;
                }
            }
        }
    }

    pub fn attachEglWindowSurface(self: *Host) !void {
        self.egl_window_width = self.physicalWidthI32();
        self.egl_window_height = self.physicalHeightI32();
        self.egl_window = c.wl_egl_window_create(@ptrCast(self.surface.?), self.egl_window_width, self.egl_window_height);
        if (self.egl_window == null) return error.WlEglWindowCreateFailed;

        self.egl_surface = c.eglCreateWindowSurface(self.display_state.egl_display, self.render_context.egl_config, @ptrCast(self.egl_window.?), null);
        if (self.egl_surface == c.EGL_NO_SURFACE) {
            std.debug.print("eglCreateWindowSurface failed: display {*} window {d}x{d} error {x}\n", .{ self.display_state.egl_display, self.egl_window_width, self.egl_window_height, c.eglGetError() });
            return eglError("eglCreateWindowSurface");
        }
    }

    pub fn setMetricsCallback(self: *Host, callback: MetricsCallback, context: ?*anyopaque) void {
        self.metrics_callback = callback;
        self.metrics_context = context;
    }

    pub fn setPointerCallback(self: *Host, callback: PointerCallback, context: ?*anyopaque) void {
        self.pointer_callback = callback;
        self.pointer_context = context;
    }

    /// 消费一次 compositor close 请求。事件派发和消费都发生在平台线程。
    pub fn takeCloseRequest(self: *Host) bool {
        if (!self.close_requested) return false;
        self.close_requested = false;
        return true;
    }

    pub fn metrics(self: *const Host) Metrics {
        return .{
            .width = @intCast(self.physicalWidthI32()),
            .height = @intCast(self.physicalHeightI32()),
            .pixel_ratio = self.activeScale(),
        };
    }

    pub fn resizeWindow(self: *Host) void {
        // resize (主线程) 与 present (引擎线程) 互斥: present 侧 tryLock 跳帧。
        self.present_mutex.lock(self.io) catch unreachable;
        defer self.present_mutex.unlock(self.io);
        self.applyBufferScale();
        const physical_width = self.physicalWidthI32();
        const physical_height = self.physicalHeightI32();
        if (self.egl_window_width == physical_width and self.egl_window_height == physical_height) return;
        self.egl_window_width = physical_width;
        self.egl_window_height = physical_height;
        if (self.egl_window) |window| c.wl_egl_window_resize(window, physical_width, physical_height, 0, 0);
    }

    pub fn isReady(self: *const Host) bool {
        return self.state == .ready;
    }

    pub fn runEventLoop(self: *Host, allocator: std.mem.Allocator, quit: *const std.atomic.Value(bool), message: []const u8, source: EventLoopSource) !void {
        std.debug.print("{s}\n", .{message});
        var fds: std.ArrayList(std.posix.pollfd) = .empty;
        defer fds.deinit(allocator);

        while (!quit.load(.acquire)) {
            try source.tick(source.context);
            if (quit.load(.acquire)) break;
            if (self.dispatchQueue() != .SUCCESS) return error.WaylandDispatchFailed;
            if (quit.load(.acquire)) break;
            self.display_state.flush();

            const base_fd_count = 4;
            const requested_external_count = if (source.external_fd_count) |count|
                count(source.context)
            else
                0;
            try fds.resize(allocator, base_fd_count + requested_external_count);
            @memset(fds.items, .{ .fd = -1, .events = 0, .revents = 0 });
            fds.items[0] = .{
                .fd = self.display_state.display.?.getFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            fds.items[1] = .{
                .fd = source.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            fds.items[2] = .{
                .fd = if (source.auxiliary_fd) |get_fd| get_fd(source.context) else -1,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            fds.items[3] = .{
                .fd = source.shutdown_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            const external_count = if (source.fill_external_fds) |fill|
                fill(source.context, fds.items[base_fd_count..])
            else
                0;
            if (external_count != requested_external_count) return error.ExternalFdCountChanged;
            _ = std.posix.poll(fds.items, source.timeout_ms(source.context)) catch return error.EventLoopPollFailed;
            if ((fds.items[3].revents & std.posix.POLL.IN) != 0) break;
            if ((fds.items[3].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) return error.ShutdownPollFailed;
            if ((fds.items[1].revents & std.posix.POLL.IN) != 0) source.consume_wake(source.context);
            if ((fds.items[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) return error.TaskWakePollFailed;
            if ((fds.items[2].revents & std.posix.POLL.NVAL) != 0) return error.AuxiliaryPollFailed;
            if ((fds.items[0].revents & std.posix.POLL.IN) != 0) {
                // 单线程模型: 主线程唯一预约读 (无需多线程原子读竞争处理)。
                if (self.display_state.display.?.prepareReadQueue(self.sharedQueue())) {
                    if (self.display_state.display.?.readEvents() != .SUCCESS) return error.WaylandDispatchFailed;
                }
            }
            if ((fds.items[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) return error.WaylandDisplayPollFailed;
            if (external_count > 0) {
                if (source.handle_external_fds) |handle| {
                    try handle(source.context, fds.items[base_fd_count..]);
                }
            }
        }
    }

    fn sharedQueue(self: *Host) *wl.EventQueue {
        return self.display_state.shared_queue orelse self.event_queue.?;
    }

    /// 分发进程级共享 queue 的已缓冲事件 (全部对象都绑它)。
    fn dispatchQueue(self: *Host) std.posix.E {
        return self.display_state.display.?.dispatchQueuePending(self.sharedQueue());
    }

    pub fn deinit(self: *Host) void {
        self.state = .shutting_down;
        self.entered_outputs.deinit(self.display_state.allocator);
        if (self.display_state.egl_display != null and self.display_state.egl_display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(self.display_state.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
            if (self.egl_surface != null and self.egl_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.display_state.egl_display, self.egl_surface);
        }
        if (self.egl_window) |window| c.wl_egl_window_destroy(window);
        if (self.fractional_scale) |fractional_scale| fractional_scale.destroy();
        if (self.viewport) |viewport| viewport.destroy();
        if (self.toplevel) |toplevel| toplevel.destroy();
        if (self.layer_surface) |layer_surface| layer_surface.destroy();
        if (self.xdg_surface) |xdg_surface| xdg_surface.destroy();
        if (self.surface) |surface| surface.destroy();
        // 关键: 显式 flush, 否则 destroy 请求只进本地队列, compositor 收不到
        // → 窗口变成幽灵窗口 (线程已死但窗口还在, hyprland ping 无应答 → 未响应)。
        self.display_state.flush();
        // event_queue 是进程级共享 queue (由 DisplayState.deinit 统一销毁),
        // 这里只清引用。
        self.event_queue = null;
        // 释放共享连接引用 (归零时 DisplayState 完整清理: eglTerminate + disconnect)
        if (self.display_state.isAcquired()) self.display_state.release();
        // 注意: 不调用 display.disconnect() — libwayland 的 wl_display_disconnect 会
        // free 对象; 进程内反复 connect/disconnect 会导致指针地址复用, 而 Mesa EGL
        // display 表按 wl_display 指针作 key (eglGetDisplay), 命中已 terminate 的
        // 僵尸条目 → eglCreateWindowSurface 报 EGL_BAD_ALLOC。保留对象(泄漏 fd +
        // 少量内存)使指针不复用。架构级修复: 进程共享单一 wl_display (后续 change)。
        // if (self.display) |display| display.disconnect();
    }

    fn beginRoleInitialization(self: *Host) !void {
        if (self.state != .uninitialized) return error.SurfaceAlreadyInitialized;
        // 刷新共享 queue 引用 (attach 时 bindGlobals 尚未创建它)。
        self.event_queue = self.display_state.shared_queue orelse return error.WaylandQueueCreateFailed;
        self.state = .initializing;
        self.configured = false;
        self.pending_width = 0;
        self.pending_height = 0;
    }

    fn requireReadyLayerRole(self: *Host) !void {
        if (self.state != .ready) return error.SurfaceNotInitialized;
        if (self.layer_surface == null) return error.SurfaceRoleMismatch;
    }

    fn requireReadyWindowRole(self: *Host) !void {
        if (self.state != .ready) return error.SurfaceNotInitialized;
        if (self.toplevel == null) return error.SurfaceRoleMismatch;
    }

    fn waitForUpdateConfigure(self: *Host) !bool {
        var attempts: usize = 0;
        while (!self.configured and attempts < 64) : (attempts += 1) {
            if (self.dispatchQueue() != .SUCCESS) return error.WaylandDispatchFailed;
            if (self.configured) return true;
            self.display_state.flush();
            var fds = [_]c.struct_pollfd{.{
                .fd = self.display_state.display.?.getFd(),
                .events = c.POLLIN,
                .revents = 0,
            }};
            const poll_result = c.poll(&fds, fds.len, 8);
            if (poll_result < 0) return error.WaylandDispatchFailed;
            if (poll_result > 0 and (fds[0].revents & c.POLLIN) != 0) {
                if (self.display_state.display.?.prepareReadQueue(self.event_queue.?)) {
                    if (self.display_state.display.?.readEvents() != .SUCCESS) return error.WaylandDispatchFailed;
                }
            }
        }
        const got_configure = self.configured;
        if (!got_configure) self.configured = true;
        return got_configure;
    }

    fn createBaseSurface(self: *Host) !void {
        self.surface = self.display_state.compositor.?.createSurface() catch return error.WaylandSurfaceCreateFailed;
        self.surface.?.setQueue(self.event_queue.?);
        self.surface.?.setListener(*Host, surfaceListener, self);
        self.createFractionalScaleObjects();
    }

    fn activeScale120(self: *const Host) u32 {
        if (self.fractional_scale_120 > 0) return self.fractional_scale_120;
        return @intCast(self.scale * 120);
    }

    pub fn activeScale(self: *const Host) f64 {
        return @as(f64, @floatFromInt(self.activeScale120())) / 120.0;
    }

    fn physicalWidthI32(self: *const Host) i32 {
        return physicalFromLogical(self.width, self.activeScale120());
    }

    fn physicalHeightI32(self: *const Host) i32 {
        return physicalFromLogical(self.height, self.activeScale120());
    }

    fn applyBufferScale(self: *Host) void {
        if (self.surface) |surface| {
            // A layer surface may intentionally start with width/height 0 so
            // opposite anchors choose that dimension.  wp_viewport rejects
            // non-positive destinations; wait for the compositor's configure
            // before installing a fractional-scale destination.
            if (self.fractional_scale_120 > 0 and self.viewport != null and self.width > 0 and self.height > 0) {
                surface.setBufferScale(1);
                self.viewport.?.setDestination(self.width, self.height);
            } else {
                surface.setBufferScale(self.scale);
                if (self.viewport) |viewport| viewport.setDestination(-1, -1);
            }
        }
    }

    fn emitMetrics(self: *Host) void {
        // 窗口可能正被自己的线程 shutdown (引擎销毁中): 共享连接的主线程
        // 仍可能 dispatch 到本窗口的 scale/configure 事件 (fractional_scale_manager
        // 是全局对象, 绑主 queue)。此时引擎句柄已失效, 再发 metrics 会 UAF。
        if (self.state == .shutting_down or self.state == .failed) return;
        self.resizeWindow();
        if (self.metrics_callback) |callback| callback(self, self.metrics_context, self.metrics());
    }

    fn applyPendingConfigure(self: *Host) void {
        var changed = false;
        if (self.pending_width > 0 and self.pending_width != self.width) {
            self.width = self.pending_width;
            changed = true;
        }
        if (self.pending_height > 0 and self.pending_height != self.height) {
            self.height = self.pending_height;
            changed = true;
        }
        self.pending_width = 0;
        self.pending_height = 0;
        if (changed) self.emitMetrics();
    }

    fn emitPointer(self: *Host, event: PointerEvent) void {
        // 同 emitMetrics: 主线程 dispatch 可能触达关闭中的窗口。
        if (self.state == .shutting_down or self.state == .failed) return;
        if (self.pointer_callback) |callback| callback(self, self.pointer_context, event);
    }

    fn outputName(self: *const Host, output: ?*wl.Output) ?u32 {
        if (output == null) return null;
        for (self.display_state.outputs.items) |output_state| {
            if (output_state.output == output) return output_state.name;
        }
        return null;
    }

    fn adoptProvisionalScaleFromOutputs(self: *Host) void {
        var next_scale: i32 = 1;
        var output_count: usize = 0;
        for (self.display_state.outputs.items) |output_state| {
            if (output_state.output != null) {
                output_count += 1;
                if (output_state.scale > next_scale) next_scale = output_state.scale;
            }
        }
        if (output_count == 0 or next_scale == self.scale) return;
        self.scale = next_scale;
        std.debug.print("Using Wayland scale {d} from {d} advertised output(s) before surface enter.\n", .{ next_scale, output_count });
    }

    pub fn recomputeScale(self: *Host) void {
        if (self.fractional_scale_120 > 0) return;
        const next_scale = integerScaleForMembership(&self.entered_outputs, self.display_state.outputs.items);
        if (next_scale == self.scale) return;
        const old_scale = self.scale;
        self.scale = next_scale;
        self.emitMetrics();
        std.debug.print("Wayland active integer scale changed: {d} -> {d}\n", .{ old_scale, next_scale });
    }

    fn createFractionalScaleObjects(self: *Host) void {
        const surface = self.surface orelse return;
        if (self.display_state.viewporter) |viewporter| {
            self.viewport = viewporter.getViewport(surface) catch |err| fallback: {
                std.debug.print("wp_viewporter.get_viewport failed: {s}\n", .{@errorName(err)});
                break :fallback null;
            };
        }
        if (self.display_state.fractional_scale_manager) |manager| {
            self.fractional_scale = manager.getFractionalScale(surface) catch |err| fallback: {
                std.debug.print("wp_fractional_scale_manager_v1.get_fractional_scale failed: {s}\n", .{@errorName(err)});
                break :fallback null;
            };
            if (self.fractional_scale) |fractional_scale| {
                fractional_scale.setListener(*Host, fractionalScaleListener, self);
                std.debug.print("Wayland fractional scale protocol enabled.\n", .{});
            }
        }
    }

    fn physicalPointerX(self: *Host) f64 {
        return self.pointer_x * self.activeScale();
    }

    fn physicalPointerY(self: *Host) f64 {
        return self.pointer_y * self.activeScale();
    }

    /// 指针事件处理 (由 DisplayState 路由回调调用; 检查事件 surface 是否属于本窗口)。
    pub fn handlePointerEvent(self: *Host, event: wl.Pointer.Event) void {
        switch (event) {
            .enter => |enter| {
                if (enter.surface != self.surface) return;
                self.pointer_focused = true;
                self.pointer_x = enter.surface_x.toDouble();
                self.pointer_y = enter.surface_y.toDouble();
                self.emitPointer(.{
                    .phase = .add,
                    .x = self.physicalPointerX(),
                    .y = self.physicalPointerY(),
                    .buttons = self.pointer_buttons,
                });
                self.emitPointer(.{
                    .phase = .hover,
                    .x = self.physicalPointerX(),
                    .y = self.physicalPointerY(),
                    .buttons = self.pointer_buttons,
                });
            },
            .leave => |leave| {
                if (leave.surface != self.surface) return;
                self.emitPointer(.{
                    .phase = .remove,
                    .x = self.physicalPointerX(),
                    .y = self.physicalPointerY(),
                    .buttons = self.pointer_buttons,
                });
                self.pointer_focused = false;
                self.pointer_buttons = 0;
            },
            .motion => |motion| {
                if (!self.pointer_focused) return;
                self.pointer_x = motion.surface_x.toDouble();
                self.pointer_y = motion.surface_y.toDouble();
                self.emitPointer(.{
                    .phase = if (self.pointer_buttons == 0) .hover else .move,
                    .x = self.physicalPointerX(),
                    .y = self.physicalPointerY(),
                    .buttons = self.pointer_buttons,
                    .time_ms = motion.time,
                });
            },
            .button => |button| {
                if (!self.pointer_focused) return;
                const bit = mouseButtonBit(button.button) orelse {
                    std.debug.print("Ignoring unsupported Wayland pointer button code: 0x{x}\n", .{button.button});
                    return;
                };
                const pressed = button.state == .pressed;
                if (pressed) {
                    self.pointer_buttons |= bit;
                } else {
                    self.pointer_buttons &= ~bit;
                }
                self.emitPointer(.{
                    .phase = if (pressed) .down else .up,
                    .x = self.physicalPointerX(),
                    .y = self.physicalPointerY(),
                    .buttons = self.pointer_buttons,
                    .time_ms = button.time,
                });
            },
            .axis => |axis| {
                if (!self.pointer_focused) return;
                const delta = axis.value.toDouble() * self.activeScale();
                var event_out: PointerEvent = .{
                    .phase = .scroll,
                    .x = self.physicalPointerX(),
                    .y = self.physicalPointerY(),
                    .buttons = self.pointer_buttons,
                    .time_ms = axis.time,
                };
                switch (axis.axis) {
                    .horizontal_scroll => event_out.scroll_delta_x = delta,
                    .vertical_scroll => event_out.scroll_delta_y = delta,
                    else => return,
                }
                self.emitPointer(event_out);
            },
            .frame => {},
            .axis_source => {},
            .axis_stop => {},
            .axis_discrete => {},
            .axis_value120 => {},
        }
    }
};

fn mapLayer(layer: surface_channel.Layer) zwlr.LayerShellV1.Layer {
    return switch (layer) {
        .background => .background,
        .bottom => .bottom,
        .top => .top,
        .overlay => .overlay,
    };
}

fn mapAnchor(anchors: surface_channel.AnchorMask) zwlr.LayerSurfaceV1.Anchor {
    return .{
        .top = anchors.top,
        .bottom = anchors.bottom,
        .left = anchors.left,
        .right = anchors.right,
    };
}

fn mapKeyboardInteractivity(value: surface_channel.KeyboardInteractivity) zwlr.LayerSurfaceV1.KeyboardInteractivity {
    return switch (value) {
        .none => .none,
        .exclusive => .exclusive,
        .on_demand => .on_demand,
    };
}

fn physicalFromLogical(logical_size: i32, scale_120: u32) i32 {
    const logical: i64 = @intCast(@max(logical_size, 1));
    const scale: i64 = @intCast(@max(scale_120, 120));
    return @intCast(@divTrunc(logical * scale + 119, 120));
}

fn fractionalScaleListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *Host) void {
    switch (event) {
        .preferred_scale => |preferred| {
            const next_scale_120 = @max(preferred.scale, 120);
            if (self.fractional_scale_120 == next_scale_120) return;
            const old_scale_120 = self.activeScale120();
            self.fractional_scale_120 = next_scale_120;
            self.emitMetrics();
            std.debug.print("Wayland fractional scale changed: {d}/120 -> {d}/120\n", .{ old_scale_120, next_scale_120 });
        },
    }
}

fn mouseButtonBit(button: u32) ?i64 {
    return switch (button) {
        btn_left => 1,
        btn_right => 2,
        btn_middle => 4,
        else => null,
    };
}

fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *Host) void {
    switch (event) {
        .configure => |configure| {
            layer_surface.ackConfigure(configure.serial);
            if (configure.width > 0) self.pending_width = @intCast(configure.width);
            if (configure.height > 0) self.pending_height = @intCast(configure.height);
            self.applyPendingConfigure();
            self.configured = true;
        },
        .closed => {
            self.close_requested = true;
            std.debug.print("layer_surface close requested for view {d}.\n", .{self.view_id});
        },
    }
}

fn surfaceListener(_: *wl.Surface, event: wl.Surface.Event, self: *Host) void {
    switch (event) {
        .enter => |enter| {
            if (self.outputName(enter.output)) |name| {
                self.entered_outputs.enter(self.display_state.allocator, name) catch |err| {
                    std.debug.print("Unable to record output membership for global {d}: {}\n", .{ name, err });
                    return;
                };
                self.recomputeScale();
            }
        },
        .leave => |leave| {
            if (self.outputName(leave.output)) |name| {
                self.entered_outputs.leave(name);
                self.recomputeScale();
            }
        },
    }
}

fn xdgSurfaceListener(surface: *xdg.Surface, event: xdg.Surface.Event, self: *Host) void {
    switch (event) {
        .configure => |configure| {
            surface.ackConfigure(configure.serial);
            self.applyPendingConfigure();
            self.configured = true;
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Host) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0) self.pending_width = configure.width;
            if (configure.height > 0) self.pending_height = configure.height;
        },
        .configure_bounds => {},
        .wm_capabilities => {},
        .close => {
            self.close_requested = true;
            std.debug.print("xdg_toplevel close requested for view {d}.\n", .{self.view_id});
        },
    }
}

fn openGlesLibrary() ?std.DynLib {
    return std.DynLib.open("libGLESv2.so.2") catch std.DynLib.open("libGLESv2.so") catch |err| {
        std.debug.print("Unable to open libGLESv2 for GL symbol fallback: {s}\n", .{@errorName(err)});
        return null;
    };
}

fn eglError(comptime step: []const u8) error{EglFailed} {
    std.debug.print("{s} failed: EGL error 0x{x}\n", .{ step, c.eglGetError() });
    return error.EglFailed;
}

test "unspecified layer dimensions remain compositor-controlled" {
    try std.testing.expectEqual(@as(i32, 0), initialLayerDimension(null));
    try std.testing.expectEqual(@as(i32, 32), initialLayerDimension(32));
}

test "output membership is isolated per window" {
    const outputs = [_]display_state.OutputState{
        .{ .name = 11, .scale = 1 },
        .{ .name = 22, .scale = 2 },
    };
    var first: OutputMembership = .{};
    defer first.deinit(std.testing.allocator);
    var second: OutputMembership = .{};
    defer second.deinit(std.testing.allocator);
    try first.enter(std.testing.allocator, 11);
    try second.enter(std.testing.allocator, 22);

    try std.testing.expectEqual(@as(i32, 1), integerScaleForMembership(&first, &outputs));
    try std.testing.expectEqual(@as(i32, 2), integerScaleForMembership(&second, &outputs));
}

test "output membership uses global names rather than reusable slots" {
    var membership: OutputMembership = .{};
    defer membership.deinit(std.testing.allocator);
    try membership.enter(std.testing.allocator, 11);

    const after_removal = [_]display_state.OutputState{.{ .name = 22, .scale = 2 }};
    try std.testing.expectEqual(@as(i32, 1), integerScaleForMembership(&membership, &after_removal));

    membership.leave(11);
    try membership.enter(std.testing.allocator, 22);
    try std.testing.expectEqual(@as(i32, 2), integerScaleForMembership(&membership, &after_removal));
}

test "output membership grows beyond the former fixed capacity" {
    var membership: OutputMembership = .{};
    defer membership.deinit(std.testing.allocator);

    var name: u32 = 1;
    while (name <= 64) : (name += 1) {
        try membership.enter(std.testing.allocator, name);
    }

    try std.testing.expectEqual(@as(usize, 64), membership.names.items.len);
    try std.testing.expect(membership.contains(64));
    membership.leave(32);
    try std.testing.expect(!membership.contains(32));
    try std.testing.expectEqual(@as(usize, 63), membership.names.items.len);
}

test "scale calculation includes outputs beyond the former fixed capacity" {
    var membership: OutputMembership = .{};
    defer membership.deinit(std.testing.allocator);

    var outputs: [64]display_state.OutputState = undefined;
    for (&outputs, 0..) |*output_state, index| {
        const name: u32 = @intCast(index + 1);
        output_state.* = .{
            .name = name,
            .scale = if (index == outputs.len - 1) 4 else 1,
        };
        try membership.enter(std.testing.allocator, name);
    }

    try std.testing.expectEqual(@as(i32, 4), integerScaleForMembership(&membership, &outputs));

    membership.leave(outputs.len);
    try std.testing.expectEqual(@as(i32, 1), integerScaleForMembership(&membership, &outputs));
}
