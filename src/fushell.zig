//! 面向开发者的 `fushell` 命令实现。
//!
//! 应用所需的 runner、选定 Flutter 引擎、ICU 数据、Fushell SDK 与 libdbus 会在
//! 构建时嵌入本可执行文件。`build` 生成自包含 bundle；`run` 监管该 bundle 以及
//! 可选的热重载/DevTools 工具；`sdk` 导出与 CLI 嵌入内容完全一致的 Dart 包。
//! `--` 之后的应用参数是不透明数据，绝不会按 Fushell 选项解析。

const std = @import("std");
const builtin = @import("builtin");
const application_config = @import("application_config.zig");
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
const build_support = @import("build_support");

comptime {
    _ = hot_reload;
}

const embedded_runner = @embedFile("fushell_runner_bin");
const embedded_dbus_runtime = @embedFile("dbus_runtime");

/// VM service URI 轮询间隔 (ns)。URI 在引擎启动日志回调中写入, 通常在
/// 引擎 run 后几百 ms 内就绪; 50ms 轮询兼顾及时性与低开销。
const vm_uri_poll_interval_ns: u64 = 50 * std.time.ns_per_ms;
/// 文件监听轮询间隔 (ns)。mtime 轮询 (非 inotify 事件驱动) 因
/// std.Io.Threaded 的 Dir.iterate 存在 BADF bug 而自实现目录迭代;
/// 500ms 足够捕获保存操作, 开销可忽略。
const watch_poll_interval_ns: u64 = 500 * std.time.ns_per_ms;

// fushell SDK 包 (`fushell sdk` 释放)
const embedded_sdk_pubspec = @embedFile("fushell_sdk_pubspec");
const embedded_sdk_lib = @embedFile("fushell_sdk_lib");
const embedded_sdk_readme = @embedFile("fushell_sdk_readme");

const embedded_engine_debug = @embedFile("flutter_engine_so_debug");
const embedded_engine_profile = @embedFile("flutter_engine_so_profile");
const embedded_engine_release = @embedFile("flutter_engine_so_release");

const Mode = cli.Mode;

/// 各模式对应的内嵌引擎字节。
fn embeddedEngine(mode: Mode) []const u8 {
    return switch (mode) {
        .debug => embedded_engine_debug,
        .profile => embedded_engine_profile,
        .release => embedded_engine_release,
    };
}

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

    const options = resolveOptions(runtime_arena, parsed);
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

    buildBundle(gpa, io, options) catch |err| {
        std.debug.print("[error] fushell build failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (options.command == .run) {
        const exit_status = runBundle(gpa, io, options) catch |err| {
            if (err == error.UserInterrupt) std.process.exit(130);
            std.debug.print("[error] fushell run failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (exit_status != 0) std.process.exit(exit_status);
    }
}

fn resolveOptions(runtime_arena: std.mem.Allocator, parsed: cli.Options) Options {
    var workdir: ?[]const u8 = null;
    var entrypoint: []const u8 = "lib/main.dart";
    var bundle_dir: []const u8 = defaultBundleDir(runtime_arena, parsed.mode);
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

fn runBundle(gpa: std.mem.Allocator, io: std.Io, options: Options) !u8 {
    std.debug.print("running {s}...\n", .{options.bundle_dir});
    hot_reload_stop.store(false, .release);

    var signal_watcher = try signal_shutdown.Watcher.init();
    defer signal_watcher.deinit();

    var resolved_service: service_uri.State = .{};
    resolved_service.clear(io);
    const hot_reload_service = if (options.devtools) &resolved_service else &flutter_runner.vm_service;

    var hot_thread: ?std.Thread = null;
    if (options.mode == .debug and options.hot_reload) {
        hot_thread = std.Thread.spawn(.{}, hotReloadThreadMain, .{ gpa, hot_reload_service }) catch |err| blk: {
            std.debug.print("[error] hot reload unavailable: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    }

    var devtools_context = devtools.Context{
        .io = io,
        .gpa = gpa,
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

/// 热重载线程: 等待引擎报告 VM service URI → 连接 → getVM 验证。
/// (spike 阶段: 验证 WebSocket + JSON-RPC 链路; 后续扩展为文件监听 + reload)
/// 主窗口关闭后由 main 置位, watcher while 循环检查退出 (避免 join 卡死)。
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

fn hotReloadThreadMain(gpa: std.mem.Allocator, service: *service_uri.State) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 等待 VM service URI (引擎启动后日志回调写入)
    var waited: usize = 0;
    var uri_buf: [512]u8 = undefined;
    const uri = while (true) {
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

    // 定位 flutter SDK (用于 frontend_server 启动参数)
    const flutter_root = queryFlutterRoot(gpa, io) catch |err| {
        std.debug.print("[hot-reload] cannot find Flutter SDK: {s}\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(flutter_root);

    const project_dir = std.process.currentPathAlloc(io, gpa) catch return;
    defer gpa.free(project_dir);

    var kernel_path_buf: [128]u8 = undefined;
    const kernel_path = std.fmt.bufPrint(&kernel_path_buf, "/tmp/fushell-hotreload-kernel-{d}.dill", .{std.os.linux.getpid()}) catch return;
    defer std.Io.Dir.cwd().deleteFile(io, kernel_path) catch {};
    var main_uri_buf: [4096]u8 = undefined;
    const main_uri = std.fmt.bufPrint(&main_uri_buf, "file://{s}/lib/main.dart", .{project_dir}) catch return;
    var err_buf: [4096]u8 = undefined;

    // Keep one frontend_server alive for incremental compilation.
    var fs = frontend_server.FrontendServer.start(gpa, io, flutter_root, project_dir, kernel_path, main_uri) catch |err| {
        std.debug.print("[hot-reload] frontend_server start failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer fs.stop();
    var dill_path_buf: [4096]u8 = undefined;
    _ = fs.compile(&err_buf, &.{}, &dill_path_buf) catch |err| {
        std.debug.print("[hot-reload] initial compile failed: {s}\n", .{@errorName(err)});
        return;
    };
    // recompile 输出增量 dill; 每次 reload 从结果行解析实际路径
    var kernel_uri_buf: [8192]u8 = undefined;
    std.debug.print("[hot-reload] initial compile done. Watching lib/**/*.dart (press 'r' to reload)...\n", .{});

    // 文件监听 (轮询 mtime)
    var baseline = scanLibDartFiles(gpa, "lib") catch return;
    defer freeFileMap(gpa, &baseline);

    while (true) {
        if (hot_reload_stop.load(.acquire)) break;
        std.Io.sleep(io, .{ .nanoseconds = watch_poll_interval_ns }, .real) catch return;

        var current = scanLibDartFiles(gpa, "lib") catch continue;
        var changed_paths = filesChanged(gpa, &baseline, &current) catch {
            freeFileMap(gpa, &current);
            continue;
        };
        // changed_paths 的路径借用自 current (之后成为新 baseline), 只 deinit 容器本身
        defer changed_paths.deinit(gpa);
        // 更新基线
        freeFileMap(gpa, &baseline);
        baseline = current;
        if (changed_paths.items.len == 0) continue;

        std.debug.print("[hot-reload] {d} file(s) changed, compiling...\n", .{changed_paths.items.len});
        // 热重载: 新 kernel 文件 → VM 替换代码 → 框架重建
        dill_path_buf[0] = 0;
        const ok = fs.compile(&err_buf, changed_paths.items, &dill_path_buf) catch |err| {
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
        const kernel_uri = std.fmt.bufPrint(&kernel_uri_buf, "file://{s}", .{dill_used}) catch continue;
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

const FileEntry = struct { path: []const u8, mtime: i64 };

fn scanLibDartFiles(gpa: std.mem.Allocator, dir: []const u8) !std.ArrayList(FileEntry) {
    var result: std.ArrayList(FileEntry) = .empty;
    try scanDirRecursive(gpa, &result, dir);
    return result;
}

fn scanDirRecursive(gpa: std.mem.Allocator, out: *std.ArrayList(FileEntry), dir: []const u8) !void {
    // 用 raw getdents64 遍历 (zig 0.16 Threaded 的 Dir.iterate 有 BADF bug)
    const dir_z = try gpa.dupeZ(u8, dir);
    defer gpa.free(dir_z);
    const fd = std.os.linux.open(dir_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (std.os.linux.errno(fd) != .SUCCESS) return;
    defer _ = std.os.linux.close(@intCast(fd));

    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: usize = @intCast(@as(isize, @bitCast(rc)));
        if (n > 0x8000000000000000) return; // errno (负数)
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *std.os.linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.name)));
            off += ent.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const full = try std.fs.path.join(gpa, &.{ dir, name });
            if (ent.type == std.os.linux.DT.DIR) {
                try scanDirRecursive(gpa, out, full);
                gpa.free(full);
            } else if (std.mem.endsWith(u8, name, ".dart")) {
                const st = statMtime(full) orelse {
                    gpa.free(full);
                    continue;
                };
                try out.append(gpa, .{ .path = full, .mtime = st });
            } else {
                gpa.free(full);
            }
        }
    }
}

fn statMtime(path: []const u8) ?i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const st = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return null;
    return @intCast(st.mtime.nanoseconds);
}

/// 返回变化的文件路径列表 (增量编译的 invalidated files)。
fn filesChanged(gpa: std.mem.Allocator, old: *std.ArrayList(FileEntry), new: *std.ArrayList(FileEntry)) !std.ArrayList([]const u8) {
    var changed: std.ArrayList([]const u8) = .empty;
    for (new.items) |n| {
        var found = false;
        for (old.items) |o| {
            if (std.mem.eql(u8, o.path, n.path)) {
                found = true;
                if (o.mtime != n.mtime) {
                    try changed.append(gpa, n.path);
                }
                break;
            }
        }
        if (!found) try changed.append(gpa, n.path);
    }
    return changed;
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

fn freeFileMap(gpa: std.mem.Allocator, map: *std.ArrayList(FileEntry)) void {
    for (map.items) |e| gpa.free(e.path);
    map.deinit(gpa);
}

/// 路径存在且是目录 (Io.Dir.openDir 成功且关闭正常 = 目录)。
fn isDir(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDir(.cwd(), io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// 默认输出目录: build/linux/<arch>/<mode> (arch 来自构建目标, Flutter 命名)。
fn defaultBundleDir(gpa: std.mem.Allocator, mode: Mode) []const u8 {
    const arch = @import("build_options").flutter_arch;
    const mode_str = switch (mode) {
        .debug => "debug",
        .release => "release",
        .profile => "profile",
    };
    return std.fmt.allocPrint(gpa, "build/linux/{s}/{s}", .{ arch, mode_str }) catch "build/bundle";
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

fn buildBundle(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    switch (options.mode) {
        .debug => try buildDebugBundle(gpa, io, options.entrypoint, options.bundle_dir),
        .release, .profile => try buildAotBundle(gpa, io, options.mode, options.entrypoint, options.bundle_dir),
    }
}

fn buildDebugBundle(gpa: std.mem.Allocator, io: std.Io, entrypoint: []const u8, bundle_dir: []const u8) !void {
    var app_config = try application_config.loadProject(gpa, io);
    defer app_config.deinit(gpa);

    const target_platform = targetPlatform();
    const flutter_root = try queryFlutterRoot(gpa, io);
    defer gpa.free(flutter_root);

    const icu_data = try std.fs.path.join(gpa, &.{ flutter_root, "bin", "cache", "artifacts", "engine", target_platform, "icudtl.dat" });
    defer gpa.free(icu_data);

    try runCommand(gpa, io, &.{ "flutter", "pub", "get" });
    const platform_arg = try std.fmt.allocPrint(gpa, "--target-platform={s}", .{target_platform});
    defer gpa.free(platform_arg);
    try runCommand(gpa, io, &.{ "flutter", "build", "bundle", "--debug", platform_arg, "-t", entrypoint });

    const data_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "data" });
    defer gpa.free(data_dir);
    const lib_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "lib" });
    defer gpa.free(lib_dir);
    const data_icu = try std.fs.path.join(gpa, &.{ data_dir, "icudtl.dat" });
    defer gpa.free(data_icu);
    const data_assets = try std.fs.path.join(gpa, &.{ data_dir, "flutter_assets" });
    defer gpa.free(data_assets);
    const engine_library = try std.fs.path.join(gpa, &.{ lib_dir, "libflutter_engine.so" });
    defer gpa.free(engine_library);

    try runCommand(gpa, io, &.{ "rm", "-rf", bundle_dir });
    try runCommand(gpa, io, &.{ "mkdir", "-p", data_dir, lib_dir });
    try runCommand(gpa, io, &.{ "cp", icu_data, data_icu });
    try runCommand(gpa, io, &.{ "cp", "-R", "build/flutter_assets", data_assets });
    try writeEmbeddedEngine(io, .debug, engine_library);
    try writeDbusRuntime(gpa, io, lib_dir);
    try copyNixRuntimeLibraries(gpa, io, lib_dir);
    try writeBundleEntry(gpa, io, bundle_dir);
    try application_config.writeBundle(gpa, io, bundle_dir, app_config);

    std.debug.print("fushell bundle ready: {s}\n", .{bundle_dir});
}

/// release/profile 共用: AOT 编译 app (assemble) + 组装 AOT bundle。
/// assemble target 名与 -dBuildMode 按模式派生 (release_bundle_... / profile_bundle_...)。
fn buildAotBundle(gpa: std.mem.Allocator, io: std.Io, mode: Mode, entrypoint: []const u8, bundle_dir: []const u8) !void {
    var app_config = try application_config.loadProject(gpa, io);
    defer app_config.deinit(gpa);

    const target_platform = targetPlatform();
    const flutter_root = try queryFlutterRoot(gpa, io);
    defer gpa.free(flutter_root);

    const icu_data = try std.fs.path.join(gpa, &.{ flutter_root, "bin", "cache", "artifacts", "engine", target_platform, "icudtl.dat" });
    defer gpa.free(icu_data);

    // 1. AOT 编译 app: `flutter build bundle --release` 只产 flutter_assets
    //    (releaseCopyFlutterBundle 不含 AOT), libapp.so 由 assemble 的
    //    {mode}_bundle_<platform>_assets target (依赖 AotElf) 产出。
    //    参数形式与官方 `flutter build linux --release` 内部完全一致
    //    (tool_backend.dart): -d defines + --output=build + target。
    try runCommand(gpa, io, &.{ "flutter", "pub", "get" });
    const platform_arg = try std.fmt.allocPrint(gpa, "-dTargetPlatform={s}", .{target_platform});
    defer gpa.free(platform_arg);
    const target_file_arg = try std.fmt.allocPrint(gpa, "-dTargetFile={s}", .{entrypoint});
    defer gpa.free(target_file_arg);
    const assemble_target = try std.fmt.allocPrint(gpa, "{s}_bundle_{s}_assets", .{ @tagName(mode), target_platform });
    defer gpa.free(assemble_target);
    const build_mode_arg = try std.fmt.allocPrint(gpa, "-dBuildMode={s}", .{@tagName(mode)});
    defer gpa.free(build_mode_arg);
    const split_debug_dir = "build/fushell_debug_info";
    const split_debug_arg = "-dSplitDebugInfo=" ++ split_debug_dir;
    // Flutter's assemble cache does not track deletion of split debug-info
    // outputs. Invalidate its AOT graph so every release build regenerates the
    // mandatory symbols artifact rather than reusing a stale app.so cache hit.
    try runCommand(gpa, io, &.{ "rm", "-rf", split_debug_dir, ".dart_tool/flutter_build" });
    try runCommand(gpa, io, &.{
        "flutter",       "assemble",     "--no-version-check", "--output=build",
        platform_arg,    build_mode_arg, target_file_arg,      split_debug_arg,
        assemble_target,
    });

    // 2. 校验 libapp.so (gen_snapshot 产物, 与自编引擎同 commit 配对)
    const app_so = try std.fs.path.join(gpa, &.{ "build", "lib", "libapp.so" });
    defer gpa.free(app_so);
    if (!try pathExists(gpa, app_so)) {
        std.debug.print("libapp.so not found at {s}\n", .{app_so});
        std.debug.print("`flutter assemble -dBuildMode={s} {s}` should have produced it (gen_snapshot AOT output).\n", .{ @tagName(mode), assemble_target });
        std.debug.print("Verify the Flutter SDK engine commit matches the embedded engine (42d3d75a).\n", .{});
        return error.MissingLibAppSo;
    }

    const debug_info_name = try std.fmt.allocPrint(gpa, "app.{s}.symbols", .{target_platform});
    defer gpa.free(debug_info_name);
    const debug_info = try std.fs.path.join(gpa, &.{ split_debug_dir, debug_info_name });
    defer gpa.free(debug_info);
    if (!try pathExists(gpa, debug_info)) {
        std.debug.print("AOT debug info not found at {s}\n", .{debug_info});
        return error.MissingAotDebugInfo;
    }

    // 3. 组装 AOT bundle
    const data_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "data" });
    defer gpa.free(data_dir);
    const lib_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "lib" });
    defer gpa.free(lib_dir);
    const data_icu = try std.fs.path.join(gpa, &.{ data_dir, "icudtl.dat" });
    defer gpa.free(data_icu);
    const data_assets = try std.fs.path.join(gpa, &.{ data_dir, "flutter_assets" });
    defer gpa.free(data_assets);
    const engine_library = try std.fs.path.join(gpa, &.{ lib_dir, "libflutter_engine.so" });
    defer gpa.free(engine_library);
    const app_so_dest = try std.fs.path.join(gpa, &.{ lib_dir, "libapp.so" });
    defer gpa.free(app_so_dest);
    const debug_info_dest = try std.fs.path.join(gpa, &.{ lib_dir, "libapp.so.symbols" });
    defer gpa.free(debug_info_dest);

    try runCommand(gpa, io, &.{ "rm", "-rf", bundle_dir });
    try runCommand(gpa, io, &.{ "mkdir", "-p", data_dir, lib_dir });
    try runCommand(gpa, io, &.{ "cp", icu_data, data_icu });
    try runCommand(gpa, io, &.{ "cp", "-R", "build/flutter_assets", data_assets });
    try runCommand(gpa, io, &.{ "cp", app_so, app_so_dest });
    try runCommand(gpa, io, &.{ "cp", debug_info, debug_info_dest });
    try writeEmbeddedEngine(io, mode, engine_library);
    try writeDbusRuntime(gpa, io, lib_dir);
    try copyNixRuntimeLibraries(gpa, io, lib_dir);
    try writeBundleEntry(gpa, io, bundle_dir);
    try application_config.writeBundle(gpa, io, bundle_dir, app_config);

    std.debug.print("fushell {s} bundle ready: {s}\n", .{ @tagName(mode), bundle_dir });
}

fn targetPlatform() []const u8 {
    if (builtin.os.tag != .linux) @compileError("fushell currently supports Linux hosts only");
    return switch (builtin.cpu.arch) {
        .x86_64 => "linux-x64",
        .aarch64 => "linux-arm64",
        else => @compileError("unsupported Fushell Flutter engine host architecture"),
    };
}

fn queryFlutterRoot(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    _ = io;

    if (try envValue(gpa, "FLUTTER_ROOT")) |root| return root;
    if (try envValue(gpa, "FLUTTER_SDK")) |root| return root;

    const path = std.c.getenv("PATH") orelse return error.FlutterRootUnavailable;
    var entries = std.mem.splitScalar(u8, std.mem.span(path), ':');
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const flutter_exe = try std.fs.path.join(gpa, &.{ entry, "flutter" });
        defer gpa.free(flutter_exe);
        if (!try pathExists(gpa, flutter_exe)) continue;

        const root_candidate = std.fs.path.dirname(entry) orelse continue;
        const root = try gpa.dupe(u8, root_candidate);
        errdefer gpa.free(root);
        const icu_probe = try std.fs.path.join(gpa, &.{ root, "bin", "cache", "artifacts", "engine", targetPlatform(), "icudtl.dat" });
        defer gpa.free(icu_probe);
        if (try pathExists(gpa, icu_probe)) return root;
        gpa.free(root);
    }

    return error.FlutterRootUnavailable;
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

fn writeDbusRuntime(gpa: std.mem.Allocator, io: std.Io, output_lib_dir: []const u8) !void {
    const destination_path = try std.fs.path.join(gpa, &.{ output_lib_dir, "libdbus-1.so.3" });
    defer gpa.free(destination_path);
    var file = try std.Io.Dir.cwd().createFile(io, destination_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, embedded_dbus_runtime);
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

fn writeEmbeddedEngine(io: std.Io, mode: Mode, path: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, .{ .permissions = .executable_file })
    else
        try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = .executable_file });
    defer file.close(io);
    try file.writeStreamingAll(io, embeddedEngine(mode));
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
