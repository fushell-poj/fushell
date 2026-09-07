//! Process-wide event pump. It borrows DisplayState and event sources, never a
//! window Host. All callbacks are serialized on the platform thread.
const std = @import("std");

/// 平台循环用来消费 Flutter task 与可选子系统描述符的适配器，不取得其状态所有权。
///
/// 回调顺序具有语义：producer 在同一 tick 内必须以相同顺序 report/fill/handle
/// 外部描述符。即使 readiness 来自其他线程，所有回调仍在平台线程执行。
pub const Source = struct {
    fd: c_int,
    context: ?*anyopaque,
    tick: *const fn (context: ?*anyopaque) anyerror!void,
    timeout_ms: *const fn (context: ?*anyopaque) i32,
    consume_wake: *const fn (context: ?*anyopaque) void,
    /// Optional dynamically-owned descriptor. A negative descriptor disables it.
    /// The next loop tick consumes readiness, keeping subsystem state on the
    /// platform thread instead of introducing worker-thread completion races.
    auxiliary_fd: ?*const fn (context: ?*anyopaque) c_int = null,
    /// Optional event sources (for example D-Bus watches) owned by the same
    /// platform thread. The count/fill/handle callbacks MUST preserve descriptor order.
    external_fd_count: ?*const fn (context: ?*anyopaque) usize = null,
    fill_external_fds: ?*const fn (context: ?*anyopaque, destination: []std.posix.pollfd) usize = null,
    handle_external_fds: ?*const fn (context: ?*anyopaque, ready: []const std.posix.pollfd) anyerror!void = null,
    /// Process shutdown notification (SIGINT/SIGTERM). A negative descriptor
    /// disables it; readiness makes the event loop stop without dispatching
    /// further Wayland work.
    shutdown_fd: c_int = -1,
};

/// Run until quit/shutdown; state provides the Wayland display and shared queue.
pub fn run(state: anytype, allocator: std.mem.Allocator, quit: *const std.atomic.Value(bool), message: []const u8, source: Source) !void {
    std.debug.print("{s}\n", .{message});
    var fds: std.ArrayList(std.posix.pollfd) = .empty;
    defer fds.deinit(allocator);

    while (!quit.load(.acquire)) {
        try source.tick(source.context);
        if (quit.load(.acquire)) break;
        if (state.display.?.dispatchQueuePending(state.shared_queue.?) != .SUCCESS) return error.WaylandDispatchFailed;
        if (quit.load(.acquire)) break;
        state.flush();

        const base_fd_count = 4;
        const requested_external_count = if (source.external_fd_count) |count|
            count(source.context)
        else
            0;
        try fds.resize(allocator, base_fd_count + requested_external_count);
        @memset(fds.items, .{ .fd = -1, .events = 0, .revents = 0 });
        fds.items[0] = .{
            .fd = state.display.?.getFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        fds.items[1] = .{
            .fd = source.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        fds.items[2] = .{
            .fd = if (source.auxiliary_fd) |get_fd| get_fd(source.context) else -1,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        fds.items[3] = .{
            .fd = source.shutdown_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        const external_count = if (source.fill_external_fds) |fill|
            fill(source.context, fds.items[base_fd_count..])
        else
            0;
        if (external_count != requested_external_count) return error.ExternalFdCountChanged;
        _ = std.posix.poll(fds.items, source.timeout_ms(source.context)) catch return error.EventLoopPollFailed;
        if ((fds.items[3].revents & std.posix.POLL.IN) != 0) break;
        if ((fds.items[3].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) return error.ShutdownPollFailed;
        if ((fds.items[1].revents & std.posix.POLL.IN) != 0) source.consume_wake(source.context);
        if ((fds.items[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) return error.TaskWakePollFailed;
        if ((fds.items[2].revents & std.posix.POLL.NVAL) != 0) return error.AuxiliaryPollFailed;
        if ((fds.items[0].revents & std.posix.POLL.IN) != 0) {
            // 单线程模型: 主线程唯一预约读 (无需多线程原子读竞争处理)。
            if (state.display.?.prepareReadQueue(state.shared_queue.?)) {
                if (state.display.?.readEvents() != .SUCCESS) return error.WaylandDispatchFailed;
            }
        }
        if ((fds.items[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) return error.WaylandDisplayPollFailed;
        if (external_count > 0) {
            if (source.handle_external_fds) |handle| {
                try handle(source.context, fds.items[base_fd_count..]);
            }
        }
    }
}

test "quit during tick does not dispatch display or block in poll" {
    const FakeDisplay = struct {
        pub fn dispatchQueuePending(_: *@This(), _: *u8) std.posix.E {
            unreachable;
        }
        pub fn getFd(_: *@This()) c_int {
            unreachable;
        }
        pub fn prepareReadQueue(_: *@This(), _: *u8) bool {
            unreachable;
        }
        pub fn readEvents(_: *@This()) std.posix.E {
            unreachable;
        }
    };
    const FakeState = struct {
        display: ?*FakeDisplay = null,
        shared_queue: ?*u8 = null,
        pub fn flush(_: *@This()) void {
            unreachable;
        }
    };
    const Callbacks = struct {
        fn tick(raw: ?*anyopaque) !void {
            const quit: *std.atomic.Value(bool) = @ptrCast(@alignCast(raw.?));
            quit.store(true, .release);
        }
        fn timeout(_: ?*anyopaque) i32 {
            unreachable;
        }
        fn wake(_: ?*anyopaque) void {
            unreachable;
        }
    };
    var state: FakeState = .{};
    var quit = std.atomic.Value(bool).init(false);
    try run(&state, std.testing.allocator, &quit, "test event pump", .{ .fd = -1, .context = &quit, .tick = Callbacks.tick, .timeout_ms = Callbacks.timeout, .consume_wake = Callbacks.wake });
}
