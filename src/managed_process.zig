//! Fushell CLI 受管子工具的有界清理逻辑。
//!
//! 受管工具位于独立进程组，使终端信号只作用于打包应用，而不会直接命中
//! `flutter attach` 或 DevTools。关闭时保持 machine-protocol 管道开启，给予
//! SIGTERM 有限宽限期；超时后对整个进程组升级为 SIGKILL，并始终回收 leader。

const std = @import("std");

const poll_interval_ns: u64 = 20 * std.time.ns_per_ms;

pub fn isAlive(pid: std.posix.pid_t) bool {
    const result = std.os.linux.kill(pid, @enumFromInt(0));
    if (result == 0) return true;
    return std.posix.errno(result) != .SRCH;
}

/// 在 `grace_ns` 范围内停止受管子进程及其全部后代。
///
/// 子进程必须以 `start_new_process_group=true` 启动，使其 pid 同时成为进程组 ID。
/// 函数会等待 leader 被回收后才返回；即使 leader 先退出，忽略 SIGTERM 的后代仍会
/// 被终止。`io` 只用于有界休眠与管道关闭。
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
