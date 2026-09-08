//! Compose Flutter's scaffolder with the embedded SDK and a small Fushell template.
//! No Engine download, build, display initialization, or global configuration.
const std = @import("std");
const cli = @import("cli");
const prompt = @import("../create_prompt.zig");
const Draft = @import("../project_draft.zig").Draft;
const Toolchain = @import("../flutter_toolchain.zig").Toolchain;
const sdk = @import("sdk.zig");
const Io = std.Io;
const Transcript = @import("../command_output.zig").Transcript;

/// Preserve inherited proxy/SDK configuration and use argv, never a shell string.
/// Cancellation reaps the direct child; terminal signals also reach its process group.
fn run(io: Io, env: *const std.process.Environ.Map, cwd: []const u8, args: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = args, .environ_map = env, .cwd = .{ .path = cwd }, .stdin = .ignore });
    defer child.kill(io);
    switch (try @import("../child_wait.zig").wait(&child, io)) {
        .exited => |code| if (code != 0) {
            std.log.err("{s} exited with status {d}", .{ args[0], code });
            return error.CreateCommandFailed;
        },
        .signal => |signal| {
            if (signal == .INT) return error.UserInterrupt;
            return error.CreateCommandFailed;
        },
        else => return error.CreateCommandFailed,
    }
}

/// Flutter's scaffold/formatter output describes the private draft, not the
/// finished Fushell project. Suppress successful output rather than rewriting
/// Flutter's prose; keep both streams on failure for actionable diagnostics.
fn runQuiet(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, args: []const []const u8) !void {
    var output = Transcript.init(gpa, io, env);
    defer output.deinit();
    output.run(.{ .path = cwd }, args) catch |err| {
        output.show();
        return err;
    };
}

pub fn execute(init: std.process.Init, options: cli.create.Options) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = init.io;
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const interactive = options.output == null or options.interactive;
    const settings = if (interactive) blk: {
        if (!try Io.File.stdin().isTty(io) or !try Io.File.stderr().isTty(io)) {
            std.log.err("create needs a terminal when no directory is provided or --interactive is used; supply an output directory for unattended creation", .{});
            return error.InteractiveTerminalRequired;
        }
        var input_buffer: [4096]u8 = undefined;
        var output_buffer: [4096]u8 = undefined;
        var input = Io.File.stdin().reader(io, &input_buffer);
        var output = Io.File.stderr().writer(io, &output_buffer);
        break :blk try prompt.collect(a, cwd, options, &input.interface, &output.interface) orelse return;
    } else prompt.resolve(a, cwd, options) catch |err| {
        std.log.err("invalid create configuration ({s}); use --project-name for directory names that are not Dart identifiers", .{@errorName(err)});
        return err;
    };

    var draft = Draft.begin(init.gpa, io, .cwd(), settings.output) catch |err| {
        std.log.err("cannot create project at {s}: {s}; only missing or empty directories are allowed", .{ settings.output, @errorName(err) });
        return err;
    };
    defer draft.deinit();
    var tools = try Toolchain.discover(init.gpa, io, init.environ_map);
    defer tools.deinit();

    // yaml is already a dependency of the selected flutter_tools installation.
    // Use that SDK's package configuration explicitly: no host Dart and no pub
    // resolution for this helper, including create --no-pub.
    const package_config = try std.fs.path.join(a, &.{ tools.root, "packages/flutter_tools/.dart_tool/package_config.json" });
    Io.Dir.cwd().access(io, package_config, .{}) catch |err| {
        std.log.err("initialized Flutter tools package config is required at {s}: {s}", .{ package_config, @errorName(err) });
        return error.FlutterToolsConfigUnavailable;
    };
    std.debug.print("Creating Fushell project {s}...\n", .{settings.output});
    runQuiet(init.gpa, io, init.environ_map, cwd, &.{
        tools.executable,   "create",              "--template=app", "--empty",             "--platforms=linux", "--no-pub",
        "--project-name",   settings.project_name, "--org",          settings.organization, "--description",     settings.description,
        draft.project_path,
    }) catch |err| {
        std.log.err("Flutter scaffold failed; destination was not changed", .{});
        return err;
    };

    const vendor = try std.fs.path.join(a, &.{ draft.project_path, "vendor" });
    const exported = try sdk.exportPackage(init.gpa, io, vendor);
    defer init.gpa.free(exported);
    inline for (.{ "configure.dart", "main.dart.tmpl", "app.dart", "widget_test.dart.tmpl", "README.md.tmpl" }) |name|
        try draft.workspace.writeFile(io, .{ .sub_path = name, .data = @embedFile("../project_templates/" ++ name) });
    const request = try std.json.Stringify.valueAlloc(a, .{
        .name = settings.project_name,
        .applicationId = settings.application_id,
        .single = settings.single_instance,
    }, .{});
    try draft.workspace.writeFile(io, .{ .sub_path = "request.json", .data = request });
    const script = try std.fs.path.join(a, &.{ draft.workspace_path, "configure.dart" });
    const packages_arg = try std.fmt.allocPrint(a, "--packages={s}", .{package_config});
    runQuiet(init.gpa, io, init.environ_map, cwd, &.{ tools.dart_executable, packages_arg, script, draft.project_path }) catch |err| {
        std.log.err("Fushell project configuration failed; destination was not changed", .{});
        return err;
    };
    // Flutter may leave a scaffold lock even with --no-pub. It predates the
    // Fushell path dependency, so discard it. A final pub get, when enabled,
    // regenerates an authoritative lock after configuration.
    const scaffold_lock = try std.fs.path.join(a, &.{ draft.project_path, "pubspec.lock" });
    Io.Dir.cwd().deleteFile(io, scaffold_lock) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // Format and syntax-check generated files before making the project visible.
    const lib = try std.fs.path.join(a, &.{ draft.project_path, "lib" });
    const tests = try std.fs.path.join(a, &.{ draft.project_path, "test" });
    try runQuiet(init.gpa, io, init.environ_map, cwd, &.{ tools.dart_executable, "format", lib, tests });
    try draft.publish();

    if (settings.pub_get) {
        run(io, init.environ_map, settings.output, &.{ tools.executable, "pub", "get" }) catch |err| {
            std.log.err("project sources are ready at {s}, but pub get failed; run flutter pub get in that directory to retry", .{settings.output});
            return err;
        };
    }
    var buffer: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buffer);
    try out.interface.print("\nFushell project created at {s}.\n\n", .{settings.output});
    if (!settings.pub_get) try out.interface.writeAll("Dependency resolution skipped (--no-pub).\n");
    try out.interface.writeAll("To run:\n  cd ");
    try shellQuote(&out.interface, settings.output);
    try out.interface.writeAll("\n  fushell run\n\nClose windows to hide them; use the Exit button or Ctrl+C to stop the process.\n");
    try out.interface.flush();
}

fn shellQuote(writer: *Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |c| if (c == '\'') try writer.writeAll("'\\''") else try writer.writeByte(c);
    try writer.writeByte('\'');
}

test {
    _ = prompt;
    _ = Draft;
    _ = Transcript;
}
