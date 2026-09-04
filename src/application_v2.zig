//! Application2 的 D-Bus wire helpers。
//!
//! 本模块只处理消息签名、UNIX_FD 参数和无 FD 的终态 reply；它不持有 request
//! message，也不把 message 生命周期当作 output endpoint 的 owner。

const std = @import("std");
const c = @import("c");

pub const interface_name = "dev.fushell.Application2";
pub const legacy_interface_name = "dev.fushell.Application1";
pub const object_path = "/dev/fushell/Application";
pub const command_method = "CommandLine";
pub const protocol_method = "GetProtocolVersion";
pub const protocol_version: u32 = 2;
pub const dbus_daemon_name = "org.freedesktop.DBus";
pub const dbus_daemon_path = "/org/freedesktop/DBus";
pub const dbus_daemon_interface = "org.freedesktop.DBus";
pub const get_name_owner_method = "GetNameOwner";

pub const Error = error{
    InvalidArguments,
    InvalidReply,
    MissingUnixFd,
    InvalidUnixFd,
    AppendFailed,
    MessageCreateFailed,
    ProtocolMismatch,
    InvalidTerminalKind,
};

pub const Command = struct {
    payload: []const u8,
    /// dbus_message_iter_get_basic 返回的独立 CLOEXEC 副本；调用方拥有并必须关闭。
    owned_output_fd: c_int,
};

pub const TerminalKind = enum(u32) {
    completed = 0,
    timed_out = 1,
};

pub const FinalReply = struct {
    terminal_kind: TerminalKind,
    exit_code: i32,
    frame_count: u64,
    stdout_bytes: u64,
    stderr_bytes: u64,
};

pub fn requireUnixFdCapability(supported: bool) !void {
    if (!supported) return error.UnixFdUnsupported;
}

pub fn canSendUnixFds(connection: *c.DBusConnection) bool {
    return c.dbus_connection_can_send_type(connection, c.DBUS_TYPE_UNIX_FD) != 0;
}

pub fn newGetNameOwnerMessage(bus_name: [:0]const u8) Error!*c.DBusMessage {
    const message = c.dbus_message_new_method_call(
        dbus_daemon_name,
        dbus_daemon_path,
        dbus_daemon_interface,
        get_name_owner_method,
    ) orelse return error.MessageCreateFailed;
    errdefer c.dbus_message_unref(message);

    var iterator: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iterator);
    var name = bus_name.ptr;
    if (c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_STRING, @ptrCast(&name)) == 0)
        return error.AppendFailed;
    return message;
}

pub fn newProtocolMessage(destination: [:0]const u8) Error!*c.DBusMessage {
    return c.dbus_message_new_method_call(
        destination.ptr,
        object_path,
        interface_name,
        protocol_method,
    ) orelse error.MessageCreateFailed;
}

/// append UNIX_FD 成功后，message 持有 internal FD 副本；caller 仍拥有原 `output_fd`，可立即关闭它。
pub fn newCommandMessage(destination: [:0]const u8, payload: []const u8, output_fd: c_int) Error!*c.DBusMessage {
    const message = c.dbus_message_new_method_call(
        destination.ptr,
        object_path,
        interface_name,
        command_method,
    ) orelse return error.MessageCreateFailed;
    errdefer c.dbus_message_unref(message);

    var iterator: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iterator);
    try appendByteArray(&iterator, payload);
    var fd = output_fd;
    if (c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_UNIX_FD, &fd) == 0)
        return error.AppendFailed;
    return message;
}

/// 验证完整 `ay,h` 结构后，取得由 libdbus 新建的 caller-owned CLOEXEC FD。
/// get_basic 之后不再执行可能失败的结构检查；返回值由调用方 exactly once 关闭。
pub fn readCommand(message: *c.DBusMessage) Error!Command {
    var iterator: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iterator) == 0 or
        c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_ARRAY or
        c.dbus_message_iter_get_element_type(&iterator) != c.DBUS_TYPE_BYTE)
        return error.InvalidArguments;

    var array: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&iterator, &array);
    var payload: [*c]const u8 = null;
    var length: c_int = 0;
    c.dbus_message_iter_get_fixed_array(&array, @ptrCast(&payload), &length);
    if (length < 0) return error.InvalidArguments;
    if (payload == null and length != 0) return error.InvalidArguments;
    if (c.dbus_message_iter_next(&iterator) == 0 or
        c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_UNIX_FD)
        return error.MissingUnixFd;
    var trailing_check = iterator;
    if (c.dbus_message_iter_next(&trailing_check) != 0) return error.InvalidArguments;

    var output_fd: c_int = -1;
    c.dbus_message_iter_get_basic(&iterator, &output_fd);
    if (output_fd < 0) return error.InvalidUnixFd;
    return .{
        .payload = if (length == 0) &.{} else payload[0..@intCast(length)],
        .owned_output_fd = output_fd,
    };
}

pub fn newReply(request: *c.DBusMessage) Error!*c.DBusMessage {
    return c.dbus_message_new_method_return(request) orelse error.MessageCreateFailed;
}

pub fn appendProtocolReply(message: *c.DBusMessage) Error!void {
    var iterator: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iterator);
    var version = protocol_version;
    if (c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_UINT32, &version) == 0)
        return error.AppendFailed;
}

pub fn parseProtocolReply(message: *c.DBusMessage) Error!u32 {
    var iterator: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iterator) == 0 or
        c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_UINT32)
        return error.InvalidReply;
    var version: u32 = 0;
    c.dbus_message_iter_get_basic(&iterator, &version);
    if (c.dbus_message_iter_next(&iterator) != 0 or version != protocol_version)
        return error.ProtocolMismatch;
    return version;
}

pub fn appendFinalReply(message: *c.DBusMessage, reply: FinalReply) Error!void {
    var iterator: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iterator);
    var terminal_kind = @intFromEnum(reply.terminal_kind);
    var exit_code = reply.exit_code;
    var frame_count = reply.frame_count;
    var stdout_bytes = reply.stdout_bytes;
    var stderr_bytes = reply.stderr_bytes;
    if (c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_UINT32, &terminal_kind) == 0 or
        c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_INT32, &exit_code) == 0 or
        c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_UINT64, &frame_count) == 0 or
        c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_UINT64, &stdout_bytes) == 0 or
        c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_UINT64, &stderr_bytes) == 0)
        return error.AppendFailed;
}

pub fn parseFinalReply(message: *c.DBusMessage) Error!FinalReply {
    var iterator: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iterator) == 0 or
        c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_UINT32)
        return error.InvalidReply;
    var terminal_value: u32 = 0;
    c.dbus_message_iter_get_basic(&iterator, &terminal_value);
    const terminal_kind: TerminalKind = switch (terminal_value) {
        0 => .completed,
        1 => .timed_out,
        else => return error.InvalidTerminalKind,
    };
    var reply = FinalReply{ .terminal_kind = terminal_kind, .exit_code = 0, .frame_count = 0, .stdout_bytes = 0, .stderr_bytes = 0 };
    if (c.dbus_message_iter_next(&iterator) == 0 or c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_INT32)
        return error.InvalidReply;
    c.dbus_message_iter_get_basic(&iterator, &reply.exit_code);
    if (c.dbus_message_iter_next(&iterator) == 0 or c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_UINT64)
        return error.InvalidReply;
    c.dbus_message_iter_get_basic(&iterator, &reply.frame_count);
    if (c.dbus_message_iter_next(&iterator) == 0 or c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_UINT64)
        return error.InvalidReply;
    c.dbus_message_iter_get_basic(&iterator, &reply.stdout_bytes);
    if (c.dbus_message_iter_next(&iterator) == 0 or c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_UINT64)
        return error.InvalidReply;
    c.dbus_message_iter_get_basic(&iterator, &reply.stderr_bytes);
    if (c.dbus_message_iter_next(&iterator) != 0) return error.InvalidReply;
    return reply;
}

pub fn errorName(message: *c.DBusMessage) ?[]const u8 {
    const name = c.dbus_message_get_error_name(message) orelse return null;
    return std.mem.span(name);
}

fn appendByteArray(iterator: *c.DBusMessageIter, bytes: []const u8) Error!void {
    var array: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(iterator, c.DBUS_TYPE_ARRAY, "y", &array) == 0)
        return error.AppendFailed;
    var pointer: [*c]const u8 = if (bytes.len == 0) null else bytes.ptr;
    if (c.dbus_message_iter_append_fixed_array(&array, c.DBUS_TYPE_BYTE, @ptrCast(&pointer), @intCast(bytes.len)) == 0) {
        c.dbus_message_iter_abandon_container(iterator, &array);
        return error.AppendFailed;
    }
    if (c.dbus_message_iter_close_container(iterator, &array) == 0)
        return error.AppendFailed;
}

fn countOpenFds(io: std.Io) !usize {
    var directory = try std.Io.Dir.openDirAbsolute(io, "/proc/self/fd", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn openTestFd() !c_int {
    const fd = std.os.linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    return @intCast(fd);
}

test "missing UNIX_FD capability is a deterministic error" {
    try std.testing.expectError(error.UnixFdUnsupported, requireUnixFdCapability(false));
    try requireUnixFdCapability(true);
}

test "trailing V2 arguments are rejected before get_basic" {
    const input_fd = try openTestFd();
    defer _ = std.os.linux.close(input_fd);
    const message = try newCommandMessage("dev.fushell.Test", "binary", input_fd);
    defer c.dbus_message_unref(message);

    var iterator: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iterator);
    var trailing: [*:0]const u8 = "trailing";
    try std.testing.expect(c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_STRING, @ptrCast(&trailing)) != 0);
    const before = try countOpenFds(std.testing.io);
    try std.testing.expectError(error.InvalidArguments, readCommand(message));
    try std.testing.expectEqual(before, try countOpenFds(std.testing.io));
}

test "get_basic returns an owned FD independent of message and caller input" {
    const input_fd = try openTestFd();
    defer _ = std.os.linux.close(input_fd);
    const baseline = try countOpenFds(std.testing.io);
    const message = try newCommandMessage("dev.fushell.Test", "binary", input_fd);
    var message_released = false;
    defer if (!message_released) c.dbus_message_unref(message);

    const command = try readCommand(message);
    var owned_fd = command.owned_output_fd;
    defer {
        if (owned_fd >= 0) _ = std.os.linux.close(owned_fd);
    }
    try std.testing.expect(owned_fd >= 0);
    try std.testing.expect(owned_fd != input_fd);
    try std.testing.expectEqualSlices(u8, "binary", command.payload);
    try std.testing.expect(c.dbus_message_contains_unix_fds(message) != 0);

    c.dbus_message_unref(message);
    message_released = true;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fcntl(input_fd, std.os.linux.F.GETFD, 0)));
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fcntl(owned_fd, std.os.linux.F.GETFD, 0)));
    _ = std.os.linux.close(owned_fd);
    owned_fd = -1;
    try std.testing.expectEqual(baseline, try countOpenFds(std.testing.io));
}

test "message unref cannot close an FD number reused by the caller" {
    const input_fd = try openTestFd();
    defer _ = std.os.linux.close(input_fd);
    const baseline = try countOpenFds(std.testing.io);
    const message = try newCommandMessage("dev.fushell.Test", "binary", input_fd);
    var message_released = false;
    defer if (!message_released) c.dbus_message_unref(message);

    const command = try readCommand(message);
    const owned_fd = command.owned_output_fd;
    _ = std.os.linux.close(owned_fd);
    const replacement_fd = try openTestFd();
    defer _ = std.os.linux.close(replacement_fd);
    try std.testing.expectEqual(owned_fd, replacement_fd);

    c.dbus_message_unref(message);
    message_released = true;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fcntl(replacement_fd, std.os.linux.F.GETFD, 0)));
    _ = std.os.linux.close(replacement_fd);
    try std.testing.expectEqual(baseline, try countOpenFds(std.testing.io));
}

test "V2 final reply is exactly u i t t t" {
    const request = c.dbus_message_new_method_call("dev.fushell.Test", object_path, interface_name, command_method) orelse return error.MessageCreateFailed;
    c.dbus_message_set_serial(request, 1);
    defer c.dbus_message_unref(request);
    const reply = try newReply(request);
    defer c.dbus_message_unref(reply);
    try appendFinalReply(reply, .{ .terminal_kind = .completed, .exit_code = 7, .frame_count = 2, .stdout_bytes = 3, .stderr_bytes = 4 });
    const parsed = try parseFinalReply(reply);
    try std.testing.expectEqual(TerminalKind.completed, parsed.terminal_kind);
    try std.testing.expectEqual(@as(i32, 7), parsed.exit_code);
    try std.testing.expectEqual(@as(u64, 2), parsed.frame_count);
    try std.testing.expectEqual(@as(u64, 3), parsed.stdout_bytes);
    try std.testing.expectEqual(@as(u64, 4), parsed.stderr_bytes);
}
