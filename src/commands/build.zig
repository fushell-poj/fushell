//! Build command execution: project selection, engine acquisition and publication.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const project = @import("project.zig");
const application_config = @import("../application_config.zig");
const bundle_transaction = @import("../bundle_transaction.zig");
const flutter_engine_store = @import("../flutter_engine_store.zig");
const flutter_toolchain = @import("../flutter_toolchain.zig");
const aot_artifacts = @import("../aot_artifacts.zig");
const Mode = cli.Mode;
const embedded_runner = @embedFile("fushell_runner_bin");
const Transcript = @import("../command_output.zig").Transcript;

pub fn execute(init: std.process.Init, options: cli.build.Options) !void {
    const plan = try project.prepare(init, options);
    var toolchain = try flutter_toolchain.Toolchain.discover(init.gpa, init.io, init.environ_map);
    defer toolchain.deinit();
    try assemble(init.gpa, init.io, init.environ_map, &toolchain, plan);
}

/// Keep engine mode conversion explicit at the CLI boundary.
fn engineStoreMode(mode: Mode) flutter_engine_store.Mode {
    return switch (mode) {
        .debug => .debug,
        .profile => .profile,
        .release => .release,
    };
}

/// Build into a sibling staging directory, then publish after all steps succeed.
/// A project lock protects Flutter's shared intermediate outputs. Engine fetching
/// overlaps compilation; every exit joins/cancels the task before borrowed state
/// is released. Only a complete staging directory replaces the previous bundle.
pub fn assemble(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    toolchain: *const flutter_toolchain.Toolchain,
    options: project.Plan,
) !void {
    var output = Transcript.init(gpa, io, environ);
    defer output.deinit();
    // assembleStaged unwinds/cancels Engine acquisition before returning here.
    // Never replay compiler output while curl owns the terminal progress line.
    const entry = assembleStaged(gpa, io, environ, toolchain, options, &output) catch |err| {
        output.show();
        return err;
    };
    defer gpa.free(entry);
    output.show();
    std.debug.print("fushell bundle ready: {s}\nbundle entry: {s}\n", .{ std.fs.path.dirname(entry).?, entry });
}

/// Return an owned final entry path only after publication. Internal staging
/// names never become success messages or application launch paths.
fn assembleStaged(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    toolchain: *const flutter_toolchain.Toolchain,
    options: project.Plan,
    output: *Transcript,
) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, "build");
    var project_lock = try @import("../cache_lock.zig").Lock.acquire(io, .cwd(), "build/.fushell-build.lock");
    defer project_lock.deinit();
    var transaction = try bundle_transaction.Transaction.begin(gpa, io, .cwd(), options.bundle_dir);
    defer transaction.deinit();
    const app_name = try readPubspecName(gpa, io);
    defer gpa.free(app_name);
    const final_entry = try std.fs.path.join(gpa, &.{ transaction.output_path, app_name });
    errdefer gpa.free(final_entry);
    const arch = try flutter_engine_store.nativeArch();
    var store = flutter_engine_store.Store.init(gpa, io, environ, &toolchain.info);
    std.debug.print("[engine] Flutter {s}, Dart {s}, revision {s}\n", .{ toolchain.info.flutter_version, toolchain.info.dart_version, toolchain.info.engine_revision });
    std.debug.print("[build] Compiling the application and preparing its bundle...\n", .{});
    var future = try io.concurrent(flutter_engine_store.Store.ensure, .{ &store, arch, engineStoreMode(options.mode), flutter_engine_store.ProgressSink{} });
    var awaited = false;
    defer if (!awaited) {
        // cancel may return a result if the task won the race: release it too.
        if (future.cancel(io)) |value| {
            var result = value;
            result.deinit(gpa);
        } else |_| {}
        // Cancellation can leave curl's carriage-return meter unterminated.
        std.debug.print("\n", .{});
    };
    switch (options.mode) {
        .debug => try buildDebugBundle(gpa, io, toolchain, options.entrypoint, transaction.staging_path, app_name, output),
        .release, .profile => try buildAotBundle(gpa, io, toolchain, options.mode, options.entrypoint, transaction.staging_path, app_name, options.symbols, output),
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
    return final_entry;
}

fn buildDebugBundle(gpa: std.mem.Allocator, io: std.Io, toolchain: *const flutter_toolchain.Toolchain, entrypoint: []const u8, bundle_dir: []const u8, app_name: []const u8, output: *Transcript) !void {
    try output.run(.inherit, &.{ toolchain.executable, "pub", "get" });
    const platform_arg = try std.fmt.allocPrint(gpa, "--target-platform={s}", .{targetPlatform()});
    defer gpa.free(platform_arg);
    try output.run(.inherit, &.{ toolchain.executable, "build", "bundle", "--debug", "--no-pub", platform_arg, "-t", entrypoint });
    try packageBundle(gpa, io, toolchain, bundle_dir, app_name, "build/flutter_assets", null, output);
}

fn buildAotBundle(gpa: std.mem.Allocator, io: std.Io, toolchain: *const flutter_toolchain.Toolchain, mode: Mode, entrypoint: []const u8, bundle_dir: []const u8, app_name: []const u8, archive_symbols: bool, output: *Transcript) !void {
    const platform = targetPlatform();
    const inputs = [_][]const u8{ @tagName(mode), entrypoint, platform, toolchain.root, toolchain.info.flutter_version, toolchain.info.dart_version, toolchain.info.engine_revision };
    const key = aot_artifacts.inputKey(&inputs);
    const output_dir = try std.fmt.allocPrint(gpa, "build/fushell_debug_info/{s}/{s}", .{ @tagName(mode), key });
    defer gpa.free(output_dir);
    try std.Io.Dir.cwd().createDirPath(io, output_dir);
    const split_dir = try std.fs.path.join(gpa, &.{ output_dir, "symbols" });
    defer gpa.free(split_dir);
    const debug_info = try std.fmt.allocPrint(gpa, "{s}/app.{s}.symbols", .{ split_dir, platform });
    defer gpa.free(debug_info);
    const app_so = try std.fs.path.join(gpa, &.{ output_dir, "lib", "libapp.so" });
    defer gpa.free(app_so);
    const assets = try std.fs.path.join(gpa, &.{ output_dir, "flutter_assets" });
    defer gpa.free(assets);
    const output_arg = try std.fmt.allocPrint(gpa, "--output={s}", .{output_dir});
    defer gpa.free(output_arg);
    const platform_arg = try std.fmt.allocPrint(gpa, "-dTargetPlatform={s}", .{platform});
    defer gpa.free(platform_arg);
    const target_arg = try std.fmt.allocPrint(gpa, "-dTargetFile={s}", .{entrypoint});
    defer gpa.free(target_arg);
    const mode_arg = try std.fmt.allocPrint(gpa, "-dBuildMode={s}", .{@tagName(mode)});
    defer gpa.free(mode_arg);
    const split_arg = try std.fmt.allocPrint(gpa, "-dSplitDebugInfo={s}", .{split_dir});
    defer gpa.free(split_arg);
    const target = try std.fmt.allocPrint(gpa, "{s}_bundle_{s}_assets", .{ @tagName(mode), platform });
    defer gpa.free(target);
    const argv: []const []const u8 = &.{ toolchain.executable, "assemble", "--no-version-check", output_arg, platform_arg, mode_arg, target_arg, split_arg, target };
    try output.run(.inherit, &.{ toolchain.executable, "pub", "get" });
    try output.run(.inherit, argv);
    if (!try pathExists(gpa, debug_info)) {
        try output.note("Recovering missing AOT symbols by invalidating only the matching cached app.so.\n", .{});
        try aot_artifacts.invalidateAot(gpa, io, output_dir);
        try output.run(.inherit, argv);
    }
    if (!try pathExists(gpa, app_so)) return error.MissingLibAppSo;
    if (!try pathExists(gpa, debug_info)) return error.MissingAotDebugInfo;
    try packageBundle(gpa, io, toolchain, bundle_dir, app_name, assets, app_so, output);
    if (archive_symbols) {
        const staged_app = try std.fs.path.join(gpa, &.{ bundle_dir, "lib", "libapp.so" });
        defer gpa.free(staged_app);
        const archive = try aot_artifacts.archive(gpa, io, staged_app, debug_info, &inputs);
        defer gpa.free(archive);
        try output.note("AOT symbols archive (paired by app SHA-256): {s}\n", .{archive});
    }
}

/// Shared runtime-only tail. Keep cp -R semantics for assets and Nix libraries.
fn packageBundle(gpa: std.mem.Allocator, io: std.Io, toolchain: *const flutter_toolchain.Toolchain, bundle_dir: []const u8, app_name: []const u8, assets: []const u8, app_so: ?[]const u8, output: *Transcript) !void {
    var app_config = try application_config.loadProject(gpa, io);
    defer app_config.deinit(gpa);
    const icu = try std.fs.path.join(gpa, &.{ toolchain.root, "bin", "cache", "artifacts", "engine", targetPlatform(), "icudtl.dat" });
    defer gpa.free(icu);
    const data_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "data" });
    defer gpa.free(data_dir);
    const lib_dir = try std.fs.path.join(gpa, &.{ bundle_dir, "lib" });
    defer gpa.free(lib_dir);
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    try std.Io.Dir.cwd().createDirPath(io, lib_dir);
    const data_icu = try std.fs.path.join(gpa, &.{ data_dir, "icudtl.dat" });
    defer gpa.free(data_icu);
    try std.Io.Dir.cwd().copyFile(icu, .cwd(), data_icu, io, .{});
    const data_assets = try std.fs.path.join(gpa, &.{ data_dir, "flutter_assets" });
    defer gpa.free(data_assets);
    try output.run(.inherit, &.{ "cp", "-R", assets, data_assets });
    if (app_so) |source| {
        const destination = try std.fs.path.join(gpa, &.{ lib_dir, "libapp.so" });
        defer gpa.free(destination);
        try std.Io.Dir.cwd().copyFile(source, .cwd(), destination, io, .{});
    }
    try copyNixRuntimeLibraries(gpa, output, lib_dir);
    try writeBundleEntry(gpa, io, bundle_dir, app_name);
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

/// Nix package 会把可随应用携带的用户态共享库物化到一个 store 目录，并通过环境变量
/// 传入。这里复制的是普通文件而非 symlink；未设置变量的开发构建继续依赖宿主环境。
fn copyNixRuntimeLibraries(gpa: std.mem.Allocator, output: *Transcript, output_lib_dir: []const u8) !void {
    const runtime_root = try envValue(gpa, "FUSHELL_RUNTIME_LIBS") orelse return;
    defer gpa.free(runtime_root);

    const source_dir = try std.fs.path.join(gpa, &.{ runtime_root, "lib", "." });
    defer gpa.free(source_dir);
    try output.run(.inherit, &.{ "cp", "-R", source_dir, output_lib_dir });
}

/// 打包入口: 把内嵌的 runner 可执行文件写出为 <bundle_dir>/<app-name> (chmod +x)。
/// app 名取自项目 pubspec.yaml 的 name 字段 (官方 my_app 同款命名)。
fn writeBundleEntry(gpa: std.mem.Allocator, io: std.Io, bundle_dir: []const u8, app_name: []const u8) !void {
    const entry_path = try std.fs.path.join(gpa, &.{ bundle_dir, app_name });
    defer gpa.free(entry_path);
    var file = try std.Io.Dir.cwd().createFile(io, entry_path, .{ .permissions = .executable_file });
    defer file.close(io);
    try file.writeStreamingAll(io, embedded_runner);
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
