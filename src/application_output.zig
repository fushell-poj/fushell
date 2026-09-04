//! 单例命令输出的数据面：FSO2 frame codec 与 Linux Unix socketpair transport。
//!
//! 该模块只定义 wire/FD 基础，不持有 D-Bus、Flutter 或 broker 状态。frame
//! payload 借用调用方内存；transport 的 Endpoint 则独占并负责其 FD 所有权。

const builtin = @import("builtin");
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

comptime {
    if (builtin.os.tag != .linux) @compileError("application output transport requires Linux SOCK_SEQPACKET");
}

pub const header_size = 20;
pub const max_payload_size = 32 * 1024;
pub const max_frame_size = header_size + max_payload_size;
pub const max_output_bytes = 8 * 1024 * 1024;
/// Linux `POLLRDHUP` 未在 Zig 0.16 的 std.os.linux.POLL 中导出。
pub const poll_rdhup: i16 = 0x2000;

pub const Stream = enum(u8) {
    stdout = 1,
    stderr = 2,
};

pub const Frame = struct {
    stream: Stream,
    sequence: u64,
    payload: []const u8,
};

pub const CodecError = error{
    BufferTooSmall,
    InvalidMagic,
    InvalidStream,
    InvalidFlags,
    InvalidReserved,
    PacketTruncated,
    PacketLengthMismatch,
    PayloadTooLarge,
    ZeroPayload,
};

pub const AccountingError = error{
    SequenceGap,
    SequenceOverflow,
    FrameCountOverflow,
    OutputLimitExceeded,
    CounterMismatch,
    ZeroPayload,
};

pub const TransportError = error{
    BadDescriptor,
    SocketPairCreateFailed,
    DuplicateFailed,
    WouldBlock,
    EndOfStream,
    PeerClosed,
    PartialPacket,
    InvalidSocketType,
    InvalidSocketDomain,
    SocketInspectionFailed,
    ShutdownFailed,
    SystemCallFailed,
};

pub const EncodeError = CodecError;
pub const DecodeError = CodecError;
pub const SendError = CodecError || TransportError;
pub const ReceiveError = CodecError || TransportError;
pub const ValidateError = CodecError || AccountingError;

/// 返回 frame 在 seqpacket 中占用的完整字节数，并拒绝超限 payload。
pub fn encodedFrameSize(frame: Frame) CodecError!usize {
    if (frame.payload.len == 0) return error.ZeroPayload;
    if (frame.payload.len > max_payload_size) return error.PayloadTooLarge;
    return header_size + frame.payload.len;
}

/// 将一个 frame 编码到调用方提供的连续 buffer；不会分配或截断 payload。
pub fn encodeFrame(frame: Frame, destination: []u8) EncodeError![]u8 {
    const size = try encodedFrameSize(frame);
    if (destination.len < size) return error.BufferTooSmall;

    @memcpy(destination[0..4], "FSO2");
    destination[4] = @intFromEnum(frame.stream);
    destination[5] = 0;
    std.mem.writeInt(u16, destination[6..8], 0, .big);
    std.mem.writeInt(u64, destination[8..16], frame.sequence, .big);
    std.mem.writeInt(u32, destination[16..20], @intCast(frame.payload.len), .big);
    @memcpy(destination[header_size..size], frame.payload);
    return destination[0..size];
}

/// 解码一份完整 seqpacket；返回的 payload 借用 packet 的存储。
pub fn decodeFrame(packet: []const u8) DecodeError!Frame {
    if (packet.len < header_size) return error.PacketTruncated;
    if (!std.mem.eql(u8, packet[0..4], "FSO2")) return error.InvalidMagic;
    if (packet[5] != 0) return error.InvalidFlags;
    if (std.mem.readInt(u16, packet[6..8], .big) != 0) return error.InvalidReserved;

    const stream: Stream = switch (packet[4]) {
        1 => .stdout,
        2 => .stderr,
        else => return error.InvalidStream,
    };
    const sequence = std.mem.readInt(u64, packet[8..16], .big);
    const payload_length = std.mem.readInt(u32, packet[16..20], .big);
    if (payload_length == 0) return error.ZeroPayload;
    if (payload_length > max_payload_size) return error.PayloadTooLarge;

    const expected_size = header_size + @as(usize, payload_length);
    if (packet.len < expected_size) return error.PacketTruncated;
    if (packet.len > expected_size) return error.PacketLengthMismatch;
    return .{
        .stream = stream,
        .sequence = sequence,
        .payload = packet[header_size..expected_size],
    };
}

pub const OutputTotals = struct {
    frame_count: u64 = 0,
    stdout_bytes: u64 = 0,
    stderr_bytes: u64 = 0,

    pub fn totalBytes(self: OutputTotals) u64 {
        return self.stdout_bytes + self.stderr_bytes;
    }

    /// 原子地检查并记录一帧；失败时 totals 保持不变。
    pub fn add(self: *OutputTotals, stream: Stream, byte_count: usize) AccountingError!void {
        if (byte_count == 0) return error.ZeroPayload;
        const bytes: u64 = @intCast(byte_count);
        if (bytes > max_output_bytes or self.totalBytes() > max_output_bytes - bytes) {
            return error.OutputLimitExceeded;
        }
        if (self.frame_count == std.math.maxInt(u64)) return error.FrameCountOverflow;

        self.frame_count += 1;
        switch (stream) {
            .stdout => self.stdout_bytes += bytes,
            .stderr => self.stderr_bytes += bytes,
        }
    }

    pub fn expectEqual(self: OutputTotals, expected: OutputTotals) AccountingError!void {
        if (self.frame_count != expected.frame_count or
            self.stdout_bytes != expected.stdout_bytes or
            self.stderr_bytes != expected.stderr_bytes)
        {
            return error.CounterMismatch;
        }
    }
};

/// 分开记录 SDK/native 接受的 logical bytes 与 send 成功后的 delivered counters。
pub const OutputAccounting = struct {
    logical: OutputTotals = .{},
    delivered: OutputTotals = .{},

    pub fn validateLogical(self: *const OutputAccounting, frame: Frame) AccountingError!void {
        var candidate = self.logical;
        try candidate.add(frame.stream, frame.payload.len);
    }

    pub fn acceptLogical(self: *OutputAccounting, frame: Frame) AccountingError!void {
        try self.logical.add(frame.stream, frame.payload.len);
    }

    pub fn markDelivered(self: *OutputAccounting, frame: Frame) AccountingError!void {
        try self.delivered.add(frame.stream, frame.payload.len);
    }
};

/// 以全局 sequence 检查 frame，并累计两个 stream 的已接收 raw bytes。
pub const FrameValidator = struct {
    next_sequence: u64 = 0,
    totals: OutputTotals = .{},

    pub fn accept(self: *FrameValidator, frame: Frame) ValidateError!void {
        if (frame.sequence != self.next_sequence) return error.SequenceGap;
        if (self.next_sequence == std.math.maxInt(u64)) return error.SequenceOverflow;

        var next_totals = self.totals;
        try next_totals.add(frame.stream, frame.payload.len);
        self.totals = next_totals;
        self.next_sequence += 1;
    }
};

pub const Endpoint = struct {
    /// 设为 -1 后 Endpoint 不再拥有任何可关闭的 FD。
    fd: posix.fd_t,
    write_shutdown: bool = false,

    pub fn duplicate(self: *const Endpoint) TransportError!Endpoint {
        if (self.fd < 0) return error.BadDescriptor;
        const result = linux.fcntl(self.fd, linux.F.DUPFD_CLOEXEC, 0);
        return switch (linux.errno(result)) {
            .SUCCESS => .{ .fd = @intCast(result) },
            else => error.DuplicateFailed,
        };
    }

    /// 在 primary 接管 D-Bus FD 前确认它仍是预期的 Unix seqpacket socket。
    pub fn validateSocket(self: *const Endpoint) TransportError!void {
        if (self.fd < 0) return error.BadDescriptor;

        var socket_type: i32 = 0;
        var type_length: linux.socklen_t = @sizeOf(i32);
        var result = linux.getsockopt(
            self.fd,
            linux.SOL.SOCKET,
            linux.SO.TYPE,
            std.mem.asBytes(&socket_type).ptr,
            &type_length,
        );
        if (linux.errno(result) != .SUCCESS) return error.SocketInspectionFailed;
        if (socket_type != linux.SOCK.SEQPACKET) return error.InvalidSocketType;

        var socket_domain: i32 = 0;
        var domain_length: linux.socklen_t = @sizeOf(i32);
        result = linux.getsockopt(
            self.fd,
            linux.SOL.SOCKET,
            linux.SO.DOMAIN,
            std.mem.asBytes(&socket_domain).ptr,
            &domain_length,
        );
        if (linux.errno(result) != .SUCCESS) return error.SocketInspectionFailed;
        if (socket_domain != linux.AF.UNIX) return error.InvalidSocketDomain;
    }

    /// 发送半关闭是 producer 的明确 EOF；重复调用不会再次触碰内核 FD。
    pub fn shutdownWrite(self: *Endpoint) TransportError!void {
        if (self.fd < 0) return error.BadDescriptor;
        if (self.write_shutdown) return;

        while (true) {
            const result = linux.shutdown(self.fd, linux.SHUT.WR);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    self.write_shutdown = true;
                    return;
                },
                .INTR => continue,
                .NOTCONN, .SHUTDOWN => return error.PeerClosed,
                else => return error.ShutdownFailed,
            }
        }
    }

    /// 只标记 HUP/RDHUP；可读数据仍须先由调用方 drain。
    pub fn hasPeerHangup(revents: i16) bool {
        return (revents & (linux.POLL.HUP | poll_rdhup)) != 0;
    }

    /// 以单次 send 保持 seqpacket frame 原子性；EAGAIN 不会缓存 frame。
    pub fn sendFrame(self: *const Endpoint, frame: Frame) SendError!void {
        if (self.fd < 0) return error.BadDescriptor;
        if (self.write_shutdown) return error.PeerClosed;
        var packet: [max_frame_size]u8 = undefined;
        const encoded = try encodeFrame(frame, &packet);

        while (true) {
            const result = linux.sendto(
                self.fd,
                encoded.ptr,
                encoded.len,
                linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL,
                null,
                0,
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result != encoded.len) return error.PartialPacket;
                    return;
                },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .PIPE, .CONNRESET, .NOTCONN, .SHUTDOWN => return error.PeerClosed,
                else => return error.SystemCallFailed,
            }
        }
    }

    /// 从非阻塞 seqpacket 接收一份 frame；MSG_TRUNC 将 packet 截断显式报告。
    pub fn receiveFrame(self: *const Endpoint, buffer: []u8) ReceiveError!Frame {
        if (self.fd < 0) return error.BadDescriptor;
        if (buffer.len == 0) return error.BufferTooSmall;

        while (true) {
            const result = linux.recvfrom(
                self.fd,
                buffer.ptr,
                buffer.len,
                linux.MSG.DONTWAIT | linux.MSG.TRUNC,
                null,
                null,
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return error.EndOfStream;
                    if (result > buffer.len) return error.PacketTruncated;
                    return decodeFrame(buffer[0..result]);
                },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .CONNRESET, .NOTCONN, .SHUTDOWN => return error.PeerClosed,
                else => return error.SystemCallFailed,
            }
        }
    }

    /// 幂等关闭；调用方可在所有 teardown 路径上重复调用。
    pub fn close(self: *Endpoint) void {
        if (self.fd < 0) return;
        const fd = self.fd;
        self.fd = -1;
        _ = linux.close(fd);
    }
};

pub const SocketPair = struct {
    first: Endpoint,
    second: Endpoint,

    pub fn close(self: *SocketPair) void {
        self.first.close();
        self.second.close();
    }

    pub fn deinit(self: *SocketPair) void {
        self.close();
    }
};

/// 创建两个同时具备 SOCK_SEQPACKET、CLOEXEC 与 NONBLOCK 的互联 endpoint。
pub fn createSocketPair() TransportError!SocketPair {
    var fds: [2]i32 = undefined;
    const result = linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &fds,
    );
    if (linux.errno(result) != .SUCCESS) return error.SocketPairCreateFailed;
    errdefer _ = linux.close(fds[0]);
    errdefer _ = linux.close(fds[1]);
    return .{
        .first = .{ .fd = fds[0] },
        .second = .{ .fd = fds[1] },
    };
}

fn expectClosed(fd: posix.fd_t) !void {
    const result = linux.fcntl(fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(result));
}

test "FSO2 codec preserves binary payload and big-endian header" {
    var wire: [max_frame_size]u8 = undefined;
    const payload = [_]u8{ 0x00, 0xff, 0x01, 0x80, 0x0a };
    const encoded = try encodeFrame(.{
        .stream = .stderr,
        .sequence = 0x0102_0304_0506_0708,
        .payload = &payload,
    }, &wire);

    const expected = [_]u8{
        'F',  'S',  'O',  '2',  2,    0,    0,    0,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0,    0,    0,    5,    0x00, 0xff, 0x01, 0x80,
        0x0a,
    };
    try std.testing.expectEqualSlices(u8, &expected, encoded);

    const decoded = try decodeFrame(encoded);
    try std.testing.expectEqual(Stream.stderr, decoded.stream);
    try std.testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), decoded.sequence);
    try std.testing.expectEqualSlices(u8, &payload, decoded.payload);
}

test "codec rejects malformed headers, truncation, and trailing bytes" {
    var wire: [max_frame_size]u8 = undefined;
    const payload = [_]u8{0xaa};
    const encoded = try encodeFrame(.{ .stream = .stdout, .sequence = 0, .payload = &payload }, &wire);

    wire[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decodeFrame(encoded));
    wire[0] = 'F';
    wire[5] = 1;
    try std.testing.expectError(error.InvalidFlags, decodeFrame(encoded));
    wire[5] = 0;
    wire[6] = 1;
    try std.testing.expectError(error.InvalidReserved, decodeFrame(encoded));
    wire[6] = 0;
    wire[4] = 3;
    try std.testing.expectError(error.InvalidStream, decodeFrame(encoded));
    wire[4] = 1;

    try std.testing.expectError(error.PacketTruncated, decodeFrame(encoded[0 .. encoded.len - 1]));
    wire[16] = 0;
    wire[17] = 0;
    wire[18] = 0;
    wire[19] = 2;
    try std.testing.expectError(error.PacketTruncated, decodeFrame(encoded));
    wire[19] = 1;
    wire[encoded.len] = 0;
    try std.testing.expectError(error.PacketLengthMismatch, decodeFrame(wire[0 .. encoded.len + 1]));

    var oversized = wire[0..header_size];
    std.mem.writeInt(u32, oversized[16..20], max_payload_size + 1, .big);
    try std.testing.expectError(error.PayloadTooLarge, decodeFrame(oversized));
    try std.testing.expectError(error.ZeroPayload, decodeFrame(&[_]u8{
        'F', 'S', 'O', '2', 1, 0, 0, 0,
        0,   0,   0,   0,   0, 0, 0, 0,
        0,   0,   0,   0,
    }));
    try std.testing.expectError(error.ZeroPayload, encodeFrame(.{
        .stream = .stdout,
        .sequence = 0,
        .payload = &[_]u8{},
    }, &wire));
    try std.testing.expectError(error.PacketTruncated, decodeFrame(&[_]u8{ 'F', 'S', 'O' }));
}

test "codec enforces the 32 KiB payload boundary" {
    var wire: [max_frame_size]u8 = undefined;
    var payload: [max_payload_size]u8 = undefined;
    @memset(&payload, 0x5a);
    const encoded = try encodeFrame(.{ .stream = .stdout, .sequence = 0, .payload = &payload }, &wire);
    try std.testing.expectEqual(@as(usize, max_frame_size), encoded.len);
    try std.testing.expectEqual(max_payload_size, (try decodeFrame(encoded)).payload.len);

    var oversized: [max_payload_size + 1]u8 = undefined;
    try std.testing.expectError(error.PayloadTooLarge, encodeFrame(.{
        .stream = .stdout,
        .sequence = 1,
        .payload = &oversized,
    }, &wire));
}

test "frame validator detects sequence gaps and accounts for exactly 8 MiB" {
    var validator: FrameValidator = .{};
    var payload: [max_payload_size]u8 = undefined;
    @memset(&payload, 0x11);

    for (0..max_output_bytes / max_payload_size) |sequence| {
        try validator.accept(.{
            .stream = if (sequence % 2 == 0) .stdout else .stderr,
            .sequence = @intCast(sequence),
            .payload = &payload,
        });
    }
    try std.testing.expectEqual(@as(u64, max_output_bytes), validator.totals.totalBytes());
    try std.testing.expectEqual(@as(u64, max_output_bytes / max_payload_size), validator.totals.frame_count);

    const before = validator.totals;
    try std.testing.expectError(error.OutputLimitExceeded, validator.accept(.{
        .stream = .stdout,
        .sequence = validator.next_sequence,
        .payload = "x",
    }));
    try validator.totals.expectEqual(before);

    var gap: FrameValidator = .{};
    try std.testing.expectError(error.SequenceGap, gap.accept(.{ .stream = .stdout, .sequence = 1, .payload = "gap" }));
    try std.testing.expectEqual(@as(u64, 0), gap.next_sequence);
}

test "socketpair has packet boundaries, CLOEXEC, and NONBLOCK" {
    var pair = try createSocketPair();
    defer pair.deinit();
    try pair.first.validateSocket();
    try pair.second.validateSocket();

    for ([_]posix.fd_t{ pair.first.fd, pair.second.fd }) |fd| {
        const fd_flags = linux.fcntl(fd, linux.F.GETFD, 0);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd_flags));
        try std.testing.expect((fd_flags & linux.FD_CLOEXEC) != 0);

        const status_flags = linux.fcntl(fd, linux.F.GETFL, 0);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(status_flags));
        try std.testing.expect((status_flags & linux.SOCK.NONBLOCK) != 0);
    }

    const payload = [_]u8{ 0, 0xff, 0x7f };
    try pair.first.sendFrame(.{ .stream = .stdout, .sequence = 0, .payload = &payload });
    var buffer: [max_frame_size]u8 = undefined;
    const frame = try pair.second.receiveFrame(&buffer);
    try std.testing.expectEqualSlices(u8, &payload, frame.payload);

    var large_payload: [max_payload_size]u8 = undefined;
    var wire: [max_frame_size]u8 = undefined;
    @memset(&large_payload, 0x44);
    const large_packet = try encodeFrame(.{
        .stream = .stderr,
        .sequence = 1,
        .payload = &large_payload,
    }, &wire);
    const sent = linux.sendto(
        pair.first.fd,
        large_packet.ptr,
        large_packet.len,
        linux.MSG.NOSIGNAL,
        null,
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(sent));
    var short_buffer: [header_size]u8 = undefined;
    try std.testing.expectError(error.PacketTruncated, pair.second.receiveFrame(&short_buffer));
}

test "socket validation rejects stream sockets and non-sockets" {
    var stream_fds: [2]i32 = undefined;
    const stream_result = linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &stream_fds,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(stream_result));
    var stream_first = Endpoint{ .fd = stream_fds[0] };
    var stream_second = Endpoint{ .fd = stream_fds[1] };
    defer stream_first.close();
    defer stream_second.close();
    try std.testing.expectError(error.InvalidSocketType, stream_first.validateSocket());

    var pipes: [2]i32 = undefined;
    const pipe_result = linux.pipe2(&pipes, .{ .CLOEXEC = true, .NONBLOCK = true });
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(pipe_result));
    var pipe_endpoint = Endpoint{ .fd = pipes[0] };
    var pipe_peer = Endpoint{ .fd = pipes[1] };
    defer pipe_endpoint.close();
    defer pipe_peer.close();
    try std.testing.expectError(error.SocketInspectionFailed, pipe_endpoint.validateSocket());
}

test "duplicate owns an independent CLOEXEC FD and close is idempotent" {
    var pair = try createSocketPair();
    defer pair.deinit();
    const original_fd = pair.first.fd;
    var duplicate = try pair.first.duplicate();
    defer duplicate.close();

    const duplicate_flags = linux.fcntl(duplicate.fd, linux.F.GETFD, 0);
    try std.testing.expect((duplicate_flags & linux.FD_CLOEXEC) != 0);
    pair.first.close();
    pair.first.close();
    try expectClosed(original_fd);

    try duplicate.sendFrame(.{ .stream = .stderr, .sequence = 0, .payload = "dup" });
    var buffer: [max_frame_size]u8 = undefined;
    const frame = try pair.second.receiveFrame(&buffer);
    try std.testing.expectEqualSlices(u8, "dup", frame.payload);

    duplicate.close();
    duplicate.close();
    try std.testing.expectError(error.EndOfStream, pair.second.receiveFrame(&buffer));
}

test "shutdownWrite emits producer EOF and HUP/RDHUP is observable" {
    var pair = try createSocketPair();
    defer pair.deinit();

    try pair.first.sendFrame(.{ .stream = .stdout, .sequence = 0, .payload = "before eof" });
    try pair.first.shutdownWrite();
    try pair.first.shutdownWrite();
    try std.testing.expectError(error.PeerClosed, pair.first.sendFrame(.{
        .stream = .stdout,
        .sequence = 1,
        .payload = "after eof",
    }));

    var buffer: [max_frame_size]u8 = undefined;
    const frame = try pair.second.receiveFrame(&buffer);
    try std.testing.expectEqualSlices(u8, "before eof", frame.payload);
    try std.testing.expectError(error.EndOfStream, pair.second.receiveFrame(&buffer));

    pair.second.close();
    var poll_fds = [_]posix.pollfd{.{
        .fd = pair.first.fd,
        .events = linux.POLL.IN | linux.POLL.HUP | poll_rdhup,
        .revents = 0,
    }};
    _ = try posix.poll(&poll_fds, 0);
    try std.testing.expect(Endpoint.hasPeerHangup(poll_fds[0].revents));
}

test "transport reports EAGAIN, EOF, and peer close without blocking" {
    var pair = try createSocketPair();
    defer pair.deinit();

    var payload: [max_payload_size]u8 = undefined;
    @memset(&payload, 0x33);
    var sequence: u64 = 0;
    var saw_would_block = false;
    while (sequence < 1024) : (sequence += 1) {
        pair.first.sendFrame(.{ .stream = .stdout, .sequence = sequence, .payload = &payload }) catch |err| {
            try std.testing.expectEqual(error.WouldBlock, err);
            saw_would_block = true;
            break;
        };
    }
    try std.testing.expect(saw_would_block);

    pair.second.close();
    try std.testing.expectError(error.PeerClosed, pair.first.sendFrame(.{
        .stream = .stdout,
        .sequence = sequence,
        .payload = "peer closed",
    }));

    var eof_pair = try createSocketPair();
    defer eof_pair.deinit();
    var buffer: [max_frame_size]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, eof_pair.second.receiveFrame(&buffer));
    eof_pair.first.close();
    try std.testing.expectError(error.EndOfStream, eof_pair.second.receiveFrame(&buffer));
}

test "logical and delivered accounting remain independent" {
    var accounting: OutputAccounting = .{};
    const first = Frame{ .stream = .stdout, .sequence = 0, .payload = "logical" };
    const second = Frame{ .stream = .stderr, .sequence = 1, .payload = "drop" };
    try accounting.acceptLogical(first);
    try accounting.acceptLogical(second);
    try accounting.markDelivered(first);
    try std.testing.expectEqual(@as(u64, 11), accounting.logical.totalBytes());
    try std.testing.expectEqual(@as(u64, 7), accounting.delivered.totalBytes());
    try std.testing.expectEqual(@as(u64, 2), accounting.logical.frame_count);
    try std.testing.expectEqual(@as(u64, 1), accounting.delivered.frame_count);
}
