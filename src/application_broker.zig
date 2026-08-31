//! 基于会话 D-Bus 实现的原生单实例代理。
//!
//! 名称所有权在 Flutter、Wayland 和 EGL 初始化之前确定，因此 secondary
//! 调用只需作为轻量运输进程存在。primary 独占一条私有 D-Bus 连接，并将
//! watch/timeout 合并到 Fushell 平台线程的事件泵；工作线程不得修改代理状态。
//!
//! 代理有意把 argv 和 cwd 视为字节串。Dart 接收无损十六进制表示，自行定义
//! 全部命令语义，并异步完成被保留的 D-Bus 方法调用。即使 Dart handler 停滞，
//! 队列、载荷和回复上限也能限制内存占用与等待时间。

const std = @import("std");
const c = @import("c");
const application_config = @import("application_config.zig");

pub const object_path = "/dev/fushell/Application";
pub const interface_name = "dev.fushell.Application1";
pub const command_method = "CommandLine";
pub const command_timeout_ms: i32 = 30_000;
pub const cancellation_grace_ms: i32 = 2_000;
const client_timeout_ms: i32 = command_timeout_ms + 5_000;
const max_invocation_payload_size = 8 * 1024 * 1024;

/// 跨进程返回的应用命令完成结果。
///
/// 两个输出缓冲区均由该值拥有；D-Bus 回复或 secondary 的 stdout/stderr
/// 复制完成后必须调用 [deinit]。
pub const CommandResult = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandResult, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

/// 排入 Dart 应用 handler 的无损调用。
///
/// `arguments` 不包含 argv[0]；其中每个切片以及 `cwd` 均由分配器拥有。
/// `is_initial` 区分创建 daemon 的首次命令与 secondary 进程发来的命令，
/// 使应用无需维护两套参数解析器。
pub const InvocationData = struct {
    id: u64,
    arguments: [][]u8,
    cwd: []u8,
    is_initial: bool,

    pub fn deinit(self: *InvocationData, gpa: std.mem.Allocator) void {
        for (self.arguments) |argument| gpa.free(argument);
        gpa.free(self.arguments);
        gpa.free(self.cwd);
        self.* = undefined;
    }
};

const QueuedInvocation = struct {
    data: InvocationData,
    message: ?*c.DBusMessage,
    deadline: std.Io.Timestamp,
    /// 调用方已收到超时回复，但 Dart 仍拥有此回调。宽限期内保留 active 槽，
    /// 既避免 handler 重入，也允许协作取消完成清理。
    replied: bool = false,
    cancellation_deadline: ?std.Io.Timestamp = null,

    fn deinit(self: *QueuedInvocation, gpa: std.mem.Allocator) void {
        self.data.deinit(gpa);
        if (self.message) |message| c.dbus_message_unref(message);
        self.* = undefined;
    }
};

const CommandTimeoutAction = enum {
    none,
    timeout,
    restart,
};

fn commandTimeoutAction(invocation: QueuedInvocation, now: std.Io.Timestamp) CommandTimeoutAction {
    if (!invocation.replied)
        return if (now.nanoseconds >= invocation.deadline.nanoseconds) .timeout else .none;
    const cancellation_deadline = invocation.cancellation_deadline orelse return .none;
    return if (now.nanoseconds >= cancellation_deadline.nanoseconds) .restart else .none;
}

fn recoveryCommandResult() CommandResult {
    return .{
        .exit_code = 75,
        .stdout = @constCast(&[_]u8{}),
        .stderr = @constCast("application daemon is restarting after an unresponsive command\n"),
    };
}

const TimeoutEntry = struct {
    timeout: *c.DBusTimeout,
    deadline: std.Io.Timestamp,
};

/// 引擎启动前完成的实例所有权判定结果。
///
/// `.disabled` 保留普通多实例启动；`.secondary` 表示命令已由 primary 完成，
/// 调用方应输出返回流并退出，不得初始化 Flutter 或图形栈。
pub const OpenResult = union(enum) {
    disabled,
    primary: *Broker,
    secondary: CommandResult,
};

/// primary 进程中的 D-Bus 状态机。
///
/// 除 [open] 和 secondary 转发路径外，所有方法都只能在 Flutter 平台线程调用。
/// D-Bus 方法消息会一直保留到 Dart 完成；超时命令仍占用 active 槽，直到迟到的
/// completion 到达，以维持“同一时刻最多一个 handler 活跃”的不变量。
pub const Broker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    connection: *c.DBusConnection,
    bus_name: [:0]u8,
    watches: std.ArrayList(*c.DBusWatch) = .empty,
    timeouts: std.ArrayList(TimeoutEntry) = .empty,
    queued: std.ArrayList(QueuedInvocation) = .empty,
    active: ?QueuedInvocation = null,
    cancellation_request: ?u64 = null,
    recovery_exit_requested: bool = false,
    next_id: u64 = 1,

    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        config: application_config.Config,
        arguments: []const []const u8,
        cwd: []const u8,
    ) !OpenResult {
        if (config.instance == .multiple) return .disabled;
        const application_id = config.application_id orelse return error.ApplicationIdRequired;
        const bus_name = try gpa.dupeZ(u8, application_id);
        errdefer gpa.free(bus_name);

        const connection = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, null) orelse
            return error.SessionBusUnavailable;
        errdefer {
            c.dbus_connection_close(connection);
            c.dbus_connection_unref(connection);
        }
        c.dbus_connection_set_exit_on_disconnect(connection, 0);

        const request_result = c.dbus_bus_request_name(
            connection,
            bus_name.ptr,
            c.DBUS_NAME_FLAG_DO_NOT_QUEUE,
            null,
        );
        switch (request_result) {
            c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER, c.DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER => {
                const broker = try gpa.create(Broker);
                errdefer gpa.destroy(broker);
                broker.* = .{
                    .gpa = gpa,
                    .io = io,
                    .connection = connection,
                    .bus_name = bus_name,
                };
                errdefer broker.deinit();
                try broker.installCallbacks();
                try broker.enqueueLocal(arguments, cwd);
                return .{ .primary = broker };
            },
            c.DBUS_REQUEST_NAME_REPLY_EXISTS => {
                const result = try forwardCommand(gpa, connection, bus_name, arguments, cwd);
                c.dbus_connection_close(connection);
                c.dbus_connection_unref(connection);
                gpa.free(bus_name);
                return .{ .secondary = result };
            },
            c.DBUS_REQUEST_NAME_REPLY_IN_QUEUE => return error.UnexpectedDbusNameQueue,
            else => return error.DBusRequestNameFailed,
        }
    }

    pub fn deinit(self: *Broker) void {
        c.dbus_connection_remove_filter(self.connection, filterCallback, self);
        _ = c.dbus_connection_set_watch_functions(self.connection, null, null, null, null, null);
        _ = c.dbus_connection_set_timeout_functions(self.connection, null, null, null, null, null);

        if (self.active) |*active| active.deinit(self.gpa);
        for (self.queued.items) |*invocation| invocation.deinit(self.gpa);
        self.queued.deinit(self.gpa);
        self.watches.deinit(self.gpa);
        self.timeouts.deinit(self.gpa);
        c.dbus_connection_close(self.connection);
        c.dbus_connection_unref(self.connection);
        self.gpa.free(self.bus_name);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    pub fn pollFdCount(self: *const Broker) usize {
        var count: usize = 0;
        for (self.watches.items) |watch| {
            if (c.dbus_watch_get_enabled(watch) != 0) count += 1;
        }
        return count;
    }

    pub fn fillPollFds(self: *Broker, destination: []std.posix.pollfd) usize {
        var count: usize = 0;
        for (self.watches.items) |watch| {
            if (count == destination.len or c.dbus_watch_get_enabled(watch) == 0) continue;
            destination[count] = .{
                .fd = c.dbus_watch_get_unix_fd(watch),
                .events = watchPollEvents(watch),
                .revents = 0,
            };
            count += 1;
        }
        return count;
    }

    pub fn handlePollFds(self: *Broker, ready: []const std.posix.pollfd) !void {
        var ready_index: usize = 0;
        for (self.watches.items) |watch| {
            if (c.dbus_watch_get_enabled(watch) == 0) continue;
            if (ready_index >= ready.len) break;
            const revents = ready[ready_index].revents;
            ready_index += 1;
            if (revents == 0) continue;
            if (c.dbus_watch_handle(watch, pollDbusFlags(revents)) == 0)
                return error.DBusWatchHandleFailed;
        }
        try self.dispatchAvailable();
    }

    pub fn nextTimeoutMs(self: *Broker) i32 {
        const now = std.Io.Clock.awake.now(self.io);
        var result: i32 = -1;
        for (self.timeouts.items) |entry| {
            if (c.dbus_timeout_get_enabled(entry.timeout) == 0) continue;
            result = minimumTimeout(result, deadlineTimeoutMs(now, entry.deadline));
        }
        if (self.active) |active| {
            if (!active.replied) {
                result = minimumTimeout(result, deadlineTimeoutMs(now, active.deadline));
            } else if (active.cancellation_deadline) |deadline| {
                result = minimumTimeout(result, deadlineTimeoutMs(now, deadline));
            }
        }
        for (self.queued.items) |queued| {
            result = minimumTimeout(result, deadlineTimeoutMs(now, queued.deadline));
        }
        return result;
    }

    pub fn pump(self: *Broker) !void {
        try self.handleExpiredTimeouts();
        try self.dispatchAvailable();
    }

    pub fn nextInvocation(self: *Broker) ?*const InvocationData {
        if (self.active != null or self.queued.items.len == 0) return null;
        self.active = self.queued.orderedRemove(0);
        return &self.active.?.data;
    }

    pub fn hasActiveInvocation(self: *const Broker) bool {
        return self.active != null;
    }

    /// 返回一次待发送给 Dart handler 的协作取消请求。
    pub fn takeCancellationRequest(self: *Broker) ?u64 {
        const request = self.cancellation_request;
        self.cancellation_request = null;
        return request;
    }

    /// handler 未在取消宽限期内结束时，要求 runner 进入既有有序关闭流程。
    pub fn recoveryExitRequested(self: *const Broker) bool {
        return self.recovery_exit_requested;
    }

    pub fn complete(self: *Broker, id: u64, result: CommandResult) !void {
        var active = self.active orelse return error.NoActiveInvocation;
        if (active.data.id != id) return error.InvocationIdMismatch;
        self.active = null;
        defer active.deinit(self.gpa);
        if (!active.replied) try self.finishInvocation(active, result);
    }

    pub fn failPending(self: *Broker, message: []const u8) void {
        const stderr = self.gpa.dupe(u8, message) catch return;
        defer self.gpa.free(stderr);
        const empty = &[_]u8{};
        const result = CommandResult{
            .exit_code = 125,
            .stdout = @constCast(empty),
            .stderr = stderr,
        };
        if (self.active) |active| {
            if (!active.replied) {
                if (active.message) |dbus_message| sendCommandReply(self.connection, dbus_message, result) catch {};
            }
        }
        for (self.queued.items) |queued| {
            if (queued.message) |dbus_message| sendCommandReply(self.connection, dbus_message, result) catch {};
        }
    }

    fn installCallbacks(self: *Broker) !void {
        if (c.dbus_connection_set_watch_functions(
            self.connection,
            addWatchCallback,
            removeWatchCallback,
            toggleWatchCallback,
            self,
            null,
        ) == 0) return error.DBusWatchSetupFailed;
        errdefer _ = c.dbus_connection_set_watch_functions(self.connection, null, null, null, null, null);

        if (c.dbus_connection_set_timeout_functions(
            self.connection,
            addTimeoutCallback,
            removeTimeoutCallback,
            toggleTimeoutCallback,
            self,
            null,
        ) == 0) return error.DBusTimeoutSetupFailed;
        errdefer _ = c.dbus_connection_set_timeout_functions(self.connection, null, null, null, null, null);

        if (c.dbus_connection_add_filter(self.connection, filterCallback, self, null) == 0)
            return error.DBusFilterSetupFailed;
    }

    fn enqueueLocal(self: *Broker, arguments: []const []const u8, cwd: []const u8) !void {
        const data = try cloneInvocationData(self.gpa, self.next_id, arguments, cwd, true);
        self.next_id += 1;
        errdefer {
            var owned = data;
            owned.deinit(self.gpa);
        }
        try self.queued.append(self.gpa, .{
            .data = data,
            .message = null,
            .deadline = commandDeadline(self.io),
        });
    }

    fn enqueueRemote(self: *Broker, message: *c.DBusMessage, payload: []const u8) !void {
        const decoded = try decodeInvocation(self.gpa, self.next_id, payload);
        self.next_id += 1;
        errdefer {
            var owned = decoded;
            owned.deinit(self.gpa);
        }
        const referenced = c.dbus_message_ref(message) orelse return error.DBusMessageRefFailed;
        errdefer c.dbus_message_unref(referenced);
        try self.queued.append(self.gpa, .{
            .data = decoded,
            .message = referenced,
            .deadline = commandDeadline(self.io),
        });
    }

    fn dispatchAvailable(self: *Broker) !void {
        while (true) {
            const status = c.dbus_connection_dispatch(self.connection);
            if (status == c.DBUS_DISPATCH_COMPLETE) {
                if (c.dbus_connection_get_is_connected(self.connection) == 0)
                    return error.SessionBusDisconnected;
                return;
            }
            if (status == c.DBUS_DISPATCH_NEED_MEMORY) return error.DBusDispatchOutOfMemory;
        }
    }

    fn handleExpiredTimeouts(self: *Broker) !void {
        const now = std.Io.Clock.awake.now(self.io);
        for (self.timeouts.items) |*entry| {
            if (c.dbus_timeout_get_enabled(entry.timeout) == 0 or now.nanoseconds < entry.deadline.nanoseconds) continue;
            if (c.dbus_timeout_handle(entry.timeout) == 0) return error.DBusTimeoutHandleFailed;
            entry.deadline = timeoutDeadline(self.io, entry.timeout);
        }

        const empty = &[_]u8{};
        const timeout_result = CommandResult{
            .exit_code = 124,
            .stdout = @constCast(empty),
            .stderr = @constCast("command timed out\n"),
        };

        if (self.active) |*active| {
            switch (commandTimeoutAction(active.*, now)) {
                .none => {},
                .timeout => {
                    active.replied = true;
                    active.cancellation_deadline = cancellationDeadline(now);
                    self.cancellation_request = active.data.id;
                    self.finishInvocation(active.*, timeout_result) catch |err| {
                        std.debug.print("[error] failed to send command timeout reply: {s}\n", .{@errorName(err)});
                    };
                },
                .restart => {
                    active.cancellation_deadline = null;
                    self.recovery_exit_requested = true;
                    self.rejectQueuedForRecovery();
                },
            }
        }

        var index: usize = 0;
        while (index < self.queued.items.len) {
            if (now.nanoseconds < self.queued.items[index].deadline.nanoseconds) {
                index += 1;
                continue;
            }
            var expired = self.queued.orderedRemove(index);
            defer expired.deinit(self.gpa);
            self.finishInvocation(expired, timeout_result) catch |err| {
                std.debug.print("[error] failed to send queued command timeout reply: {s}\n", .{@errorName(err)});
            };
        }
    }

    fn rejectQueuedForRecovery(self: *Broker) void {
        const result = recoveryCommandResult();
        while (self.queued.items.len > 0) {
            var queued = self.queued.orderedRemove(0);
            defer queued.deinit(self.gpa);
            self.finishInvocation(queued, result) catch {};
        }
    }

    fn finishInvocation(self: *Broker, invocation: QueuedInvocation, result: CommandResult) !void {
        if (invocation.message) |message| {
            try sendCommandReply(self.connection, message, result);
        } else {
            if (result.stdout.len > 0)
                std.Io.File.stdout().writeStreamingAll(self.io, result.stdout) catch {};
            if (result.stderr.len > 0)
                std.Io.File.stderr().writeStreamingAll(self.io, result.stderr) catch {};
        }
    }
};

fn forwardCommand(
    gpa: std.mem.Allocator,
    connection: *c.DBusConnection,
    bus_name: [:0]const u8,
    arguments: []const []const u8,
    cwd: []const u8,
) !CommandResult {
    const payload = try encodeInvocation(gpa, arguments, cwd);
    defer gpa.free(payload);

    const message = c.dbus_message_new_method_call(
        bus_name.ptr,
        object_path,
        interface_name,
        command_method,
    ) orelse return error.DBusMessageCreateFailed;
    defer c.dbus_message_unref(message);
    try appendByteArray(message, payload);

    // The secondary process does no Flutter or Wayland work, so a blocking
    // D-Bus call is appropriate. Restore the default terminal signal behavior
    // first: SIGINT/SIGTERM then interrupt the process immediately instead of
    // being consumed by the primary runner's signalfd policy.
    var termination_signals = std.posix.sigemptyset();
    std.posix.sigaddset(&termination_signals, std.posix.SIG.INT);
    std.posix.sigaddset(&termination_signals, std.posix.SIG.TERM);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &termination_signals, null);

    const reply = c.dbus_connection_send_with_reply_and_block(
        connection,
        message,
        client_timeout_ms,
        null,
    ) orelse return error.DBusCommandFailed;
    defer c.dbus_message_unref(reply);
    return parseCommandReply(gpa, reply);
}

fn filterCallback(
    _: ?*c.DBusConnection,
    message_optional: ?*c.DBusMessage,
    user_data: ?*anyopaque,
) callconv(.c) c.DBusHandlerResult {
    const message = message_optional orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    const broker: *Broker = @ptrCast(@alignCast(user_data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const path = c.dbus_message_get_path(message);
    if (path == null or !std.mem.eql(u8, std.mem.span(path), object_path))
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (c.dbus_message_is_method_call(message, interface_name, command_method) == 0)
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    if (broker.recovery_exit_requested) {
        sendCommandReply(broker.connection, message, recoveryCommandResult()) catch {};
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }

    const payload = readByteArray(message) catch {
        sendErrorReply(broker.connection, message, "dev.fushell.Error.InvalidCommand", "invalid command payload");
        return c.DBUS_HANDLER_RESULT_HANDLED;
    };
    broker.enqueueRemote(message, payload) catch |err| {
        if (err == error.OutOfMemory) return c.DBUS_HANDLER_RESULT_NEED_MEMORY;
        sendErrorReply(broker.connection, message, "dev.fushell.Error.InvalidCommand", "invalid command payload");
    };
    return c.DBUS_HANDLER_RESULT_HANDLED;
}

fn addWatchCallback(watch_optional: ?*c.DBusWatch, data: ?*anyopaque) callconv(.c) c.dbus_bool_t {
    const watch = watch_optional orelse return 0;
    const broker: *Broker = @ptrCast(@alignCast(data orelse return 0));
    broker.watches.append(broker.gpa, watch) catch return 0;
    return 1;
}

fn removeWatchCallback(watch_optional: ?*c.DBusWatch, data: ?*anyopaque) callconv(.c) void {
    const watch = watch_optional orelse return;
    const broker: *Broker = @ptrCast(@alignCast(data orelse return));
    for (broker.watches.items, 0..) |candidate, index| {
        if (candidate == watch) {
            _ = broker.watches.orderedRemove(index);
            return;
        }
    }
}

fn toggleWatchCallback(_: ?*c.DBusWatch, _: ?*anyopaque) callconv(.c) void {}

fn addTimeoutCallback(timeout_optional: ?*c.DBusTimeout, data: ?*anyopaque) callconv(.c) c.dbus_bool_t {
    const timeout = timeout_optional orelse return 0;
    const broker: *Broker = @ptrCast(@alignCast(data orelse return 0));
    broker.timeouts.append(broker.gpa, .{
        .timeout = timeout,
        .deadline = timeoutDeadline(broker.io, timeout),
    }) catch return 0;
    return 1;
}

fn removeTimeoutCallback(timeout_optional: ?*c.DBusTimeout, data: ?*anyopaque) callconv(.c) void {
    const timeout = timeout_optional orelse return;
    const broker: *Broker = @ptrCast(@alignCast(data orelse return));
    for (broker.timeouts.items, 0..) |entry, index| {
        if (entry.timeout == timeout) {
            _ = broker.timeouts.orderedRemove(index);
            return;
        }
    }
}

fn toggleTimeoutCallback(timeout_optional: ?*c.DBusTimeout, data: ?*anyopaque) callconv(.c) void {
    const timeout = timeout_optional orelse return;
    const broker: *Broker = @ptrCast(@alignCast(data orelse return));
    for (broker.timeouts.items) |*entry| {
        if (entry.timeout == timeout) {
            entry.deadline = timeoutDeadline(broker.io, timeout);
            return;
        }
    }
}

fn watchPollEvents(watch: *c.DBusWatch) i16 {
    const flags = c.dbus_watch_get_flags(watch);
    var events: i16 = 0;
    if (flags & c.DBUS_WATCH_READABLE != 0) events |= std.posix.POLL.IN;
    if (flags & c.DBUS_WATCH_WRITABLE != 0) events |= std.posix.POLL.OUT;
    return events;
}

fn pollDbusFlags(revents: i16) c_uint {
    var flags: c_uint = 0;
    if (revents & std.posix.POLL.IN != 0) flags |= c.DBUS_WATCH_READABLE;
    if (revents & std.posix.POLL.OUT != 0) flags |= c.DBUS_WATCH_WRITABLE;
    if (revents & std.posix.POLL.ERR != 0) flags |= c.DBUS_WATCH_ERROR;
    if (revents & std.posix.POLL.HUP != 0) flags |= c.DBUS_WATCH_HANGUP;
    return flags;
}

fn timeoutDeadline(io: std.Io, timeout: *c.DBusTimeout) std.Io.Timestamp {
    const interval_ms: u64 = @intCast(@max(c.dbus_timeout_get_interval(timeout), 0));
    return std.Io.Clock.awake.now(io).addDuration(std.Io.Duration.fromMilliseconds(@intCast(interval_ms)));
}

fn commandDeadline(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io).addDuration(std.Io.Duration.fromMilliseconds(command_timeout_ms));
}

fn cancellationDeadline(now: std.Io.Timestamp) std.Io.Timestamp {
    return now.addDuration(std.Io.Duration.fromMilliseconds(cancellation_grace_ms));
}

fn deadlineTimeoutMs(now: std.Io.Timestamp, deadline: std.Io.Timestamp) i32 {
    if (now.nanoseconds >= deadline.nanoseconds) return 0;
    const remaining_ns: u64 = @intCast(deadline.nanoseconds - now.nanoseconds);
    const rounded_ms = @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(@min(rounded_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
}

fn minimumTimeout(current: i32, candidate: i32) i32 {
    if (current < 0) return candidate;
    return @min(current, candidate);
}

fn cloneInvocationData(
    gpa: std.mem.Allocator,
    id: u64,
    arguments: []const []const u8,
    cwd: []const u8,
    is_initial: bool,
) !InvocationData {
    const owned_arguments = try gpa.alloc([]u8, arguments.len);
    errdefer gpa.free(owned_arguments);
    var initialized: usize = 0;
    errdefer for (owned_arguments[0..initialized]) |argument| gpa.free(argument);
    for (arguments, 0..) |argument, index| {
        owned_arguments[index] = try gpa.dupe(u8, argument);
        initialized += 1;
    }
    return .{
        .id = id,
        .arguments = owned_arguments,
        .cwd = try gpa.dupe(u8, cwd),
        .is_initial = is_initial,
    };
}

/// 将 argv/cwd 编码为 D-Bus 方法使用的有界二进制载荷。
/// 长度前缀采用小端序，并保留内嵌 NUL 与非 UTF-8 字节。
pub fn encodeInvocation(gpa: std.mem.Allocator, arguments: []const []const u8, cwd: []const u8) ![]u8 {
    if (arguments.len > std.math.maxInt(u32) or cwd.len > std.math.maxInt(u32))
        return error.InvocationTooLarge;
    var size: usize = 8 + cwd.len;
    for (arguments) |argument| {
        if (argument.len > std.math.maxInt(u32)) return error.InvocationTooLarge;
        size = std.math.add(usize, size, 4 + argument.len) catch return error.InvocationTooLarge;
    }
    if (size > max_invocation_payload_size) return error.InvocationTooLarge;
    const result = try gpa.alloc(u8, size);
    errdefer gpa.free(result);
    var cursor: usize = 0;
    writeU32(result[cursor..][0..4], @intCast(arguments.len));
    cursor += 4;
    for (arguments) |argument| {
        writeU32(result[cursor..][0..4], @intCast(argument.len));
        cursor += 4;
        @memcpy(result[cursor .. cursor + argument.len], argument);
        cursor += argument.len;
    }
    writeU32(result[cursor..][0..4], @intCast(cwd.len));
    cursor += 4;
    @memcpy(result[cursor .. cursor + cwd.len], cwd);
    return result;
}

/// 解码一份线协议载荷，并为参数与 cwd 分配独立存储。
/// 尾随字节、过多参数及超过协议总上限的载荷都会被拒绝，而非静默截断。
pub fn decodeInvocation(gpa: std.mem.Allocator, id: u64, payload: []const u8) !InvocationData {
    if (payload.len > max_invocation_payload_size) return error.InvocationTooLarge;
    var cursor: usize = 0;
    const argument_count = try readU32(payload, &cursor);
    if (argument_count > 65_536) return error.InvalidInvocation;
    const arguments = try gpa.alloc([]u8, argument_count);
    errdefer gpa.free(arguments);
    var initialized: usize = 0;
    errdefer for (arguments[0..initialized]) |argument| gpa.free(argument);
    while (initialized < arguments.len) : (initialized += 1) {
        const length = try readU32(payload, &cursor);
        if (length > payload.len - cursor) return error.InvalidInvocation;
        arguments[initialized] = try gpa.dupe(u8, payload[cursor .. cursor + length]);
        cursor += length;
    }
    const cwd_length = try readU32(payload, &cursor);
    if (cwd_length > payload.len - cursor or cursor + cwd_length != payload.len)
        return error.InvalidInvocation;
    return .{
        .id = id,
        .arguments = arguments,
        .cwd = try gpa.dupe(u8, payload[cursor .. cursor + cwd_length]),
        .is_initial = false,
    };
}

fn writeU32(destination: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, destination, value, .big);
}

fn readU32(payload: []const u8, cursor: *usize) !u32 {
    if (payload.len - cursor.* < 4) return error.InvalidInvocation;
    const value = std.mem.readInt(u32, payload[cursor.*..][0..4], .big);
    cursor.* += 4;
    return value;
}

fn appendByteArray(message: *c.DBusMessage, bytes: []const u8) !void {
    var iterator: c.DBusMessageIter = undefined;
    var array: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iterator);
    if (c.dbus_message_iter_open_container(&iterator, c.DBUS_TYPE_ARRAY, "y", &array) == 0)
        return error.DBusAppendFailed;
    var pointer: [*c]const u8 = bytes.ptr;
    if (c.dbus_message_iter_append_fixed_array(&array, c.DBUS_TYPE_BYTE, @ptrCast(&pointer), @intCast(bytes.len)) == 0)
        return error.DBusAppendFailed;
    if (c.dbus_message_iter_close_container(&iterator, &array) == 0)
        return error.DBusAppendFailed;
}

fn readByteArray(message: *c.DBusMessage) ![]const u8 {
    var iterator: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iterator) == 0 or
        c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_ARRAY or
        c.dbus_message_iter_get_element_type(&iterator) != c.DBUS_TYPE_BYTE)
        return error.InvalidDbusArguments;
    var array: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&iterator, &array);
    var pointer: [*c]const u8 = null;
    var length: c_int = 0;
    c.dbus_message_iter_get_fixed_array(&array, @ptrCast(&pointer), &length);
    if (length < 0) return error.InvalidDbusArguments;
    return pointer[0..@intCast(length)];
}

fn sendCommandReply(connection: *c.DBusConnection, request: *c.DBusMessage, result: CommandResult) !void {
    const reply = c.dbus_message_new_method_return(request) orelse return error.DBusMessageCreateFailed;
    defer c.dbus_message_unref(reply);
    var iterator: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(reply, &iterator);
    var exit_code = result.exit_code;
    if (c.dbus_message_iter_append_basic(&iterator, c.DBUS_TYPE_INT32, &exit_code) == 0)
        return error.DBusAppendFailed;
    try appendByteArrayToIterator(&iterator, result.stdout);
    try appendByteArrayToIterator(&iterator, result.stderr);
    if (c.dbus_connection_send(connection, reply, null) == 0) return error.DBusSendFailed;
}

fn appendByteArrayToIterator(iterator: *c.DBusMessageIter, bytes: []const u8) !void {
    var array: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(iterator, c.DBUS_TYPE_ARRAY, "y", &array) == 0)
        return error.DBusAppendFailed;
    var pointer: [*c]const u8 = bytes.ptr;
    if (c.dbus_message_iter_append_fixed_array(&array, c.DBUS_TYPE_BYTE, @ptrCast(&pointer), @intCast(bytes.len)) == 0)
        return error.DBusAppendFailed;
    if (c.dbus_message_iter_close_container(iterator, &array) == 0)
        return error.DBusAppendFailed;
}

fn parseCommandReply(gpa: std.mem.Allocator, message: *c.DBusMessage) !CommandResult {
    var iterator: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iterator) == 0 or
        c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_INT32)
        return error.InvalidDbusReply;
    var exit_code: i32 = 0;
    c.dbus_message_iter_get_basic(&iterator, &exit_code);
    if (c.dbus_message_iter_next(&iterator) == 0) return error.InvalidDbusReply;
    const stdout = try duplicateByteArray(gpa, &iterator);
    errdefer gpa.free(stdout);
    if (c.dbus_message_iter_next(&iterator) == 0) return error.InvalidDbusReply;
    const stderr = try duplicateByteArray(gpa, &iterator);
    return .{ .exit_code = exit_code, .stdout = stdout, .stderr = stderr };
}

fn duplicateByteArray(gpa: std.mem.Allocator, iterator: *c.DBusMessageIter) ![]u8 {
    if (c.dbus_message_iter_get_arg_type(iterator) != c.DBUS_TYPE_ARRAY or
        c.dbus_message_iter_get_element_type(iterator) != c.DBUS_TYPE_BYTE)
        return error.InvalidDbusReply;
    var array: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(iterator, &array);
    var pointer: [*c]const u8 = null;
    var length: c_int = 0;
    c.dbus_message_iter_get_fixed_array(&array, @ptrCast(&pointer), &length);
    if (length < 0) return error.InvalidDbusReply;
    if (length == 0) return gpa.alloc(u8, 0);
    if (pointer == null) return error.InvalidDbusReply;
    return gpa.dupe(u8, pointer[0..@intCast(length)]);
}

fn sendErrorReply(connection: *c.DBusConnection, request: *c.DBusMessage, name: [:0]const u8, message: [:0]const u8) void {
    const reply = c.dbus_message_new_error(request, name.ptr, message.ptr) orelse return;
    defer c.dbus_message_unref(reply);
    _ = c.dbus_connection_send(connection, reply, null);
}

test "invocation envelope preserves arbitrary argument bytes" {
    const gpa = std.testing.allocator;
    const arguments = [_][]const u8{
        "open",
        &[_]u8{ 0xff, 0x00, '\n', '\\' },
        "window",
    };
    const encoded = try encodeInvocation(gpa, &arguments, "/tmp/work");
    defer gpa.free(encoded);
    var decoded = try decodeInvocation(gpa, 42, encoded);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 42), decoded.id);
    try std.testing.expectEqual(arguments.len, decoded.arguments.len);
    for (arguments, decoded.arguments) |expected, actual| try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualStrings("/tmp/work", decoded.cwd);
}

test "invocation envelope rejects truncation and trailing bytes" {
    const gpa = std.testing.allocator;
    const arguments = [_][]const u8{"open"};
    const encoded = try encodeInvocation(gpa, &arguments, "/tmp");
    defer gpa.free(encoded);
    try std.testing.expectError(error.InvalidInvocation, decodeInvocation(gpa, 1, encoded[0 .. encoded.len - 1]));

    const trailing = try std.mem.concat(gpa, u8, &.{ encoded, "x" });
    defer gpa.free(trailing);
    try std.testing.expectError(error.InvalidInvocation, decodeInvocation(gpa, 1, trailing));
}

test "invocation envelope rejects oversized payload" {
    const payload = try std.testing.allocator.alloc(u8, max_invocation_payload_size + 1);
    defer std.testing.allocator.free(payload);
    try std.testing.expectError(
        error.InvocationTooLarge,
        decodeInvocation(std.testing.allocator, 1, payload),
    );
}

test "cancelled callback remains serialized until late completion" {
    const allocator = std.testing.allocator;
    const deadline = std.Io.Clock.awake.now(std.testing.io);
    var broker: Broker = .{
        .gpa = allocator,
        .io = std.testing.io,
        .connection = undefined,
        .bus_name = try allocator.dupeZ(u8, "dev.fushell.Test"),
    };
    defer {
        if (broker.active) |*active| active.deinit(allocator);
        for (broker.queued.items) |*queued| queued.deinit(allocator);
        broker.queued.deinit(allocator);
        broker.watches.deinit(allocator);
        broker.timeouts.deinit(allocator);
        allocator.free(broker.bus_name);
    }

    broker.active = .{
        .data = .{
            .id = 1,
            .is_initial = false,
            .arguments = try allocator.alloc([]u8, 0),
            .cwd = try allocator.dupe(u8, ""),
        },
        .message = null,
        .deadline = deadline,
        .replied = true,
        .cancellation_deadline = deadline.addDuration(
            std.Io.Duration.fromMilliseconds(cancellation_grace_ms),
        ),
    };
    try broker.queued.append(allocator, .{
        .data = .{
            .id = 2,
            .is_initial = false,
            .arguments = try allocator.alloc([]u8, 0),
            .cwd = try allocator.dupe(u8, ""),
        },
        .message = null,
        .deadline = deadline,
    });

    try std.testing.expect(broker.nextInvocation() == null);
    const empty = @constCast(&[_]u8{});
    try broker.complete(1, .{ .stdout = empty, .stderr = empty });
    const next = broker.nextInvocation() orelse return error.MissingQueuedInvocation;
    try std.testing.expectEqual(@as(u64, 2), next.id);
    try broker.complete(2, .{ .stdout = empty, .stderr = empty });
}

test "command timeout requests cancellation before daemon restart" {
    const deadline = std.Io.Timestamp{ .nanoseconds = 100 };
    var invocation = QueuedInvocation{
        .data = undefined,
        .message = null,
        .deadline = deadline,
    };

    try std.testing.expectEqual(.none, commandTimeoutAction(invocation, .{ .nanoseconds = 99 }));
    try std.testing.expectEqual(.timeout, commandTimeoutAction(invocation, deadline));

    invocation.replied = true;
    invocation.cancellation_deadline = .{ .nanoseconds = 2100 };
    try std.testing.expectEqual(.none, commandTimeoutAction(invocation, .{ .nanoseconds = 2099 }));
    try std.testing.expectEqual(.restart, commandTimeoutAction(invocation, .{ .nanoseconds = 2100 }));
}

test "recovery requests are one-shot and reject queued commands" {
    const allocator = std.testing.allocator;
    const deadline = std.Io.Clock.awake.now(std.testing.io);
    var broker: Broker = .{
        .gpa = allocator,
        .io = std.testing.io,
        .connection = undefined,
        .bus_name = try allocator.dupeZ(u8, "dev.fushell.Test"),
    };
    defer {
        for (broker.queued.items) |*queued| queued.deinit(allocator);
        broker.queued.deinit(allocator);
        broker.watches.deinit(allocator);
        broker.timeouts.deinit(allocator);
        allocator.free(broker.bus_name);
    }

    broker.cancellation_request = 17;
    try std.testing.expectEqual(@as(?u64, 17), broker.takeCancellationRequest());
    try std.testing.expectEqual(@as(?u64, null), broker.takeCancellationRequest());

    try broker.queued.append(allocator, .{
        .data = .{
            .id = 18,
            .is_initial = false,
            .arguments = try allocator.alloc([]u8, 0),
            .cwd = try allocator.dupe(u8, ""),
        },
        .message = null,
        .deadline = deadline,
    });
    broker.rejectQueuedForRecovery();
    try std.testing.expectEqual(@as(usize, 0), broker.queued.items.len);
}

test "poll and dbus watch flags round trip" {
    const revents = std.posix.POLL.IN | std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP;
    const flags = pollDbusFlags(revents);
    try std.testing.expect(flags & c.DBUS_WATCH_READABLE != 0);
    try std.testing.expect(flags & c.DBUS_WATCH_WRITABLE != 0);
    try std.testing.expect(flags & c.DBUS_WATCH_ERROR != 0);
    try std.testing.expect(flags & c.DBUS_WATCH_HANGUP != 0);
}
