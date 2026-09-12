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
const application_output = @import("application_output.zig");
const application_v2 = @import("application_v2.zig");
const output_sink_helper = @import("output_sink_helper.zig");
const retained_signal = @import("retained_signal.zig");

pub const object_path = application_v2.object_path;
pub const interface_name = application_v2.interface_name;
pub const legacy_interface_name = application_v2.legacy_interface_name;
pub const command_method = application_v2.command_method;
pub const protocol_method = application_v2.protocol_method;
pub const command_timeout_ms: i32 = 30_000;
pub const cancellation_grace_ms: i32 = 2_000;
const client_timeout_ms: i32 = command_timeout_ms + 5_000;
const max_invocation_payload_size = 8 * 1024 * 1024;

fn isHelperReapError(err: anyerror) bool {
    return err == error.ReapTimeout or err == error.WaitFailed or err == error.SignalFailed or err == error.ClockFailed;
}

fn isHelperProtocolError(err: anyerror) bool {
    return err == error.SummaryTruncated or err == error.InvalidSummary or err == error.MissingSummary or err == error.AlreadyTerminal;
}

pub const FatalReason = enum {
    dbus_watch_handle_failed,
    dbus_dispatch_failed,
    dbus_timeout_failed,
    command_reply_failed,
    error_reply_failed,
    filter_failed,
    helper_control_failed,
    helper_protocol_failed,
    helper_reap_failed,
    output_transport_failed,
};

pub const ReplySendResult = enum { sent, failed, already_attempted };

pub fn claimReplyAttempt(attempted: *bool) bool {
    if (attempted.*) return false;
    attempted.* = true;
    return true;
}

pub fn classifyReplySend(succeeded: bool) ReplySendResult {
    return if (succeeded) .sent else .failed;
}

/// Dart handler 的终态结果；输出已经通过 invocation writer 逐帧交付。
pub const CommandResult = struct {
    terminal_kind: application_v2.TerminalKind = .completed,
    exit_code: i32,
};

/// secondary 本地生成的诊断；业务 stdout/stderr 已由 sink helper 直接交付。
pub const SecondaryResult = struct {
    exit_code: i32,
    stderr: []u8,

    pub fn deinit(self: *SecondaryResult, gpa: std.mem.Allocator) void {
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

const PendingFrame = struct {
    stream: application_output.Stream,
    sequence: u64,
    payload: []u8,
    write_response: bool,
};

pub const WriteOutcome = enum { committed, detached, pending };
pub const PendingWriteResult = enum { committed, detached, cancelled, fatal };

pub const PendingWriteOutcome = struct {
    id: u64,
    result: PendingWriteResult,
};

const QueuedInvocation = struct {
    data: InvocationData,
    /// V2 reply 不含 UNIX_FD；携 FD 的 request 只活到 get_basic 完成。
    message: ?*c.DBusMessage,
    output: ?application_output.Endpoint = null,
    accounting: application_output.OutputAccounting = .{},
    pending_frame: ?PendingFrame = null,
    completion_exit_code: ?i32 = null,
    deadline: std.Io.Timestamp,
    /// 调用方已收到超时回复，但 Dart 仍拥有此回调。宽限期内保留 active 槽，
    /// 既避免 handler 重入，也允许协作取消完成清理。
    replied: bool = false,
    reply_attempted: bool = false,
    cancellation_deadline: ?std.Io.Timestamp = null,

    fn deinit(self: *QueuedInvocation, gpa: std.mem.Allocator) void {
        self.data.deinit(gpa);
        if (self.output) |*endpoint| endpoint.close();
        if (self.pending_frame) |frame| gpa.free(frame.payload);
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
    return .{ .exit_code = 75 };
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
    secondary: SecondaryResult,
};

/// primary 进程中的 D-Bus 状态机。
///
/// 除 [open] 和 secondary 转发路径外，所有方法都只能在 Flutter 平台线程调用。
/// 无 FD 的 retained method-return 会一直保留到 Dart 完成；携 FD 的 request 只活到
/// `get_basic` 完成。超时命令仍占用 active 槽，直到迟到的 completion 到达，以维持
/// “同一时刻最多一个 handler 活跃”的不变量。
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
    fatal_reason: ?FatalReason = null,
    pending_write_outcome: ?PendingWriteOutcome = null,
    /// initial invocation 的 helper 在 Flutter 初始化前创建，并由 primary 独占。
    initial_helper: ?output_sink_helper.Handle = null,
    initial_helper_summary: ?output_sink_helper.Summary = null,
    initial_expected_totals: ?application_output.OutputTotals = null,
    /// 记录 initial 已进入终态，使迟到 sink_write 仍按 consumer detach 处理。
    initial_terminal: ?CommandResult = null,
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
        var bus_name_owned = true;
        defer if (bus_name_owned) gpa.free(bus_name);

        const connection = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, null) orelse
            return error.SessionBusUnavailable;
        var connection_owned = true;
        defer if (connection_owned) {
            c.dbus_connection_close(connection);
            c.dbus_connection_unref(connection);
        };
        c.dbus_connection_set_exit_on_disconnect(connection, 0);
        application_v2.requireUnixFdCapability(application_v2.canSendUnixFds(connection)) catch return error.UnixFdUnsupported;

        const request_result = c.dbus_bus_request_name(
            connection,
            bus_name.ptr,
            c.DBUS_NAME_FLAG_DO_NOT_QUEUE,
            null,
        );
        switch (request_result) {
            c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER, c.DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER => {
                const broker = try gpa.create(Broker);
                broker.* = .{
                    .gpa = gpa,
                    .io = io,
                    .connection = connection,
                    .bus_name = bus_name,
                };
                bus_name_owned = false;
                connection_owned = false;
                broker.initial_helper = output_sink_helper.spawn(io, 1, 2) catch |err| return cleanupBrokerInitializationFailure(broker, err);
                broker.installCallbacks() catch |err| return cleanupBrokerInitializationFailure(broker, err);
                broker.enqueueLocal(arguments, cwd) catch |err| return cleanupBrokerInitializationFailure(broker, err);
                return .{ .primary = broker };
            },
            c.DBUS_REQUEST_NAME_REPLY_EXISTS => {
                const result = try forwardCommand(gpa, io, connection, bus_name, arguments, cwd);
                return .{ .secondary = result };
            },
            c.DBUS_REQUEST_NAME_REPLY_IN_QUEUE => return error.UnexpectedDbusNameQueue,
            else => return error.DBusRequestNameFailed,
        }
    }

    fn cleanupBrokerInitializationFailure(broker: *Broker, init_err: anyerror) anyerror {
        broker.deinit() catch |cleanup_err| {
            std.log.scoped(.application).err("broker initialization failed: {s}; cleanup failed: {s}", .{ @errorName(init_err), @errorName(cleanup_err) });
            return error.OpenInitializationCleanupFailed;
        };
        return init_err;
    }

    pub fn deinit(self: *Broker) !void {
        if (self.initial_helper) |*helper| {
            try helper.deinit();
            self.initial_helper = null;
        }
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
        if (self.initial_helper != null and self.initial_helper.?.control.fd >= 0) count += 1;
        if (self.active) |active| {
            if (active.output != null) count += 1;
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
        if (self.initial_helper) |*helper| {
            if (helper.control.fd >= 0 and count < destination.len) {
                destination[count] = .{
                    .fd = helper.control.fd,
                    .events = std.posix.POLL.IN | std.posix.POLL.HUP | 0x2000,
                    .revents = 0,
                };
                count += 1;
            }
        }
        if (self.active) |active| {
            if (active.output != null and count < destination.len) {
                var events: i16 = std.posix.POLL.ERR | std.posix.POLL.HUP | 0x2000;
                if (active.pending_frame != null) events |= std.posix.POLL.OUT;
                destination[count] = .{
                    .fd = active.output.?.fd,
                    .events = events,
                    .revents = 0,
                };
                count += 1;
            }
        }
        return count;
    }

    fn detachActiveOutput(self: *Broker, active: *QueuedInvocation) !void {
        if (active.output) |*endpoint| endpoint.close();
        active.output = null;
        if (active.pending_frame) |pending| {
            if (pending.write_response) {
                self.pending_write_outcome = .{ .id = active.data.id, .result = .detached };
            }
            self.gpa.free(pending.payload);
            active.pending_frame = null;
        }
        try self.pumpPendingOutput();
    }

    fn processInitialHelperSummary(self: *Broker, summary: output_sink_helper.Summary) !void {
        switch (summary.status) {
            .ok => {
                if (self.initial_expected_totals) |expected| {
                    summary.totals.expectEqual(expected) catch |err| {
                        self.markFatal(.helper_protocol_failed);
                        return err;
                    };
                }
                self.initial_helper_summary = summary;
            },
            .sink_write => {
                const initial_active = if (self.active) |active| active.data.is_initial else false;
                if (self.initial_helper == null or (!initial_active and self.initial_terminal == null)) {
                    self.markFatal(.helper_protocol_failed);
                    return error.HelperProtocolFailed;
                }
                self.initial_helper_summary = summary;
                if (self.active) |*active| {
                    if (active.data.is_initial) try self.detachActiveOutput(active);
                }
            },
            .frame_integrity, .terminated => {
                self.markFatal(.helper_protocol_failed);
                return error.HelperProtocolFailed;
            },
        }
    }

    pub fn handlePollFds(self: *Broker, ready: []const std.posix.pollfd) !void {
        if (self.fatal_reason != null) return error.FatalState;
        var ready_index: usize = 0;
        for (self.watches.items) |watch| {
            if (c.dbus_watch_get_enabled(watch) == 0) continue;
            if (ready_index >= ready.len) break;
            const revents = ready[ready_index].revents;
            ready_index += 1;
            if (revents == 0) continue;
            if (c.dbus_watch_handle(watch, pollDbusFlags(revents)) == 0) {
                self.markFatal(.dbus_watch_handle_failed);
                return error.DBusWatchHandleFailed;
            }
        }
        if (self.initial_helper) |*helper| {
            if (helper.control.fd >= 0 and ready_index < ready.len) {
                const helper_result = helper.pollSummary() catch |err| {
                    self.markFatal(if (isHelperProtocolError(err)) .helper_protocol_failed else .helper_control_failed);
                    return err;
                };
                switch (helper_result) {
                    .eof => {
                        const summary = helper.finish(100 * std.time.ns_per_ms) catch |err| {
                            self.markFatal(if (isHelperReapError(err)) .helper_reap_failed else .helper_protocol_failed);
                            return err;
                        };
                        if (self.initial_helper_summary == null) try self.processInitialHelperSummary(summary);
                    },
                    .summary => |summary| try self.processInitialHelperSummary(summary),
                    .pending => {},
                }
                ready_index += 1;
            }
        }
        if (self.active) |*active| {
            if (active.output != null and ready_index < ready.len) {
                const revents = ready[ready_index].revents;
                ready_index += 1;
                if ((revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | 0x2000)) != 0) {
                    self.detachActiveOutput(active) catch |err| {
                        self.markFatal(.output_transport_failed);
                        return err;
                    };
                } else if ((revents & std.posix.POLL.OUT) != 0) {
                    self.pumpPendingOutput() catch |err| {
                        self.markFatal(.output_transport_failed);
                        return err;
                    };
                }
            }
        }
        self.dispatchAvailable() catch |err| {
            if (self.fatal_reason == null) self.fatal_reason = .dbus_dispatch_failed;
            return err;
        };
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
        if (self.fatal_reason != null) return error.FatalState;
        self.handleExpiredTimeouts() catch |err| {
            if (self.fatal_reason == null) self.fatal_reason = .dbus_timeout_failed;
            return err;
        };
        self.dispatchAvailable() catch |err| {
            if (self.fatal_reason == null) self.fatal_reason = .dbus_dispatch_failed;
            return err;
        };
    }

    pub fn markFatal(self: *Broker, reason: FatalReason) void {
        if (self.fatal_reason == null) self.fatal_reason = reason;
    }

    pub fn fatalReason(self: *const Broker) ?FatalReason {
        return self.fatal_reason;
    }

    pub fn consumeFatalReason(self: *Broker) ?FatalReason {
        const reason = self.fatal_reason;
        self.fatal_reason = null;
        return reason;
    }

    pub fn nextInvocation(self: *Broker) ?*const InvocationData {
        if (self.active != null or self.queued.items.len == 0) return null;
        self.active = self.queued.orderedRemove(0);
        return &self.active.?.data;
    }

    pub fn hasActiveInvocation(self: *const Broker) bool {
        return self.active != null;
    }

    pub fn hasPendingOutput(self: *const Broker) bool {
        if (self.active) |active| return active.pending_frame != null;
        return false;
    }

    /// 返回一次待发送给 Dart handler 的协作取消请求。
    pub fn takeCancellationRequest(self: *Broker) ?u64 {
        const request = self.cancellation_request;
        self.cancellation_request = null;
        return request;
    }

    /// handler 未在取消宽限期内结束时，要求 runner 进入既有有序关闭流程。
    pub fn recoveryExitRequested(self: *const Broker) bool {
        return self.recovery_exit_requested and self.active != null;
    }

    pub fn takePendingWriteOutcome(self: *Broker) ?PendingWriteOutcome {
        const outcome = self.pending_write_outcome;
        self.pending_write_outcome = null;
        return outcome;
    }

    pub fn write(self: *Broker, id: u64, stream: application_output.Stream, payload: []const u8) !WriteOutcome {
        if (self.active) |*active| {
            if (active.data.id != id) return error.InvocationIdMismatch;
            if (active.replied) return error.ApplicationCancelled;
            if (active.completion_exit_code != null) return error.OutputClosed;
            if (active.pending_frame != null) return error.PendingWrite;

            const frame = application_output.Frame{
                .stream = stream,
                .sequence = active.accounting.logical.frame_count,
                .payload = payload,
            };
            // 预检必须发生在 send、payload duplicate 和 logical 状态变更之前。
            try active.accounting.validateLogical(frame);
            if (active.output == null) {
                try active.accounting.acceptLogical(frame);
                return .detached;
            }
            active.output.?.sendFrame(frame) catch |err| switch (err) {
                error.WouldBlock => {
                    const pending = try self.gpa.dupe(u8, payload);
                    active.accounting.acceptLogical(frame) catch |accounting_err| {
                        self.gpa.free(pending);
                        return accounting_err;
                    };
                    active.pending_frame = .{
                        .stream = stream,
                        .sequence = frame.sequence,
                        .payload = pending,
                        .write_response = true,
                    };
                    return .pending;
                },
                error.PeerClosed => {
                    try active.accounting.acceptLogical(frame);
                    var closed = active.output.?;
                    closed.close();
                    active.output = null;
                    return .detached;
                },
                else => return err,
            };
            try active.accounting.acceptLogical(frame);
            try active.accounting.markDelivered(frame);
            return .committed;
        }
        return error.NoActiveInvocation;
    }

    pub fn complete(self: *Broker, id: u64, result: CommandResult) !void {
        if (self.active) |*active| {
            if (active.data.id != id) return error.InvocationIdMismatch;
            if (active.pending_frame != null) return error.PendingOutputWrite;
            if (!active.replied) {
                active.completion_exit_code = result.exit_code;
                try self.finishInvocation(active, result);
            } else {
                self.recovery_exit_requested = false;
            }
            active.deinit(self.gpa);
            self.active = null;
            return;
        }
        return error.NoActiveInvocation;
    }

    pub fn failPending(self: *Broker) void {
        const result = CommandResult{ .exit_code = 125 };
        if (self.active) |*active| {
            if (!active.replied) {
                active.replied = true;
                self.finishInvocation(active, result) catch self.markFatal(.command_reply_failed);
            }
        }
        for (self.queued.items) |*queued| {
            self.finishInvocation(queued, result) catch self.markFatal(.command_reply_failed);
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
        const helper = self.initial_helper orelse return error.InitialHelperUnavailable;
        var output = try helper.producer.duplicate();
        errdefer output.close();
        try self.queued.append(self.gpa, .{
            .data = data,
            .message = null,
            .output = output,
            .deadline = commandDeadline(self.io),
        });
    }

    fn enqueueRemote(
        self: *Broker,
        message: *c.DBusMessage,
        payload: []const u8,
        owned_output_fd: std.posix.fd_t,
        deadline: std.Io.Timestamp,
    ) !void {
        var output = application_output.Endpoint{ .fd = owned_output_fd };
        errdefer output.close();
        if (self.outstandingCount() >= 32) return error.Busy;
        try output.validateSocket();
        const reply = try application_v2.newReply(message);
        errdefer c.dbus_message_unref(reply);
        const decoded = try decodeInvocation(self.gpa, self.next_id, payload);
        self.next_id += 1;
        errdefer {
            var owned = decoded;
            owned.deinit(self.gpa);
        }
        try self.queued.append(self.gpa, .{
            .data = decoded,
            .message = reply,
            .output = output,
            .deadline = deadline,
        });
    }

    fn outstandingCount(self: *const Broker) usize {
        return self.queued.items.len + @intFromBool(self.active != null);
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

        const timeout_result = CommandResult{ .terminal_kind = .timed_out, .exit_code = 124 };

        if (self.active) |*active| {
            switch (commandTimeoutAction(active.*, now)) {
                .none => {},
                .timeout => {
                    active.replied = true;
                    active.cancellation_deadline = cancellationDeadline(now);
                    self.cancellation_request = active.data.id;
                    self.finishInvocation(active, timeout_result) catch |err| return err;
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
            self.finishInvocation(&expired, timeout_result) catch |err| return err;
        }
    }

    fn rejectQueuedForRecovery(self: *Broker) void {
        const result = recoveryCommandResult();
        while (self.queued.items.len > 0) {
            var queued = self.queued.orderedRemove(0);
            defer queued.deinit(self.gpa);
            self.finishInvocation(&queued, result) catch self.markFatal(.command_reply_failed);
        }
    }

    fn finishInvocation(self: *Broker, invocation: *QueuedInvocation, result: CommandResult) !void {
        self.clearPendingFrame(invocation);
        if (invocation.output) |*endpoint| {
            endpoint.shutdownWrite() catch |err| {
                if (err != error.PeerClosed) {
                    self.markFatal(.output_transport_failed);
                    endpoint.close();
                    return err;
                }
            };
            endpoint.close();
        }
        if (invocation.data.is_initial) {
            self.initial_terminal = result;
            self.initial_expected_totals = invocation.accounting.delivered;
            if (self.initial_helper_summary) |summary| {
                if (summary.status == .ok) {
                    summary.totals.expectEqual(self.initial_expected_totals.?) catch |err| {
                        self.markFatal(.helper_protocol_failed);
                        return err;
                    };
                }
            }
            if (self.initial_helper) |*helper| helper.closeOutput();
        }
        if (invocation.message) |message| {
            if (!claimReplyAttempt(&invocation.reply_attempted)) return error.ReplyAlreadyAttempted;
            invocation.replied = true;
            sendCommandReply(self.connection, message, result.terminal_kind, result.exit_code, invocation.accounting.delivered) catch |err| {
                _ = classifyReplySend(false);
                self.markFatal(.command_reply_failed);
                return err;
            };
            _ = classifyReplySend(true);
        }
    }

    fn pumpPendingOutput(self: *Broker) !void {
        if (self.active) |*active| {
            const pending_write = if (active.pending_frame) |pending| pending.write_response else false;
            try self.pumpInvocationOutput(active);
            if (pending_write and active.pending_frame == null and self.pending_write_outcome == null) {
                self.pending_write_outcome = .{ .id = active.data.id, .result = if (active.output == null) .detached else .committed };
            }
            if (active.completion_exit_code != null and active.pending_frame == null and !active.replied) {
                const terminal_result = CommandResult{ .exit_code = active.completion_exit_code.? };
                try self.finishInvocation(active, terminal_result);
                active.deinit(self.gpa);
                self.active = null;
            }
        }
    }

    fn pumpInvocationOutput(self: *Broker, invocation: *QueuedInvocation) !void {
        if (invocation.pending_frame) |*pending| {
            const frame = application_output.Frame{
                .stream = pending.stream,
                .sequence = pending.sequence,
                .payload = pending.payload,
            };
            if (invocation.output == null) {
                if (pending.write_response) {
                    self.pending_write_outcome = .{ .id = invocation.data.id, .result = .detached };
                }
                self.gpa.free(pending.payload);
                invocation.pending_frame = null;
                return;
            }
            invocation.output.?.sendFrame(frame) catch |err| switch (err) {
                error.WouldBlock => return,
                error.PeerClosed => {
                    if (pending.write_response) {
                        self.pending_write_outcome = .{ .id = invocation.data.id, .result = .detached };
                    }
                    self.gpa.free(pending.payload);
                    invocation.pending_frame = null;
                    var closed = invocation.output.?;
                    closed.close();
                    invocation.output = null;
                    return;
                },
                else => return err,
            };
            try invocation.accounting.markDelivered(frame);
            self.gpa.free(pending.payload);
            invocation.pending_frame = null;
        }
    }

    fn clearPendingFrame(self: *Broker, invocation: *QueuedInvocation) void {
        if (invocation.pending_frame) |pending| {
            if (pending.write_response) {
                self.pending_write_outcome = .{ .id = invocation.data.id, .result = if (self.fatal_reason != null) .fatal else .cancelled };
            }
            self.gpa.free(pending.payload);
        }
        invocation.pending_frame = null;
    }
};

const OwnerWatch = struct {
    connection: *c.DBusConnection,
    bus_name: [:0]const u8,
    expected_owner: [:0]const u8,
    rule: ?[:0]u8 = null,
    lost: bool = false,

    fn init(self: *OwnerWatch, gpa: std.mem.Allocator) !void {
        const rule_text = try std.fmt.allocPrint(
            gpa,
            "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='{s}'",
            .{self.bus_name},
        );
        defer gpa.free(rule_text);
        const rule = try gpa.dupeZ(u8, rule_text);
        errdefer gpa.free(rule);
        var error_storage: [128]u8 align(8) = undefined;
        const dbus_error: *c.DBusError = @ptrCast(&error_storage);
        c.dbus_error_init(dbus_error);
        c.dbus_bus_add_match(self.connection, rule.ptr, dbus_error);
        if (c.dbus_error_is_set(dbus_error) != 0) {
            c.dbus_error_free(dbus_error);
            return error.OwnerWatchSetupFailed;
        }
        if (c.dbus_connection_add_filter(self.connection, ownerWatchFilter, self, null) == 0) {
            c.dbus_bus_remove_match(self.connection, rule.ptr, null);
            return error.OwnerWatchSetupFailed;
        }
        self.rule = rule;
        c.dbus_connection_flush(self.connection);
    }

    fn deinit(self: *OwnerWatch, gpa: std.mem.Allocator) void {
        c.dbus_connection_remove_filter(self.connection, ownerWatchFilter, self);
        if (self.rule) |rule| {
            c.dbus_bus_remove_match(self.connection, rule.ptr, null);
            c.dbus_connection_flush(self.connection);
            gpa.free(rule);
            self.rule = null;
        }
    }
};

fn ownerWatchFilter(
    _: ?*c.DBusConnection,
    message: ?*c.DBusMessage,
    user_data: ?*anyopaque,
) callconv(.c) c.DBusHandlerResult {
    const watch: *OwnerWatch = @ptrCast(@alignCast(user_data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const sender = c.dbus_message_get_sender(message orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED);
    if (sender == null or !std.mem.eql(u8, std.mem.span(sender), "org.freedesktop.DBus") or
        c.dbus_message_is_signal(message.?, "org.freedesktop.DBus", "NameOwnerChanged") == 0)
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    var iterator: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message.?, &iterator) == 0 or c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_STRING)
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    var changed_name: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iterator, @ptrCast(&changed_name));
    if (!std.mem.eql(u8, std.mem.span(changed_name), watch.bus_name)) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (c.dbus_message_iter_next(&iterator) == 0 or c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_STRING)
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    var old_owner: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iterator, @ptrCast(&old_owner));
    if (c.dbus_message_iter_next(&iterator) == 0 or c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_STRING)
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    var new_owner: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iterator, @ptrCast(&new_owner));
    if (std.mem.eql(u8, std.mem.span(old_owner), watch.expected_owner) and
        (new_owner[0] == 0 or !std.mem.eql(u8, std.mem.span(new_owner), watch.expected_owner)))
        watch.lost = true;
    return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

fn dispatchDbus(connection: *c.DBusConnection) !void {
    while (true) {
        const status = c.dbus_connection_dispatch(connection);
        if (status == c.DBUS_DISPATCH_COMPLETE) {
            if (c.dbus_connection_get_is_connected(connection) == 0) return error.DBusDisconnected;
            return;
        }
        if (status == c.DBUS_DISPATCH_NEED_MEMORY) return error.DBusDispatchOutOfMemory;
    }
}

fn pollDbus(
    connection: *c.DBusConnection,
    timeout_ms: i32,
    owner_watch: ?*OwnerWatch,
    signal_source: ?*const retained_signal.Source,
) !void {
    var fd: c_int = -1;
    if (c.dbus_connection_get_unix_fd(connection, &fd) == 0) return error.DBusFdUnavailable;
    var events: i16 = std.posix.POLL.IN;
    if (c.dbus_connection_get_outgoing_size(connection) > 0) events |= std.posix.POLL.OUT;
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = events, .revents = 0 },
        .{ .fd = if (signal_source) |source| source.fd else -1, .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP, .revents = 0 },
    };
    const count = if (signal_source == null) @as(usize, 1) else @as(usize, 2);
    if (try std.posix.poll(poll_fds[0..count], timeout_ms) == 0) return error.DBusTimeout;
    if (signal_source != null and (poll_fds[1].revents & std.posix.POLL.IN) != 0) {
        const event = signal_source.?.receive() catch |err| return err;
        return switch (event.signo) {
            .INT => error.Interrupted,
            .TERM => error.Terminated,
            else => error.SignalSourceFailed,
        };
    }
    if (signal_source != null and (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0)
        return error.SignalSourceFailed;
    if ((poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0)
        return error.DBusDisconnected;
    if ((poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.OUT)) != 0) {
        if (c.dbus_connection_read_write(connection, 0) == 0) return error.DBusDisconnected;
        try dispatchDbus(connection);
    }
    if (owner_watch) |watch| if (watch.lost) return error.OwnerLost;
}

fn pollSecondary(
    connection: *c.DBusConnection,
    helper_fd: std.posix.fd_t,
    signal_fd: std.posix.fd_t,
    timeout_ms: i32,
) ![3]std.posix.pollfd {
    var dbus_fd: c_int = -1;
    if (c.dbus_connection_get_unix_fd(connection, &dbus_fd) == 0) return error.DBusFdUnavailable;
    var dbus_events: i16 = std.posix.POLL.IN;
    if (c.dbus_connection_get_outgoing_size(connection) > 0) dbus_events |= std.posix.POLL.OUT;
    var fds = [_]std.posix.pollfd{
        .{ .fd = dbus_fd, .events = dbus_events, .revents = 0 },
        .{ .fd = helper_fd, .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP, .revents = 0 },
        .{ .fd = signal_fd, .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP, .revents = 0 },
    };
    if (try std.posix.poll(&fds, timeout_ms) == 0) return error.DBusTimeout;
    if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0)
        return error.DBusDisconnected;
    if ((fds[1].revents & std.posix.POLL.NVAL) != 0 or (fds[2].revents & std.posix.POLL.NVAL) != 0)
        return error.SecondaryPollFailed;
    return fds;
}

fn cancelPendingCall(pending: *?*c.DBusPendingCall) void {
    if (pending.*) |call| {
        c.dbus_pending_call_cancel(call);
        c.dbus_pending_call_unref(call);
        pending.* = null;
    }
}

fn forwardCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    connection: *c.DBusConnection,
    bus_name: [:0]const u8,
    arguments: []const []const u8,
    cwd: []const u8,
) !SecondaryResult {
    application_v2.requireUnixFdCapability(application_v2.canSendUnixFds(connection)) catch
        return localDiagnostic(gpa, 125, "session bus cannot transport UNIX_FD\n");

    var signal_source = retained_signal.Source.init() catch |err| {
        return localDiagnosticError(gpa, 125, "failed to retain termination signals: ", err);
    };
    defer signal_source.close();

    const owner = getUniqueOwner(gpa, io, connection, bus_name, &signal_source) catch |err| {
        if (err == error.Interrupted) return localDiagnostic(gpa, 130, "interrupted\n");
        if (err == error.Terminated) return localDiagnostic(gpa, 143, "terminated\n");
        return localDiagnosticError(gpa, 125, "application owner disappeared before V2 probe: ", err);
    };
    defer gpa.free(owner);
    var owner_watch = OwnerWatch{
        .connection = connection,
        .bus_name = bus_name,
        .expected_owner = owner,
    };
    owner_watch.init(gpa) catch |err| {
        return localDiagnosticError(gpa, 125, "failed to monitor application owner: ", err);
    };
    defer owner_watch.deinit(gpa);

    const protocol_message = application_v2.newProtocolMessage(owner) catch |err| {
        return localDiagnosticError(gpa, 76, "incompatible Application2 protocol: ", err);
    };
    const protocol_reply = sendPendingAndWait(io, connection, protocol_message, 2_000, &owner_watch, &signal_source) catch |err| {
        if (err == error.Interrupted) return localDiagnostic(gpa, 130, "interrupted\n");
        if (err == error.Terminated) return localDiagnostic(gpa, 143, "terminated\n");
        if (err == error.OwnerLost or err == error.DBusDisconnected) return localDiagnostic(gpa, 125, "application owner disappeared during V2 probe\n");
        return localDiagnosticError(gpa, 76, "incompatible daemon; stop it before retrying: ", err);
    };
    defer c.dbus_message_unref(protocol_reply);
    if (c.dbus_message_get_type(protocol_reply) == c.DBUS_MESSAGE_TYPE_ERROR) {
        const error_code: i32 = if (application_v2.errorName(protocol_reply)) |name|
            if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.ServiceUnknown")) 125 else 76
        else
            76;
        return localDiagnostic(gpa, error_code, if (error_code == 125) "application owner disappeared during V2 probe\n" else "incompatible daemon; Application2 protocol version 2 is required\n");
    }
    _ = application_v2.parseProtocolReply(protocol_reply) catch {
        return localDiagnostic(gpa, 76, "incompatible daemon; Application2 protocol version 2 is required\n");
    };

    const payload = try encodeInvocation(gpa, arguments, cwd);
    defer gpa.free(payload);
    var helper = try output_sink_helper.spawn(io, std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO);
    var result = forwardCommandWithHelper(
        gpa,
        io,
        connection,
        owner,
        payload,
        &signal_source,
        &owner_watch,
        &helper,
    ) catch |inner_err| {
        helper.deinit() catch |cleanup_err| {
            std.log.scoped(.application).err("forward failed: {s}; helper cleanup failed: {s}", .{ @errorName(inner_err), @errorName(cleanup_err) });
            return error.ForwardAndCleanupFailed;
        };
        return inner_err;
    };
    helper.deinit() catch |cleanup_err| {
        result.deinit(gpa);
        return cleanup_err;
    };
    return result;
}

fn forwardCommandWithHelper(
    gpa: std.mem.Allocator,
    io: std.Io,
    connection: *c.DBusConnection,
    owner: [:0]const u8,
    payload: []const u8,
    signal_source: *retained_signal.Source,
    owner_watch: *OwnerWatch,
    helper: *output_sink_helper.Handle,
) !SecondaryResult {
    const message = application_v2.newCommandMessage(owner, payload, helper.producer.fd) catch |err| {
        return localDiagnosticError(gpa, 125, "failed to create V2 command: ", err);
    };
    var pending: ?*c.DBusPendingCall = null;
    defer cancelPendingCall(&pending);
    if (c.dbus_connection_send_with_reply(connection, message, &pending, client_timeout_ms) == 0 or pending == null) {
        c.dbus_message_unref(message);
        return localDiagnostic(gpa, 125, "failed to send V2 command\n");
    }
    // libdbus 已建立 message-owned FD 副本；此处只能关闭 secondary original，不能
    // shutdownWrite，否则会让 helper read peer 先看到 EOF 并使 primary 后续写入 EPIPE。
    helper.producer.close();
    c.dbus_message_unref(message);

    const deadline = std.Io.Clock.awake.now(io).addDuration(std.Io.Duration.fromMilliseconds(client_timeout_ms));
    var final_reply: ?application_v2.FinalReply = null;
    var helper_summary: ?output_sink_helper.Summary = null;
    var helper_eof = false;
    while (true) {
        dispatchDbus(connection) catch return localDiagnostic(gpa, 125, "daemon D-Bus connection was lost\n");
        if (owner_watch.lost) return localDiagnostic(gpa, 125, "application owner disappeared during command\n");
        if (pending) |call| {
            if (c.dbus_pending_call_get_completed(call) != 0) {
                const reply = c.dbus_pending_call_steal_reply(call) orelse return localDiagnostic(gpa, 125, "daemon command reply was lost\n");
                c.dbus_pending_call_unref(call);
                pending = null;
                if (c.dbus_message_get_type(reply) == c.DBUS_MESSAGE_TYPE_ERROR) {
                    defer c.dbus_message_unref(reply);
                    return try localErrorReply(gpa, reply);
                }
                final_reply = application_v2.parseFinalReply(reply) catch {
                    c.dbus_message_unref(reply);
                    return localDiagnostic(gpa, 125, "invalid Application2 final reply\n");
                };
                c.dbus_message_unref(reply);
            }
        }
        if (final_reply != null and helper_summary != null and helper_eof) {
            const summary = try helper.finish(100 * std.time.ns_per_ms);
            if (summary.status != .ok or
                summary.totals.frame_count != final_reply.?.frame_count or
                summary.totals.stdout_bytes != final_reply.?.stdout_bytes or
                summary.totals.stderr_bytes != final_reply.?.stderr_bytes)
                return localDiagnostic(gpa, 125, "Application2 output integrity counters mismatch\n");
            if (final_reply.?.terminal_kind == .timed_out)
                return localDiagnostic(gpa, 124, "application command timed out\n");
            return .{ .exit_code = final_reply.?.exit_code, .stderr = try gpa.alloc(u8, 0) };
        }
        const now = std.Io.Clock.awake.now(io);
        if (now.nanoseconds >= deadline.nanoseconds) return localDiagnostic(gpa, 124, "application command timed out\n");
        const fds = pollSecondary(
            connection,
            if (helper_eof) -1 else helper.control.fd,
            signal_source.fd,
            deadlineTimeoutMs(now, deadline),
        ) catch |err| {
            if (err == error.DBusDisconnected) return localDiagnostic(gpa, 125, "daemon D-Bus connection was lost\n");
            return err;
        };
        if ((fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.OUT)) != 0) {
            if (c.dbus_connection_read_write(connection, 0) == 0) return localDiagnostic(gpa, 125, "daemon D-Bus connection was lost\n");
            dispatchDbus(connection) catch |err| {
                if (err == error.DBusDisconnected) return localDiagnostic(gpa, 125, "daemon D-Bus connection was lost\n");
                return err;
            };
        }
        if ((fds[1].revents & std.posix.POLL.ERR) != 0) return localDiagnostic(gpa, 125, "sink helper poll failed\n");
        if ((fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            switch (try helper.pollSummary()) {
                .summary => |summary| {
                    helper_summary = summary;
                    if (summary.status != .ok) return localDiagnostic(gpa, 125, switch (summary.status) {
                        .sink_write => "sink helper consumer write failed\n",
                        .frame_integrity => "sink helper reported frame integrity failure\n",
                        .terminated => "sink helper terminated before completion\n",
                        .ok => unreachable,
                    });
                },
                .eof => {
                    helper_eof = true;
                    if (helper_summary == null) return localDiagnostic(gpa, 125, "sink helper EOF arrived without summary\n");
                },
                .pending => {},
            }
        }
        if ((fds[2].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) return localDiagnostic(gpa, 125, "signal source poll failed\n");
        if ((fds[2].revents & std.posix.POLL.IN) != 0) {
            if (signal_source.receive() catch |err| if (err == error.WouldBlock) null else return err) |event|
                return localDiagnostic(gpa, event.exitCode(), if (event.exitCode() == 130) "interrupted\n" else "terminated\n");
        }
    }
}

fn sendPendingAndWait(
    io: std.Io,
    connection: *c.DBusConnection,
    message: *c.DBusMessage,
    timeout_ms: i32,
    owner_watch: ?*OwnerWatch,
    signal_source: ?*const retained_signal.Source,
) !*c.DBusMessage {
    var pending: ?*c.DBusPendingCall = null;
    defer cancelPendingCall(&pending);
    if (c.dbus_connection_send_with_reply(connection, message, &pending, timeout_ms) == 0 or pending == null) {
        c.dbus_message_unref(message);
        return error.DBusCommandFailed;
    }
    c.dbus_message_unref(message);
    const deadline = std.Io.Clock.awake.now(io).addDuration(std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)));
    while (true) {
        if (owner_watch) |watch| if (watch.lost) return error.OwnerLost;
        if (c.dbus_pending_call_get_completed(pending.?) != 0) {
            const reply = c.dbus_pending_call_steal_reply(pending.?) orelse {
                cancelPendingCall(&pending);
                return error.DBusCommandFailed;
            };
            c.dbus_pending_call_unref(pending.?);
            pending = null;
            return reply;
        }
        const now = std.Io.Clock.awake.now(io);
        if (now.nanoseconds >= deadline.nanoseconds) return error.DBusTimeout;
        pollDbus(connection, deadlineTimeoutMs(now, deadline), owner_watch, signal_source) catch |err| return err;
    }
}

fn getUniqueOwner(
    gpa: std.mem.Allocator,
    io: std.Io,
    connection: *c.DBusConnection,
    bus_name: [:0]const u8,
    signal_source: *const retained_signal.Source,
) ![:0]u8 {
    const message = try application_v2.newGetNameOwnerMessage(bus_name);
    const reply = try sendPendingAndWait(io, connection, message, 2_000, null, signal_source);
    defer c.dbus_message_unref(reply);
    if (c.dbus_message_get_type(reply) == c.DBUS_MESSAGE_TYPE_ERROR) return error.OwnerLost;
    var iterator: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(reply, &iterator) == 0 or c.dbus_message_iter_get_arg_type(&iterator) != c.DBUS_TYPE_STRING)
        return error.InvalidOwnerReply;
    var owner: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iterator, @ptrCast(&owner));
    if (c.dbus_message_iter_next(&iterator) != 0) return error.InvalidOwnerReply;
    return try gpa.dupeZ(u8, std.mem.span(owner));
}

fn localDiagnostic(gpa: std.mem.Allocator, exit_code: i32, message: []const u8) !SecondaryResult {
    return .{ .exit_code = exit_code, .stderr = try gpa.dupe(u8, message) };
}

fn localDiagnosticError(gpa: std.mem.Allocator, exit_code: i32, prefix: []const u8, err: anyerror) !SecondaryResult {
    const message = try std.fmt.allocPrint(gpa, "{s}{s}\n", .{ prefix, @errorName(err) });
    return .{ .exit_code = exit_code, .stderr = message };
}

fn localErrorReply(gpa: std.mem.Allocator, message: *c.DBusMessage) !SecondaryResult {
    const name = application_v2.errorName(message) orelse "org.freedesktop.DBus.Error.Failed";
    if (std.mem.eql(u8, name, "dev.fushell.Error.Busy")) return localDiagnostic(gpa, 75, "application command queue is full\n");
    if (std.mem.eql(u8, name, "dev.fushell.Error.IncompatibleProtocol")) return localDiagnostic(gpa, 76, "incompatible daemon; stop it before retrying\n");
    return localDiagnostic(gpa, 125, "application daemon owner was lost\n");
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
    if (c.dbus_message_is_method_call(message, legacy_interface_name, command_method) != 0) {
        sendErrorReply(
            broker.connection,
            message,
            "dev.fushell.Error.IncompatibleProtocol",
            "Application1 is not supported; stop the daemon and retry with Application2",
        ) catch broker.markFatal(.error_reply_failed);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    if (c.dbus_message_is_method_call(message, interface_name, protocol_method) != 0) {
        const reply = application_v2.newReply(message) catch {
            broker.markFatal(.error_reply_failed);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        };
        defer c.dbus_message_unref(reply);
        application_v2.appendProtocolReply(reply) catch {
            broker.markFatal(.error_reply_failed);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        };
        if (c.dbus_connection_send(broker.connection, reply, null) == 0) {
            broker.markFatal(.error_reply_failed);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    if (c.dbus_message_is_method_call(message, interface_name, command_method) == 0)
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    if (broker.recovery_exit_requested) {
        sendErrorReply(broker.connection, message, "dev.fushell.Error.Busy", "application daemon is recovering") catch broker.markFatal(.error_reply_failed);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    const receive_deadline = commandDeadline(broker.io);
    const command = application_v2.readCommand(message) catch |err| {
        if (err == error.InvalidUnixFd) {
            sendErrorReply(broker.connection, message, "dev.fushell.Error.InvalidOutput", "CommandLine output FD is invalid") catch broker.markFatal(.error_reply_failed);
        } else {
            sendErrorReply(broker.connection, message, "dev.fushell.Error.InvalidCommand", "expected CommandLine(ay,h)") catch broker.markFatal(.error_reply_failed);
        }
        return c.DBUS_HANDLER_RESULT_HANDLED;
    };
    broker.enqueueRemote(message, command.payload, @intCast(command.owned_output_fd), receive_deadline) catch |err| {
        if (err == error.OutOfMemory) {
            broker.markFatal(.filter_failed);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        if (err == error.Busy) {
            sendErrorReply(broker.connection, message, "dev.fushell.Error.Busy", "application command queue is full") catch broker.markFatal(.error_reply_failed);
        } else if (err == error.InvalidSocketDomain or err == error.InvalidSocketType or err == error.BadDescriptor or err == error.SocketInspectionFailed or err == error.DuplicateFailed) {
            sendErrorReply(broker.connection, message, "dev.fushell.Error.InvalidOutput", "output FD is not an AF_UNIX SOCK_SEQPACKET") catch broker.markFatal(.error_reply_failed);
        } else {
            broker.markFatal(.filter_failed);
        }
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

fn sendCommandReply(
    connection: *c.DBusConnection,
    reply: *c.DBusMessage,
    terminal_kind: application_v2.TerminalKind,
    exit_code: i32,
    delivered: application_output.OutputTotals,
) !void {
    try application_v2.appendFinalReply(reply, .{
        .terminal_kind = terminal_kind,
        .exit_code = exit_code,
        .frame_count = delivered.frame_count,
        .stdout_bytes = delivered.stdout_bytes,
        .stderr_bytes = delivered.stderr_bytes,
    });
    if (c.dbus_connection_send(connection, reply, null) == 0) return error.DBusSendFailed;
}

fn sendErrorReply(connection: *c.DBusConnection, request: *c.DBusMessage, name: [:0]const u8, message: [:0]const u8) !void {
    const reply = c.dbus_message_new_error(request, name.ptr, message.ptr) orelse return error.ErrorReplyCreateFailed;
    defer c.dbus_message_unref(reply);
    if (c.dbus_connection_send(connection, reply, null) == 0) return error.ErrorReplySendFailed;
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

test "initial helper terminal state accepts late sink detach" {
    const allocator = std.testing.allocator;
    var broker: Broker = .{
        .gpa = allocator,
        .io = std.testing.io,
        .connection = undefined,
        .bus_name = try allocator.dupeZ(u8, "dev.fushell.InitialTest"),
        .initial_helper = .{
            .io = std.testing.io,
            .producer = .{ .fd = -1 },
            .control = .{ .fd = -1 },
            .pid = 0,
        },
    };
    defer {
        broker.initial_helper.?.deinit() catch @panic("initial helper cleanup failed");
        allocator.free(broker.bus_name);
    }

    broker.initial_terminal = .{ .exit_code = 0 };
    try broker.processInitialHelperSummary(.{
        .status = .sink_write,
        .totals = .{ .frame_count = 1, .stdout_bytes = 2 },
    });
    try std.testing.expect(broker.fatal_reason == null);
}

test "initial helper summary validates counters before or after terminal" {
    const allocator = std.testing.allocator;
    var broker: Broker = .{
        .gpa = allocator,
        .io = std.testing.io,
        .connection = undefined,
        .bus_name = try allocator.dupeZ(u8, "dev.fushell.InitialSummaryTest"),
    };
    defer allocator.free(broker.bus_name);

    broker.initial_expected_totals = .{ .frame_count = 1, .stdout_bytes = 3 };
    try broker.processInitialHelperSummary(.{
        .status = .ok,
        .totals = .{ .frame_count = 1, .stdout_bytes = 3 },
    });
    broker.initial_terminal = .{ .exit_code = 0 };
    try std.testing.expect(broker.fatal_reason == null);
}

test "initial helper counter mismatch is fatal" {
    const allocator = std.testing.allocator;
    var broker: Broker = .{
        .gpa = allocator,
        .io = std.testing.io,
        .connection = undefined,
        .bus_name = try allocator.dupeZ(u8, "dev.fushell.InitialMismatchTest"),
    };
    defer allocator.free(broker.bus_name);

    broker.initial_expected_totals = .{ .frame_count = 1, .stdout_bytes = 3 };
    try std.testing.expectError(error.CounterMismatch, broker.processInitialHelperSummary(.{
        .status = .ok,
        .totals = .{ .frame_count = 1, .stdout_bytes = 2 },
    }));
    try std.testing.expectEqual(FatalReason.helper_protocol_failed, broker.fatal_reason.?);
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
    try broker.complete(1, .{ .exit_code = 0 });
    const next = broker.nextInvocation() orelse return error.MissingQueuedInvocation;
    try std.testing.expectEqual(@as(u64, 2), next.id);
    try broker.complete(2, .{ .exit_code = 0 });
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

fn expectClosed(fd: std.posix.fd_t) !void {
    const result = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    try std.testing.expectEqual(std.os.linux.E.BADF, std.os.linux.errno(result));
}

test "broker fatal state exposes and consumes its reason" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    try std.testing.expect(broker.fatalReason() == null);
    broker.markFatal(.error_reply_failed);
    broker.markFatal(.output_transport_failed);
    try std.testing.expectEqual(FatalReason.error_reply_failed, broker.fatalReason().?);
    try std.testing.expectEqual(FatalReason.error_reply_failed, broker.consumeFatalReason().?);
    try std.testing.expect(broker.fatalReason() == null);
}

test "reply attempt state is one-shot and send failure is fatal" {
    var attempted = false;
    try std.testing.expect(claimReplyAttempt(&attempted));
    try std.testing.expect(!claimReplyAttempt(&attempted));
    try std.testing.expectEqual(ReplySendResult.failed, classifyReplySend(false));
    try std.testing.expectEqual(ReplySendResult.sent, classifyReplySend(true));
}

test "native write commits frame and delivered counters" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    var pair = try application_output.createSocketPair();
    defer pair.deinit();
    broker.active = .{
        .data = .{
            .id = 1,
            .arguments = try std.testing.allocator.alloc([]u8, 0),
            .cwd = try std.testing.allocator.dupe(u8, ""),
            .is_initial = false,
        },
        .message = null,
        .output = pair.first,
        .deadline = std.Io.Clock.awake.now(std.testing.io),
    };
    pair.first.fd = -1;
    defer if (broker.active) |*active| active.deinit(std.testing.allocator);

    try std.testing.expectEqual(WriteOutcome.committed, try broker.write(1, .stdout, "abc"));
    try std.testing.expectEqual(@as(u64, 1), broker.active.?.accounting.logical.frame_count);
    try std.testing.expectEqual(@as(u64, 1), broker.active.?.accounting.delivered.frame_count);
    var packet: [application_output.max_frame_size]u8 = undefined;
    const received = try pair.second.receiveFrame(&packet);
    try std.testing.expectEqual(@as(u64, 0), received.sequence);
    try std.testing.expectEqualSlices(u8, "abc", received.payload);
    pair.first.fd = -1;
}

test "native pending write is flushed once and reports committed outcome" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    var pair = try application_output.createSocketPair();
    defer pair.deinit();
    broker.active = .{
        .data = .{
            .id = 2,
            .arguments = try std.testing.allocator.alloc([]u8, 0),
            .cwd = try std.testing.allocator.dupe(u8, ""),
            .is_initial = false,
        },
        .message = null,
        .output = pair.first,
        .deadline = std.Io.Clock.awake.now(std.testing.io),
    };
    pair.first.fd = -1;
    defer if (broker.active) |*active| active.deinit(std.testing.allocator);

    var filler: [application_output.max_payload_size]u8 = undefined;
    var sequence: u64 = 0;
    while (true) : (sequence += 1) {
        broker.active.?.output.?.sendFrame(.{ .stream = .stdout, .sequence = sequence, .payload = &filler }) catch |err| {
            try std.testing.expectEqual(error.WouldBlock, err);
            break;
        };
    }
    try std.testing.expectEqual(WriteOutcome.pending, try broker.write(2, .stderr, "pending"));
    try std.testing.expectEqual(@as(u64, 0), broker.active.?.accounting.delivered.frame_count);

    var packet: [application_output.max_frame_size]u8 = undefined;
    while (true) {
        _ = pair.second.receiveFrame(&packet) catch |err| {
            try std.testing.expectEqual(error.WouldBlock, err);
            break;
        };
    }
    try broker.pumpPendingOutput();
    const outcome = broker.takePendingWriteOutcome().?;
    try std.testing.expectEqual(@as(u64, 2), outcome.id);
    try std.testing.expectEqual(PendingWriteResult.committed, outcome.result);
    try std.testing.expectEqual(@as(u64, 1), broker.active.?.accounting.delivered.frame_count);
}

test "native write preflight rejects full quota before send or allocation" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    var pair = try application_output.createSocketPair();
    defer pair.deinit();
    broker.active = .{
        .data = .{
            .id = 3,
            .arguments = try std.testing.allocator.alloc([]u8, 0),
            .cwd = try std.testing.allocator.dupe(u8, ""),
            .is_initial = false,
        },
        .message = null,
        .output = pair.first,
        .deadline = std.Io.Clock.awake.now(std.testing.io),
    };
    pair.first.fd = -1;
    defer if (broker.active) |*active| active.deinit(std.testing.allocator);
    broker.active.?.accounting.logical.stdout_bytes = application_output.max_output_bytes;

    try std.testing.expectError(error.OutputLimitExceeded, broker.write(3, .stdout, "x"));
    try std.testing.expectEqual(@as(u64, application_output.max_output_bytes), broker.active.?.accounting.logical.stdout_bytes);
    var packet: [application_output.max_frame_size]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, pair.second.receiveFrame(&packet));
}

test "pending write peer close commits detached outcome with matching ID" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    var pair = try application_output.createSocketPair();
    defer pair.deinit();
    broker.active = .{
        .data = .{
            .id = 4,
            .arguments = try std.testing.allocator.alloc([]u8, 0),
            .cwd = try std.testing.allocator.dupe(u8, ""),
            .is_initial = false,
        },
        .message = null,
        .output = pair.first,
        .deadline = std.Io.Clock.awake.now(std.testing.io),
    };
    pair.first.fd = -1;
    defer if (broker.active) |*active| active.deinit(std.testing.allocator);

    var filler: [application_output.max_payload_size]u8 = undefined;
    var sequence: u64 = 0;
    while (true) : (sequence += 1) {
        broker.active.?.output.?.sendFrame(.{ .stream = .stdout, .sequence = sequence, .payload = &filler }) catch |err| {
            try std.testing.expectEqual(error.WouldBlock, err);
            break;
        };
    }
    try std.testing.expectEqual(WriteOutcome.pending, try broker.write(4, .stderr, "pending"));
    pair.second.close();
    try broker.pumpPendingOutput();
    const outcome = broker.takePendingWriteOutcome().?;
    try std.testing.expectEqual(@as(u64, 4), outcome.id);
    try std.testing.expectEqual(PendingWriteResult.detached, outcome.result);
    try std.testing.expectEqual(@as(u64, 0), broker.active.?.accounting.delivered.frame_count);
}

test "native detached write consumes logical quota without delivered counters" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    broker.active = .{
        .data = .{
            .id = 2,
            .arguments = try std.testing.allocator.alloc([]u8, 0),
            .cwd = try std.testing.allocator.dupe(u8, ""),
            .is_initial = false,
        },
        .message = null,
        .deadline = std.Io.Clock.awake.now(std.testing.io),
    };
    defer if (broker.active) |*active| active.deinit(std.testing.allocator);

    try std.testing.expectEqual(WriteOutcome.detached, try broker.write(2, .stderr, "drop"));
    try std.testing.expectEqual(@as(u64, 1), broker.active.?.accounting.logical.frame_count);
    try std.testing.expectEqual(@as(u64, 0), broker.active.?.accounting.delivered.frame_count);
}

test "native write rejects zero payload and stale IDs" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    broker.active = .{
        .data = .{
            .id = 3,
            .arguments = try std.testing.allocator.alloc([]u8, 0),
            .cwd = try std.testing.allocator.dupe(u8, ""),
            .is_initial = false,
        },
        .message = null,
        .deadline = std.Io.Clock.awake.now(std.testing.io),
    };
    defer if (broker.active) |*active| active.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvocationIdMismatch, broker.write(4, .stdout, "x"));
    try std.testing.expectError(error.ZeroPayload, broker.write(3, .stdout, ""));
}

test "remote Busy closes the already-owned output FD exactly once" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    try broker.queued.ensureTotalCapacity(broker.gpa, 32);
    broker.queued.items.len = 32;
    defer broker.queued.deinit(broker.gpa);

    var pair = try application_output.createSocketPair();
    const owned_fd = pair.first.fd;
    pair.first.fd = -1;
    defer pair.deinit();
    const fake_message: *c.DBusMessage = @ptrFromInt(1);
    try std.testing.expectError(error.Busy, broker.enqueueRemote(fake_message, &.{}, owned_fd, .{ .nanoseconds = 0 }));
    try expectClosed(owned_fd);
}

test "invalid remote output closes the caller-owned FD" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    const owned_fd = std.os.linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(owned_fd) != .SUCCESS) return error.OpenFailed;
    const fake_message: *c.DBusMessage = @ptrFromInt(1);
    try std.testing.expectError(error.SocketInspectionFailed, broker.enqueueRemote(fake_message, &.{}, @intCast(owned_fd), .{ .nanoseconds = 0 }));
    try expectClosed(@intCast(owned_fd));
}

test "accepted remote output is queued without duplicating the owned FD" {
    var broker = Broker{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    defer broker.queued.deinit(broker.gpa);
    var pair = try application_output.createSocketPair();
    const owned_fd = pair.first.fd;
    pair.first.fd = -1;
    defer pair.deinit();
    const payload = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const message = try application_v2.newCommandMessage("dev.fushell.Test", &payload, owned_fd);
    c.dbus_message_set_serial(message, 1);
    defer c.dbus_message_unref(message);

    try broker.enqueueRemote(message, &payload, owned_fd, .{ .nanoseconds = 0 });
    try std.testing.expectEqual(owned_fd, broker.queued.items[0].output.?.fd);
    broker.queued.items[0].deinit(broker.gpa);
    broker.queued.items.len = 0;
    try expectClosed(owned_fd);
}

test "local error reply propagates OOM without leaking the reply" {
    const request = c.dbus_message_new_method_call("dev.fushell.Test", "/", "dev.fushell.Test", "CommandLine") orelse return error.MessageCreateFailed;
    defer c.dbus_message_unref(request);
    c.dbus_message_set_serial(request, 1);
    const reply = c.dbus_message_new_error(request, "dev.fushell.Error.Busy", "busy") orelse return error.MessageCreateFailed;
    defer c.dbus_message_unref(reply);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, localErrorReply(failing.allocator(), reply));
}

test "decode OOM closes the caller-owned output FD" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var broker = Broker{
        .gpa = failing.allocator(),
        .io = std.testing.io,
        .connection = @ptrFromInt(1),
        .bus_name = @constCast("dev.fushell.Test"),
    };
    var pair = try application_output.createSocketPair();
    const owned_fd = pair.first.fd;
    pair.first.fd = -1;
    defer pair.deinit();
    const message = try application_v2.newCommandMessage("dev.fushell.Test", &.{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, owned_fd);
    c.dbus_message_set_serial(message, 1);
    defer c.dbus_message_unref(message);
    try std.testing.expectError(error.OutOfMemory, broker.enqueueRemote(message, &.{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, owned_fd, .{ .nanoseconds = 0 }));
    try expectClosed(owned_fd);
}
