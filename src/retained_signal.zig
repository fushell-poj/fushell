//! 将 SIGINT/SIGTERM 保留为带 signo 的非阻塞 signalfd 事件。
//!
//! 该模块不安装共享 signal handler，也不使用进程级 last_signal；调用方取得事件后
//! 自己决定退出码。close 会恢复 init 前的完整 signal mask。

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

comptime {
    if (@import("builtin").os.tag != .linux) @compileError("retained signal source requires Linux signalfd");
}

pub const Event = struct {
    signo: posix.SIG,

    pub fn exitCode(self: Event) u8 {
        return switch (self.signo) {
            .INT => 130,
            .TERM => 143,
            else => unreachable,
        };
    }
};

pub const Error = error{
    SignalMaskFailed,
    SignalFdCreateFailed,
    SignalFdClosed,
    WouldBlock,
    ShortRead,
    UnexpectedSignal,
};

pub const Source = struct {
    fd: posix.fd_t,
    previous_mask: posix.sigset_t,
    mask_saved: bool = true,

    pub fn init() Error!Source {
        var mask = posix.sigemptyset();
        posix.sigaddset(&mask, .INT);
        posix.sigaddset(&mask, .TERM);

        var previous_mask: posix.sigset_t = undefined;
        posix.sigprocmask(posix.SIG.BLOCK, &mask, &previous_mask);
        errdefer posix.sigprocmask(posix.SIG.SETMASK, &previous_mask, null);

        const raw_fd = posix.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK) catch {
            return error.SignalFdCreateFailed;
        };
        errdefer _ = linux.close(raw_fd);

        return .{
            .fd = raw_fd,
            .previous_mask = previous_mask,
        };
    }

    /// 非阻塞读取一个被保留的 signal；没有事件时显式返回 WouldBlock。
    pub fn receive(self: *const Source) Error!Event {
        if (self.fd < 0) return error.SignalFdClosed;

        var info: linux.signalfd_siginfo = undefined;
        while (true) {
            const result = linux.read(self.fd, std.mem.asBytes(&info).ptr, @sizeOf(linux.signalfd_siginfo));
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result != @sizeOf(linux.signalfd_siginfo)) return error.ShortRead;
                    const signo: posix.SIG = @enumFromInt(info.signo);
                    return switch (signo) {
                        .INT, .TERM => .{ .signo = signo },
                        else => error.UnexpectedSignal,
                    };
                },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.SignalFdClosed,
            }
        }
    }

    /// 幂等关闭 fd，并恢复创建 source 前的 mask。
    pub fn close(self: *Source) void {
        if (self.fd >= 0) {
            const fd = self.fd;
            self.fd = -1;
            _ = linux.close(fd);
        }
        if (self.mask_saved) {
            self.mask_saved = false;
            posix.sigprocmask(posix.SIG.SETMASK, &self.previous_mask, null);
        }
    }

    pub fn deinit(self: *Source) void {
        self.close();
    }
};

fn currentMask() Error!posix.sigset_t {
    var mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.SETMASK, null, &mask);
    return mask;
}

test "signalfd retains SIGINT/SIGTERM and maps exit codes" {
    var source = try Source.init();
    defer source.close();

    const blocked = try currentMask();
    try std.testing.expect(posix.sigismember(&blocked, .INT));
    try std.testing.expect(posix.sigismember(&blocked, .TERM));
    try std.testing.expectError(error.WouldBlock, source.receive());

    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.kill(linux.getpid(), .INT)));
    const interrupt = try source.receive();
    try std.testing.expectEqual(posix.SIG.INT, interrupt.signo);
    try std.testing.expectEqual(@as(u8, 130), interrupt.exitCode());

    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.kill(linux.getpid(), .TERM)));
    const terminate = try source.receive();
    try std.testing.expectEqual(posix.SIG.TERM, terminate.signo);
    try std.testing.expectEqual(@as(u8, 143), terminate.exitCode());
}

test "signalfd close restores mask and FD exactly once" {
    const before = try currentMask();
    var source = try Source.init();
    const source_fd = source.fd;
    const during = try currentMask();
    try std.testing.expect(posix.sigismember(&during, .INT));
    try std.testing.expect(posix.sigismember(&during, .TERM));

    source.close();
    source.close();
    try std.testing.expectEqual(@as(posix.fd_t, -1), source.fd);
    const after = try currentMask();
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));

    const result = linux.fcntl(source_fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(result));
}
