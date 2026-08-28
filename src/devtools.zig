//! 监管 `fushell run --devtools` 所启动的 Flutter 工具链。
//!
//! Debug 模式先以 machine mode 附加 Flutter Tool，由 DDS 提供 Inspector 与
//! Debugger 所需的表达式编译器；Profile 模式可让 DevTools 直接连接原始 VM
//! Service。监管器不拥有应用进程，只观察 `stop`，把工具进程组与终端信号隔离，
//! 并执行有界清理，避免卡死的子进程阻止 CLI 退出。

const std = @import("std");
const flutter_attach = @import("flutter_attach.zig");
const managed_process = @import("managed_process.zig");
const service_uri = @import("service_uri.zig");

const uri_wait_timeout_ms: usize = 20_000;
const default_stop_grace_ms: usize = 2_000;
const poll_interval_ns: u64 = 50 * std.time.ns_per_ms;

/// 传给 DevTools 监管线程的借用状态。
///
/// 所有指针都必须比 [threadMain] 存活更久。`service_state` 发布 runner 的原始
/// VM URI；Debug 模式下 `reload_service_state` 会被替换为 DDS URI，使文件监视器
/// 与浏览器共享同一个端点。
pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator = std.heap.page_allocator,
    launch_browser: bool,
    executable: []const u8 = "dart",
    flutter_executable: []const u8 = "flutter",
    use_flutter_attach: bool = false,
    raw_service: ?*service_uri.State = null,
    resolved_service: ?*service_uri.State = null,
    stop_grace_ms: usize = default_stop_grace_ms,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// 在应用停止前持续管理 attach/DevTools 生命周期。
/// 工具启动失败只产生诊断，不会终止应用。
pub fn threadMain(context: *Context) void {
    var uri_buf: [512]u8 = undefined;
    const uri = waitForVmService(context, &uri_buf) orelse return;

    if (!context.use_flutter_attach) {
        if (context.resolved_service) |resolved| resolved.set(context.io, uri);
        run(context, uri);
        return;
    }

    const attach = flutter_attach.Session.create(.{
        .io = context.io,
        .allocator = context.gpa,
        .executable = context.flutter_executable,
        .stop_grace_ms = context.stop_grace_ms,
    }, uri) catch |err| {
        if (!context.stop.load(.acquire)) {
            std.debug.print("[error] Failed to start Flutter attach bridge: {s}.\n", .{@errorName(err)});
        }
        if (context.resolved_service) |resolved| resolved.set(context.io, uri);
        return;
    };
    defer attach.destroy();

    const dds_uri = attach.waitForDdsUri(&context.stop) catch |err| {
        if (!context.stop.load(.acquire)) {
            std.debug.print("[error] Flutter attach did not publish a DDS URI: {s}.\n", .{@errorName(err)});
        }
        if (context.resolved_service) |resolved| resolved.set(context.io, uri);
        return;
    };
    if (context.resolved_service) |resolved| resolved.set(context.io, dds_uri);
    std.debug.print("[fushell] Flutter attach DDS ready for DevTools and hot reload.\n", .{});
    runManaged(context, dds_uri, attach);

    // DevTools may exit independently (for example, when its browser window is
    // closed). Keep DDS and the expression compiler alive for hot reload until
    // the application stops or Flutter attach itself exits.
    while (!context.stop.load(.acquire) and attach.isAlive()) {
        std.Io.sleep(context.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .real) catch break;
    }
}

fn run(context: *Context, uri: []const u8) void {
    runManaged(context, uri, null);
}

fn runManaged(context: *Context, uri: []const u8, attach: ?*flutter_attach.Session) void {
    var args: [7][]const u8 = undefined;
    var count: usize = 0;
    args[count] = context.executable;
    count += 1;
    args[count] = "devtools";
    count += 1;
    args[count] = "--host=127.0.0.1";
    count += 1;
    args[count] = "--port=0";
    count += 1;
    args[count] = if (context.launch_browser) "--launch-browser" else "--no-launch-browser";
    count += 1;
    args[count] = uri;
    count += 1;

    var child = std.process.spawn(context.io, .{
        .argv = args[0..count],
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = 0,
    }) catch |err| {
        std.debug.print("[devtools] failed to start `dart devtools`: {s}\n", .{@errorName(err)});
        return;
    };

    const pid = child.id orelse return;
    defer if (child.id != null) {
        managed_process.stopAndWait(context.io, &child, context.stop_grace_ms * std.time.ns_per_ms);
    };
    std.debug.print("[devtools] started for {s}\n", .{uri});

    while (!context.stop.load(.acquire)) {
        if (attach) |session| {
            if (!session.isAlive()) {
                std.debug.print("[error] Flutter attach exited; DDS-backed DevTools is no longer available.\n", .{});
                return;
            }
        }
        var status: u32 = 0;
        const result = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result != 0) {
                    child.id = null;
                    std.debug.print("[devtools] exited (status 0x{x}).\n", .{status});
                    return;
                }
            },
            .INTR => continue,
            .CHILD => {
                child.id = null;
                return;
            },
            else => {},
        }
        std.Io.sleep(context.io, .{ .nanoseconds = poll_interval_ns }, .real) catch break;
    }

    managed_process.stopAndWait(context.io, &child, context.stop_grace_ms * std.time.ns_per_ms);
    std.debug.print("[devtools] stopped.\n", .{});
}

fn waitForVmService(context: *Context, uri_buf: []u8) ?[]const u8 {
    const raw_service = context.raw_service orelse {
        std.debug.print("[error] DevTools was started without a VM Service source.\n", .{});
        return null;
    };
    var waited_ms: usize = 0;
    while (!context.stop.load(.acquire)) {
        if (raw_service.get(context.io, uri_buf)) |uri| return uri;
        if (waited_ms >= uri_wait_timeout_ms) {
            std.debug.print("[devtools] timeout waiting for VM service URI.\n", .{});
            return null;
        }
        std.Io.sleep(context.io, .{ .nanoseconds = poll_interval_ns }, .real) catch return null;
        waited_ms += poll_interval_ns / std.time.ns_per_ms;
    }
    return null;
}

test "managed devtools startup failure returns without affecting the caller" {
    var context = Context{
        .io = std.testing.io,
        .launch_browser = true,
        .executable = "/definitely/missing/fushell-dart",
    };
    run(&context, "http://127.0.0.1:8181/token=/");
}

test "managed devtools receives the authenticated URI and is reaped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var fake = try tmp.dir.createFile(std.testing.io, "fake-dart", .{ .permissions = .executable_file });
        defer fake.close(std.testing.io);
        try fake.writeStreamingAll(std.testing.io,
            \\#!/usr/bin/env bash
            \\dir="$(cd "$(dirname "$0")" && pwd)"
            \\printf '%s\n' "$@" > "$dir/args"
            \\trap 'printf TERM > "$dir/term"; exit 0' TERM
            \\while true; do sleep 0.05; done
            \\
        );
    }

    const executable = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/fake-dart",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(executable);

    var context = Context{
        .io = std.testing.io,
        .launch_browser = false,
        .executable = executable,
    };
    const uri = "http://127.0.0.1:8181/auth-token=/";
    const thread = try std.Thread.spawn(.{}, run, .{ &context, uri });
    var joined = false;
    defer if (!joined) {
        context.stop.store(true, .release);
        thread.join();
    };

    var started = false;
    for (0..40) |_| {
        if (tmp.dir.openFile(std.testing.io, "args", .{})) |file| {
            file.close(std.testing.io);
            started = true;
            break;
        } else |_| {
            try std.Io.sleep(std.testing.io, .{ .nanoseconds = poll_interval_ns }, .real);
        }
    }
    try std.testing.expect(started);

    context.stop.store(true, .release);
    thread.join();
    joined = true;

    const args = try tmp.dir.readFileAlloc(
        std.testing.io,
        "args",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(args);
    try std.testing.expect(std.mem.indexOf(u8, args, "devtools\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "--no-launch-browser\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, uri) != null);

    const term = try tmp.dir.readFileAlloc(
        std.testing.io,
        "term",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(term);
    try std.testing.expectEqualStrings("TERM", term);
}

test "managed devtools is forcibly reaped after ignoring termination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var fake = try tmp.dir.createFile(std.testing.io, "fake-dart", .{ .permissions = .executable_file });
        defer fake.close(std.testing.io);
        try fake.writeStreamingAll(std.testing.io,
            \\#!/usr/bin/env bash
            \\dir="$(cd "$(dirname "$0")" && pwd)"
            \\printf '%s\n' "$@" > "$dir/args"
            \\printf started > "$dir/started"
            \\trap '' TERM
            \\while true; do sleep 0.05; done
            \\
        );
    }

    const executable = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/fake-dart",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(executable);

    var context = Context{
        .io = std.testing.io,
        .launch_browser = true,
        .executable = executable,
        .stop_grace_ms = 100,
    };
    const thread = try std.Thread.spawn(.{}, run, .{ &context, "http://127.0.0.1:8181/token=/" });
    var joined = false;
    defer if (!joined) {
        context.stop.store(true, .release);
        thread.join();
    };

    var started = false;
    for (0..40) |_| {
        if (tmp.dir.openFile(std.testing.io, "started", .{})) |file| {
            file.close(std.testing.io);
            started = true;
            break;
        } else |_| {
            try std.Io.sleep(std.testing.io, .{ .nanoseconds = poll_interval_ns }, .real);
        }
    }
    try std.testing.expect(started);

    context.stop.store(true, .release);
    thread.join();
    joined = true;

    const args = try tmp.dir.readFileAlloc(
        std.testing.io,
        "args",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(args);
    try std.testing.expect(std.mem.indexOf(u8, args, "--launch-browser\n") != null);
}
