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
const max_outputs = 16;

const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;

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

pub const MetricsCallback = *const fn (context: ?*anyopaque, metrics: Metrics) void;
pub const PointerCallback = *const fn (context: ?*anyopaque, event: PointerEvent) void;
pub const EventLoopTickCallback = *const fn (context: ?*anyopaque) anyerror!void;

pub const State = enum {
    uninitialized,
    initializing,
    ready,
    failed,
    shutting_down,
};

const OutputState = struct {
    name: u32 = 0,
    output: ?*wl.Output = null,
    scale: i32 = 1,
    entered: bool = false,
};

/// 主窗口 Host (scale 回调目标; attach 时设置)。
var primary_host: ?*Host = null;

pub const Host = struct {
    /// 进程级共享连接 (wl_display + EGL display + 全局对象)。
    display_state: *display_state.DisplayState = undefined,
    /// 本窗口的事件 queue: 窗口对象 (surface/xdg/toplevel) 绑定它。
    event_queue: ?*wl.EventQueue = null,
    /// 主窗口: 全局对象 (registry/output/seat/pointer) 绑它的 queue。
    is_primary: bool = false,
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

    egl_config: c.EGLConfig = null,
    egl_context: c.EGLContext = null,
    egl_surface: c.EGLSurface = null,
    egl_bootstrap_surface: c.EGLSurface = null,
    egl_resource_context: c.EGLContext = null,
    egl_resource_surface: c.EGLSurface = null,

    configured: bool = false,
    running: bool = true,
    width: i32 = default_width,
    height: i32 = default_height,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    scale: i32 = 1,
    fractional_scale_120: u32 = 0,

    pointer_focused: bool = false,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_buttons: i64 = 0,

    metrics_callback: ?MetricsCallback = null,
    metrics_context: ?*anyopaque = null,
    pointer_callback: ?PointerCallback = null,
    pointer_context: ?*anyopaque = null,

    /// 绑定到共享 DisplayState (acquire + 创建本窗口 event queue)。
    /// is_primary=true 的主窗口额外把全局对象绑到自己的 queue 并初始化输入。
    pub fn attach(self: *Host, state: *display_state.DisplayState, is_primary: bool) !void {
        self.display_state = state;
        self.is_primary = is_primary;
        _ = try state.acquire();
        self.event_queue = state.display.?.createQueue() catch return error.WaylandQueueCreateFailed;
        if (is_primary) {
            try state.attachPrimary(self.event_queue.?);
            primary_host = self;
            // output scale 变化 → 主窗口重算 scale (共享 scale 状态)
            display_state.scale_change_callback = struct {
                fn cb() void {
                    if (primary_host) |host| host.recomputeScale();
                }
            }.cb;
        }
        self.adoptProvisionalScaleFromOutputs();
    }

    pub fn initializeWindowRole(self: *Host, window: surface_channel.WindowRole) !void {
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

        const title_z = try std.heap.c_allocator.dupeZ(u8, window.title);
        defer std.heap.c_allocator.free(title_z);
        const app_id_z = try std.heap.c_allocator.dupeZ(u8, window.app_id);
        defer std.heap.c_allocator.free(app_id_z);
        self.toplevel.?.setTitle(title_z);
        self.toplevel.?.setAppId(app_id_z);

        self.applyBufferScale();
        self.surface.?.commit();
        self.display_state.flushLocked();
        try self.waitForInitialConfigure();
        try self.attachEglWindowSurface();
        self.state = .ready;
    }

    pub fn initializeLayerRole(self: *Host, layer: surface_channel.LayerRole) !void {
        try self.beginRoleInitialization();
        errdefer self.state = .failed;
        if (self.display_state.layer_shell == null) return error.LayerShellUnavailable;

        if (layer.width) |width| self.width = width;
        if (layer.height) |height| self.height = height;

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
        self.display_state.flushLocked();
        try self.waitForInitialConfigure();
        try self.attachEglWindowSurface();
        self.state = .ready;
    }

    pub fn updateLayerRole(self: *Host, update: surface_channel.LayerSurfaceUpdate) !bool {
        try self.requireReadyLayerRole();
        if (update.isEmpty()) return false;

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
        self.display_state.flushLocked();
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
        self.display_state.flushLocked();
        return false;
    }

    pub fn waitForInitialConfigure(self: *Host) !void {
        while (!self.configured) {
            if (self.dispatchQueue() != .SUCCESS) return error.WaylandDispatchFailed;
            self.display_state.flushLocked();
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

    pub fn initEglBootstrap(self: *Host) !void {
        // eglGetDisplay/Initialize 在 DisplayState.init 完成 (共享);
        // context 也是共享的 (Mesa 驱动线程按 context 创建, 共享后不随窗口增长)。
        std.debug.assert(self.display_state.egl_display != null);
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
        if (c.eglChooseConfig(self.display_state.egl_display, &config_attribs, &self.egl_config, 1, &config_count) != c.EGL_TRUE or config_count == 0) {
            return eglError("eglChooseConfig");
        }

        const context_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_CLIENT_VERSION, 2,
            c.EGL_NONE,
        };
        self.egl_context = c.eglCreateContext(self.display_state.egl_display, self.egl_config, c.EGL_NO_CONTEXT, &context_attribs);
        if (self.egl_context == c.EGL_NO_CONTEXT) return eglError("eglCreateContext");

        const pbuffer_attribs = [_]c.EGLint{
            c.EGL_WIDTH,  1,
            c.EGL_HEIGHT, 1,
            c.EGL_NONE,
        };
        self.egl_bootstrap_surface = c.eglCreatePbufferSurface(self.display_state.egl_display, self.egl_config, &pbuffer_attribs);
        if (self.egl_bootstrap_surface == c.EGL_NO_SURFACE) return eglError("eglCreatePbufferSurface(bootstrap)");

        self.display_state.openGlesLibrary();
        try self.makeCurrent();
        try self.clearCurrent();
    }

    pub fn attachEglWindowSurface(self: *Host) !void {
        try self.initEglBootstrap();

        self.egl_window_width = self.physicalWidthI32();
        self.egl_window_height = self.physicalHeightI32();
        self.egl_window = c.wl_egl_window_create(@ptrCast(self.surface.?), self.egl_window_width, self.egl_window_height);
        if (self.egl_window == null) return error.WlEglWindowCreateFailed;

        self.egl_surface = c.eglCreateWindowSurface(self.display_state.egl_display, self.egl_config, @ptrCast(self.egl_window.?), null);
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

    pub fn metrics(self: *const Host) Metrics {
        return .{
            .width = @intCast(self.physicalWidthI32()),
            .height = @intCast(self.physicalHeightI32()),
            .pixel_ratio = self.activeScale(),
        };
    }

    pub fn makeCurrent(self: *Host) !void {
        const surface = if (self.state == .ready and self.egl_surface != null and self.egl_surface != c.EGL_NO_SURFACE)
            self.egl_surface
        else
            self.egl_bootstrap_surface;
        if (surface == null or surface == c.EGL_NO_SURFACE) return error.EglFailed;
        if (c.eglMakeCurrent(self.display_state.egl_display, surface, surface, self.egl_context) != c.EGL_TRUE) {
            return eglError("eglMakeCurrent");
        }
    }

    pub fn clearCurrent(self: *Host) !void {
        if (c.eglMakeCurrent(self.display_state.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT) != c.EGL_TRUE) {
            return eglError("eglMakeCurrent(clear)");
        }
    }

    pub fn makeWindowCurrent(self: *Host) !void {
        if (self.egl_surface == null or self.egl_surface == c.EGL_NO_SURFACE) return error.EglFailed;
        if (c.eglMakeCurrent(self.display_state.egl_display, self.egl_surface, self.egl_surface, self.egl_context) != c.EGL_TRUE) {
            return eglError("eglMakeCurrent(window)");
        }
    }

    pub fn makeResourceCurrent(self: *Host) !void {
        if (self.egl_resource_context == null or self.egl_resource_context == c.EGL_NO_CONTEXT) return self.makeWindowCurrent();
        if (c.eglMakeCurrent(self.display_state.egl_display, self.egl_resource_surface, self.egl_resource_surface, self.egl_resource_context) != c.EGL_TRUE) {
            return eglError("eglMakeCurrent(resource)");
        }
    }

    pub fn swapBuffers(self: *Host) !void {
        if (c.eglSwapBuffers(self.display_state.egl_display, self.egl_surface) != c.EGL_TRUE) return eglError("eglSwapBuffers");
    }

    pub fn resizeWindow(self: *Host) void {
        self.applyBufferScale();
        const physical_width = self.physicalWidthI32();
        const physical_height = self.physicalHeightI32();
        if (self.egl_window_width == physical_width and self.egl_window_height == physical_height) return;
        self.egl_window_width = physical_width;
        self.egl_window_height = physical_height;
        if (self.egl_window) |window| c.wl_egl_window_resize(window, physical_width, physical_height, 0, 0);
    }

    pub fn defaultFramebuffer(_: *Host) u32 {
        return 0;
    }

    pub fn resolveGlProc(self: *Host, name: [*:0]const u8) ?*anyopaque {
        const proc = c.eglGetProcAddress(name);
        if (proc != null) return @ptrCast(@constCast(proc));

        if (self.display_state.gles_library) |*gles_library| {
            const name_slice: [:0]const u8 = std.mem.span(name);
            if (gles_library.lookup(?*anyopaque, name_slice)) |symbol| return symbol;
        }
        return null;
    }

    pub fn isReady(self: *const Host) bool {
        return self.state == .ready;
    }

    pub fn runEventLoop(self: *Host, message: []const u8, tick_callback: ?EventLoopTickCallback, tick_context: ?*anyopaque) !void {
        std.debug.print("{s}\n", .{message});
        while (self.running) {
            if (tick_callback) |callback| try callback(tick_context);
            if (self.dispatchQueue() != .SUCCESS) return error.WaylandDispatchFailed;
            self.display_state.flushLocked();

            var fds = [_]c.struct_pollfd{.{
                .fd = self.display_state.display.?.getFd(),
                .events = c.POLLIN,
                .revents = 0,
            }};
            const poll_result = c.poll(&fds, fds.len, 8);
            if (poll_result < 0) return error.WaylandDispatchFailed;
            if (poll_result > 0 and (fds[0].revents & c.POLLIN) != 0) {
                // 多线程原子读: 只有一个线程能成功预约读, 其他线程下一轮 dispatch
                if (self.display_state.display.?.prepareReadQueue(self.event_queue.?)) {
                    if (self.display_state.display.?.readEvents() != .SUCCESS) return error.WaylandDispatchFailed;
                }
            }
        }
    }

    /// 分发本窗口 queue 的已缓冲事件。
    fn dispatchQueue(self: *Host) std.posix.E {
        return self.display_state.display.?.dispatchQueuePending(self.event_queue.?);
    }

    pub fn deinit(self: *Host) void {
        self.state = .shutting_down;
        if (self.display_state.egl_display != null and self.display_state.egl_display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(self.display_state.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
            if (self.egl_surface != null and self.egl_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.display_state.egl_display, self.egl_surface);
            if (self.egl_bootstrap_surface != null and self.egl_bootstrap_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.display_state.egl_display, self.egl_bootstrap_surface);
            if (self.egl_resource_surface != null and self.egl_resource_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.display_state.egl_display, self.egl_resource_surface);
            if (self.egl_resource_context != null and self.egl_resource_context != c.EGL_NO_CONTEXT) _ = c.eglDestroyContext(self.display_state.egl_display, self.egl_resource_context);
            if (self.egl_context != null and self.egl_context != c.EGL_NO_CONTEXT) _ = c.eglDestroyContext(self.display_state.egl_display, self.egl_context);
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
        self.display_state.flushLocked();
        // 释放本窗口的 event queue。主窗口的 queue 就是 primary_queue,
        // 由 DisplayState.deinit 在销毁全部全局代理后统一销毁; 这里只销毁
        // spawn 窗口自己的 queue (其代理已在上方全部销毁)。
        if (!self.is_primary) {
            if (self.event_queue) |queue| queue.destroy();
            self.event_queue = null;
        }
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
            self.display_state.flushLocked();
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
            if (self.fractional_scale_120 > 0 and self.viewport != null) {
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
        if (self.metrics_callback) |callback| callback(self.metrics_context, self.metrics());
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
        if (self.pointer_callback) |callback| callback(self.pointer_context, event);
    }

    fn outputSlotByName(self: *Host, name: u32) ?*OutputState {
        for (&self.display_state.outputs) |*output_state| {
            if (output_state.name == name and output_state.output != null) return output_state;
        }
        return null;
    }

    fn outputSlotByObject(self: *Host, output: ?*wl.Output) ?*display_state.OutputState {
        if (output == null) return null;
        for (&self.display_state.outputs) |*output_state| {
            if (output_state.output == output) return output_state;
        }
        return null;
    }

    fn emptyOutputSlot(self: *Host) ?*display_state.OutputState {
        for (&self.display_state.outputs) |*output_state| {
            if (output_state.output == null) return output_state;
        }
        return null;
    }

    fn adoptProvisionalScaleFromOutputs(self: *Host) void {
        var next_scale: i32 = 1;
        var output_count: usize = 0;
        for (self.display_state.outputs) |output_state| {
            if (output_state.output != null) {
                output_count += 1;
                if (output_state.scale > next_scale) next_scale = output_state.scale;
            }
        }
        if (output_count == 0 or next_scale == self.scale) return;
        self.scale = next_scale;
        std.debug.print("Using Wayland scale {d} from {d} advertised output(s) before surface enter.\n", .{ next_scale, output_count });
    }

    fn recomputeScale(self: *Host) void {
        if (self.fractional_scale_120 > 0) return;
        var next_scale: i32 = 1;
        for (self.display_state.outputs) |output_state| {
            if (output_state.entered and output_state.scale > next_scale) next_scale = output_state.scale;
        }
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
        .closed => self.running = false,
    }
}

fn surfaceListener(_: *wl.Surface, event: wl.Surface.Event, self: *Host) void {
    switch (event) {
        .enter => |enter| {
            if (self.outputSlotByObject(enter.output)) |slot| {
                slot.entered = true;
                self.recomputeScale();
            }
        },
        .leave => |leave| {
            if (self.outputSlotByObject(leave.output)) |slot| {
                slot.entered = false;
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
            std.debug.print("xdg_toplevel close event; stopping event loop.\n", .{});
            self.running = false;
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
