//! Test-only local Wayland wire recorder. No compositor, EGL, or desktop connection.
const std = @import("std");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const DisplayState = @import("wl_display_state.zig").DisplayState;
const c = @import("c");
extern "c" fn socketpair(domain: c_int, kind: c_int, protocol: c_int, fds: *[2]c_int) c_int;

pub const Probe = struct {
    peer: c_int = -1,
    last_zone: i32 = 0,
    state: DisplayState = .{},
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    pub fn init(self: *Probe) !void {
        var fds: [2]c_int = undefined;
        if (socketpair(1, 1, 0, &fds) != 0) return error.SocketPairFailed;
        self.peer = fds[1];
        self.state.display = try wl.Display.connectToFd(fds[0]);
        self.state.shared_queue = try self.state.display.?.createQueue();
        self.state.registry = try self.state.display.?.getRegistry();
        self.state.compositor = try self.state.registry.?.bind(1, wl.Compositor, 4);
        self.state.layer_shell = try self.state.registry.?.bind(2, zwlr.LayerShellV1, 4);
    }
    pub fn deinit(self: *Probe) void {
        if (self.layer_surface) |layer| layer.destroy();
        if (self.surface) |surface| surface.destroy();
        self.state.shared_queue.?.destroy();
        self.state.display.?.disconnect();
        _ = c.close(self.peer);
    }
    pub fn queueClosed(self: *Probe, host: anytype) !void {
        const words = [_]u32{ host.layer_surface.?.getId(), (8 << 16) | 1 };
        const bytes = std.mem.asBytes(&words);
        try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), c.write(self.peer, bytes.ptr, bytes.len));
    }
    pub fn queueConfigure(self: *Probe, host: anytype, width: u32, height: u32) !void {
        self.surface = host.surface;
        self.layer_surface = host.layer_surface;
        const words = [_]u32{ host.layer_surface.?.getId(), 20 << 16, 1, width, height };
        const bytes = std.mem.asBytes(&words);
        try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), c.write(self.peer, bytes.ptr, bytes.len));
    }
    pub const Requests = struct {
        zones: [32]i32 = undefined,
        zone_count: usize = 0,
        committed_zones: [32]i32 = undefined,
        commits: usize = 0,
        total: usize = 0,
        pub fn expectZones(self: Requests, expected: []const i32) !void {
            try std.testing.expectEqualSlices(i32, expected, self.zones[0..self.zone_count]);
        }
    };
    pub fn drain(self: *Probe, host: anytype) !Requests {
        self.state.flush();
        var result: Requests = .{};
        var buffer: [16384]u8 align(4) = undefined;
        var len: usize = 0;
        while (true) {
            var poll = [_]c.struct_pollfd{.{ .fd = self.peer, .events = c.POLLIN, .revents = 0 }};
            const ready = c.poll(&poll, 1, 0);
            try std.testing.expect(ready >= 0);
            if (ready == 0) break;
            const count = c.read(self.peer, buffer[len..].ptr, buffer.len - len);
            try std.testing.expect(count > 0);
            len += @intCast(count);
        }
        const words = std.mem.bytesAsSlice(u32, buffer[0..len]);
        var i: usize = 0;
        while (i < words.len) {
            try std.testing.expect(i + 2 <= words.len);
            const id = words[i];
            const opcode = words[i + 1] & 0xffff;
            const size = words[i + 1] >> 16;
            try std.testing.expect(size >= 8 and size % 4 == 0 and i + size / 4 <= words.len);
            result.total += 1;
            if (host.layer_surface != null and id == host.layer_surface.?.getId() and opcode == 2) {
                self.last_zone = @bitCast(words[i + 2]);
                result.zones[result.zone_count] = self.last_zone;
                result.zone_count += 1;
            }
            if (host.surface != null and id == host.surface.?.getId() and opcode == 6) {
                result.committed_zones[result.commits] = self.last_zone;
                result.commits += 1;
            }
            i += size / 4;
        }
        return result;
    }
};
