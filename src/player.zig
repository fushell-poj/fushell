//! Bundle player shared by the installed app runner and `fushell run`.

const std = @import("std");
const application_broker = @import("application_broker.zig");
const application_config = @import("application_config.zig");
const flutter_runner = @import("flutter_runner.zig");

comptime {
    _ = @import("surface_channel.zig");
}

const broker_cleanup_deadline_ns = std.time.ns_per_s;
const broker_cleanup_attempts: usize = 3;

fn cleanupBrokerWithRetry(broker: *application_broker.Broker, io: std.Io) !void {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.{ .nanoseconds = broker_cleanup_deadline_ns });
    var attempts: usize = 0;
    var last_error: ?anyerror = null;
    while (attempts < broker_cleanup_attempts) : (attempts += 1) {
        broker.deinit() catch |err| {
            last_error = err;
            if (attempts + 1 >= broker_cleanup_attempts) break;
            if (std.Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) break;
            std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real) catch {};
            continue;
        };
        return;
    }
    if (broker.initial_helper) |helper| {
        std.debug.print("[error] broker cleanup still owns helper pid {d} after {d} attempts\n", .{ helper.pid, attempts });
    }
    return last_error orelse error.BrokerCleanupFailed;
}

fn finishPlayerFailure(broker: ?*application_broker.Broker, io: std.Io, run_err: anyerror) !u8 {
    if (broker) |active_broker| {
        cleanupBrokerWithRetry(active_broker, io) catch |cleanup_err| {
            std.debug.print("[error] player failed: {s}; broker cleanup failed: {s}\n", .{ @errorName(run_err), @errorName(cleanup_err) });
            return error.RunAndCleanupFailed;
        };
    }
    return run_err;
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
            try std.Io.File.stderr().writeStreamingAll(io, result.stderr);
            return commandExitStatus(result.exit_code);
        },
    }
    const engine_library = resolveBundleEngineLibrary(gpa, bundle_path) catch |run_err| {
        return finishPlayerFailure(broker, io, run_err);
    };
    defer gpa.free(engine_library);

    flutter_runner.run(gpa, .{
        .io = io,
        .engine_library = engine_library,
        .bundle_path = bundle_path,
        .vm_service_port = vm_service_port,
        .shutdown_fd = shutdown_fd,
        .application_broker = broker,
        .dart_entrypoint_arguments = dart_entrypoint_arguments,
    }) catch |run_err| {
        return finishPlayerFailure(broker, io, run_err);
    };
    if (broker) |active_broker| {
        cleanupBrokerWithRetry(active_broker, io) catch |cleanup_err| return cleanup_err;
    }
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
