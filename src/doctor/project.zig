//! Project diagnostics: source manifest first, then a read-only YAML/URI helper
//! using the selected Flutter tools' existing yaml package (not a new parser).
const std = @import("std");
const config = @import("../application_config.zig");
const native = @import("native.zig");
const process = @import("process.zig");
const report_mod = @import("report.zig");
const Report = report_mod.Report;
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const Context = struct { root: ?[]const u8 = null, single: bool = false, pubspec: bool = false };

/// Context strings live in the caller's arena. A missing manifest is the same
/// multiple-instance default used by build/runtime, not a doctor-only policy.
pub fn inspect(report: *Report, a: Allocator, io: Io, input: []const u8) !Context {
    var context: Context = .{};
    const dir = Io.Dir.cwd().openDir(io, input, .{}) catch |err| {
        try report.add("project", "Project", .@"error", "cannot open the project directory", &.{ input, @errorName(err) }, "Pass an existing, readable project directory.");
        return context;
    };
    defer dir.close(io);
    context.root = try dir.realPathFileAlloc(io, ".", a);
    try report.add("project", "Project", .ok, "project directory is readable", &.{context.root.?}, null);
    context.pubspec = try regular(dir, io, "pubspec.yaml");
    if (!context.pubspec) try report.add("project.pubspec", "Project pubspec", .@"error", "pubspec.yaml is missing or not a regular file", &.{}, "Restore the project pubspec.yaml.");
    if (!try regular(dir, io, "lib/main.dart")) try report.add("project.entrypoint", "Default entrypoint", .warning, "lib/main.dart is missing; the default build/run entrypoint is unavailable", &.{}, "Restore lib/main.dart or explicitly pass your custom Dart entrypoint to build/run.");
    const stat = dir.statFile(io, config.source_file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try report.add("project.manifest", "Application policy", .ok, "multiple instances (fushell.json omitted)", &.{}, null);
            return context;
        },
        else => return err,
    };
    if (stat.kind != .file or stat.size > 64 * 1024) {
        try report.add("project.manifest", "Application policy", .@"error", "fushell.json is not a regular configuration file within 64 KiB", &.{}, null);
        return context;
    }
    const bytes = try dir.readFileAlloc(io, config.source_file_name, a, .limited(64 * 1024));
    var policy = config.parse(a, bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        try report.add("project.manifest", "Application policy", .@"error", "invalid fushell.json", &.{@errorName(err)}, "Fix the application manifest before building or running.");
        return context;
    };
    defer policy.deinit(a);
    context.single = policy.instance == .single;
    try report.add("project.manifest", "Application policy", .ok, @tagName(policy.instance), if (policy.application_id) |id| &.{id} else &.{}, null);
    return context;
}

pub fn dependencies(report: *Report, init: std.process.Init, tools: ?native.Flutter, context: Context) !void {
    if (context.root == null or !context.pubspec) return;
    const sdk = tools orelse return report.add("project.dependencies", "Project dependencies", .info, "YAML/package resolution checks skipped: Flutter is unavailable", &.{}, null);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const packages = try std.fs.path.join(a, &.{ sdk.root, "packages/flutter_tools/.dart_tool/package_config.json" });
    if (!try regular(.cwd(), init.io, packages)) return report.add("project.dependencies", "Project dependencies", .info, "YAML checks skipped: Flutter tools package configuration is missing", &.{packages}, "Initialize the selected Flutter SDK; doctor never runs pub get for the project.");
    const temporary_base = init.environ_map.get("TMPDIR") orelse "/tmp";
    const base = try Io.Dir.cwd().openDir(init.io, temporary_base, .{});
    defer base.close(init.io);
    const base_path = try base.realPathFileAlloc(init.io, ".", a);
    var random: [16]u8 = undefined;
    init.io.random(&random);
    const name = try std.fmt.allocPrint(a, "fushell-doctor-{x}", .{random});
    try base.createDir(init.io, name, .fromMode(0o700));
    defer {
        const protection = init.io.swapCancelProtection(.blocked);
        defer _ = init.io.swapCancelProtection(protection);
        base.deleteTree(init.io, name) catch {};
    }
    const temporary = try base.openDir(init.io, name, .{});
    defer temporary.close(init.io);
    try temporary.writeFile(init.io, .{ .sub_path = "project.dart", .data = @embedFile("project.dart") });
    const script = try std.fs.path.join(a, &.{ base_path, name, "project.dart" });
    const result = process.run(a, init.io, .{
        .argv = &.{ sdk.dart_executable, try std.fmt.allocPrint(a, "--packages={s}", .{packages}), script, context.root.?, sdk.root },
        .environ = init.environ_map,
        .cwd = .{ .dir = temporary },
        .timeout_ms = 15_000,
    }) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        return report.add("project.dependencies", "Project dependencies", .@"error", "the read-only project probe did not complete", &.{@errorName(err)}, "Check the selected Dart SDK and temporary directory. Project files were not changed.");
    };
    defer process.deinit(a, result);
    switch (result.term) {
        .exited => |code| if (code != 0) return report.add("project.dependencies", "Project dependencies", .@"error", "the selected Dart SDK could not run the YAML probe", &.{}, "Check the initialized Flutter tools package configuration."),
        else => return report.add("project.dependencies", "Project dependencies", .@"error", "the project probe terminated unexpectedly", &.{}, null),
    }
    const Reply = struct { schemaVersion: u32, checks: []report_mod.Check };
    const parsed = std.json.parseFromSlice(Reply, a, result.stdout, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return report.add("project.dependencies", "Project dependencies", .@"error", "the project probe returned invalid JSON", &.{}, null);
    };
    defer parsed.deinit();
    if (parsed.value.schemaVersion != 1 or parsed.value.checks.len == 0 or parsed.value.checks.len > 16) return error.InvalidProjectProbeProtocol;
    for (parsed.value.checks) |check| try report.add(check.id, check.title, check.status, check.summary, check.details, check.remedy);
}

pub fn regular(dir: Io.Dir, io: Io, path: []const u8) !bool {
    const stat = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .file;
}
