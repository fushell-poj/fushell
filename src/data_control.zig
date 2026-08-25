//! wlr-data-control-unstable-v1 客户端: 系统剪贴板读写。
//!
//! 写 (复制): manager.createDataSource → source.offer(text/plain) → device.setSelection
//!            其他应用请求内容时, source 收到 send(mime, fd) 事件 → 写 fd。
//! 读 (粘贴): device 收到 selection 事件 → offer 对象 → offer 的 offer 事件记录 mime
//!            → offer.receive(mime, pipe_w) → 读 pipe_r 内容。
//!
//! 线程模型: 协议事件、平台消息与剪贴板 API 都在平台线程执行；模块不做
//!           额外线程同步。读取 pipe 由主事件循环非阻塞驱动。

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const display_state = @import("wl_display_state.zig");

const max_clipboard_bytes: usize = 16 * 1024 * 1024;

pub const DataControl = struct {
    gpa: std.mem.Allocator,
    display: *display_state.DisplayState,
    manager: ?*zwlr.DataControlManagerV1 = null,
    device: ?*zwlr.DataControlDeviceV1 = null,
    /// 我们发布的 source (正在提供剪贴板内容)。
    source: ?*zwlr.DataControlSourceV1 = null,
    /// 当前系统剪贴板 offer (粘贴来源)。
    offer: ?*zwlr.DataControlOfferV1 = null,
    /// offer 支持的 mime 列表 (offer 事件累积)。
    offer_mimes: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 当前发布的内容 (send 回调时写入 fd)。
    published_text: std.ArrayListUnmanaged(u8) = .empty,
    /// 正在读取的外部 selection；fd 与累积缓冲均由平台线程拥有。
    request_fd: ?i32 = null,
    request_bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, display: *display_state.DisplayState) DataControl {
        return .{ .gpa = gpa, .display = display };
    }

    pub fn deinit(self: *DataControl) void {
        for (self.offer_mimes.items) |m| self.gpa.free(m);
        self.offer_mimes.deinit(self.gpa);
        self.published_text.deinit(self.gpa);
        self.cancelRequestText();
        self.request_bytes.deinit(self.gpa);
        if (self.source) |src| src.destroy();
        if (self.offer) |off| off.destroy();
        if (self.device) |dev| dev.destroy();
        if (self.manager) |m| m.destroy();
        self.source = null;
        self.offer = null;
        self.device = null;
        self.manager = null;
    }

    /// registry global 出现 data_control_manager 时绑定。
    pub fn bindManager(self: *DataControl, global: *wl.Registry, name: u32, version: u32) void {
        if (self.manager != null) return;
        self.manager = wl.Registry.bind(global, name, zwlr.DataControlManagerV1, @min(version, 2)) catch return;
        if (self.display.seat) |seat| self.bindDevice(seat);
    }

    /// seat 可用时创建 data device。
    pub fn bindDevice(self: *DataControl, seat: *wl.Seat) void {
        if (self.manager == null or self.device != null) return;
        const device = self.manager.?.getDataDevice(seat) catch null orelse return;
        device.setListener(*DataControl, deviceListener, self);
        self.device = device;
    }

    /// 系统剪贴板是否可能包含文本 (offer 存在且含 text/plain)。
    pub fn hasText(self: *DataControl) bool {
        if (self.offer == null) return false;
        for (self.offer_mimes.items) |m| {
            if (std.mem.eql(u8, m, "text/plain")) return true;
        }
        return false;
    }

    /// 发布文本到系统剪贴板。
    pub fn publish(self: *DataControl, text: []const u8) void {
        self.published_text.clearRetainingCapacity();
        self.published_text.appendSlice(self.gpa, text) catch return;

        if (self.manager == null or self.device == null) return; // 无 data-control → 仅内存
        // 销毁旧 source (若有)
        if (self.source) |old| {
            old.destroy();
            self.source = null;
        }
        const source = self.manager.?.createDataSource() catch return;
        source.setListener(*DataControl, sourceListener, self);
        source.offer("text/plain");
        self.source = source;
        self.device.?.setSelection(source);
    }

    pub const RequestProgress = union(enum) {
        pending,
        complete: ?[]u8,
    };

    /// Starts a text/plain transfer. The runner polls requestFd() alongside
    /// Wayland and Flutter task wakeups, so a slow owner cannot stall the UI.
    pub fn beginRequestText(self: *DataControl) !bool {
        const offer = self.offer orelse return false;
        if (!self.hasText()) return false;
        if (self.request_fd != null) return error.ClipboardBusy;

        var pipe_fds: [2]i32 = undefined;
        if (std.os.linux.errno(std.os.linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) return error.ClipboardPipeFailed;
        const read_fd = pipe_fds[0];
        const write_fd = pipe_fds[1];
        errdefer _ = std.os.linux.close(read_fd);
        defer _ = std.os.linux.close(write_fd);

        offer.receive("text/plain", write_fd);
        self.display.flush();
        self.request_fd = read_fd;
        self.request_bytes.clearRetainingCapacity();
        return true;
    }

    pub fn requestFd(self: *const DataControl) ?i32 {
        return self.request_fd;
    }

    /// Drains currently available bytes. A completed slice transfers ownership
    /// to the caller; pending leaves the request registered for the next poll.
    pub fn pumpRequestText(self: *DataControl) !RequestProgress {
        const fd = self.request_fd orelse return error.NoClipboardRequest;
        var chunk: [4096]u8 = undefined;
        while (true) {
            const count = std.posix.read(fd, &chunk) catch |err| switch (err) {
                error.WouldBlock => return .pending,
                else => {
                    self.cancelRequestText();
                    return error.ClipboardReadFailed;
                },
            };
            if (count == 0) {
                _ = std.os.linux.close(fd);
                self.request_fd = null;
                if (self.request_bytes.items.len == 0) return .{ .complete = null };
                return .{ .complete = try self.request_bytes.toOwnedSlice(self.gpa) };
            }
            if (self.request_bytes.items.len > max_clipboard_bytes -| count) {
                self.cancelRequestText();
                return error.ClipboardTooLarge;
            }
            try self.request_bytes.appendSlice(self.gpa, chunk[0..count]);
        }
    }

    pub fn cancelRequestText(self: *DataControl) void {
        if (self.request_fd) |fd| _ = std.os.linux.close(fd);
        self.request_fd = null;
        self.request_bytes.clearRetainingCapacity();
    }

    fn sourceListener(source: *zwlr.DataControlSourceV1, event: zwlr.DataControlSourceV1.Event, data: *DataControl) void {
        _ = source;
        switch (event) {
            .send => |s| {
                // 把 published_text 写入 fd
                const text = data.published_text.items;
                if (text.len > 0) {
                    var off: usize = 0;
                    while (off < text.len) {
                        const w = std.os.linux.write(s.fd, text[off..].ptr, text.len - off);
                        switch (std.os.linux.errno(w)) {
                            .SUCCESS => {
                                if (w == 0) break;
                                off += w;
                            },
                            .INTR => continue,
                            else => break,
                        }
                    }
                }
                _ = std.os.linux.close(s.fd);
            },
            .cancelled => {
                // 新 selection 取代我们 → 销毁 source
                if (data.source) |src| {
                    src.destroy();
                    data.source = null;
                }
            },
        }
    }

    fn deviceListener(device: *zwlr.DataControlDeviceV1, event: zwlr.DataControlDeviceV1.Event, data: *DataControl) void {
        _ = device;
        switch (event) {
            .data_offer => |doffer| {
                // 新 offer 对象 (后续 selection 事件引用它)。先注册 listener。
                doffer.id.setListener(*DataControl, offerListener, data);
                // 新 offer 开始: 旧 offer 的 mime 作废。
                for (data.offer_mimes.items) |m| data.gpa.free(m);
                data.offer_mimes.clearRetainingCapacity();
            },
            .selection => |sel| {
                // 注意: 不能在这里清 mime 列表 — offer 的 mime 事件先于
                // selection 到达 (compositor 事件顺序), selection 时列表已填好。
                // 旧 offer 的 mime 在 data_offer 事件(新 offer 开始)时清理。
                if (data.offer != null and data.offer != sel.id) {
                    data.offer.?.destroy();
                }
                data.offer = sel.id;
            },
            .finished => {
                // compositor 销毁 device
                data.device = null;
            },
            .primary_selection => {
                // 主选择 (中键粘贴) — 本实现忽略。
            },
        }
    }

    fn offerListener(offer: *zwlr.DataControlOfferV1, event: zwlr.DataControlOfferV1.Event, data: *DataControl) void {
        _ = offer;
        switch (event) {
            .offer => |offer_ev| {
                // 注意: mime 事件先于 selection 到达 (compositor 顺序),
                // 此时 data.offer 尚未设置 — 不能做 offer 匹配检查。
                const mime_z: [*:0]const u8 = offer_ev.mime_type;
                const copy = data.gpa.dupe(u8, std.mem.span(mime_z)) catch return;
                data.offer_mimes.append(data.gpa, copy) catch {
                    data.gpa.free(copy);
                };
            },
        }
    }
};

test "non-blocking clipboard request remains pending until producer closes" {
    var pipe_fds: [2]c_int = undefined;
    try std.testing.expectEqual(
        std.os.linux.E.SUCCESS,
        std.os.linux.errno(std.os.linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })),
    );
    var writer_open = true;
    defer if (writer_open) std.posix.close(pipe_fds[1]);

    var dc: DataControl = undefined;
    dc.gpa = std.testing.allocator;
    dc.request_fd = pipe_fds[0];
    dc.request_bytes = .empty;
    defer dc.cancelRequestText();

    try std.testing.expectEqual(DataControl.RequestProgress.pending, try dc.pumpRequestText());
    try std.testing.expectEqual(@as(usize, 5), try std.posix.write(pipe_fds[1], "hello"));
    try std.testing.expectEqual(DataControl.RequestProgress.pending, try dc.pumpRequestText());

    std.posix.close(pipe_fds[1]);
    writer_open = false;
    const complete = try dc.pumpRequestText();
    const text = switch (complete) {
        .complete => |value| value orelse return error.ExpectedClipboardText,
        .pending => return error.ExpectedCompletedClipboardRead,
    };
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
    try std.testing.expectEqual(@as(?c_int, null), dc.request_fd);
}

test "clipboard source destruction completes an empty request" {
    var pipe_fds: [2]c_int = undefined;
    try std.testing.expectEqual(
        std.os.linux.E.SUCCESS,
        std.os.linux.errno(std.os.linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })),
    );

    var dc: DataControl = undefined;
    dc.gpa = std.testing.allocator;
    dc.request_fd = pipe_fds[0];
    dc.request_bytes = .empty;
    defer dc.cancelRequestText();

    try std.testing.expectEqual(DataControl.RequestProgress.pending, try dc.pumpRequestText());
    std.posix.close(pipe_fds[1]);
    const result = try dc.pumpRequestText();
    switch (result) {
        .complete => |value| try std.testing.expectEqual(@as(?[]u8, null), value),
        .pending => return error.ExpectedCompletedClipboardRead,
    }
    try std.testing.expectEqual(@as(?c_int, null), dc.request_fd);
}
