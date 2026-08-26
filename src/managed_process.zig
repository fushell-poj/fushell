const std = @import("std");

const poll_interval_ns: u64 = 20 * std.time.ns_per_ms;

pub fn isAlive(pid: std.posix.pid_t) bool {
    const result = std.os.linux.kill(pid, @enumFromInt(0));
    if (result == 0) return true;
    return std.posix.errno(result) != .SRCH;
}

/// Stop a managed child and every descendant in its dedicated process group.
/// Managed subprocesses are spawned with `pgid = 0`, so the group id equals
/// the direct child's pid. Keeping tooling outside fushell's foreground group
/// prevents Ctrl+C from tearing down pipes before the parent can reap them.
pub fn stopAndWait(io: std.Io, child: *std.process.Child, grace_ns: u64) void {
    const pid = child.id orelse return;
    const group = -pid;

    _ = std.os.linux.kill(group, std.posix.SIG.TERM);
    const steps = @max(@as(u64, 1), grace_ns / poll_interval_ns);
    for (0..@intCast(steps)) |_| {
        if (tryReap(io, child, pid)) {
            // TERM normally reaches the entire group. Ensure no descendant that
            // ignored it survives after the direct child has been reaped.
            _ = std.os.linux.kill(group, std.posix.SIG.KILL);
            return;
        }
        std.Io.sleep(io, .{ .nanoseconds = poll_interval_ns }, .real) catch break;
    }

    _ = std.os.linux.kill(group, std.posix.SIG.KILL);
    _ = child.wait(io) catch {
        child.kill(io);
        return;
    };
}

fn tryReap(io: std.Io, child: *std.process.Child, pid: std.posix.pid_t) bool {
    var status: u32 = 0;
    const result = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
    switch (std.posix.errno(result)) {
        .SUCCESS => {
            if (result == 0) return false;
            closePipes(io, child);
            child.id = null;
            return true;
        },
        .INTR => return false,
        .CHILD => {
            closePipes(io, child);
            child.id = null;
            return true;
        },
        else => return false,
    }
}

fn closePipes(io: std.Io, child: *std.process.Child) void {
    if (child.stdin) |file| file.close(io);
    if (child.stdout) |file| file.close(io);
    if (child.stderr) |file| file.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}
