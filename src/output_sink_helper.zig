//! Fork 前可启动的隔离输出 sink helper。
//!
//! parent 只负责写 output endpoint、poll control summary 和回收 child；child 在
//! 固定 FD 上独占 frame reader 与 stdout/stderr sink，不触碰 D-Bus、Flutter 或 allocator。

const std = @import("std");
const output = @import("application_output.zig");
const linux = std.os.linux;
const posix = std.posix;

comptime {
    if (@import("builtin").os.tag != .linux) @compileError("output sink helper requires Linux fork/close_range");
}

pub const fixed_output_fd: posix.fd_t = 3;
pub const fixed_control_fd: posix.fd_t = 4;
const temporary_fd_start: posix.fd_t = 100;
const summary_size = 32;
const reap_step_ns: u64 = 1 * std.time.ns_per_ms;

pub const SummaryStatus = enum(u8) {
    ok = 1,
    frame_integrity = 2,
    sink_write = 3,
    terminated = 4,
};

pub const Summary = struct {
    status: SummaryStatus,
    totals: output.OutputTotals,
};

pub const TerminalState = enum {
    running,
    finished,
    terminated,
    failed,
};

pub const Error = output.SendError || posix.PollError || error{
    InvalidSinkFd,
    ForkFailed,
    ChildSetupFailed,
    SummaryTruncated,
    InvalidSummary,
    MissingSummary,
    WaitTimeout,
    ReapTimeout,
    WaitFailed,
    SignalFailed,
    ClockFailed,
    AlreadyTerminal,
};

pub const PollResult = union(enum) {
    pending,
    summary: Summary,
    eof,
};

const Deadline = struct {
    expires_ns: u64,

    fn after(timeout_ns: u64) Error!Deadline {
        const now = try monotonicNow();
        return .{ .expires_ns = if (timeout_ns > std.math.maxInt(u64) - now)
            std.math.maxInt(u64)
        else
            now + timeout_ns };
    }

    fn expired(self: *const Deadline) Error!bool {
        return (try monotonicNow()) >= self.expires_ns;
    }
};

fn monotonicNow() Error!u64 {
    var timestamp: posix.timespec = undefined;
    const result = posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &timestamp);
    if (posix.errno(result) != .SUCCESS) return error.ClockFailed;
    return @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.nsec));
}

fn sleepUntil(deadline: Deadline, io: std.Io) Error!void {
    const now = try monotonicNow();
    if (now >= deadline.expires_ns) return;
    const remaining = deadline.expires_ns - now;
    std.Io.sleep(io, .{ .nanoseconds = @min(remaining, reap_step_ns) }, .real) catch {};
}

fn sendSignal(pid: posix.pid_t, signal: posix.SIG) Error!void {
    const result = linux.kill(pid, signal);
    switch (linux.errno(result)) {
        .SUCCESS, .SRCH => {},
        else => return error.SignalFailed,
    }
}

pub const Handle = struct {
    io: std.Io,
    producer: output.Endpoint,
    control: output.Endpoint,
    pid: posix.pid_t,
    summary: ?Summary = null,
    control_eof: bool = false,
    terminal_state: TerminalState = .running,
    last_reap_status: ?u32 = null,

    /// 发送 frame 的唯一 parent-side API；不会在 parent 线程执行终端写。
    pub fn sendFrame(self: *const Handle, frame: output.Frame) Error!void {
        return self.producer.sendFrame(frame);
    }

    /// 关闭 producer 的写方向，使 helper 最终收到 EOF。
    pub fn closeOutput(self: *Handle) void {
        _ = self.producer.shutdownWrite() catch {};
        self.producer.close();
    }

    /// 以 timeout=0 poll summary/control；没有事件时立即返回 pending。
    pub fn pollSummary(self: *Handle) Error!PollResult {
        if (self.control_eof) return .eof;

        var poll_fds = [_]posix.pollfd{.{
            .fd = self.control.fd,
            .events = linux.POLL.IN | linux.POLL.HUP | output.poll_rdhup,
            .revents = 0,
        }};
        _ = try posix.poll(&poll_fds, 0);
        if ((poll_fds[0].revents & (linux.POLL.IN | linux.POLL.HUP | output.poll_rdhup)) == 0) {
            return .pending;
        }

        var packet: [summary_size]u8 = undefined;
        const result = linux.recvfrom(
            self.control.fd,
            &packet,
            packet.len,
            linux.MSG.DONTWAIT | linux.MSG.TRUNC,
            null,
            null,
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) {
                    self.control_eof = true;
                    return .eof;
                }
                if (result > packet.len) return error.SummaryTruncated;
                const summary = decodeSummary(packet[0..result]) catch return error.InvalidSummary;
                self.summary = summary;
                return .{ .summary = summary };
            },
            .INTR => return .pending,
            .AGAIN => return .pending,
            .CONNRESET, .NOTCONN, .SHUTDOWN => {
                self.control_eof = true;
                return .eof;
            },
            else => return error.WaitFailed,
        }
    }

    /// 正常 producer EOF 后等待 summary；超时会主动走 TERM→KILL cleanup。
    /// cleanup 错误优先于原始 WaitTimeout，以免把泄漏的 child 伪装成正常超时。
    pub fn finish(self: *Handle, timeout_ns: u64) Error!Summary {
        switch (self.terminal_state) {
            .finished, .terminated => return self.summary orelse error.MissingSummary,
            .failed => return error.AlreadyTerminal,
            .running => {},
        }
        self.closeOutput();
        const deadline = try Deadline.after(timeout_ns);
        while (true) {
            _ = self.pollSummary() catch |err| return self.finishFailure(err);
            if (self.summary != null and self.control_eof) {
                const reaped = self.tryReap() catch |err| return self.finishFailure(err);
                if (reaped) {
                    self.closeAll();
                    self.terminal_state = .finished;
                    return self.summary orelse error.MissingSummary;
                }
            }
            if (try deadline.expired()) break;
            sleepUntil(deadline, self.io) catch |err| return self.finishFailure(err);
        }
        return self.finishFailure(error.WaitTimeout);
    }

    /// TERM 和 KILL 各自只在 grace deadline 内使用 WNOHANG reap。
    /// reap 失败时保留 pid/FD，调用方可稍后重试；不会伪造已回收状态。
    pub fn terminate(self: *Handle, grace_ns: u64) Error!Summary {
        switch (self.terminal_state) {
            .finished, .terminated => return self.summary orelse .{ .status = .terminated, .totals = .{} },
            .failed, .running => {},
        }
        if (self.pid <= 0) {
            self.closeAll();
            self.terminal_state = .terminated;
            return self.summary orelse .{ .status = .terminated, .totals = .{} };
        }

        try sendSignal(self.pid, .TERM);
        const term_deadline = try Deadline.after(@max(grace_ns, reap_step_ns));
        if (!(try self.reapUntil(term_deadline))) {
            try sendSignal(self.pid, .KILL);
            const kill_deadline = try Deadline.after(@max(grace_ns, reap_step_ns));
            if (!(try self.reapUntil(kill_deadline))) return error.ReapTimeout;
        }
        self.closeAll();
        self.terminal_state = .terminated;
        return self.summary orelse .{ .status = .terminated, .totals = .{} };
    }

    pub fn terminalState(self: *const Handle) TerminalState {
        return self.terminal_state;
    }

    /// cleanup 失败时保留 child/FD ownership，调用方必须决定如何传播错误或重试。
    pub fn deinit(self: *Handle) Error!void {
        if (self.pid > 0) _ = try self.terminate(100 * std.time.ns_per_ms);
        self.closeAll();
    }

    fn closeAll(self: *Handle) void {
        self.closeOutput();
        self.control.close();
    }

    fn finishFailure(self: *Handle, original: Error) Error!Summary {
        _ = self.terminate(100 * std.time.ns_per_ms) catch |cleanup_err| {
            self.terminal_state = .failed;
            return cleanup_err;
        };
        self.terminal_state = .failed;
        return original;
    }

    fn tryReap(self: *Handle) Error!bool {
        if (self.pid <= 0) return true;
        var status: u32 = 0;
        const result = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return false;
                self.last_reap_status = status;
                self.pid = 0;
                return true;
            },
            .CHILD => {
                self.last_reap_status = null;
                self.pid = 0;
                return true;
            },
            .INTR => return false,
            else => return error.WaitFailed,
        }
    }

    fn reapUntil(self: *Handle, deadline: Deadline) Error!bool {
        while (true) {
            if (try self.tryReap()) return true;
            if (try deadline.expired()) return false;
            try sleepUntil(deadline, self.io);
        }
    }
};

const SpawnOptions = struct {
    ignore_term: bool = false,
    ready_handshake: bool = false,
};

/// 在 fork 前创建所有 FD；child 只继承固定 output/control/stdout/stderr 端点。
pub fn spawn(io: std.Io, stdout_fd: posix.fd_t, stderr_fd: posix.fd_t) Error!Handle {
    return spawnWithOptions(io, stdout_fd, stderr_fd, .{});
}

fn spawnWithOptions(io: std.Io, stdout_fd: posix.fd_t, stderr_fd: posix.fd_t, options: SpawnOptions) Error!Handle {
    if (stdout_fd < 0 or stderr_fd < 0) return error.InvalidSinkFd;

    var output_pair = try output.createSocketPair();
    errdefer output_pair.deinit();
    var control_pair = try output.createSocketPair();
    errdefer control_pair.deinit();

    const expected_parent_pid = linux.getpid();
    const raw_pid = linux.fork();
    switch (linux.errno(raw_pid)) {
        .SUCCESS => {},
        else => return error.ForkFailed,
    }
    if (raw_pid == 0) {
        // PDEATHSIG 只兜底保护顶层 cleanup 失败或 parent 异常死亡，不能替代
        // 正常的 TERM→KILL→bounded reap；设置后再次确认 parent 没有竞态退出。
        _ = posix.prctl(.SET_PDEATHSIG, .{@intFromEnum(posix.SIG.KILL)}) catch linux.exit_group(127);
        if (linux.getppid() != expected_parent_pid) linux.exit_group(127);
        output_pair.first.close();
        control_pair.first.close();
        childEntry(output_pair.second.fd, control_pair.second.fd, stdout_fd, stderr_fd, options.ignore_term, options.ready_handshake);
    }

    output_pair.second.close();
    control_pair.second.close();
    return .{
        .io = io,
        .producer = output_pair.first,
        .control = control_pair.first,
        .pid = @intCast(raw_pid),
    };
}

fn childEntry(output_fd: posix.fd_t, control_fd: posix.fd_t, stdout_fd: posix.fd_t, stderr_fd: posix.fd_t, ignore_term: bool, ready_handshake: bool) noreturn {
    if (!remapChildFds(output_fd, control_fd, stdout_fd, stderr_fd)) {
        linux.exit_group(127);
    }
    // helper 不应继承 parent 的 signalfd 屏蔽状态；TERM/INT 必须可在宽限期内默认终止。
    var empty_mask = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty_mask, null);
    const default_action: posix.Sigaction = .{
        .handler = .{ .handler = @ptrFromInt(0) },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &default_action, null);
    if (ignore_term) {
        const ignore_action: posix.Sigaction = .{
            .handler = .{ .handler = @ptrFromInt(1) },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(.TERM, &ignore_action, null);
    } else {
        posix.sigaction(.TERM, &default_action, null);
    }
    // 关闭的 sink 返回 EPIPE 而非杀死 helper，让它发送 sink_write summary。
    const ignore_sigpipe: posix.Sigaction = .{
        .handler = .{ .handler = @ptrFromInt(1) },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ignore_sigpipe, null);
    if (ready_handshake) {
        _ = linux.sendto(fixed_control_fd, "READY", 5, linux.MSG.NOSIGNAL, null, 0);
    }
    childLoop();
}

fn remapChildFds(output_fd: posix.fd_t, control_fd: posix.fd_t, stdout_fd: posix.fd_t, stderr_fd: posix.fd_t) bool {
    const sources = [_]posix.fd_t{ output_fd, control_fd, stdout_fd, stderr_fd };
    var temporary: [sources.len]posix.fd_t = undefined;
    for (sources, 0..) |source, index| {
        const result = linux.fcntl(
            source,
            linux.F.DUPFD_CLOEXEC,
            @as(usize, @intCast(temporary_fd_start + @as(posix.fd_t, @intCast(index)))),
        );
        if (linux.errno(result) != .SUCCESS) return false;
        temporary[index] = @intCast(result);
    }

    const destinations = [_]posix.fd_t{ fixed_output_fd, fixed_control_fd, 1, 2 };
    for (temporary, destinations) |source, destination| {
        const result = linux.dup3(source, destination, linux.SOCK.CLOEXEC);
        if (linux.errno(result) != .SUCCESS) return false;
    }

    const close_result = linux.close_range(5, std.math.maxInt(posix.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
    if (linux.errno(close_result) != .SUCCESS) return false;

    const control_flags = linux.fcntl(fixed_control_fd, linux.F.GETFL, 0);
    if (linux.errno(control_flags) != .SUCCESS) return false;
    const blocking_flags = control_flags & ~@as(usize, linux.SOCK.NONBLOCK);
    const set_result = linux.fcntl(fixed_control_fd, linux.F.SETFL, blocking_flags);
    return linux.errno(set_result) == .SUCCESS;
}

fn childLoop() noreturn {
    var endpoint = output.Endpoint{ .fd = fixed_output_fd };
    var validator: output.FrameValidator = .{};
    var buffer: [output.max_frame_size]u8 = undefined;
    var status: SummaryStatus = .ok;

    while (true) {
        var poll_fds = [_]posix.pollfd{.{
            .fd = fixed_output_fd,
            .events = linux.POLL.IN | linux.POLL.HUP | output.poll_rdhup,
            .revents = 0,
        }};
        _ = posix.poll(&poll_fds, -1) catch {
            status = .terminated;
            break;
        };

        const frame = endpoint.receiveFrame(&buffer) catch |err| {
            status = if (err == error.EndOfStream) .ok else .frame_integrity;
            break;
        };
        var candidate = validator;
        candidate.accept(frame) catch {
            status = .frame_integrity;
            break;
        };
        if (!writeSink(frame)) {
            status = .sink_write;
            break;
        }
        validator = candidate;
    }

    // 仅供 fixture 注入 control EOF-no-summary；正常 helper 必须发送终态 summary。
    if (std.c.getenv("FUSHELL_TEST_NO_HELPER_SUMMARY") == null) {
        sendSummary(.{ .status = status, .totals = validator.totals });
    }
    endpoint.close();
    _ = linux.close(fixed_control_fd);
    linux.exit(0);
}

fn writeSink(frame: output.Frame) bool {
    const fd: posix.fd_t = switch (frame.stream) {
        .stdout => 1,
        .stderr => 2,
    };
    var offset: usize = 0;
    while (offset < frame.payload.len) {
        const result = linux.write(fd, frame.payload[offset..].ptr, frame.payload.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return false;
                offset += result;
            },
            .INTR => continue,
            .PIPE, .CONNRESET, .NOTCONN, .SHUTDOWN => return false,
            else => return false,
        }
    }
    return true;
}

fn sendSummary(summary: Summary) void {
    var packet: [summary_size]u8 = undefined;
    encodeSummary(summary, &packet);
    while (true) {
        const result = linux.sendto(fixed_control_fd, &packet, packet.len, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(result)) {
            .SUCCESS => if (result == packet.len) return else linux.exit_group(127),
            .INTR => continue,
            else => linux.exit_group(127),
        }
    }
}

fn encodeSummary(summary: Summary, packet: *[summary_size]u8) void {
    @memcpy(packet[0..4], "FSH1");
    packet[4] = @intFromEnum(summary.status);
    @memset(packet[5..8], 0);
    std.mem.writeInt(u64, packet[8..16], summary.totals.frame_count, .big);
    std.mem.writeInt(u64, packet[16..24], summary.totals.stdout_bytes, .big);
    std.mem.writeInt(u64, packet[24..32], summary.totals.stderr_bytes, .big);
}

fn decodeSummary(packet: []const u8) Error!Summary {
    if (packet.len != summary_size or !std.mem.eql(u8, packet[0..4], "FSH1") or !std.mem.eql(u8, packet[5..8], &[_]u8{ 0, 0, 0 })) {
        return error.InvalidSummary;
    }
    const status: SummaryStatus = switch (packet[4]) {
        1 => .ok,
        2 => .frame_integrity,
        3 => .sink_write,
        4 => .terminated,
        else => return error.InvalidSummary,
    };
    return .{
        .status = status,
        .totals = .{
            .frame_count = std.mem.readInt(u64, packet[8..16], .big),
            .stdout_bytes = std.mem.readInt(u64, packet[16..24], .big),
            .stderr_bytes = std.mem.readInt(u64, packet[24..32], .big),
        },
    };
}

fn waitSteps(timeout_ns: u64) usize {
    const rounded = timeout_ns / reap_step_ns + @intFromBool(timeout_ns % reap_step_ns != 0);
    return @intCast(@max(@as(u64, 1), rounded));
}

fn countOpenFds(io: std.Io) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

test "helper preserves interleaved binary streams and reports summary" {
    const io = std.testing.io;
    var stdout_pipe: [2]i32 = undefined;
    var stderr_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&stdout_pipe, .{ .CLOEXEC = true })));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&stderr_pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(stdout_pipe[0]);
    defer _ = linux.close(stderr_pipe[0]);

    var helper = try spawn(io, stdout_pipe[1], stderr_pipe[1]);
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    _ = linux.close(stdout_pipe[1]);
    _ = linux.close(stderr_pipe[1]);

    const out_one = [_]u8{ 0, 0xff, 0x01 };
    const err_one = [_]u8{ 0x80, 0x00 };
    const out_two = [_]u8{ 0xfe, 0x0a };
    try helper.sendFrame(.{ .stream = .stdout, .sequence = 0, .payload = &out_one });
    try helper.sendFrame(.{ .stream = .stderr, .sequence = 1, .payload = &err_one });
    try helper.sendFrame(.{ .stream = .stdout, .sequence = 2, .payload = &out_two });
    const summary = try helper.finish(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(SummaryStatus.ok, summary.status);
    try std.testing.expectEqual(@as(posix.pid_t, 0), helper.pid);
    try std.testing.expectEqual(@as(posix.fd_t, -1), helper.control.fd);
    try std.testing.expectEqual(@as(u64, 3), summary.totals.frame_count);
    try std.testing.expectEqual(@as(u64, 7), summary.totals.stdout_bytes + summary.totals.stderr_bytes);
    try std.testing.expectEqual(TerminalState.finished, helper.terminalState());
    const repeated = try helper.finish(1 * std.time.ns_per_ms);
    try std.testing.expectEqual(summary.totals.frame_count, repeated.totals.frame_count);

    var stdout_data: [out_one.len + out_two.len]u8 = undefined;
    var stderr_data: [err_one.len]u8 = undefined;
    try readExact(stdout_pipe[0], &stdout_data);
    try readExact(stderr_pipe[0], &stderr_data);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0xff, 0x01, 0xfe, 0x0a }, &stdout_data);
    try std.testing.expectEqualSlices(u8, &err_one, &stderr_data);
}

test "helper reports frame integrity and parent poll stays nonblocking" {
    const io = std.testing.io;
    const null_fd = linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(null_fd));
    defer _ = linux.close(@intCast(null_fd));

    var helper = try spawn(io, @intCast(null_fd), @intCast(null_fd));
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    const initial = try helper.pollSummary();
    try std.testing.expectEqual(PollResult.pending, initial);

    try helper.sendFrame(.{ .stream = .stdout, .sequence = 1, .payload = "gap" });
    const summary = try helper.finish(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(SummaryStatus.frame_integrity, summary.status);
    try std.testing.expectEqual(@as(u64, 0), summary.totals.frame_count);
}

test "helper rejects malformed wire packet with integrity summary" {
    const io = std.testing.io;
    const null_fd = linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(null_fd));
    defer _ = linux.close(@intCast(null_fd));

    var helper = try spawn(io, @intCast(null_fd), @intCast(null_fd));
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    var malformed: [output.header_size + 1]u8 = undefined;
    @memset(&malformed, 0);
    @memcpy(malformed[0..4], "NOPE");
    malformed[4] = 1;
    malformed[19] = 1;
    malformed[20] = 0xff;
    const sent = linux.sendto(
        helper.producer.fd,
        &malformed,
        malformed.len,
        linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL,
        null,
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(sent));

    const summary = try helper.finish(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(SummaryStatus.frame_integrity, summary.status);
    try std.testing.expectEqual(@as(u64, 0), summary.totals.frame_count);
}

test "helper reports sink write failure with delivered summary" {
    const io = std.testing.io;
    const full_fd = linux.open("/dev/full", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(full_fd));
    defer _ = linux.close(@intCast(full_fd));

    var helper = try spawn(io, @intCast(full_fd), @intCast(full_fd));
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    try helper.sendFrame(.{ .stream = .stdout, .sequence = 0, .payload = "full" });

    const summary = try helper.finish(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(SummaryStatus.sink_write, summary.status);
    try std.testing.expectEqual(@as(u64, 0), summary.totals.frame_count);
}

test "closed sink pipe becomes sink_write summary instead of SIGPIPE death" {
    const io = std.testing.io;
    var sink_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&sink_pipe, .{ .CLOEXEC = true })));

    var helper = try spawn(io, sink_pipe[1], sink_pipe[1]);
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    _ = linux.close(sink_pipe[0]);
    _ = linux.close(sink_pipe[1]);

    try helper.sendFrame(.{ .stream = .stdout, .sequence = 0, .payload = "closed" });
    const summary = try helper.finish(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(SummaryStatus.sink_write, summary.status);
    try std.testing.expectEqual(@as(u64, 0), summary.totals.frame_count);
    try std.testing.expectEqual(@as(posix.pid_t, 0), helper.pid);
}

test "helper receives PDEATHSIG when its short-lived parent exits" {
    const io = std.testing.io;
    var report_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&report_pipe, .{ .CLOEXEC = true })));
    const short_parent_raw = linux.fork();
    switch (linux.errno(short_parent_raw)) {
        .SUCCESS => {},
        else => return error.ForkFailed,
    }
    const short_parent: posix.pid_t = @intCast(short_parent_raw);
    if (short_parent == 0) {
        _ = linux.close(report_pipe[0]);
        const null_fd = linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        if (linux.errno(null_fd) != .SUCCESS) linux.exit_group(127);
        const helper = spawn(io, @intCast(null_fd), @intCast(null_fd)) catch linux.exit_group(127);
        var helper_pid = helper.pid;
        _ = linux.write(report_pipe[1], std.mem.asBytes(&helper_pid).ptr, @sizeOf(posix.pid_t));
        _ = linux.close(@intCast(null_fd));
        _ = linux.close(report_pipe[1]);
        linux.exit_group(0);
    }
    _ = linux.close(report_pipe[1]);
    var report_fds = [_]posix.pollfd{.{ .fd = report_pipe[0], .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&report_fds, 500));
    var helper_pid: posix.pid_t = 0;
    const received = linux.read(report_pipe[0], std.mem.asBytes(&helper_pid).ptr, @sizeOf(posix.pid_t));
    _ = linux.close(report_pipe[0]);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(received));
    try std.testing.expectEqual(@as(usize, @sizeOf(posix.pid_t)), received);

    const deadline = try Deadline.after(500 * std.time.ns_per_ms);
    var parent_status: u32 = 0;
    while (true) {
        const waited = linux.waitpid(short_parent, &parent_status, linux.W.NOHANG);
        if (linux.errno(waited) == .SUCCESS and waited != 0) break;
        if (try deadline.expired()) return error.TestTimeout;
        try sleepUntil(deadline, io);
    }
    while (linux.errno(linux.kill(helper_pid, @enumFromInt(0))) == .SUCCESS) {
        if (try deadline.expired()) return error.TestTimeout;
        try sleepUntil(deadline, io);
    }
}

test "helper terminate records the normal SIGTERM wait status" {
    const io = std.testing.io;
    const null_fd = linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(null_fd));
    defer _ = linux.close(@intCast(null_fd));

    var helper = try spawn(io, @intCast(null_fd), @intCast(null_fd));
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    _ = try helper.terminate(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(posix.pid_t, 0), helper.pid);
    try std.testing.expect(helper.last_reap_status != null);
    try std.testing.expectEqual(@as(u32, 15), helper.last_reap_status.? & 0x7f);
}

test "helper clears ownership after an external waitpid reaps the child" {
    const io = std.testing.io;
    const null_fd = linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(null_fd));
    defer _ = linux.close(@intCast(null_fd));

    var helper = try spawn(io, @intCast(null_fd), @intCast(null_fd));
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    const deadline = try Deadline.after(500 * std.time.ns_per_ms);
    _ = linux.kill(helper.pid, .TERM);
    while (true) {
        var status: u32 = 0;
        const waited = linux.waitpid(helper.pid, &status, linux.W.NOHANG);
        if (linux.errno(waited) == .SUCCESS and waited != 0) break;
        if (try deadline.expired()) return error.TestTimeout;
        try sleepUntil(deadline, io);
    }
    try std.testing.expect(try helper.tryReap());
    try std.testing.expectEqual(@as(posix.pid_t, 0), helper.pid);
    try std.testing.expect(helper.last_reap_status == null);
}

test "helper KILL fallback reaps a child that ignores SIGTERM" {
    const io = std.testing.io;
    const null_fd = linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(null_fd));
    defer _ = linux.close(@intCast(null_fd));

    var helper = try spawnWithOptions(io, @intCast(null_fd), @intCast(null_fd), .{ .ignore_term = true, .ready_handshake = true });
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    var ready_fds = [_]posix.pollfd{.{ .fd = helper.control.fd, .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&ready_fds, 500));
    var ready: [5]u8 = undefined;
    const ready_size = linux.recvfrom(helper.control.fd, &ready, ready.len, linux.MSG.DONTWAIT, null, null);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(ready_size));
    try std.testing.expectEqualSlices(u8, "READY", ready[0..@intCast(ready_size)]);
    _ = try helper.terminate(5 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(posix.pid_t, 0), helper.pid);
    try std.testing.expectEqual(@as(u32, 9), helper.last_reap_status.? & 0x7f);
}

test "helper TERM/KILL path reaps child and returns FD count to baseline" {
    const io = std.testing.io;
    const before = try countOpenFds(io);
    var sink_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&sink_pipe, .{ .CLOEXEC = true })));
    var sink_read = sink_pipe[0];
    defer {
        if (sink_read >= 0) _ = linux.close(sink_read);
    }

    var helper = try spawn(io, sink_pipe[1], sink_pipe[1]);
    defer helper.deinit() catch @panic("sink helper cleanup failed");
    _ = linux.close(sink_pipe[1]);
    sink_pipe[1] = -1;

    var payload: [output.max_payload_size]u8 = undefined;
    @memset(&payload, 0x7e);
    var sequence: u64 = 0;
    var saw_would_block = false;
    while (sequence < 256) : (sequence += 1) {
        helper.sendFrame(.{ .stream = .stdout, .sequence = sequence, .payload = &payload }) catch |err| {
            try std.testing.expectEqual(error.WouldBlock, err);
            saw_would_block = true;
            break;
        };
    }
    try std.testing.expect(saw_would_block);
    try std.testing.expectEqual(PollResult.pending, try helper.pollSummary());

    const child_pid = helper.pid;
    try std.testing.expectError(error.WaitTimeout, helper.finish(1 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(posix.pid_t, 0), helper.pid);
    try std.testing.expectEqual(@as(posix.fd_t, -1), helper.control.fd);
    helper.deinit() catch @panic("sink helper cleanup failed");
    _ = linux.close(sink_read);
    sink_read = -1;

    const after = try countOpenFds(io);
    try std.testing.expectEqual(before, after);
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(linux.kill(child_pid, @enumFromInt(0))));
}

fn readExact(fd: posix.fd_t, destination: []u8) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const result = linux.read(fd, destination[offset..].ptr, destination.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.UnexpectedEof;
                offset += result;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}
