const std = @import("std");
const builtin = @import("builtin");
const flutter = @import("flutter_embedder.zig");
const display_state = @import("wl_display_state.zig");
const egl = @import("wayland_egl_host.zig");
const player = @import("player.zig");
const flutter_runner = @import("flutter_runner.zig");
const hot_reload = @import("hot_reload.zig");
const frontend_server = @import("frontend_server.zig");
const build_support = @import("build_support");

comptime {
    _ = hot_reload;
}

const embedded_runner = @embedFile("fushell_runner_bin");

/// VM service URI 轮询间隔 (ns)。URI 在引擎启动日志回调中写入, 通常在
/// 引擎 run 后几百 ms 内就绪; 50ms 轮询兼顾及时性与低开销。
const vm_uri_poll_interval_ns: u64 = 50 * std.time.ns_per_ms;
/// 文件监听轮询间隔 (ns)。mtime 轮询 (非 inotify 事件驱动) 因
/// std.Io.Threaded 的 Dir.iterate 存在 BADF bug 而自实现目录迭代;
/// 500ms 足够捕获保存操作, 开销可忽略。
const watch_poll_interval_ns: u64 = 500 * std.time.ns_per_ms;

// fushell SDK 包 (fushell-build sdk 释放)
const embedded_sdk_pubspec = @embedFile("fushell_sdk_pubspec");
const embedded_sdk_lib = @embedFile("fushell_sdk_lib");
const embedded_sdk_readme = @embedFile("fushell_sdk_readme");

const embedded_engine_debug = @embedFile("flutter_engine_so_debug");
const embedded_engine_profile = @embedFile("flutter_engine_so_profile");
const embedded_engine_release = @embedFile("flutter_engine_so_release");

const Mode = enum { debug, profile, release };

/// 各模式对应的内嵌引擎字节。
fn embeddedEngine(mode: Mode) []const u8 {
    return switch (mode) {
        .debug => embedded_engine_debug,
        .profile => embedded_engine_profile,
        .release => embedded_engine_release,
    };
}

const Options = struct {
    mode: Mode = .debug,
    /// run 子命令: 打包后进程内直接播放 (开发工具模式)。
    run: bool = false,
    /// sdk 子命令: 释放内嵌的 fushell 包到指定目录 (默认 ./vendor)。
    sdk: bool = false,
    sdk_dir: ?[]const u8 = null,
    /// 第一个位置参数是目录时: 视为工作目录 (chdir 后打包)。
    workdir: ?[]const u8 = null,
    entrypoint: []const u8,
    bundle_dir: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // 进程级 arena: 生命周期 = 整个进程, 退出时自动回收。
    // args.toSlice 文档要求 arena 式分配器 (结果含多个分配);
    // 默认 bundle_dir (defaultBundleDir) 也用它, 避免每次打包泄漏一个字符串。
    const runtime_arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(runtime_arena);
    // zig 0.16: init.io 自带完整环境, std.process.spawn 可解析 PATH 命令 (flutter/gclient 等)
    const io = init.io;
    const options = parseArgs(runtime_arena, args) catch |err| {
        printUsage();
        if (err == error.HelpRequested) return;
        return err;
    };

    // sdk 子命令: 释放内嵌的 fushell 包 (不需要工作目录/打包)
    if (options.sdk) {
        const sdk_dir = options.sdk_dir orelse "vendor";
        releaseSdk(gpa, io, sdk_dir) catch |err| {
            std.debug.print("[error] fushell-build sdk failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }

    // 目录参数 → 工作目录 (所有相对路径: flutter 命令/产物/bundle 默认目录)
    if (options.workdir) |workdir| {
        const workdir_z = try gpa.dupeZ(u8, workdir);
        defer gpa.free(workdir_z);
        const chdir_result = std.c.chdir(workdir_z.ptr);
        if (chdir_result != 0) {
            std.debug.print("[error] fushell-build failed: cannot chdir to {s} (errno {d})\n", .{ workdir, std.posix.errno(chdir_result) });
            std.process.exit(1);
        }
        std.debug.print("working directory: {s}\n", .{workdir});
    }

    buildBundle(gpa, io, options) catch |err| {
        std.debug.print("[error] fushell-build failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    if (options.run) {
        std.debug.print("running {s}...\n", .{options.bundle_dir});
        // 热重载: 仅 debug 模式 (JIT 引擎带 VM service)
        const enable_vm_service = options.run and options.mode == .debug;
        var hot_thread: ?std.Thread = null;
        if (enable_vm_service) {
            const spawn_result = std.Thread.spawn(.{}, hotReloadThreadMain, .{gpa});
            hot_thread = spawn_result catch |err| blk: {
                std.debug.print("[error] hot reload unavailable: {s}\n", .{@errorName(err)});
                break :blk null;
            };
        }
        player.runPlayer(gpa, options.bundle_dir, enable_vm_service) catch |err| {
            std.debug.print("[error] fushell-build run failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        // 主窗口已关 (引擎退出): 通知热重载线程退出, 再 join 收尸。
        // 否则 watcher 的 while(true) 永挂, join 卡死进程。
        hot_reload_stop.store(true, .release);
        if (hot_thread) |t| t.join();
    }
}

fn parseArgs(runtime_arena: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var mode: Mode = .debug;
    var run: bool = false;
    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var index: usize = 1;
    // run 子命令: fushell-build run [options] [<folder>]
    if (index < args.len and std.mem.eql(u8, args[index], "run")) {
        run = true;
        index += 1;
    }
    // sdk 子命令: fushell-build sdk [<dir>]  (释放内嵌 fushell 包)
    var sdk_dir: ?[]const u8 = null;
    if (!run and index < args.len and std.mem.eql(u8, args[index], "sdk")) {
        index += 1;
        if (index < args.len and !std.mem.startsWith(u8, args[index], "-")) {
            sdk_dir = args[index];
            index += 1;
        }
        if (index != args.len) return error.InvalidArguments;
        return Options{
            .mode = .debug,
            .run = false,
            .sdk = true,
            .sdk_dir = sdk_dir,
            .entrypoint = "lib/main.dart",
            .bundle_dir = "build/linux/x64/debug",
        };
    }

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--debug")) {
            mode = .debug;
        } else if (std.mem.eql(u8, arg, "--release")) {
            mode = .release;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            mode = .profile;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("unknown option: {s}\n", .{arg});
            return error.InvalidArguments;
        } else {
            if (positional_count == positional.len) return error.InvalidArguments;
            positional[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count > positional.len) return error.InvalidArguments;

    // 第一个位置参数: 目录 → 工作目录 (entry/输出用默认); 否则 → entrypoint
    var workdir: ?[]const u8 = null;
    var entrypoint: []const u8 = "lib/main.dart";
    var bundle_dir: []const u8 = defaultBundleDir(runtime_arena, mode);
    if (positional_count >= 1) {
        if (isDir(positional[0])) {
            workdir = positional[0];
            if (positional_count >= 2) bundle_dir = positional[1];
        } else {
            entrypoint = positional[0];
            if (positional_count >= 2) bundle_dir = positional[1];
        }
    }

    return .{
        .mode = mode,
        .run = run,
        .workdir = workdir,
        .entrypoint = entrypoint,
        .bundle_dir = bundle_dir,
    };
}

/// 热重载线程: 等待引擎报告 VM service URI → 连接 → getVM 验证。
/// (spike 阶段: 验证 WebSocket + JSON-RPC 链路; 后续扩展为文件监听 + reload)
/// 主窗口关闭后由 main 置位, watcher while 循环检查退出 (避免 join 卡死)。
var hot_reload_stop = std.atomic.Value(bool).init(false);
fn hotReloadThreadMain(gpa: std.mem.Allocator) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 等待 VM service URI (引擎启动后日志回调写入)
    var waited: usize = 0;
    var uri_buf: [512]u8 = undefined;
    const uri = while (true) {
        if (flutter_runner.vm_service.get(&uri_buf)) |u| break u;
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
    // 提取 isolateId: 找 "id":"isolates/... (Dart JSON 会转义 / 为 \/)
    const iso_marker = "\"id\":\"isolates\\/";
    const iso_idx = std.mem.indexOf(u8, vm_result, iso_marker) orelse {
        std.debug.print("[hot-reload] cannot find isolate id in getVM result\n", .{});
        return;
    };
    const iso_start = iso_idx + iso_marker.len;
    const iso_end = std.mem.indexOfScalar(u8, vm_result[iso_start..], '"') orelse return;
    // VM service 需要完整 id: "isolates/<number>"
    var iso_buf: [128]u8 = undefined;
    const isolate_id = std.fmt.bufPrint(&iso_buf, "isolates/{s}", .{vm_result[iso_start .. iso_start + iso_end]}) catch return;
    std.debug.print("[hot-reload] isolateId: {s}\n", .{isolate_id});

    // 定位 flutter SDK (用于 frontend_server 启动参数)
    const flutter_root = queryFlutterRoot(gpa, io) catch |err| {
        std.debug.print("[hot-reload] cannot find Flutter SDK: {s}\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(flutter_root);

    const project_dir = std.process.currentPathAlloc(io, gpa) catch return;
    defer gpa.free(project_dir);

    const kernel_path = "/tmp/fushell-hotreload-kernel.dill";
    var main_uri_buf: [4096]u8 = undefined;
    const main_uri = std.fmt.bufPrint(&main_uri_buf, "file://{s}/lib/main.dart", .{project_dir}) catch return;
    var err_buf: [4096]u8 = undefined;

    // 常驻 frontend_server (诊断模式: 查退出根因)
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

fn printUsage() void {
    std.debug.print("usage: fushell-build [--debug|--profile|--release] [<entry-dart-file>] [<output-dir>]\n", .{});
    std.debug.print("       fushell-build run [--debug|--profile|--release] [<project-dir>]\n", .{});
    std.debug.print("       fushell-build sdk [<dir>]   (release the fushell package; default ./vendor)\n", .{});
    std.debug.print("  default entry: lib/main.dart   default output: build/linux/x64/<mode>\n", .{});
    std.debug.print("  <project-dir> (first arg is a directory) → treated as the working directory\n", .{});
    std.debug.print("  run → build then play in-process (dev tool mode; debug auto hot-reload)\n", .{});
    std.debug.print("example: fushell-build --release                      # → build/linux/x64/release\n", .{});
    std.debug.print("         fushell-build examples/smoke_app             # build in that project\n", .{});
    std.debug.print("         fushell-build run examples/smoke_app         # build + play\n", .{});
    std.debug.print("         fushell-build lib/top_bar.dart build/top_bar_bundle\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("debug builds produce a Fushell bundle with:\n", .{});
    std.debug.print("  <output>/data/icudtl.dat\n", .{});
    std.debug.print("  <output>/data/flutter_assets/\n", .{});
    std.debug.print("  <output>/lib/libflutter_engine.so\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("release builds additionally require a prior `flutter build bundle --release`\n", .{});
    std.debug.print("and produce:\n", .{});
    std.debug.print("  <output>/lib/libapp.so\n", .{});
}

fn buildBundle(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    switch (options.mode) {
        .debug => try buildDebugBundle(gpa, io, options.entrypoint, options.bundle_dir),
        .release, .profile => try buildAotBundle(gpa, io, options.mode, options.entrypoint, options.bundle_dir),
    }
}

fn buildDebugBundle(gpa: std.mem.Allocator, io: std.Io, entrypoint: []const u8, bundle_dir: []const u8) !void {
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
    try writeBundleEntry(gpa, io, bundle_dir);

    std.debug.print("fushell bundle ready: {s}\n", .{bundle_dir});
}

/// release/profile 共用: AOT 编译 app (assemble) + 组装 AOT bundle。
/// assemble target 名与 -dBuildMode 按模式派生 (release_bundle_... / profile_bundle_...)。
fn buildAotBundle(gpa: std.mem.Allocator, io: std.Io, mode: Mode, entrypoint: []const u8, bundle_dir: []const u8) !void {
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
    try runCommand(gpa, io, &.{
        "flutter",    "assemble",     "--no-version-check", "--output=build",
        platform_arg, build_mode_arg, target_file_arg,      assemble_target,
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

    try runCommand(gpa, io, &.{ "rm", "-rf", bundle_dir });
    try runCommand(gpa, io, &.{ "mkdir", "-p", data_dir, lib_dir });
    try runCommand(gpa, io, &.{ "cp", icu_data, data_icu });
    try runCommand(gpa, io, &.{ "cp", "-R", "build/flutter_assets", data_assets });
    try runCommand(gpa, io, &.{ "cp", app_so, app_so_dest });
    try writeEmbeddedEngine(io, mode, engine_library);
    try writeBundleEntry(gpa, io, bundle_dir);

    std.debug.print("fushell {s} bundle ready: {s}\n", .{ @tagName(mode), bundle_dir });
}

fn targetPlatform() []const u8 {
    if (builtin.os.tag != .linux) @compileError("fushell-build currently supports Linux hosts only");
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
