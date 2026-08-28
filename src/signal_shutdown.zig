//! 把 SIGINT 与 SIGTERM 转换为可 poll 的事件循环输入。
//!
//! 进程级 handler 只执行 async-signal-safe 的 eventfd 写入；全部 Flutter、Wayland、
//! D-Bus 与子进程清理仍留在正常平台线程。每个进程只能有一个活动 watcher，因为
//! POSIX signal disposition 与目标描述符都是进程全局状态。

const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

var active_fd = std.atomic.Value(c_int).init(-1);

fn signalHandler(_: posix.SIG) callconv(.c) void {
    const fd = active_fd.load(.acquire);
    if (fd < 0) return;

    var one: u64 = 1;
    _ = linux.write(fd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
}

/// 拥有 eventfd 以及 `init` 期间替换的 signal disposition。
///
/// 描述符为非阻塞，可直接注册到 EventPump。`deinit` 会先禁止 handler 写入，再关闭
/// fd 并恢复两项旧 disposition，避免迟到信号写入已经复用的描述符。
pub const Watcher = struct {
    fd: c_int,
    old_int: posix.Sigaction,
    old_term: posix.Sigaction,

    pub fn init() !Watcher {
        if (active_fd.load(.acquire) >= 0) return error.SignalWatcherAlreadyActive;

        const raw_fd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        switch (linux.errno(raw_fd)) {
            .SUCCESS => {},
            else => return error.SignalWatcherCreateFailed,
        }
        const fd: c_int = @intCast(raw_fd);
        errdefer _ = linux.close(fd);

        const action = posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        var old_int: posix.Sigaction = undefined;
        var old_term: posix.Sigaction = undefined;

        active_fd.store(fd, .release);
        posix.sigaction(.INT, &action, &old_int);
        errdefer posix.sigaction(.INT, &old_int, null);
        posix.sigaction(.TERM, &action, &old_term);

        return .{
            .fd = fd,
            .old_int = old_int,
            .old_term = old_term,
        };
    }

    pub fn deinit(self: *Watcher) void {
        active_fd.store(-1, .release);
        posix.sigaction(.INT, &self.old_int, null);
        posix.sigaction(.TERM, &self.old_term, null);
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    pub fn triggered(self: *const Watcher) bool {
        var fds = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = posix.poll(&fds, 0) catch return false;
        return (fds[0].revents & posix.POLL.IN) != 0;
    }
};

test "SIGTERM makes the watcher descriptor readable" {
    var watcher = try Watcher.init();
    defer watcher.deinit();

    try posix.kill(linux.getpid(), .TERM);

    var attempts: usize = 0;
    while (!watcher.triggered() and attempts < 100) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(watcher.triggered());
}
