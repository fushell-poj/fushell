//! Thread-safe Flutter platform-task scheduler backed by a dynamic priority
//! queue and Linux eventfd wakeups.

const std = @import("std");
const c = @import("c");
const linux = std.os.linux;

const PendingTask = struct {
    task: c.FlutterTask,
    target_time_nanos: u64,
    sequence: u64,
};

fn order(_: void, lhs: PendingTask, rhs: PendingTask) std.math.Order {
    const by_time = std.math.order(lhs.target_time_nanos, rhs.target_time_nanos);
    if (by_time != .eq) return by_time;
    return std.math.order(lhs.sequence, rhs.sequence);
}

const PriorityQueue = std.PriorityQueue(PendingTask, void, order);

/// Thread-safe Flutter platform-task queue with an eventfd wakeup.
/// Posting never waits for the platform thread. Allocation failure is recorded
/// as a fatal scheduler error so the process exits visibly instead of silently
/// dropping an engine task.
pub const TaskQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    queue: PriorityQueue = .empty,
    wake_fd: std.posix.fd_t = -1,
    next_sequence: u64 = 0,
    failed: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !TaskQueue {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventFdCreateFailed;
        return .{ .allocator = allocator, .io = io, .wake_fd = @intCast(rc) };
    }

    pub fn deinit(self: *TaskQueue) void {
        self.queue.deinit(self.allocator);
        if (self.wake_fd >= 0) {
            _ = linux.close(self.wake_fd);
            self.wake_fd = -1;
        }
    }

    pub fn post(self: *TaskQueue, task: c.FlutterTask, target_time_nanos: u64) void {
        self.lock();
        self.queue.push(self.allocator, .{
            .task = task,
            .target_time_nanos = target_time_nanos,
            .sequence = self.next_sequence,
        }) catch {
            self.failed.store(true, .release);
            self.unlock();
            self.notify();
            return;
        };
        self.next_sequence +%= 1;
        self.unlock();
        self.notify();
    }

    pub fn popDue(self: *TaskQueue, now_nanos: u64) ?c.FlutterTask {
        self.lock();
        defer self.unlock();
        const pending = self.queue.peek() orelse return null;
        if (pending.target_time_nanos > now_nanos) return null;
        return self.queue.pop().?.task;
    }

    pub fn timeoutMs(self: *TaskQueue, now_nanos: u64) i32 {
        self.lock();
        defer self.unlock();
        const pending = self.queue.peek() orelse return -1;
        if (pending.target_time_nanos <= now_nanos) return 0;
        const delta = pending.target_time_nanos - now_nanos;
        const rounded_ms = (delta + 999_999) / 1_000_000;
        return @intCast(@min(rounded_ms, @as(u64, std.math.maxInt(i32))));
    }

    pub fn hasFailed(self: *const TaskQueue) bool {
        return self.failed.load(.acquire);
    }

    pub fn drainWake(self: *TaskQueue) void {
        var value: u64 = 0;
        while (true) {
            const rc = linux.read(self.wake_fd, std.mem.asBytes(&value).ptr, @sizeOf(u64));
            switch (linux.errno(rc)) {
                .SUCCESS => continue,
                .INTR => continue,
                .AGAIN => return,
                else => {
                    self.failed.store(true, .release);
                    return;
                },
            }
        }
    }

    fn lock(self: *TaskQueue) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *TaskQueue) void {
        self.mutex.unlock(self.io);
    }

    pub fn notify(self: *TaskQueue) void {
        const one: u64 = 1;
        while (true) {
            const rc = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
            switch (linux.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                // A saturated eventfd is already readable, so no wakeup is lost.
                .AGAIN => return,
                else => {
                    self.failed.store(true, .release);
                    return;
                },
            }
        }
    }
};

test "task queue grows beyond the former fixed capacity without blocking" {
    var queue = try TaskQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

    const task = std.mem.zeroes(c.FlutterTask);
    for (0..300) |index| queue.post(task, @intCast(index));
    queue.drainWake();

    var count: usize = 0;
    while (queue.popDue(1_000)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 300), count);
    try std.testing.expect(!queue.hasFailed());
}

test "task queue preserves deadlines and reports the next timeout" {
    var queue = try TaskQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

    var later = std.mem.zeroes(c.FlutterTask);
    later.task = 5;
    var sooner = std.mem.zeroes(c.FlutterTask);
    sooner.task = 2;
    queue.post(later, 5_000_000);
    queue.post(sooner, 2_000_000);
    try std.testing.expectEqual(@as(i32, 1), queue.timeoutMs(1_000_001));
    try std.testing.expect(queue.popDue(1_999_999) == null);
    try std.testing.expectEqual(@as(u64, 2), queue.popDue(2_000_000).?.task);
    try std.testing.expectEqual(@as(u64, 5), queue.popDue(5_000_000).?.task);
}

test "cross-thread post wakes a blocked platform poll" {
    var queue = try TaskQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(target: *TaskQueue) void {
            var task = std.mem.zeroes(c.FlutterTask);
            task.task = 42;
            target.post(task, 0);
        }
    }.run, .{&queue});
    thread.join();

    var poll_fds = [_]std.posix.pollfd{.{ .fd = queue.wake_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&poll_fds, 100));
    queue.drainWake();
    try std.testing.expectEqual(@as(u64, 42), queue.popDue(0).?.task);
}

test "equal deadlines preserve post order and wakeups coalesce" {
    var queue = try TaskQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

    for (0..100) |index| {
        var task = std.mem.zeroes(c.FlutterTask);
        task.task = @intCast(index);
        queue.post(task, 10);
    }
    var poll_fds = [_]std.posix.pollfd{.{ .fd = queue.wake_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&poll_fds, 100));
    queue.drainWake();
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 0));
    for (0..100) |index| {
        try std.testing.expectEqual(@as(u64, @intCast(index)), queue.popDue(10).?.task);
    }
}

test "concurrent producers do not lose tasks" {
    var queue = try TaskQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

    const Producer = struct {
        fn run(target: *TaskQueue, base: u64) void {
            for (0..100) |index| {
                var task = std.mem.zeroes(c.FlutterTask);
                task.task = base + index;
                target.post(task, 0);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{ &queue, @as(u64, @intCast(index)) * 100 });
    }
    for (&threads) |*thread| thread.join();
    queue.drainWake();

    var count: usize = 0;
    while (queue.popDue(0)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 400), count);
    try std.testing.expect(!queue.hasFailed());
}

test "allocation failure becomes a visible fatal scheduler state" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var queue = try TaskQueue.init(failing.allocator(), std.testing.io);
    defer queue.deinit();

    queue.post(std.mem.zeroes(c.FlutterTask), 0);
    try std.testing.expect(queue.hasFailed());
    var poll_fds = [_]std.posix.pollfd{.{ .fd = queue.wake_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&poll_fds, 100));
}
