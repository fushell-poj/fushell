//! 面向开发者的 `fushell` 命令实现。
//!
//! runner 与 Fushell Dart SDK 在构建时嵌入本可执行文件；系统库由宿主提供。
//! Flutter Engine 则根据当前 Flutter CLI 的 Engine revision 按需从
//! fushell-engine-builds 获取，并缓存在 Flutter 项目的 build 目录。
//! `build` 生成自包含 bundle；`run` 监管该 bundle 以及可选的
//! 热重载/DevTools 工具；`sdk` 导出与 CLI 嵌入内容完全一致的 Dart 包。
//! `--` 之后的应用参数是不透明数据，绝不会按 Fushell 选项解析。

const std = @import("std");
const builtin = @import("builtin");
const application_config = @import("application_config.zig");
const bundle_transaction = @import("bundle_transaction.zig");
const flutter = @import("flutter_embedder.zig");
const display_state = @import("wl_display_state.zig");
const egl = @import("wayland_egl_host.zig");
const player = @import("player.zig");
const flutter_runner = @import("flutter_runner.zig");
const hot_reload = @import("hot_reload.zig");
const frontend_server = @import("frontend_server.zig");
const cli = @import("fushell_cli.zig");
const devtools = @import("devtools.zig");
const service_uri = @import("service_uri.zig");
const signal_shutdown = @import("signal_shutdown.zig");
const flutter_engine_store = @import("flutter_engine_store.zig");
const flutter_toolchain = @import("flutter_toolchain.zig");
const source_snapshot = @import("source_snapshot.zig");

comptime {
    _ = hot_reload;
}

const embedded_runner = @embedFile("fushell_runner_bin");

/// VM service URI 轮询间隔 (ns)。URI 在引擎启动日志回调中写入, 通常在
/// 引擎 run 后几百 ms 内就绪; 50ms 轮询兼顾及时性与低开销。
const vm_uri_poll_interval_ns: u64 = 50 * std.time.ns_per_ms;
/// Poll source snapshots every 500ms; platform rendering has its own event loop.
const watch_poll_interval_ns: u64 = 500 * std.time.ns_per_ms;

// fushell SDK 包 (`fushell sdk` 释放)
const embedded_sdk_pubspec = @embedFile("fushell_sdk_pubspec");
const embedded_sdk_lib = @embedFile("fushell_sdk_lib");
const embedded_sdk_readme = @embedFile("fushell_sdk_readme");

const Mode = cli.Mode;

const Options = struct {
    command: cli.Command,
    mode: Mode,
    hot_reload: bool,
    devtools: bool,
    launch_browser: bool,
    vm_service_port: ?u16,
    application_args: []const [:0]const u8,
    /// 第一个位置参数是目录时: 视为工作目录 (chdir 后打包)。
    workdir: ?[]const u8 = null,
    entrypoint: []const u8,
    bundle_dir: []const u8,

    fn vmServiceEnabled(self: Options) bool {
        return (self.mode == .debug and self.hot_reload) or self.devtools or self.vm_service_port != null;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const runtime_arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(runtime_arena);
    const io = init.io;

    const parsed = cli.parse(args[1..]) catch |err| {
        std.debug.print("[error] {s}\n\n", .{cli.errorMessage(err)});
        printUsage(io);
        std.process.exit(2);
    };
    if (parsed.command == .help or parsed.help) {
        printUsage(io);
        return;
    }
    if (parsed.command == .sdk) {
        const sdk_dir = parsed.positional(0) orelse "vendor";
        releaseSdk(gpa, io, sdk_dir) catch |err| {
            std.debug.print("[error] fushell sdk failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }

    const options = try resolveOptions(runtime_arena, parsed);
    if (options.vm_service_port) |port| {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        var server = address.listen(io, .{}) catch |err| {
            std.debug.print("[error] VM service port {d} is unavailable on 127.0.0.1: {s}\n", .{ port, @errorName(err) });
            std.process.exit(1);
        };
        server.deinit(io);
    }
    if (options.workdir) |workdir| {
        std.Io.Threaded.chdir(workdir) catch |err| {
            std.debug.print("[error] fushell failed: cannot chdir to {s}: {s}\n", .{ workdir, @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("working directory: {s}\n", .{workdir});
    }

    var toolchain = try flutter_toolchain.Toolchain.discover(gpa, io, init.environ_map);
    defer toolchain.deinit();
    buildBundle(gpa, io, init.environ_map, &toolchain, options) catch |err| {
        std.debug.print("[error] fushell build failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (options.command == .run) {
        const exit_status = runBundle(gpa, io, &toolchain, options) catch |err| {
            if (err == error.UserInterrupt) std.process.exit(130);
            std.debug.print("[error] fushell run failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (exit_status != 0) std.process.exit(exit_status);
    }
}

fn resolveOptions(runtime_arena: std.mem.Allocator, parsed: cli.Options) !Options {
    var workdir: ?[]const u8 = null;
    var entrypoint: []const u8 = "lib/main.dart";
    var bundle_dir: []const u8 = try defaultBundleDir(runtime_arena, parsed.mode);
    if (parsed.positional(0)) |first| {
        if (isDir(first)) {
            workdir = first;
            if (parsed.positional(1)) |output| bundle_dir = output;
        } else {
            entrypoint = first;
            if (parsed.positional(1)) |output| bundle_dir = output;
        }
    }

    return .{
        .command = parsed.command,
        .mode = parsed.mode,
        .hot_reload = parsed.hot_reload,
        .devtools = parsed.devtools,
        .launch_browser = parsed.launch_browser,
        .vm_service_port = parsed.vm_service_port,
        .application_args = parsed.application_args,
        .workdir = workdir,
        .entrypoint = entrypoint,
        .bundle_dir = bundle_dir,
    };
}

fn runBundle(gpa: std.mem.Allocator, io: std.Io, toolchain: *const flutter_toolchain.Toolchain, options: Options) !u8 {
    std.debug.print("running {s}...\n", .{options.bundle_dir});
    hot_reload_stop.store(false, .release);

    var signal_watcher = try signal_shutdown.Watcher.init();
    defer signal_watcher.deinit();

    var resolved_service: service_uri.State = .{};
    resolved_service.clear(io);
    const hot_reload_service = if (options.devtools) &resolved_service else &flutter_runner.vm_service;

    var hot_thread: ?std.Thread = null;
    if (options.mode == .debug and options.hot_reload) {
        hot_thread = std.Thread.spawn(.{}, hotReloadThreadMain, .{ gpa, hot_reload_service, toolchain, options.entrypoint }) catch |err| blk: {
            std.debug.print("[error] hot reload unavailable: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    }

    var devtools_context = devtools.Context{
        .io = io,
        .gpa = gpa,
        .executable = toolchain.dart_executable,
        .flutter_executable = toolchain.executable,
        .launch_browser = options.launch_browser,
        .use_flutter_attach = options.mode == .debug,
        .raw_service = &flutter_runner.vm_service,
        .resolved_service = &resolved_service,
    };
    var devtools_thread: ?std.Thread = null;
    if (options.devtools) {
        devtools_thread = std.Thread.spawn(.{}, devtools.threadMain, .{&devtools_context}) catch |err| blk: {
            std.debug.print("[error] DevTools unavailable: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    }

    defer {
        hot_reload_stop.store(true, .release);
        devtools_context.stop.store(true, .release);
        if (hot_thread) |thread| thread.join();
        if (devtools_thread) |thread| thread.join();
    }

    const vm_service_port: ?u16 = if (options.vmServiceEnabled()) options.vm_service_port orelse 0 else null;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const application_args = try gpa.alloc([]const u8, options.application_args.len);
    defer gpa.free(application_args);
    for (options.application_args, 0..) |argument, index| application_args[index] = argument;
    const exit_status = try player.runPlayer(
        gpa,
        io,
        options.bundle_dir,
        vm_service_port,
        signal_watcher.fd,
        application_args,
        cwd,
    );
    if (signal_watcher.triggered()) return error.UserInterrupt;
    return exit_status;
}

/// Wait for the VM service, compile the selected entrypoint, and watch source changes.
/// All startup/watcher waits observe the CLI shutdown flag.
var hot_reload_stop = std.atomic.Value(bool).init(false);
fn parseIsolateId(allocator: std.mem.Allocator, result: []const u8, buffer: []u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const isolates = parsed.value.object.get("isolates") orelse return null;
    if (isolates != .array or isolates.array.items.len == 0) return null;
    const isolate = isolates.array.items[0];
    if (isolate != .object) return null;
    const id = isolate.object.get("id") orelse return null;
    if (id != .string) return null;
    return std.fmt.bufPrint(buffer, "{s}", .{id.string}) catch null;
}

fn hotReloadThreadMain(gpa: std.mem.Allocator, service: *service_uri.State, toolchain: *const flutter_toolchain.Toolchain, entrypoint: []const u8) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 等待 VM service URI (引擎启动后日志回调写入)
    var waited: usize = 0;
    var uri_buf: [512]u8 = undefined;
    const uri = while (true) {
        if (hot_reload_stop.load(.acquire)) return;
        if (service.get(io, &uri_buf)) |u| break u;
        if (waited > 20_000) {
            std.debug.print("[hot-reload] timeout waiting for VM service URI.\n", .{});
            return;
        }
        std.Io.sleep(io, .{ .nanoseconds = vm_uri_poll_interval_ns }, .real) catch return;
        waited += vm_uri_poll_interval_ns / std.time.ns_per_ms;
    };
    std.debug.print("[hot-reload] connecting to VM service: {s}\n", .{uri});
    const parsed = hot_reload.parseUri(uri) catch |err| {
        std.debug.print("[hot-reload] bad VM service URI: {s}\n", .{@errorName(err)});
        return;
    };
    var vm = hot_reload.VmService.connect(io, parsed) catch |err| {
        std.debug.print("[hot-reload] connect failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer vm.close();

    var out: [65536]u8 = undefined;
    const vm_result = vm.call("getVM", "{}", &out) catch |err| {
        std.debug.print("[hot-reload] getVM failed: {s}\n", .{@errorName(err)});
        return;
    };
    var iso_buf: [128]u8 = undefined;
    const isolate_id = parseIsolateId(gpa, vm_result, &iso_buf) orelse {
        std.debug.print("[hot-reload] cannot find isolate id in getVM result\n", .{});
        return;
    };
    std.debug.print("[hot-reload] isolateId: {s}\n", .{isolate_id});

    const flutter_root = toolchain.root;

    const project_dir = std.process.currentPathAlloc(io, gpa) catch return;
    defer gpa.free(project_dir);

    var kernel_path_buf: [128]u8 = undefined;
    const kernel_path = std.fmt.bufPrint(&kernel_path_buf, "/tmp/fushell-hotreload-kernel-{d}.dill", .{std.os.linux.getpid()}) catch return;
    defer std.Io.Dir.cwd().deleteFile(io, kernel_path) catch {};
    const main_path = std.fs.path.resolve(gpa, &.{ project_dir, entrypoint }) catch return;
    defer gpa.free(main_path);
    const main_uri = flutter_toolchain.fileUri(gpa, main_path) catch return;
    defer gpa.free(main_uri);
    var err_buf: [4096]u8 = undefined;

    // Keep one frontend_server alive for incremental compilation.
    var fs = frontend_server.FrontendServer.start(gpa, io, flutter_root, project_dir, kernel_path, main_uri) catch |err| {
        std.debug.print("[hot-reload] frontend_server start failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer fs.stop();
    var dill_path_buf: [4096]u8 = undefined;
    const initial_ok = fs.compile(&err_buf, &.{}, &dill_path_buf) catch |err| {
        std.debug.print("[hot-reload] initial compile failed: {s}\n", .{@errorName(err)});
        return;
    };
    if (!initial_ok) {
        std.debug.print("[hot-reload] initial compile has errors\n", .{});
        return;
    }
    // recompile outputs incremental dill; use the path returned by the compiler.
    std.debug.print("[hot-reload] initial compile done. Watching Dart source changes...\n", .{});

    // 文件监听 (轮询 mtime)
    var baseline = source_snapshot.Snapshot.scan(gpa, io, .cwd(), entrypoint) catch return;
    defer baseline.deinit();

    while (true) {
        if (hot_reload_stop.load(.acquire)) break;
        std.Io.sleep(io, .{ .nanoseconds = watch_poll_interval_ns }, .real) catch return;

        var current = source_snapshot.Snapshot.scan(gpa, io, .cwd(), entrypoint) catch continue;
        var changed_paths = source_snapshot.Snapshot.changes(&baseline, &current, gpa) catch {
            current.deinit();
            continue;
        };
        defer changed_paths.deinit();
        baseline.deinit();
        baseline = current;
        if (changed_paths.paths.items.len == 0) continue;
        for (changed_paths.paths.items) |*path| {
            const absolute = std.fs.path.resolve(gpa, &.{ project_dir, path.* }) catch return;
            defer gpa.free(absolute);
            const uri_path = flutter_toolchain.fileUri(gpa, absolute) catch return;
            gpa.free(path.*);
            path.* = uri_path;
        }

        std.debug.print("[hot-reload] {d} file(s) changed, compiling...\n", .{changed_paths.paths.items.len});
        // 热重载: 新 kernel 文件 → VM 替换代码 → 框架重建
        dill_path_buf[0] = 0;
        const ok = fs.compile(&err_buf, changed_paths.paths.items, &dill_path_buf) catch |err| {
            std.debug.print("[hot-reload] compile failed: {s}\n", .{@errorName(err)});
            continue;
        };
        if (!ok) {
            std.debug.print("[hot-reload] compile errors (app state kept):\n{s}\n", .{std.mem.sliceTo(&err_buf, 0)});
            continue;
        }
        const dill_used: []const u8 = if (dill_path_buf[0] != 0)
            std.mem.sliceTo(dill_path_buf[0..], 0)
        else
            kernel_path;
        std.debug.print("[hot-reload] kernel: {s}\n", .{dill_used});
        const absolute_dill = std.fs.path.resolve(gpa, &.{ project_dir, dill_used }) catch continue;
        defer gpa.free(absolute_dill);
        const kernel_uri = flutter_toolchain.fileUri(gpa, absolute_dill) catch continue;
        defer gpa.free(kernel_uri);
        const reload_out = vm.reloadSources(isolate_id, kernel_uri, &out) catch |err| {
            std.debug.print("[hot-reload] reloadSources failed: {s}\n", .{@errorName(err)});
            continue;
        };
        const success = std.mem.indexOf(u8, reload_out, "\"success\":true") != null;
        if (success) {
            _ = vm.reassemble(isolate_id, &out) catch |err| {
                std.debug.print("[hot-reload] reassemble failed: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("[hot-reload] reloaded OK (state preserved).\n", .{});
        } else {
            std.debug.print("[hot-reload] reload failed: {s}\n", .{reload_out[0..@min(reload_out.len, 300)]});
        }
    }
}

test "parse isolate id from standard DDS getVM JSON" {
    var buffer: [64]u8 = undefined;
    const id = parseIsolateId(
        std.testing.allocator,
        "{\"type\":\"VM\",\"isolates\":[{\"id\":\"isolates/42\"}]}",
        &buffer,
    ) orelse return error.MissingIsolateId;
    try std.testing.expectEqualStrings("isolates/42", id);
}

/// 路径存在且是目录 (Io.Dir.openDir 成功且关闭正常 = 目录)。
fn isDir(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDir(.cwd(), io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// 默认输出目录: build/linux/<arch>/<mode> (arch 来自构建目标, Flutter 命名)。
fn defaultBundleDir(gpa: std.mem.Allocator, mode: Mode) ![]const u8 {
    const arch = @import("build_options").flutter_arch;
    const mode_str = switch (mode) {
        .debug => "debug",
        .release => "release",
        .profile => "profile",
    };
    return std.fmt.allocPrint(gpa, "build/linux/{s}/{s}", .{ arch, mode_str });
}
/// Keep engine mode conversion explicit at the CLI boundary.
fn engineStoreMode(mode: Mode) flutter_engine_store.Mode {
    return switch (mode) {
        .debug => .debug,
        .profile => .profile,
        .release => .release,
    };
}

fn printUsage(io: std.Io) void {
    std.Io.File.stdout().writeStreamingAll(io,
        \\usage: fushell <command> [options]
        \\
        \\commands:
        \\  build [--debug|--profile|--release] [project-dir|entry.dart] [output-dir]
        \\  run   [--debug|--profile|--release] [run-options] [project-dir|entry.dart] [output-dir]
        \\  sdk   [output-dir]
        \\  help
        \\
        \\run options:
        \\  --devtools                 start local Dart DevTools after VM Service discovery
        \\  --no-launch-browser        do not open a browser for DevTools
        \\  --vm-service-port=<port>   fixed VM Service port; 0 selects a random port
        \\  --no-hot-reload            disable debug-mode automatic hot reload
        \\
        \\defaults:
        \\  mode: --debug
        \\  project: current directory
        \\  entry: lib/main.dart
        \\  output: build/linux/x64/<mode>
        \\
        \\examples:
        \\  fushell build --release ./app
        \\  fushell run --debug --devtools ./app
        \\  fushell run --profile --devtools --no-launch-browser ./app
        \\  fushell run --debug --vm-service-port=8181 ./app
        \\
        \\VM Service authentication remains enabled and binds to localhost.
        \\Release mode does not support DevTools or VM Service options.
        \\
    ) catch |err| std.log.err("failed to write CLI help: {s}", .{@errorName(err)});
}

/// Build into a sibling staging directory, then publish after all steps succeed.
/// A project lock protects Flutter's shared intermediate outputs. Engine fetching
/// overlaps compilation; every exit joins/cancels the task before borrowed state
/// is released. Only a complete staging directory replaces the previous bundle.
fn buildBundle(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    toolchain: *const flutter_toolchain.Toolchain,
    options: Options,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, "build");
    var project_lock = try @import("cache_lock.zig").Lock.acquire(io, .cwd(), "build/.fushell-build.lock");
    defer project_lock.deinit();
    var transaction = try bundle_transaction.Transaction.begin(gpa, io, .cwd(), options.bundle_dir);
    defer transaction.deinit();
    const arch = try flutter_engine_store.nativeArch();
    var store = flutter_engine_store.Store.init(gpa, io, environ, &toolchain.info);
    std.debug.print("[engine] Flutter {s}, Dart {s}, revision {s}\n", .{ toolchain.info.flutter_version, toolchain.info.dart_version, toolchain.info.engine_revision });
    var future = try io.concurrent(flutter_engine_store.Store.ensure, .{ &store, arch, engineStoreMode(options.mode), flutter_engine_store.ProgressSink{} });
    var awaited = false;
    defer if (!awaited) {
        // cancel may return a result if the task won the race: release it too.
        if (future.cancel(io)) |value| {
            var result = value;
            result.deinit(gpa);
        } else |_| {}
    };
    switch (options.mode) {
        .debug => try buildDebugBundle(gpa, io, toolchain, options.entrypoint, transaction.staging_path),
        .release, .profile => try buildAotBundle(gpa, io, toolchain, options.mode, options.entrypoint, transaction.staging_path),
    }
    const download = future.await(io);
    awaited = true;
    var engine = try download;
    defer engine.deinit(gpa);
    std.debug.print("[engine] {s}: {s}\n", .{ if (engine.from_cache) "cache hit" else "download verified", engine.path });
    const lib_dir = try std.fs.path.join(gpa, &.{ transaction.staging_path, "lib" });
    defer gpa.free(lib_dir);
    const copied = try store.copy(arch, engineStoreMode(options.mode), lib_dir);
    defer gpa.free(copied);
    try transaction.commit();
    std.debug.print("fushell bundle ready: {s}\n", .{options.bundle_dir});
}

fn buildDebugBundle(
    gpa: std.mem.Allocator,
    io: std.Io,
    toolchain: *const flutter_toolchain.Toolchain,
    entrypoint: []const u8,
    bundle_dir: []const u8,
) !void {
    var app_config =
        try application_config.loadProject(gpa, io);
    defer app_config.deinit(gpa);

    const target_platform = targetPlatform();

    const flutter_root = toolchain.root;

    const icu_data = try std.fs.path.join(
        gpa,
        &.{
            flutter_root,
            "bin",
            "cache",
            "artifacts",
            "engine",
            target_platform,
            "icudtl.dat",
        },
    );
    defer gpa.free(icu_data);

    try runCommand(gpa, io, &.{ toolchain.executable, "pub", "get" });

    const platform_arg = try std.fmt.allocPrint(gpa, "--target-platform={s}", .{target_platform});
    defer gpa.free(platform_arg);

    try runCommand(gpa, io, &.{
        toolchain.executable,
        "build",
        "bundle",
        "--debug",
        platform_arg,
        "-t",
        entrypoint,
    });

    const data_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "data" });
    defer gpa.free(data_dir);

    const lib_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "lib" });
    defer gpa.free(lib_dir);

    const data_icu = try std.fs.path.join(gpa, &.{ data_dir, "icudtl.dat" });
    defer gpa.free(data_icu);

    const data_assets =
        try std.fs.path.join(gpa, &.{ data_dir, "flutter_assets" });
    defer gpa.free(data_assets);

    try runCommand(gpa, io, &.{ "mkdir", "-p", data_dir, lib_dir });

    try runCommand(gpa, io, &.{ "cp", icu_data, data_icu });

    try runCommand(gpa, io, &.{ "cp", "-R", "build/flutter_assets", data_assets });

    try copyNixRuntimeLibraries(gpa, io, lib_dir);

    try writeBundleEntry(gpa, io, bundle_dir);

    try application_config.writeBundle(gpa, io, bundle_dir, app_config);
}
/// release/profile 共用：AOT 编译 app + 组装 AOT bundle。
///
/// Engine 不再内嵌在 Fushell CLI 中，而是在最终 assemble 阶段根据
/// 当前 Flutter CLI 的 engineRevision 通过 Flutter Engine Store 获取。
fn buildAotBundle(
    gpa: std.mem.Allocator,
    io: std.Io,
    toolchain: *const flutter_toolchain.Toolchain,
    mode: Mode,
    entrypoint: []const u8,
    bundle_dir: []const u8,
) !void {
    var app_config = try application_config.loadProject(gpa, io);
    defer app_config.deinit(gpa);

    const target_platform = targetPlatform();

    const flutter_root = toolchain.root;

    const icu_data = try std.fs.path.join(gpa, &.{
        flutter_root,
        "bin",
        "cache",
        "artifacts",
        "engine",
        target_platform,
        "icudtl.dat",
    });
    defer gpa.free(icu_data);

    try runCommand(gpa, io, &.{ toolchain.executable, "pub", "get" });

    const platform_arg = try std.fmt.allocPrint(gpa, "-dTargetPlatform={s}", .{target_platform});
    defer gpa.free(platform_arg);

    const target_file_arg = try std.fmt.allocPrint(gpa, "-dTargetFile={s}", .{entrypoint});
    defer gpa.free(target_file_arg);

    const assemble_target = try std.fmt.allocPrint(
        gpa,
        "{s}_bundle_{s}_assets",
        .{ @tagName(mode), target_platform },
    );
    defer gpa.free(assemble_target);

    const build_mode_arg = try std.fmt.allocPrint(
        gpa,
        "-dBuildMode={s}",
        .{@tagName(mode)},
    );
    defer gpa.free(build_mode_arg);

    const split_debug_dir = "build/fushell_debug_info";

    const split_debug_arg = "-dSplitDebugInfo=" ++ split_debug_dir;

    const debug_info_name = try std.fmt.allocPrint(gpa, "app.{s}.symbols", .{target_platform});
    defer gpa.free(debug_info_name);

    const debug_info = try std.fs.path.join(gpa, &.{
        split_debug_dir,
        debug_info_name,
    });
    defer gpa.free(debug_info);

    // Preserve incremental AOT artifacts. Invalidate only when an external
    // deletion removed the symbols Flutter's cache does not track.
    if (!try pathExists(gpa, debug_info)) {
        try runCommand(gpa, io, &.{ "rm", "-rf", ".dart_tool/flutter_build" });
    }

    try runCommand(gpa, io, &.{
        toolchain.executable,
        "assemble",
        "--no-version-check",
        "--output=build",

        platform_arg,
        build_mode_arg,
        target_file_arg,
        split_debug_arg,

        assemble_target,
    });

    const app_so = try std.fs.path.join(gpa, &.{
        "build",
        "lib",
        "libapp.so",
    });
    defer gpa.free(app_so);

    if (!try pathExists(gpa, app_so)) {
        std.debug.print(
            "libapp.so not found at {s}\n",
            .{app_so},
        );

        std.debug.print(
            "`flutter assemble -dBuildMode={s} {s}` should have produced it.\n",
            .{
                @tagName(mode),
                assemble_target,
            },
        );

        return error.MissingLibAppSo;
    }

    if (!try pathExists(gpa, debug_info)) {
        std.debug.print("AOT debug info not found at {s}\n", .{debug_info});

        return error.MissingAotDebugInfo;
    }

    const data_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "data" });
    defer gpa.free(data_dir);

    const lib_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "lib" });
    defer gpa.free(lib_dir);

    const data_icu = try std.fs.path.join(gpa, &.{ data_dir, "icudtl.dat" });
    defer gpa.free(data_icu);

    const data_assets = try std.fs.path.join(gpa, &.{ data_dir, "flutter_assets" });
    defer gpa.free(data_assets);

    const app_so_dest = try std.fs.path.join(gpa, &.{ lib_dir, "libapp.so" });
    defer gpa.free(app_so_dest);

    const debug_info_dest = try std.fs.path.join(gpa, &.{ lib_dir, "libapp.so.symbols" });
    defer gpa.free(debug_info_dest);

    try runCommand(gpa, io, &.{ "mkdir", "-p", data_dir, lib_dir });

    try runCommand(gpa, io, &.{ "cp", icu_data, data_icu });

    try runCommand(gpa, io, &.{ "cp", "-R", "build/flutter_assets", data_assets });

    try runCommand(gpa, io, &.{ "cp", app_so, app_so_dest });

    try runCommand(gpa, io, &.{ "cp", debug_info, debug_info_dest });

    try copyNixRuntimeLibraries(gpa, io, lib_dir);

    try writeBundleEntry(gpa, io, bundle_dir);

    try application_config.writeBundle(gpa, io, bundle_dir, app_config);
}

fn targetPlatform() []const u8 {
    if (builtin.os.tag != .linux) @compileError("fushell currently supports Linux hosts only");
    return switch (builtin.cpu.arch) {
        .x86_64 => "linux-x64",
        .aarch64 => "linux-arm64",
        else => @compileError("unsupported Fushell Flutter engine host architecture"),
    };
}

fn envValue(gpa: std.mem.Allocator, comptime name: []const u8) !?[]u8 {
    const raw = std.c.getenv(name ++ "\x00") orelse return null;
    return try gpa.dupe(u8, std.mem.span(raw));
}

fn pathExists(gpa: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    return std.c.access(path_z.ptr, std.c.F_OK) == 0;
}

fn runCommand(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    _ = gpa;
    std.debug.print("$", .{});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n", .{});

    if (argv.len == 0) return error.CommandFailed;

    // 用 std.process.spawn (需要完整环境解析 PATH, io 由调用方提供: init.io / graph.io)
    var child = try std.process.spawn(io, .{ .argv = argv });
    defer child.kill(io);
    // Child 无 deinit: wait 后由 io 释放 (spawn 的 stdio 管道在 wait 时清理)

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("command exited with status {d}\n", .{code});
                return error.CommandFailed;
            }
        },
        .signal, .stopped => |sig| {
            std.debug.print("command terminated by signal {d}\n", .{sig});
            return error.CommandFailed;
        },
        .unknown => return error.CommandFailed,
    }
}

/// Nix package 会把可随应用携带的用户态共享库物化到一个 store 目录，并通过环境变量
/// 传入。这里复制的是普通文件而非 symlink；未设置变量的开发构建继续依赖宿主环境。
fn copyNixRuntimeLibraries(gpa: std.mem.Allocator, io: std.Io, output_lib_dir: []const u8) !void {
    const runtime_root = try envValue(gpa, "FUSHELL_RUNTIME_LIBS") orelse return;
    defer gpa.free(runtime_root);

    const source_dir = try std.fs.path.join(gpa, &.{ runtime_root, "lib", "." });
    defer gpa.free(source_dir);
    try runCommand(gpa, io, &.{ "cp", "-R", source_dir, output_lib_dir });
}

/// 打包入口: 把内嵌的 runner 可执行文件写出为 <bundle_dir>/<app-name> (chmod +x)。
/// app 名取自项目 pubspec.yaml 的 name 字段 (官方 my_app 同款命名)。
fn writeBundleEntry(gpa: std.mem.Allocator, io: std.Io, bundle_dir: []const u8) !void {
    const app_name = try readPubspecName(gpa, io);
    defer gpa.free(app_name);
    const entry_path = try std.fs.path.join(gpa, &.{ bundle_dir, app_name });
    defer gpa.free(entry_path);
    var file = try std.Io.Dir.cwd().createFile(io, entry_path, .{ .permissions = .executable_file });
    defer file.close(io);
    try file.writeStreamingAll(io, embedded_runner);
    std.debug.print("bundle entry: {s}\n", .{entry_path});
}

/// `sdk` 子命令: 释放内嵌的 fushell 包到 <dir>/fushell (默认 ./vendor/fushell)。
/// 外部项目通过 path 依赖导入: pubspec → fushell: { path: <dir>/fushell }
fn releaseSdk(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    const target = try std.fs.path.join(gpa, &.{ dir, "fushell" });
    defer gpa.free(target);
    const lib_dir = try std.fs.path.join(gpa, &.{ target, "lib" });
    defer gpa.free(lib_dir);

    // 创建目录 (幂等: createDirPath 会递归创建不存在的路径)
    std.Io.Dir.cwd().createDirPath(io, lib_dir) catch return error.SdkReleaseDirCreateFailed;

    // 写 pubspec.yaml
    const pubspec_path = try std.fs.path.join(gpa, &.{ target, "pubspec.yaml" });
    defer gpa.free(pubspec_path);
    var pubspec_file = try std.Io.Dir.cwd().createFile(io, pubspec_path, .{});
    defer pubspec_file.close(io);
    try pubspec_file.writeStreamingAll(io, embedded_sdk_pubspec);

    // 写 lib/fushell.dart
    const lib_path = try std.fs.path.join(gpa, &.{ lib_dir, "fushell.dart" });
    defer gpa.free(lib_path);
    var lib_file = try std.Io.Dir.cwd().createFile(io, lib_path, .{});
    defer lib_file.close(io);
    try lib_file.writeStreamingAll(io, embedded_sdk_lib);

    // 写 README.md
    const readme_path = try std.fs.path.join(gpa, &.{ target, "README.md" });
    defer gpa.free(readme_path);
    var readme_file = try std.Io.Dir.cwd().createFile(io, readme_path, .{});
    defer readme_file.close(io);
    try readme_file.writeStreamingAll(io, embedded_sdk_readme);

    std.debug.print("fushell SDK released to {s}\n", .{target});
    std.debug.print("add to your project pubspec.yaml:\n", .{});
    std.debug.print("  dependencies:\n", .{});
    std.debug.print("    fushell:\n", .{});
    std.debug.print("      path: {s}\n", .{target});
}

test "released SDK matches the canonical embedded package byte-for-byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(output_root);

    try releaseSdk(std.testing.allocator, std.testing.io, output_root);

    const pubspec = try tmp.dir.readFileAlloc(
        std.testing.io,
        "fushell/pubspec.yaml",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(pubspec);
    const library = try tmp.dir.readFileAlloc(
        std.testing.io,
        "fushell/lib/fushell.dart",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(library);
    const readme = try tmp.dir.readFileAlloc(
        std.testing.io,
        "fushell/README.md",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(readme);

    try std.testing.expectEqualSlices(u8, embedded_sdk_pubspec, pubspec);
    try std.testing.expectEqualSlices(u8, embedded_sdk_lib, library);
    try std.testing.expectEqualSlices(u8, embedded_sdk_readme, readme);
}

/// 解析 pubspec.yaml 的第一层 name (无缩进的 "name:" 行)。
fn readPubspecName(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    var buf: [8192]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, "pubspec.yaml", &buf) catch return error.PubspecNotFound;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            const value = std.mem.trim(u8, trimmed["name:".len..], " \t\r");
            if (value.len > 0 and value[0] != '#') {
                return gpa.dupe(u8, value);
            }
        }
    }
    return error.PubspecNameNotFound;
}
