const std = @import("std");
const c = @import("c");
const egl = @import("wayland_egl_host.zig");
const flutter = @import("flutter_embedder.zig");
const surface_channel = @import("surface_channel.zig");
const display_state = @import("wl_display_state.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;

const frame_interval_nanos: u64 = 16_666_667;
const max_pending_flutter_tasks = 1024;
const flutter_default_font_family = "Roboto";

/// spawn 窗口注册表: 主窗口退出时关闭所有子窗口 (共享 Dart VM)。
/// 子窗口线程不 detach, 由主线程 join, 保证进程干净退出。
const max_spawned_windows = 64;
const SpawnEntry = struct {
    active: bool = false,
    thread: std.Thread = undefined,
    host: ?*egl.Host = null,
};
var spawn_entries: [max_spawned_windows]SpawnEntry = undefined;
var spawn_mutex: std.atomic.Mutex = .unlocked;

/// 进程级共享 DisplayState (单例): 主窗口首次创建, spawn 窗口共享。
/// 引用计数由 Host.attach/release 管理; 归零时 DisplayState 完整清理。
var global_display_state: ?*display_state.DisplayState = null;
var display_state_mutex: std.atomic.Mutex = .unlocked;

fn getDisplayState() !*display_state.DisplayState {
    while (!display_state_mutex.tryLock()) std.atomic.spinLoopHint();
    defer display_state_mutex.unlock();
    if (global_display_state == null) {
        const state = try std.heap.page_allocator.create(display_state.DisplayState);
        state.* = .{};
        global_display_state = state;
    }
    return global_display_state.?;
}

/// 主窗口 runner (指针路由的目标之一)。
var main_runner_host: ?*egl.Host = null;

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

/// atomic.Mutex (0.16) 无 lock(), 用自旋 tryLock。
fn lockSpawnMutex() void {
    while (!spawn_mutex.tryLock()) std.atomic.spinLoopHint();
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

pub const Options = struct {
    engine_library: []const u8,
    bundle_path: []const u8,
    /// 引擎关闭时是否销毁 Dart VM。多 engine 共享 VM 场景 (多窗口) 必须为 false,
    /// 由最后一个 engine (或进程退出) 负责 VM 生命周期。
    shutdown_vm_when_done: bool = true,
    /// 自定义 Dart entrypoint (custom_dart_entrypoint), 空则用 main。
    entrypoint: ?[]const u8 = null,
    /// 传给 entrypoint 的命令行参数 (dart_entrypoint_argv)。
    entrypoint_argv: ?[]const []const u8 = null,
    /// 外部提供的 Host (spawn 窗口): 主线程需要访问它以触发退出。
    external_host: ?*egl.Host = null,
    /// 主窗口: runEventLoop 结束后先关闭所有 spawn 窗口再销毁 VM。
    is_main_window: bool = false,
    /// 启动 VM service (热重载用, 仅 debug/JIT 引擎支持):
    /// 传 --enable-vm-service --vm-service-port=0, URI 从引擎日志解析。
    enable_vm_service: bool = false,
};

const Bundle = struct {
    assets_path: [:0]u8,
    icu_data_path: [:0]u8,
    app_so_path: ?[:0]u8 = null,
    overlay_assets_path: ?[]u8 = null,

    fn deinit(self: Bundle, allocator: std.mem.Allocator) void {
        if (self.overlay_assets_path) |overlay_path| {
            deleteTreeBestEffort(overlay_path);
            allocator.free(overlay_path);
        }
        if (self.app_so_path) |app_so| {
            allocator.free(app_so);
        }
        allocator.free(self.assets_path);
        allocator.free(self.icu_data_path);
    }
};

const FontconfigFont = struct {
    family: []u8,
    path: []u8,

    fn deinit(self: FontconfigFont, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        allocator.free(self.path);
    }
};

const PendingFlutterTask = struct {
    task: c.FlutterTask,
    target_time_nanos: u64,
};

const Runner = struct {
    allocator: std.mem.Allocator,
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

    fn now(self: *Runner) u64 {
        return self.api.get_current_time();
    }

    fn beginMetricsUpdate(self: *Runner) u64 {
        return self.metrics_generation.fetchAdd(1, .release) + 1;
    }

    fn beginRender(self: *Runner) void {
        self.rendering_generation.store(self.metrics_generation.load(.acquire), .release);
    }

    fn shouldPresentRenderedFrame(self: *Runner) bool {
        return self.rendering_generation.load(.acquire) == self.metrics_generation.load(.acquire);
    }

    fn queueFlutterTask(self: *Runner, task: c.FlutterTask, target_time_nanos: u64) void {
        self.lockTaskQueue();
        defer self.task_mutex.unlock();
        if (self.pending_task_count == self.pending_tasks.len) {
            std.debug.print("Flutter platform task queue is full; dropping task.\n", .{});
            return;
        }
        self.pending_tasks[self.pending_task_count] = .{ .task = task, .target_time_nanos = target_time_nanos };
        self.pending_task_count += 1;
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
        while (!self.task_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var api = try flutter.Api.load(allocator, options.engine_library);
    defer api.deinit();

    // 引擎模式决定启动协议:
    //   AOT 引擎 (release):  libapp.so ELF 快照 → FlutterEngineCreateAOTData
    //   JIT 引擎 (debug):     kernel_blob.bin → assets_path 直接启动
    const is_aot = api.runs_aot_compiled_dart_code();
    var aot_data: c.FlutterEngineAOTData = null;
    var aot_source: c.FlutterEngineAOTDataSource = undefined;

    const bundle = if (is_aot) blk: {
        std.debug.print("Flutter engine reports AOT-only execution; using AOT launch path (libapp.so).\n", .{});
        const aot_bundle = try validateAotBundle(allocator, options.bundle_path);
        aot_source = std.mem.zeroes(c.FlutterEngineAOTDataSource);
        aot_source.type = c.kFlutterEngineAOTDataSourceTypeElfPath;
        aot_source.unnamed_0.elf_path = aot_bundle.app_so_path.?.ptr;
        try flutter.ensureSuccess(api.create_aot_data(&aot_source, &aot_data), "FlutterEngineCreateAOTData");
        break :blk aot_bundle;
    } else try validateJitBundle(allocator, options.bundle_path);
    defer bundle.deinit(allocator);
    defer if (aot_data != null) {
        flutter.ensureSuccess(api.collect_aot_data(aot_data), "FlutterEngineCollectAOTData") catch |err| {
            std.debug.print("FlutterEngineCollectAOTData failed: {s}\n", .{@errorName(err)});
        };
    };

    var local_host: egl.Host = .{};
    const host: *egl.Host = options.external_host orelse &local_host;
    defer if (options.external_host == null) local_host.deinit();
    // 进程级共享 DisplayState: 主窗口首次创建 (acquire 时 connect),
    // spawn 窗口 acquire 共享。主窗口退出时 shutdownSpawnedWindows 先 join 全部
    // spawn, 再 host.deinit() 使引用归零 → 连接完整清理。
    const state = try getDisplayState();
    try host.attach(state, options.is_main_window);
    if (options.is_main_window) {
        main_runner_host = host;
        display_state.setPointerEventCallback(displayPointerRouter, null);
    }
    try host.initEglBootstrap();
    std.debug.print("Wayland display connected and EGL bootstrap context is ready. Waiting for Dart surface initialization.\n", .{});

    var runner: Runner = .{ .allocator = allocator, .host = host, .api = &api, .platform_thread_id = std.Thread.getCurrentId(), .engine_library = options.engine_library, .bundle_path = options.bundle_path };
    host.setMetricsCallback(metricsCallback, &runner);
    host.setPointerCallback(pointerCallback, &runner);

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

    var project_args: c.FlutterProjectArgs = std.mem.zeroes(c.FlutterProjectArgs);
    project_args.struct_size = @sizeOf(c.FlutterProjectArgs);
    project_args.assets_path = bundle.assets_path.ptr;
    project_args.icu_data_path = bundle.icu_data_path.ptr;
    project_args.vsync_callback = vsyncCallback;
    project_args.custom_task_runners = &custom_task_runners;
    project_args.platform_message_callback = platformMessageCallback;
    project_args.shutdown_dart_vm_when_done = options.shutdown_vm_when_done;
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

    // 自定义 entrypoint + argv (多窗口 spawn 用): 分配在 run 的 allocator 上,
    // run 阻塞期间 (engine 运行中) 有效, engine 启动时已消费。
    // argv 独立于 entrypoint 注入: 新窗口用 main 入口, 窗口标识通过 argv 传递
    // (Dart 侧 main(List<String> args) 接收)。
    if (options.entrypoint) |entrypoint| {
        const entrypoint_z = try allocator.dupeZ(u8, entrypoint);
        project_args.custom_dart_entrypoint = entrypoint_z.ptr;
    }
    if (options.entrypoint_argv) |argv| {
        const argv_z = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, 0..) |arg, i| argv_z[i] = (try allocator.dupeZ(u8, arg)).ptr;
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
            std.debug.print("FlutterEngineShutdown after startup error failed: {s}\n", .{flutter.resultName(shutdown_result)});
        }
    };

    std.debug.print("Flutter engine is running. Dart must call FushellSurface.init before rendering.\n", .{});
    try host.runEventLoop("Flutter first-frame mode is active.", flutterTaskPumpCallback, &runner);

    // 主窗口关闭: 先关闭所有子窗口引擎 (它们共享 VM), 再销毁 VM。
    // 否则子引擎仍在使用 VM 时销毁 → 崩溃。
    if (options.is_main_window) shutdownSpawnedWindows();

    std.debug.print("Shutting down Flutter engine.\n", .{});
    try flutter.ensureSuccess(api.shutdown(runner.engine), "FlutterEngineShutdown");
    runner.engine = null;
    std.debug.print("engine window thread exited.\n", .{});
}

fn validateJitBundle(allocator: std.mem.Allocator, bundle_path: []const u8) !Bundle {
    if (!try pathExists(allocator, bundle_path)) {
        std.debug.print("Flutter bundle path does not exist: {s}\n", .{bundle_path});
        return error.InvalidFlutterBundle;
    }

    const gtk_assets = try std.fs.path.join(allocator, &.{ bundle_path, "data", "flutter_assets" });
    defer allocator.free(gtk_assets);
    const gtk_icu = try std.fs.path.join(allocator, &.{ bundle_path, "data", "icudtl.dat" });
    defer allocator.free(gtk_icu);
    if (try validateAssetsLayout(allocator, gtk_assets, gtk_icu)) {
        return try prepareBundle(allocator, gtk_assets, gtk_icu, null);
    }

    const raw_assets = try std.fs.path.join(allocator, &.{ bundle_path, "flutter_assets" });
    defer allocator.free(raw_assets);
    const raw_icu = try std.fs.path.join(allocator, &.{ bundle_path, "icudtl.dat" });
    defer allocator.free(raw_icu);
    if (try validateAssetsLayout(allocator, raw_assets, raw_icu)) {
        return try prepareBundle(allocator, raw_assets, raw_icu, null);
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
fn validateAotBundle(allocator: std.mem.Allocator, bundle_path: []const u8) !Bundle {
    if (!try pathExists(allocator, bundle_path)) {
        std.debug.print("Flutter bundle path does not exist: {s}\n", .{bundle_path});
        return error.InvalidFlutterBundle;
    }

    const gtk_assets = try std.fs.path.join(allocator, &.{ bundle_path, "data", "flutter_assets" });
    defer allocator.free(gtk_assets);
    const gtk_icu = try std.fs.path.join(allocator, &.{ bundle_path, "data", "icudtl.dat" });
    defer allocator.free(gtk_icu);
    const gtk_app = try std.fs.path.join(allocator, &.{ bundle_path, "lib", "libapp.so" });
    defer allocator.free(gtk_app);
    if (try validateAotLayout(allocator, gtk_assets, gtk_icu, gtk_app)) {
        return try prepareBundle(allocator, gtk_assets, gtk_icu, gtk_app);
    }

    const raw_assets = try std.fs.path.join(allocator, &.{ bundle_path, "flutter_assets" });
    defer allocator.free(raw_assets);
    const raw_icu = try std.fs.path.join(allocator, &.{ bundle_path, "icudtl.dat" });
    defer allocator.free(raw_icu);
    if (try validateAotLayout(allocator, raw_assets, raw_icu, gtk_app)) {
        return try prepareBundle(allocator, raw_assets, raw_icu, gtk_app);
    }

    std.debug.print("Flutter AOT bundle is incomplete. Expected:\n", .{});
    std.debug.print("  {s}/lib/libapp.so\n", .{bundle_path});
    std.debug.print("  {s}/data/flutter_assets/\n", .{bundle_path});
    std.debug.print("  {s}/data/icudtl.dat\n", .{bundle_path});
    std.debug.print("Build it with: flutter build bundle --release (libapp.so via gen_snapshot).\n", .{});
    return error.InvalidFlutterBundle;
}

fn validateAotLayout(allocator: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8, app_so_path: []const u8) !bool {
    return try pathExists(allocator, assets_path) and try pathExists(allocator, icu_data_path) and try pathExists(allocator, app_so_path);
}

fn validateAssetsLayout(allocator: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8) !bool {
    const kernel_blob = try std.fs.path.join(allocator, &.{ assets_path, "kernel_blob.bin" });
    defer allocator.free(kernel_blob);
    return try pathExists(allocator, assets_path) and try pathExists(allocator, icu_data_path) and try pathExists(allocator, kernel_blob);
}

fn prepareBundle(allocator: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8, app_so_path: ?[]const u8) !Bundle {
    const injected_assets_path = prepareFontconfigAssetsOverlay(allocator, assets_path) catch |err| switch (err) {
        error.SystemFontUnavailable, error.FontManifestAlreadyProvidesDefault => null,
        else => fallback: {
            std.debug.print("System font asset injection failed: {s}; continuing with original bundle assets.\n", .{@errorName(err)});
            break :fallback null;
        },
    };

    if (injected_assets_path) |overlay_path| {
        std.debug.print("Using fontconfig system font asset overlay: {s}\n", .{overlay_path});
        return .{
            .assets_path = try allocator.dupeZ(u8, overlay_path),
            .icu_data_path = try allocator.dupeZ(u8, icu_data_path),
            .app_so_path = if (app_so_path) |p| try allocator.dupeZ(u8, p) else null,
            .overlay_assets_path = overlay_path,
        };
    }

    return .{
        .assets_path = try allocator.dupeZ(u8, assets_path),
        .icu_data_path = try allocator.dupeZ(u8, icu_data_path),
        .app_so_path = if (app_so_path) |p| try allocator.dupeZ(u8, p) else null,
    };
}

fn pathExists(allocator: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return std.c.access(path_z.ptr, std.c.F_OK) == 0;
}

fn prepareFontconfigAssetsOverlay(allocator: std.mem.Allocator, assets_path: []const u8) ![]u8 {
    const system_font = try resolveFontconfigSansFont(allocator);
    defer system_font.deinit(allocator);

    const manifest_path = try std.fs.path.join(allocator, &.{ assets_path, "FontManifest.json" });
    defer allocator.free(manifest_path);

    if (readFileAllocC(allocator, manifest_path)) |manifest| {
        defer allocator.free(manifest);
        if (manifestHasFontFamily(manifest, system_font.family) and manifestHasFontFamily(manifest, flutter_default_font_family)) {
            return error.FontManifestAlreadyProvidesDefault;
        }
    } else |_| {}

    const assets_abs = try realPathAlloc(allocator, assets_path);
    defer allocator.free(assets_abs);

    const overlay_path = try makeTempOverlayDir(allocator);
    errdefer {
        deleteTreeBestEffort(overlay_path);
        allocator.free(overlay_path);
    }

    try symlinkTopLevelAssets(allocator, assets_abs, overlay_path);

    const font_dir_name = "fushell_system_fonts";
    const font_dir = try std.fs.path.joinZ(allocator, &.{ overlay_path, font_dir_name });
    defer allocator.free(font_dir);
    if (c.mkdir(font_dir.ptr, 0o700) != 0) return error.CreateOverlayFailed;

    const font_basename = std.fs.path.basename(system_font.path);
    const font_asset = try std.fs.path.join(allocator, &.{ font_dir_name, font_basename });
    defer allocator.free(font_asset);
    const font_link = try std.fs.path.joinZ(allocator, &.{ overlay_path, font_asset });
    defer allocator.free(font_link);
    const system_font_path_z = try allocator.dupeZ(u8, system_font.path);
    defer allocator.free(system_font_path_z);
    if (c.symlink(system_font_path_z.ptr, font_link.ptr) != 0) return error.CreateOverlayFailed;

    try writeInjectedFontManifest(allocator, assets_path, overlay_path, system_font.family, font_asset);
    std.debug.print("Resolved fontconfig sans font for Flutter text fallback: {s} ({s}); registering Flutter default alias {s}\n", .{ system_font.family, system_font.path, flutter_default_font_family });
    return overlay_path;
}

fn resolveFontconfigSansFont(allocator: std.mem.Allocator) !FontconfigFont {
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
        .family = try allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(family_value)))),
        .path = try allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_value)))),
    };
}

fn makeTempOverlayDir(allocator: std.mem.Allocator) ![]u8 {
    const tmp_dir = std.c.getenv("TMPDIR") orelse "/tmp";
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const path = try std.fmt.allocPrint(allocator, "{s}/fushell-flutter-assets-{d}-{d}-{d}", .{ std.mem.span(tmp_dir), c.getpid(), c.time(null), attempt });
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        if (c.mkdir(path_z.ptr, 0o700) == 0) return path;
        allocator.free(path);
    }
    return error.CreateOverlayFailed;
}

fn symlinkTopLevelAssets(allocator: std.mem.Allocator, assets_abs: []const u8, overlay_path: []const u8) !void {
    const assets_abs_z = try allocator.dupeZ(u8, assets_abs);
    defer allocator.free(assets_abs_z);
    const dir = c.opendir(assets_abs_z.ptr) orelse return error.CreateOverlayFailed;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name = direntName(entry);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (std.mem.eql(u8, name, "FontManifest.json")) continue;
        if (std.mem.eql(u8, name, "fushell_system_fonts")) continue;

        const src = try std.fs.path.joinZ(allocator, &.{ assets_abs, name });
        defer allocator.free(src);
        const dst = try std.fs.path.joinZ(allocator, &.{ overlay_path, name });
        defer allocator.free(dst);
        if (c.symlink(src.ptr, dst.ptr) != 0) return error.CreateOverlayFailed;
    }
}

fn writeInjectedFontManifest(allocator: std.mem.Allocator, original_assets_path: []const u8, overlay_path: []const u8, family: []const u8, asset: []const u8) !void {
    const original_manifest_path = try std.fs.path.join(allocator, &.{ original_assets_path, "FontManifest.json" });
    defer allocator.free(original_manifest_path);

    const original_manifest = readFileAllocC(allocator, original_manifest_path) catch null;
    defer if (original_manifest) |manifest| allocator.free(manifest);

    const generated = try buildFontManifest(allocator, original_manifest, family, asset);
    defer allocator.free(generated);

    const overlay_manifest_path = try std.fs.path.joinZ(allocator, &.{ overlay_path, "FontManifest.json" });
    defer allocator.free(overlay_manifest_path);
    try writeFileC(overlay_manifest_path, generated);
}

fn buildFontManifest(allocator: std.mem.Allocator, original_manifest: ?[]const u8, family: []const u8, asset: []const u8) ![]u8 {
    try validateJsonStringFragment(family);
    try validateJsonStringFragment(flutter_default_font_family);
    try validateJsonStringFragment(asset);

    const injected = if (std.mem.eql(u8, family, flutter_default_font_family))
        try std.fmt.allocPrint(allocator, "{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}}", .{ family, asset, asset })
    else
        try std.fmt.allocPrint(allocator, "{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}},{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}}", .{ family, asset, asset, flutter_default_font_family, asset, asset });
    defer allocator.free(injected);

    if (original_manifest == null) {
        return try std.fmt.allocPrint(allocator, "[{s}]\n", .{injected});
    }

    const original = original_manifest.?;
    var end = original.len;
    while (end > 0 and std.ascii.isWhitespace(original[end - 1])) end -= 1;
    if (end == 0 or original[end - 1] != ']') return try std.fmt.allocPrint(allocator, "[{s}]\n", .{injected});

    var has_existing_entries = false;
    for (original[0 .. end - 1]) |byte| {
        if (!std.ascii.isWhitespace(byte) and byte != '[') {
            has_existing_entries = true;
            break;
        }
    }

    const comma = if (has_existing_entries) "," else "";
    return try std.fmt.allocPrint(allocator, "{s}{s}{s}]\n", .{ original[0 .. end - 1], comma, injected });
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

fn readFileAllocC(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = c.fopen(path_z.ptr, "rb") orelse return error.FileUnavailable;
    defer _ = c.fclose(file);

    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.FileUnavailable;
    const length = c.ftell(file);
    if (length < 0 or length > 1024 * 1024) return error.FileUnavailable;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.FileUnavailable;

    const buffer = try allocator.alloc(u8, @intCast(length));
    errdefer allocator.free(buffer);
    const read_count = c.fread(buffer.ptr, 1, buffer.len, file);
    if (read_count != buffer.len) return error.FileUnavailable;
    return buffer;
}

fn writeFileC(path_z: [:0]const u8, bytes: []const u8) !void {
    const file = c.fopen(path_z.ptr, "wb") orelse return error.FileUnavailable;
    defer _ = c.fclose(file);
    if (c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.FileUnavailable;
}

fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const resolved = c.realpath(path_z.ptr, null) orelse return error.FileUnavailable;
    defer c.free(resolved);
    return try allocator.dupe(u8, std.mem.span(resolved));
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
    sendMetrics(runner, host_metrics) catch |err| {
        std.debug.print("Flutter metrics callback failed: {s}\n", .{@errorName(err)});
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
        std.debug.print("Flutter pointer callback failed: {s}\n", .{@errorName(err)});
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

    if (!std.mem.eql(u8, channel, surface_channel.channel_name)) {
        std.debug.print("Unsupported Flutter platform channel: {s}\n", .{channel});
        sendEmptyPlatformResponse(runner, message.response_handle);
        return;
    }

    const request = surface_channel.parseRequest(runner.allocator, payload) catch |err| {
        const code = surface_channel.parseErrorCode(err);
        std.debug.print("Invalid fushell surface message: {s}\n", .{code});
        sendSurfaceError(runner, message.response_handle, null, code, "invalid fushell surface request");
        return;
    };
    defer request.deinit(runner.allocator);

    handleSurfaceRequest(runner, request) catch |err| {
        const code = surfaceRequestErrorCode(err);
        std.debug.print("Fushell surface request failed: {s}\n", .{code});
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
/// 上下文复制到 page_allocator (线程生命周期独立于请求/runner)。
fn spawnWindow(runner: *Runner, request: surface_channel.SpawnRequest) !void {
    // 分配注册表槽位 (线程不 detach, 主窗口退出时 join)
    lockSpawnMutex();
    var slot: ?usize = null;
    for (&spawn_entries, 0..) |*entry, i| {
        if (!entry.active) {
            entry.active = true;
            slot = i;
            break;
        }
    }
    unlockSpawnMutex();
    const slot_index = slot orelse {
        std.debug.print("too many spawned windows (max {d})\n", .{max_spawned_windows});
        return error.TooManySpawnedWindows;
    };

    const context = std.heap.page_allocator.create(SpawnContext) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.destroy(context);

    context.engine_library = std.heap.page_allocator.dupe(u8, runner.engine_library) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(context.engine_library);
    context.bundle_path = std.heap.page_allocator.dupe(u8, runner.bundle_path) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(context.bundle_path);
    context.entrypoint = std.heap.page_allocator.dupe(u8, request.entrypoint) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(context.entrypoint);
    context.args = std.heap.page_allocator.alloc([]const u8, request.args.len + 1) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(context.args);
    // argv[0] = 窗口身份 (entrypoint 名), 之后是请求的 args。
    // 新窗口用 main 入口启动 (main 永远在 AOT 快照中), 通过 dart_entrypoint_argv 区分。
    context.args[0] = std.heap.page_allocator.dupe(u8, request.entrypoint) catch return error.OutOfMemory;
    for (request.args, 0..) |arg, i| {
        context.args[i + 1] = std.heap.page_allocator.dupe(u8, arg) catch return error.OutOfMemory;
    }
    context.slot = slot_index;

    const thread = std.Thread.spawn(.{}, spawnThreadMain, .{context}) catch |err| {
        lockSpawnMutex();
        spawn_entries[slot_index].active = false;
        unlockSpawnMutex();
        std.debug.print("failed to spawn window thread: {s}\n", .{@errorName(err)});
        return error.WindowSpawnFailed;
    };
    lockSpawnMutex();
    spawn_entries[slot_index].thread = thread;
    unlockSpawnMutex();
    std.debug.print("spawned window engine (entrypoint: {s})\n", .{request.entrypoint});
}

/// spawn 线程的上下文 (page_allocator 持有, 线程结束时释放)。
const SpawnContext = struct {
    engine_library: []u8,
    bundle_path: []u8,
    entrypoint: []u8,
    args: [][]const u8,
    slot: usize,
};

fn spawnThreadMain(context: *SpawnContext) void {
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
        unlockSpawnMutex();
        host.deinit();
        std.heap.page_allocator.free(context.engine_library);
        std.heap.page_allocator.free(context.bundle_path);
        std.heap.page_allocator.free(context.entrypoint);
        for (context.args) |arg| std.heap.page_allocator.free(arg);
        std.heap.page_allocator.free(context.args);
        std.heap.page_allocator.destroy(context);
    }
    run(std.heap.page_allocator, .{
        .engine_library = context.engine_library,
        .bundle_path = context.bundle_path,
        .shutdown_vm_when_done = false,
        // 新窗口用 main 入口 (main 是 AOT tree-shaker 的根, 永远保留);
        // 窗口身份通过 argv[0] 传递, Dart 侧用 PlatformDispatcher.instance.args 区分。
        .entrypoint = null,
        .entrypoint_argv = context.args,
        .external_host = &host,
    }) catch |err| {
        std.debug.print("spawned window engine failed: {s}\n", .{@errorName(err)});
    };
}

fn surfaceRequestErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.SurfaceAlreadyInitialized => "SurfaceAlreadyInitialized",
        error.SurfaceNotInitialized => "SurfaceNotInitialized",
        error.SurfaceRoleMismatch => "SurfaceRoleMismatch",
        error.LayerShellUnavailable => "LayerShellUnavailable",
        error.WaylandSurfaceCreateFailed,
        error.XdgSurfaceCreateFailed,
        error.XdgToplevelCreateFailed,
        error.LayerSurfaceCreateFailed,
        error.WaylandDispatchFailed,
        error.WlEglWindowCreateFailed,
        error.EglFailed,
        error.FlutterEngineCallFailed,
        => @errorName(err),
        else => @errorName(err),
    };
}

fn sendSurfaceSuccess(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, id: i64) void {
    const response = surface_channel.successResponse(runner.allocator, id) catch |err| {
        std.debug.print("Failed to encode fushell surface success response: {s}\n", .{@errorName(err)});
        return;
    };
    defer runner.allocator.free(response);
    sendPlatformResponse(runner, response_handle, response);
}

fn sendSurfaceError(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, id: ?i64, code: []const u8, message: []const u8) void {
    const response = surface_channel.errorResponse(runner.allocator, id, code, message) catch |err| {
        std.debug.print("Failed to encode fushell surface error response: {s}\n", .{@errorName(err)});
        return;
    };
    defer runner.allocator.free(response);
    sendPlatformResponse(runner, response_handle, response);
}

fn sendPlatformResponse(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle, response: []const u8) void {
    if (response_handle == null) {
        std.debug.print("Flutter platform message had no response handle.\n", .{});
        return;
    }
    if (runner.engine == null) {
        std.debug.print("Cannot reply to Flutter platform message before engine handle is available.\n", .{});
        return;
    }
    const result = runner.api.send_platform_message_response(runner.engine, response_handle, response.ptr, response.len);
    if (result != c.kSuccess) {
        std.debug.print("FlutterEngineSendPlatformMessageResponse failed: {s}\n", .{flutter.resultName(result)});
    }
}

fn sendEmptyPlatformResponse(runner: *Runner, response_handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
    if (response_handle == null) return;
    if (runner.engine == null) {
        std.debug.print("Cannot reply to unsupported Flutter platform message before engine handle is available.\n", .{});
        return;
    }
    const result = runner.api.send_platform_message_response(runner.engine, response_handle, null, 0);
    if (result != c.kSuccess) {
        std.debug.print("FlutterEngineSendPlatformMessageResponse(empty) failed: {s}\n", .{flutter.resultName(result)});
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
        std.debug.print("Flutter make_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    if (ready) runner.beginRender();
    return true;
}

fn clearCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    if (!runner.host.isReady()) return true;
    runner.host.clearCurrent() catch |err| {
        std.debug.print("Flutter clear_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

fn makeResourceCurrentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    if (!runner.host.isReady() and !runner.bootstrap_resource_logged) {
        std.debug.print("Flutter requested resource rendering before FushellSurface.init completed; using EGL bootstrap pbuffer until Dart selects a surface role.\n", .{});
        runner.bootstrap_resource_logged = true;
    }
    runner.host.makeResourceCurrent() catch |err| {
        std.debug.print("Flutter make_resource_current callback failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

fn presentCallback(user_data: ?*anyopaque) callconv(.c) bool {
    const runner = fromUserData(user_data);
    if (!runner.host.isReady()) {
        if (!runner.bootstrap_present_logged) {
            std.debug.print("Flutter requested present before FushellSurface.init completed; dropping bootstrap frame until Dart selects a surface role.\n", .{});
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
            std.debug.print("FlutterEngineScheduleFrame after stale resize frame failed: {s}\n", .{flutter.resultName(schedule_result)});
        }
        return true;
    }
    runner.host.swapBuffers() catch |err| {
        std.debug.print("Flutter present callback failed: {s}\n", .{@errorName(err)});
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
        std.debug.print("Flutter vsync requested before engine handle was available; dropping baton {d}.\n", .{baton});
        return;
    }
    const frame_start = runner.now();
    const frame_target = frame_start + frame_interval_nanos;
    const result = runner.api.on_vsync(runner.engine, baton, frame_start, frame_target);
    if (result != c.kSuccess) {
        std.debug.print("FlutterEngineOnVsync failed: {s}\n", .{flutter.resultName(result)});
    }
}

/// 热重载: 从引擎日志解析出的 VM service URI (http://127.0.0.1:PORT/TOKEN/)。
/// logMessageCallback 写入, hot_reload 模块读取。
pub var vm_service_uri: [512]u8 = undefined;
pub var vm_service_uri_len: usize = 0;

fn logMessageCallback(tag: [*c]const u8, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const safe_tag = if (tag == null) "flutter" else std.mem.span(tag);
    const safe_message = if (message == null) "" else std.mem.span(message);
    std.debug.print("[{s}] {s}\n", .{ safe_tag, safe_message });

    // 解析 VM service 地址: "The Dart VM service is listening on http://..."
    if (vm_service_uri_len == 0) {
        const prefix = "The Dart VM service is listening on ";
        if (std.mem.indexOf(u8, safe_message, prefix)) |idx| {
            const rest = safe_message[idx + prefix.len ..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
            if (end > 0 and end <= vm_service_uri.len) {
                @memcpy(vm_service_uri[0..end], rest[0..end]);
                vm_service_uri_len = end;
                std.debug.print("[fushell] VM service URI: {s}\n", .{vm_service_uri[0..end]});
            }
        }
    }
}
