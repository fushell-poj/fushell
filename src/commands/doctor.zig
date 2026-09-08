//! Doctor orchestration. Independent failures become report entries, not early
//! exits. Project policy is loaded even when Flutter fails, so singleton runtime
//! requirements are never silently downgraded to multiple-instance warnings.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const report_mod = @import("../doctor/report.zig");
const native = @import("../doctor/native.zig");
const engine = @import("../doctor/engine.zig");
const project = @import("../doctor/project.zig");
const process = @import("../doctor/process.zig");
const SignalSource = @import("../retained_signal.zig").Source;
const Report = report_mod.Report;
const Io = std.Io;

/// Interrupts cancel the entire probe tree and reap subprocesses before return.
pub fn execute(init: std.process.Init, options: cli.doctor.Options) !u8 {
    var signals = try SignalSource.init();
    defer signals.close();
    const Event = union(enum) { done: anyerror!u8, signal: anyerror!u8 };
    var buffer: [2]Event = undefined;
    var select = Io.Select(Event).init(init.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.done, runReport, .{ init, options });
    try select.concurrent(.signal, waitSignal, .{ init.io, &signals });
    return switch (try select.await()) {
        .done => |result| result,
        .signal => |result| result,
    };
}

fn waitSignal(io: Io, source: *const SignalSource) anyerror!u8 {
    while (true) {
        if (source.receive()) |event| return event.exitCode() else |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        }
        try Io.sleep(io, .fromMilliseconds(25), .awake);
    }
}

fn runReport(init: std.process.Init, options: cli.doctor.Options) anyerror!u8 {
    var report = Report.init(init.gpa);
    defer report.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const supported = builtin.os.tag == .linux and (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);
    try report.add("host", "Host", if (supported) .ok else .@"error", try std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }), &.{}, if (supported) null else "Fushell supports Linux x86_64/aarch64.");

    const context = if (options.project) |path| project.inspect(&report, a, init.io, path) catch |err| blk: {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try report.add("project", "Project", .@"error", "project metadata could not be inspected", &.{@errorName(err)}, "Check project permissions and file types.");
        break :blk project.Context{};
    } else project.Context{};
    var flutter_reply: ?std.json.Parsed(native.Reply) = native.query(init, .flutter) catch |err| blk: {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try report.add("flutter", "Flutter", .@"error", "Flutter SDK discovery failed or timed out", &.{@errorName(err)}, "Run the selected Flutter CLI manually to initialize or repair its SDK.");
        break :blk null;
    };
    defer if (flutter_reply) |*value| value.deinit();
    var tools: ?native.Flutter = null;
    if (flutter_reply) |reply| {
        if (std.mem.eql(u8, reply.value.code, "ok") and reply.value.flutter != null) {
            tools = reply.value.flutter;
            const sdk = tools.?;
            const selection = if (nonempty(init.environ_map.get("FLUTTER_ROOT"))) "selected via FLUTTER_ROOT" else if (nonempty(init.environ_map.get("FLUTTER_SDK"))) "selected via FLUTTER_SDK" else "selected via PATH";
            try report.add("flutter", "Flutter", .ok, try std.fmt.allocPrint(a, "Flutter {s}; Dart {s}", .{ sdk.flutter_version, sdk.dart_version }), &.{ sdk.executable, sdk.root, sdk.engine_revision, selection }, null);
            checkTooling(&report, init, sdk) catch |err| {
                if (err == error.OutOfMemory or err == error.Canceled) return err;
                try report.add("flutter.tooling", "Flutter tooling", .@"error", "SDK tooling could not be inspected", &.{@errorName(err)}, "Check the selected SDK's files and permissions.");
            };
        } else {
            try report.add("flutter", "Flutter", .@"error", "selected Flutter SDK is not usable", &.{reply.value.code}, "Select or initialize Flutter using FLUTTER_ROOT, FLUTTER_SDK, or PATH.");
        }
    }
    project.dependencies(&report, init, tools, context) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try report.add("project.dependencies", "Project dependencies", .@"error", "project dependency probe failed", &.{@errorName(err)}, "Check metadata and temporary directory permissions.");
    };
    engine.check(&report, init, tools, context.root) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try report.add("engine", "Fushell Engine", .@"error", "Engine check did not complete", &.{@errorName(err)}, "Check repository and cache access; no cache files were changed.");
    };
    try desktop(&report, init, .wayland, false);
    try desktop(&report, init, .dbus, context.single);
    var buffer: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(init.io, &buffer);
    if (options.machine) try report_mod.renderMachine(&out.interface, &report) else try report_mod.renderHuman(&out.interface, &report, options.verbose);
    try out.interface.flush();
    return if (report.hasErrors()) 1 else 0;
}

fn checkTooling(report: *Report, init: std.process.Init, sdk: native.Flutter) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const packages = try std.fs.path.join(a, &.{ sdk.root, "packages/flutter_tools/.dart_tool/package_config.json" });
    const ready = try project.regular(.cwd(), init.io, packages);
    try report.add("flutter.tooling", "Flutter project tooling", if (ready) .ok else .@"error", if (ready) "Flutter tools package configuration is present" else "Flutter tools package configuration is missing (required by create and YAML diagnostics)", &.{packages}, if (ready) null else "Initialize the selected Flutter SDK; doctor does not run pub get for your project.");
    const dart = process.run(a, init.io, .{ .argv = &.{ sdk.dart_executable, "--version" }, .environ = init.environ_map, .timeout_ms = 5_000, .stdout_limit = 16 * 1024, .stderr_limit = 16 * 1024 }) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        return report.add("flutter.dart", "Dart executable", .@"error", "selected Dart executable could not run", &.{@errorName(err)}, "Repair the selected Flutter SDK or its runtime loader.");
    };
    defer process.deinit(a, dart);
    const ran = switch (dart.term) {
        .exited => |code| code == 0,
        else => false,
    };
    try report.add("flutter.dart", "Dart executable", if (ran) .ok else .@"error", if (ran) "selected Dart executable runs" else "selected Dart executable failed", &.{sdk.dart_executable}, null);
    const platform = if (builtin.cpu.arch == .aarch64) "linux-arm64" else "linux-x64";
    const icu = try std.fs.path.join(a, &.{ sdk.root, "bin/cache/artifacts/engine", platform, "icudtl.dat" });
    const cached = try project.regular(.cwd(), init.io, icu);
    try report.add("flutter.linux_cache", "Flutter Linux artifacts", if (cached) .ok else .warning, if (cached) "the ICU artifact used by Fushell packaging is present" else "the Linux ICU artifact is not cached; an uncached build needs SDK initialization/network", &.{icu}, if (cached) null else "Run flutter precache --linux with the selected SDK. Doctor does not initialize this cache.");
}

fn desktop(report: *Report, init: std.process.Init, kind: native.Kind, required: bool) !void {
    const id = if (kind == .wayland) "wayland" else "dbus";
    const title = if (kind == .wayland) "Wayland session" else "Session D-Bus";
    const remedy = if (kind == .wayland) "Building/creation do not require a display; running windows requires a working Wayland session." else if (required) "This single-instance project requires a working session bus with Unix FD passing." else "Multiple-instance applications do not require a session bus.";
    var reply = native.query(init, kind) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        return report.add(id, title, if (required) .@"error" else .warning, "session probe failed or timed out", &.{@errorName(err)}, remedy);
    };
    defer reply.deinit();
    const ok = std.mem.eql(u8, reply.value.code, "ok");
    try report.add(id, title, if (ok) .ok else if (required) .@"error" else .warning, if (ok) (if (kind == .wayland) "compositor connection and round trip succeeded (no window created)" else "session connection, registration, and Unix FD transport are available") else reply.value.code, &.{}, if (ok) null else remedy);
}

fn nonempty(value: ?[]const u8) bool {
    return if (value) |text| text.len > 0 else false;
}

test {
    _ = report_mod;
    _ = process;
    _ = engine;
}
