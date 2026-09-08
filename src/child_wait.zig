//! Keep ownership of a child until it has actually exited and been reaped.
const std = @import("std");

/// Wait and clean up a failed/cancelled wait. In Zig 0.16's POSIX backend,
/// Child.wait clears child.id even when it returns Canceled without reaping.
/// Retain that PID so cleanup cannot silently become a no-op, leaving curl
/// running with the terminal's stderr open. Pipes have already been closed by
/// the backend; only the process identity is restored, never stale file handles.
pub fn wait(child: *std.process.Child, io: std.Io) !std.process.Child.Term {
    const pending_id = child.id;
    return child.wait(io) catch |err| {
        if (err == error.Canceled) child.id = pending_id;
        child.kill(io);
        return err;
    };
}

test "cancelled wait terminates and reaps the child rather than losing its PID" {
    const io = std.testing.io;
    var pid = std.atomic.Value(i32).init(0);
    const Task = struct {
        fn run(task_io: std.Io, value: *std.atomic.Value(i32)) !void {
            var child = try std.process.spawn(task_io, .{
                .argv = &.{ "/bin/sh", "-c", "while :; do :; done" },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            defer child.kill(task_io);
            value.store(child.id.?, .release);
            _ = try wait(&child, task_io);
        }
    };
    var task = try io.concurrent(Task.run, .{ io, &pid });
    defer task.cancel(io) catch {};
    while (pid.load(.acquire) == 0) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    var status: u32 = undefined;
    const result = std.os.linux.waitpid(pid.load(.acquire), &status, std.os.linux.W.NOHANG);
    try std.testing.expectEqual(std.os.linux.E.CHILD, std.os.linux.errno(result));
}
