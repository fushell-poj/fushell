//! Development run lifecycle and hot reload, separate from argument parsing.
const std = @import("std");
const cli = @import("cli");
const build = @import("build.zig");
const project = @import("project.zig");
const player = @import("../player.zig");
const flutter_runner = @import("../flutter_runner.zig");
const hot_reload = @import("../hot_reload.zig");
const frontend_server = @import("../frontend_server.zig");
const devtools = @import("../devtools.zig");
const service_uri = @import("../service_uri.zig");
const signal_shutdown = @import("../signal_shutdown.zig");
const flutter_toolchain = @import("../flutter_toolchain.zig");
const source_snapshot = @import("../source_snapshot.zig");

const vm_uri_poll_interval_ns: u64 = 50 * std.time.ns_per_ms;
const watch_poll_interval_ns: u64 = 500 * std.time.ns_per_ms;

/// Build first, then run using the same selected SDK. Errors unwind resources
/// before the process entry point maps them to an exit status.
pub fn execute(init: std.process.Init, options: cli.run.Options) !u8 {
    if (options.vm_service_port) |port| {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        var server = address.listen(init.io, .{}) catch |err| {
            std.log.err("VM Service port {d} is unavailable on 127.0.0.1: {s}", .{ port, @errorName(err) });
            return err;
        };
        server.deinit(init.io);
    }
    const plan = try project.prepare(init, options.build);
    var toolchain = try flutter_toolchain.Toolchain.discover(init.gpa, init.io, init.environ_map);
    defer toolchain.deinit();
    try build.assemble(init.gpa, init.io, init.environ_map, &toolchain, plan);
    return runBundle(init.gpa, init.io, &toolchain, plan, options);
}

fn runBundle(gpa: std.mem.Allocator, io: std.Io, toolchain: *const flutter_toolchain.Toolchain, plan: project.Plan, options: cli.run.Options) !u8 {
    std.debug.print("running {s}...\n", .{plan.bundle_dir});
    hot_reload_stop.store(false, .release);

    var signal_watcher = try signal_shutdown.Watcher.init();
    defer signal_watcher.deinit();

    var resolved_service: service_uri.State = .{};
    resolved_service.clear(io);
    const hot_reload_service = if (options.devtools) &resolved_service else &flutter_runner.vm_service;

    var hot_thread: ?std.Thread = null;
    if (plan.mode == .debug and options.hot_reload) {
        hot_thread = std.Thread.spawn(.{}, hotReloadThreadMain, .{ gpa, hot_reload_service, toolchain, plan.entrypoint }) catch |err| blk: {
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
        .use_flutter_attach = plan.mode == .debug,
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
    const exit_status = try player.runPlayer(
        gpa,
        io,
        plan.bundle_dir,
        vm_service_port,
        signal_watcher.fd,
        options.application_args,
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
