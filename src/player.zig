//! Bundle player shared by the installed app runner and `fushell run`.

const std = @import("std");
const application_broker = @import("application_broker.zig");
const application_config = @import("application_config.zig");
const flutter_runner = @import("flutter_runner.zig");

comptime {
    _ = @import("surface_channel.zig");
}

/// Plays a bundle until its Dart process requests exit. Single-instance bundles
/// acquire their session-bus name before any Flutter or Wayland initialization;
/// secondary invocations forward argv/cwd and return the Dart handler's status.
pub fn runPlayer(
    gpa: std.mem.Allocator,
    io: std.Io,
    bundle_path: []const u8,
    vm_service_port: ?u16,
    shutdown_fd: c_int,
    application_arguments: []const []const u8,
    cwd: []const u8,
) !u8 {
    var config = try application_config.loadBundle(gpa, io, bundle_path);
    defer config.deinit(gpa);

    var broker: ?*application_broker.Broker = null;
    var dart_entrypoint_arguments = application_arguments;
    switch (try application_broker.Broker.open(
        gpa,
        io,
        config,
        application_arguments,
        cwd,
    )) {
        .disabled => {},
        .primary => |primary| {
            broker = primary;
            // Single-instance invocations use the application channel so the
            // initial and forwarded command share one Dart handler.
            dart_entrypoint_arguments = &.{};
        },
        .secondary => |result_value| {
            var result = result_value;
            defer result.deinit(gpa);
            try std.Io.File.stdout().writeStreamingAll(io, result.stdout);
            try std.Io.File.stderr().writeStreamingAll(io, result.stderr);
            return commandExitStatus(result.exit_code);
        },
    }
    defer if (broker) |active_broker| active_broker.deinit();

    const engine_library = try resolveBundleEngineLibrary(gpa, bundle_path);
    defer gpa.free(engine_library);

    try flutter_runner.run(gpa, .{
        .io = io,
        .engine_library = engine_library,
        .bundle_path = bundle_path,
        .vm_service_port = vm_service_port,
        .shutdown_fd = shutdown_fd,
        .application_broker = broker,
        .dart_entrypoint_arguments = dart_entrypoint_arguments,
    });
    return 0;
}

fn commandExitStatus(exit_code: i32) u8 {
    return if (exit_code >= 0 and exit_code <= std.math.maxInt(u8))
        @intCast(exit_code)
    else
        1;
}

fn resolveBundleEngineLibrary(gpa: std.mem.Allocator, bundle_path: []const u8) ![]const u8 {
    const engine_library = try std.fs.path.join(gpa, &.{ bundle_path, "lib", "libflutter_engine.so" });
    errdefer gpa.free(engine_library);

    if (!try pathExists(gpa, engine_library)) {
        std.debug.print("Flutter engine library is missing from the app bundle.\n", .{});
        std.debug.print("Expected: {s}\n", .{engine_library});
        return error.MissingFlutterEngineLibrary;
    }

    return engine_library;
}

fn pathExists(gpa: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    return std.c.access(path_z.ptr, std.c.F_OK) == 0;
}
