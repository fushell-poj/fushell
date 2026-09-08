//! Linux child ownership: observe exit without reaping, then collect once.
//! Normal work has no deadline. Only cancellation has a TERM grace period.
const std = @import("std");
const Io = std.Io;
const Child = std.process.Child;
const linux = std.os.linux;
const poll_ms = 10;
const terminate_grace_ms = 250;

/// Check the direct child's exit state without closing pipes or releasing its
/// PID. Only this owner may reap the child. WNOWAIT prevents PID reuse between
/// observing exit, finishing output capture, and cleanup.
pub fn exited(child: *const Child) !bool {
    const pid = child.id orelse return true;
    var info = std.mem.zeroes(linux.siginfo_t);
    while (true) switch (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null))) {
        .SUCCESS => return info.fields.common.first.piduid.pid != 0,
        .INTR => continue,
        else => return error.ChildStatusFailed,
    };
}

/// Wait cancellably until exit is known, then reap with cancellation blocked.
/// Never enter Zig 0.16's cancellable Child.wait while a child is still running:
/// that path clears ownership even when it returns Canceled without reaping.
/// No stale PID or closed pipe handle is restored as a workaround.
pub fn wait(child: *Child, io: Io) !Child.Term {
    errdefer terminate(child, io);
    while (true) {
        try io.checkCancel();
        if (try exited(child)) break;
        try Io.sleep(io, .fromMilliseconds(poll_ms), .awake);
    }
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return child.wait(io);
}

/// Idempotent direct-child cleanup. TERM is followed by KILL after a bounded
/// grace period; reap before releasing the PID and pipe handles. Keep the
/// inherited terminal process group, so Ctrl+C still reaches tools normally.
/// Never signal a negative PID: this API does not own the caller's process group
/// or arbitrary descendants. A kernel-uninterruptible process can still delay
/// reaping after KILL; userspace cannot impose a hard bound on that kernel wait.
pub fn terminate(child: *Child, io: Io) void {
    const pid = child.id orelse return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    _ = linux.kill(pid, .TERM);
    const start = Io.Timestamp.now(io, .awake);
    while (!(exited(child) catch false)) {
        if (start.untilNow(io, .awake).toMilliseconds() >= terminate_grace_ms) break;
        Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch {};
    }
    if (!(exited(child) catch false)) _ = linux.kill(pid, .KILL);
    // Exit/cancellation observation never relinquished our child identity.
    _ = child.wait(io) catch {};
}

test "exit observation retains the PID and a nonzero exit status" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 23" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer terminate(&child, io);
    const pid = child.id.?;
    while (!try exited(&child)) try Io.sleep(io, .fromMilliseconds(1), .awake);
    try std.testing.expectEqual(pid, child.id.?);
    try std.testing.expect(try exited(&child));
    try std.testing.expectEqual(@as(u8, 23), (try wait(&child, io)).exited);
    try std.testing.expect(child.id == null);
}

test "cancelled wait escalates TERM and reaps a child that ignores it" {
    const io = std.testing.io;
    var pid = std.atomic.Value(i32).init(0);
    const Task = struct {
        fn run(task_io: Io, value: *std.atomic.Value(i32)) !void {
            var child = try std.process.spawn(task_io, .{
                .argv = &.{ "/bin/sh", "-c", "trap '' TERM; printf x; while :; do :; done" },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .ignore,
            });
            defer terminate(&child, task_io);
            var buffer: [32]u8 = undefined;
            var ready = child.stdout.?.reader(task_io, &buffer);
            _ = try ready.interface.takeByte(); // TERM handler is installed.
            value.store(child.id.?, .release);
            _ = try wait(&child, task_io);
        }
    };
    var task = try io.concurrent(Task.run, .{ io, &pid });
    defer task.cancel(io) catch {};
    const deadline = Io.Timestamp.now(io, .awake);
    while (pid.load(.acquire) == 0) {
        if (deadline.untilNow(io, .awake).toMilliseconds() > 3_000) return error.ChildNotReady;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    const start = Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expect(start.untilNow(io, .awake).toMilliseconds() < 2_000);
    var status: u32 = undefined;
    try std.testing.expectEqual(linux.E.CHILD, linux.errno(linux.waitpid(pid.load(.acquire), &status, linux.W.NOHANG)));
}
