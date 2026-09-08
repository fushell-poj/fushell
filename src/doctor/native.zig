//! Isolated native/Flutter probes. They re-execute this exact CLI, not a shell or
//! an extra installed helper. The private entrypoint is not a public CLI command.
//! Isolation bounds blocking libdbus/Wayland/Flutter initialization and contains
//! native-library exits; the supervising doctor process always owns the report.
const std = @import("std");
const c = @import("c");
const Toolchain = @import("../flutter_toolchain.zig").Toolchain;
const process = @import("process.zig");
const Io = std.Io;
pub const marker = "--internal-doctor-probe";
pub const Kind = enum { flutter, wayland, dbus };
pub const Flutter = struct {
    executable: []u8,
    root: []u8,
    dart_executable: []u8,
    flutter_version: []u8,
    dart_version: []u8,
    engine_revision: []u8,
};
pub const Reply = struct {
    protocol: u32 = 1,
    code: []const u8,
    flutter: ?Flutter = null,
};

/// Called before public command parsing. No compatibility aliases or fallback.
pub fn entry(init: std.process.Init, args: []const []const u8) !?u8 {
    if (args.len == 0 or !std.mem.eql(u8, args[0], marker)) return null;
    if (args.len != 2) return 2;
    const kind = std.meta.stringToEnum(Kind, args[1]) orelse return 2;
    var out_buffer: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(init.io, &out_buffer);
    switch (kind) {
        .flutter => {
            var tools = Toolchain.discover(init.gpa, init.io, init.environ_map) catch |err| {
                try std.json.Stringify.value(Reply{ .code = @errorName(err) }, .{}, &out.interface);
                try out.interface.flush();
                return 0;
            };
            defer tools.deinit();
            try std.json.Stringify.value(Reply{ .code = "ok", .flutter = .{
                .executable = tools.executable,
                .root = tools.root,
                .dart_executable = tools.dart_executable,
                .flutter_version = tools.info.flutter_version,
                .dart_version = tools.info.dart_version,
                .engine_revision = tools.info.engine_revision,
            } }, .{}, &out.interface);
        },
        .wayland => try std.json.Stringify.value(Reply{ .code = wayland(init.environ_map) }, .{}, &out.interface),
        .dbus => try std.json.Stringify.value(Reply{ .code = try dbus(init) }, .{}, &out.interface),
    }
    try out.interface.flush();
    return 0;
}

/// Caller owns the parsed reply. Timeout and native process failure are distinct.
pub fn query(init: std.process.Init, kind: Kind) !std.json.Parsed(Reply) {
    const self = try std.process.executablePathAlloc(init.io, init.gpa);
    defer init.gpa.free(self);
    const result = try process.run(init.gpa, init.io, .{
        .argv = &.{ self, marker, @tagName(kind) },
        .environ = init.environ_map,
        .timeout_ms = if (kind == .flutter) 30_000 else 3_000,
    });
    defer process.deinit(init.gpa, result);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ProbeFailed,
        else => return error.ProbeFailed,
    }
    const parsed = try std.json.parseFromSlice(Reply, init.gpa, result.stdout, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.protocol != 1) return error.InvalidProbeProtocol;
    return parsed;
}

fn wayland(env: *const std.process.Environ.Map) []const u8 {
    // Never consume an inherited connection used by the invoking process.
    if (nonempty(env.get("WAYLAND_SOCKET")) != null) return "inherited_socket_not_probed";
    const display = nonempty(env.get("WAYLAND_DISPLAY")) orelse "wayland-0";
    if (!std.fs.path.isAbsolute(display) and nonempty(env.get("XDG_RUNTIME_DIR")) == null) return "not_configured";
    const connection = c.wl_display_connect(null) orelse return "connect_failed";
    defer c.wl_display_disconnect(connection);
    // A connection alone could be a stale/non-Wayland listener. Sync without
    // creating surfaces, EGL contexts, or binding optional global protocols.
    if (c.wl_display_roundtrip(connection) < 0) return "roundtrip_failed";
    return "ok";
}

fn dbus(init: std.process.Init) ![]const u8 {
    const env = init.environ_map;
    const a = init.arena.allocator();
    const address = nonempty(env.get("DBUS_SESSION_BUS_ADDRESS")) orelse blk: {
        const runtime = nonempty(env.get("XDG_RUNTIME_DIR")) orelse return "not_configured";
        const path = try std.fs.path.join(a, &.{ runtime, "bus" });
        // Use the conventional user bus only; never invoke dbus-launch/autolaunch.
        const escaped = c.dbus_address_escape_value(try a.dupeZ(u8, path)) orelse return error.OutOfMemory;
        defer c.dbus_free(escaped);
        break :blk try std.fmt.allocPrint(a, "unix:path={s}", .{std.mem.span(escaped)});
    };
    // libdbus can launch a daemon through this transport. Doctor is read-only.
    if (std.mem.indexOf(u8, address, "autolaunch:") != null) return "autolaunch_not_probed";
    const connection = c.dbus_connection_open_private(try a.dupeZ(u8, address), null) orelse return "connect_failed";
    defer c.dbus_connection_unref(connection);
    defer c.dbus_connection_close(connection);
    c.dbus_connection_set_exit_on_disconnect(connection, 0);
    if (c.dbus_bus_register(connection, null) == 0) return "register_failed";
    // Only the unique connection name is assigned; never request the app ID.
    if (c.dbus_connection_can_send_type(connection, c.DBUS_TYPE_UNIX_FD) == 0) return "unix_fd_unavailable";
    return "ok";
}

fn nonempty(value: ?[]const u8) ?[]const u8 {
    return if (value) |text| if (text.len > 0) text else null else null;
}
