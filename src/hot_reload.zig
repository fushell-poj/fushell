//! 热重载: VM service WebSocket 客户端 + JSON-RPC (最小实现)。
//!
//! VM service = Dart VM 内建的调试服务 (WebSocket + JSON-RPC):
//!   - 地址: http://127.0.0.1:PORT/TOKEN/ (从引擎日志解析, 见 flutter_runner)
//!   - 热重载: reloadSources(isolateId) 替换已加载代码
//!             ext.flutter.reassemble 重建 widget 树
//!
//! 本模块只实现客户端最小子集: TCP 连接 + HTTP Upgrade 握手 +
//! text 帧编解码 + JSON-RPC 请求/响应。

/// VM service 响应等待超时 (ms)。VM service 对 JSON-RPC 请求通常毫秒级响应,
/// 5s 是保守上限 (frontend_server 编译期间 VM 繁忙时也不会超过)。
const vm_service_poll_timeout_ms: i32 = 5000;

const std = @import("std");
const net = std.Io.net;

/// 解析 VM service URI: http://127.0.0.1:PORT/TOKEN/
pub const Uri = struct {
    host: []const u8,
    port: u16,
    token: []const u8,
};

pub fn parseUri(uri: []const u8) !Uri {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, uri, scheme)) return error.InvalidVmServiceUri;
    const rest = uri[scheme.len..];
    // host[:port]/token/
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidVmServiceUri;
    const host_port = rest[0..path_start];
    const token = rest[path_start + 1 ..];

    var host: []const u8 = host_port;
    var port: u16 = 80;
    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        host = host_port[0..colon];
        port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return error.InvalidVmServiceUri;
    }
    // 去尾部斜杠
    const token_trimmed = std.mem.trim(u8, token, "/");
    if (token_trimmed.len == 0) return error.InvalidVmServiceUri;
    return .{ .host = host, .port = port, .token = token_trimmed };
}

/// VM service 连接 (已升级为 WebSocket)。
pub const VmService = struct {
    stream: net.Stream,
    io: std.Io,
    recv_buf: [65536]u8 = undefined,
    recv_start: usize = 0,
    recv_end: usize = 0,
    next_id: u32 = 1,

    /// TCP 连接 + HTTP Upgrade 握手。
    pub fn connect(io: std.Io, uri: Uri) !VmService {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", uri.port);
        const stream = try addr.connect(io, .{ .mode = .stream });

        var vm: VmService = .{ .stream = stream, .io = io };

        // HTTP Upgrade 请求
        var key_buf: [24]u8 = undefined;
        const key = try makeWebSocketKey(&key_buf);
        var request_buf: [512]u8 = undefined;
        // WebSocket 端点是 /TOKEN/ws (实测: 根路径返回 200 文本, /ws 才升级 101)
        // HTTP 头必须以 \r\n 结尾 (VM service 严格解析, 只发 \n 会不响应)
        const request = try std.fmt.bufPrint(&request_buf, "GET /{s}/ws HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n", .{ uri.token, uri.port, key });
        try vm.writeAll(request);

        // 读响应头 (直到 \r\n\r\n)
        var header: [4096]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < header.len) {
            const n = try vm.readSome(header[header_len..]);
            if (n == 0) return error.VmServiceConnectionClosed;
            header_len += n;
            if (std.mem.indexOf(u8, header[0..header_len], "\r\n\r\n")) |idx| {
                const head = header[0..idx];
                if (!std.mem.startsWith(u8, head, "HTTP/1.1 101")) return error.VmServiceUpgradeFailed;
                // 剩余字节保留到 recv 缓冲
                const extra = header_len - (idx + 4);
                if (extra > 0) {
                    @memcpy(vm.recv_buf[0..extra], header[idx + 4 .. header_len]);
                    vm.recv_start = 0;
                    vm.recv_end = extra;
                }
                return vm;
            }
        }
        return error.VmServiceUpgradeFailed;
    }

    pub fn close(self: *VmService) void {
        self.stream.close(self.io);
    }

    /// JSON-RPC 调用: 发请求, 读响应帧, 返回 result 的 JSON 片段 (调用方解析)。
    /// 跳过事件帧 (无 id) 和其他请求的响应 (id 不匹配)。
    pub fn call(self: *VmService, method: []const u8, params: []const u8, out: []u8) ![]const u8 {
        const id = self.next_id;
        self.next_id += 1;

        var msg_buf: [2048]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
        , .{ id, method, params });

        try self.sendText(msg);

        // 读帧直到 id 匹配的响应
        var frame_buf: [65536]u8 = undefined;
        while (true) {
            const payload = try self.recvFrame(&frame_buf);
            // 找顶层 "id":<数字> (嵌套字段如 isolates[].id 是字符串, parseInt 失败会跳过)
            var search_from: usize = 0;
            var matched_id = false;
            while (std.mem.indexOf(u8, payload[search_from..], "\"id\":")) |rel| {
                const id_idx = search_from + rel;
                const after_id = std.mem.trim(u8, payload[id_idx + 5 ..], " \t");
                const id_end = std.mem.indexOfAny(u8, after_id, ",}") orelse break;
                const got_id = std.fmt.parseInt(u32, after_id[0..id_end], 10) catch {
                    search_from = id_idx + 5;
                    continue;
                };
                if (got_id != id) {
                    search_from = id_idx + 5;
                    continue;
                }
                matched_id = true;
                break;
            }
            if (!matched_id) continue;
            // 找 result:
            if (std.mem.indexOf(u8, payload, "\"result\":")) |res_idx| {
                const rest = payload[res_idx + 9 ..];
                const trimmed = std.mem.trim(u8, rest, " \t");
                const end = findJsonEnd(trimmed) orelse continue;
                if (end > out.len) return error.ResponseTooLarge;
                @memcpy(out[0..end], trimmed[0..end]);
                return out[0..end];
            }
            return error.JsonRpcError; // 有 id 无 result = error 响应
        }
    }

    /// 热重载: 用新 kernel 文件替换已加载代码 (状态保留)。
    /// root_lib_uri: file:///path/to/new.kernel.dill (完整 kernel 即可, 非 delta)。
    pub fn reloadSources(self: *VmService, isolate_id: []const u8, root_lib_uri: []const u8, out: []u8) ![]const u8 {
        var params_buf: [4096]u8 = undefined;
        const params = try std.fmt.bufPrint(&params_buf, "{{\"isolateId\":\"{s}\",\"pause\":false,\"rootLibUri\":\"{s}\"}}", .{ isolate_id, root_lib_uri });
        return self.call("reloadSources", params, out);
    }

    /// 通知 Flutter 框架重建 widget 树 (reload 后调用)。
    pub fn reassemble(self: *VmService, isolate_id: []const u8, out: []u8) ![]const u8 {
        var params_buf: [512]u8 = undefined;
        const params = try std.fmt.bufPrint(&params_buf, "{{\"isolateId\":\"{s}\"}}", .{isolate_id});
        return self.call("ext.flutter.reassemble", params, out);
    }

    /// 发送一个 text 帧 (客户端掩码)。
    fn sendText(self: *VmService, payload: []const u8) !void {
        var frame: [1024 + 14]u8 = undefined;
        var len: usize = 0;
        frame[len] = 0x81; // FIN | text
        len += 1;
        var mask: [4]u8 = undefined;
        randomBytes(self.io, &mask);
        if (payload.len < 126) {
            frame[len] = 0x80 | @as(u8, @intCast(payload.len));
            len += 1;
        } else if (payload.len < 65536) {
            frame[len] = 0x80 | 126;
            len += 1;
            std.mem.writeInt(u16, frame[len..][0..2], @intCast(payload.len), .big);
            len += 2;
        } else {
            frame[len] = 0x80 | 127;
            len += 1;
            std.mem.writeInt(u64, frame[len..][0..8], @intCast(payload.len), .big);
            len += 8;
        }
        @memcpy(frame[len .. len + 4], &mask);
        len += 4;
        for (payload, 0..) |b, i| frame[len + i] = b ^ mask[i % 4];
        len += payload.len;
        try self.writeAll(frame[0..len]);
    }

    /// 读一个完整帧, 返回 payload (调用方 buffer)。
    fn recvFrame(self: *VmService, buf: []u8) ![]const u8 {
        // 先消费缓冲中已有数据 (握手后的剩余)
        var opcode: u8 = 0;
        while (true) {
            if (self.recv_end - self.recv_start >= 2) {
                const b0 = self.recv_buf[self.recv_start];
                const b1 = self.recv_buf[self.recv_start + 1];
                opcode = b0 & 0x0f;
                var len: u64 = b1 & 0x7f;
                var header_len: usize = 2;
                if (len == 126) {
                    if (self.recv_end - self.recv_start < 4) return error.VmServiceConnectionClosed;
                    len = std.mem.readInt(u16, self.recv_buf[self.recv_start + 2 ..][0..2], .big);
                    header_len = 4;
                } else if (len == 127) {
                    if (self.recv_end - self.recv_start < 10) return error.VmServiceConnectionClosed;
                    len = std.mem.readInt(u64, self.recv_buf[self.recv_start + 2 ..][0..8], .big);
                    header_len = 10;
                }
                const masked = (b1 & 0x80) != 0;
                var mask: [4]u8 = .{ 0, 0, 0, 0 };
                if (masked) {
                    if (self.recv_end - self.recv_start < header_len + 4) return error.VmServiceConnectionClosed;
                    @memcpy(&mask, self.recv_buf[self.recv_start + header_len ..][0..4]);
                    header_len += 4;
                }
                if (len > buf.len) return error.ResponseTooLarge;
                while (self.recv_end - self.recv_start < header_len + len) {
                    const n = try self.readSome(self.recv_buf[self.recv_end..]);
                    if (n == 0) return error.VmServiceConnectionClosed;
                    self.recv_end += n;
                }
                const payload = self.recv_buf[self.recv_start + header_len .. self.recv_start + header_len + len];
                self.recv_start += header_len + len;
                if (masked) {
                    for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
                }
                if (opcode == 0x9) continue; // ping → 忽略 (简化)
                if (opcode == 0x8) return error.VmServiceConnectionClosed; // close
                @memcpy(buf[0..payload.len], payload);
                return buf[0..payload.len];
            }
            const n = try self.readSome(self.recv_buf[self.recv_end..]);
            if (n == 0) return error.VmServiceConnectionClosed;
            self.recv_end += n;
        }
    }

    fn readSome(self: *VmService, buf: []u8) !usize {
        // poll 等待可读 (5s 超时), 然后直接 vtable.netRead (绕开 Reader 缓冲层)
        var fds = [_]std.posix.pollfd{.{
            .fd = self.stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const pr = std.posix.poll(&fds, 5000) catch return 0;
        if (pr == 0) return 0;
        var data: [1][]u8 = .{buf};
        return self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &data) catch return 0;
    }

    fn writeAll(self: *VmService, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &buf);
        try writer.interface.writeAll(data);
        try writer.interface.flush(); // Writer 带缓冲, 必须显式 flush
    }
};

/// 非密码学随机 (WebSocket key/mask 不需要安全随机)。
fn randomBytes(io: std.Io, buf: []u8) void {
    const t = std.Io.Timestamp.now(io, .real).nanoseconds;
    var prng = std.Random.DefaultPrng.init(@intCast(t & 0xffffffffffff));
    prng.random().bytes(buf);
}

/// 生成 Sec-WebSocket-Key (16 随机字节 base64)。
fn makeWebSocketKey(buf: *[24]u8) ![24:0]u8 {
    var key: [16]u8 = undefined;
    randomBytes(std.Io.Threaded.global_single_threaded.io(), &key);
    const encoded = std.base64.standard.Encoder.encode(buf, &key);
    var out: [24:0]u8 = undefined;
    @memcpy(out[0..encoded.len], encoded);
    out[encoded.len] = 0;
    return out;
}

/// 简单 JSON 值结束位置 (只支持 {} / [] / 字符串 / 数字 / true/false/null 的顶层值)。
/// 从 value 开头算, 返回长度。找不到返回 null。
fn findJsonEnd(s: []const u8) ?usize {
    if (s.len == 0) return null;
    switch (s[0]) {
        '{' => {
            var depth: usize = 1;
            var in_str = false;
            var i: usize = 1;
            while (i < s.len) : (i += 1) {
                const ch = s[i];
                if (in_str) {
                    if (ch == '\\') {
                        i += 1;
                        continue;
                    }
                    if (ch == '"') in_str = false;
                    continue;
                }
                switch (ch) {
                    '"' => in_str = true,
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
            }
            return null;
        },
        '"' => {
            var i: usize = 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (s[i] == '"') return i + 1;
            }
            return null;
        },
        else => {
            const end = std.mem.indexOfAny(u8, s, ",}") orelse return s.len;
            return end;
        },
    }
}
