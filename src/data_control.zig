//! wlr-data-control-unstable-v1 客户端: 系统剪贴板读写。
//!
//! 写 (复制): manager.createDataSource → source.offer(text/plain) → device.setSelection
//!            其他应用请求内容时, source 收到 send(mime, fd) 事件 → 写 fd。
//! 读 (粘贴): device 收到 selection 事件 → offer 对象 → offer 的 offer 事件记录 mime
//!            → offer.receive(mime, pipe_w) → 读 pipe_r 内容。
//!
//! 线程模型: 事件在主线程 dispatch (primary queue), publish/requestText 可在
//!           任意线程调用 (内部加锁 + flush_mutex 保护 marshal)。

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const display_state = @import("wl_display_state.zig");

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

    mutex: std.atomic.Mutex = .unlocked,

    fn lock(self: *DataControl) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn init(gpa: std.mem.Allocator, display: *display_state.DisplayState) DataControl {
        return .{ .gpa = gpa, .display = display };
    }

    pub fn deinit(self: *DataControl) void {
        self.lock();
        defer self.mutex.unlock();
        for (self.offer_mimes.items) |m| self.gpa.free(m);
        self.offer_mimes.deinit(self.gpa);
        self.published_text.deinit(self.gpa);
        if (self.manager) |m| m.destroy();
        self.manager = null;
        if (self.device) |dev| dev.destroy();
        self.device = null;
        self.source = null;
        if (self.offer) |off| off.destroy();
        self.offer = null;
    }

    /// registry global 出现 data_control_manager 时绑定。
    pub fn bindManager(self: *DataControl, global: *wl.Registry, name: u32, version: u32) void {
        self.lock();
        if (self.manager != null) {
            self.mutex.unlock();
            return;
        }
        const manager = wl.Registry.bind(global, name, zwlr.DataControlManagerV1, @min(version, 2)) catch {
            self.mutex.unlock();
            return;
        };
        self.manager = manager;
        // 记录 seat 引用, 解锁后再 bindDevice (bindDevice 自身加锁, 避免自旋锁不可重入死锁)。
        const seat = self.display.seat;
        self.mutex.unlock();
        if (seat) |s| self.bindDevice(s);
    }

    /// seat 可用时创建 data device。
    pub fn bindDevice(self: *DataControl, seat: *wl.Seat) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.manager == null or self.device != null) return;
        const device = self.manager.?.getDataDevice(seat) catch null orelse return;
        device.setListener(*DataControl, deviceListener, self);
        self.device = device;
    }

    /// 系统剪贴板是否可能包含文本 (offer 存在且含 text/plain)。
    pub fn hasText(self: *DataControl) bool {
        self.lock();
        defer self.mutex.unlock();
        if (self.offer == null) return false;
        for (self.offer_mimes.items) |m| {
            if (std.mem.eql(u8, m, "text/plain")) return true;
        }
        return false;
    }

    /// 发布文本到系统剪贴板。
    pub fn publish(self: *DataControl, text: []const u8) void {
        self.lock();
        defer self.mutex.unlock();
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

    /// 请求系统剪贴板文本。返回 null = 无内容或失败。
    /// 调用方负责 free 返回值。
    pub fn requestText(self: *DataControl, gpa: std.mem.Allocator) ?[]const u8 {
        // 阶段 1: 锁内检查 + 发起 receive。锁在阶段 2 前必须释放 —
        // 否则等待循环里 dispatch 的 source.send 事件 (sourceListener)
        // 会自旋等同一把锁 → 死锁 (应用内复制→粘贴必现)。
        var pipe_fds: [2]i32 = undefined;
        {
            self.lock();
            defer self.mutex.unlock();
            const offer = self.offer orelse {
                return null;
            };
            var has_text_plain = false;
            for (self.offer_mimes.items) |m| {
                if (std.mem.eql(u8, m, "text/plain")) {
                    has_text_plain = true;
                    break;
                }
            }
            if (!has_text_plain) {
                return null;
            }

            _ = std.os.linux.pipe2(&pipe_fds, .{});
            const write_fd = pipe_fds[1];

            // marshal 需要 display 锁 (避免与主线程 dispatch 竞争)
            self.display.lockFlush();
            offer.receive("text/plain", write_fd);
            self.display.unlockFlush();
            if (self.display.display) |d| _ = d.flush();
            _ = std.os.linux.close(write_fd);
        }
        const read_fd = pipe_fds[0];

        // 后台线程阻塞读 fd; 主线程等待期间持续 dispatch,
        // 让 compositor 把 source.send 事件送进来 (数据经 fd 到达)。
        const ThreadCtx = struct {
            fd: i32,
            buf: [65536]u8 = undefined,
            n: usize = 0,
            done: bool = false,
        };
        var ctx: ThreadCtx = .{ .fd = read_fd };
        const thread = std.Thread.spawn(.{}, struct {
            fn run(c: *ThreadCtx) void {
                while (c.n < c.buf.len) {
                    // poll 100ms 超时: 无数据也退出, 保证 join 不卡死。
                    var pfd = [1]std.posix.pollfd{.{ .fd = c.fd, .events = std.posix.POLL.IN, .revents = 0 }};
                    const pr = std.posix.poll(&pfd, 100) catch break;
                    if (pr == 0) break;
                    const r = std.os.linux.read(c.fd, c.buf[c.n..].ptr, c.buf.len - c.n);
                    if (std.os.linux.errno(r) == .SUCCESS) {
                        if (r == 0) break;
                        c.n += r;
                    } else if (std.os.linux.errno(r) == .INTR) {
                        continue;
                    } else break;
                }
                _ = std.os.linux.close(c.fd);
                c.done = true;
            }
        }.run, .{&ctx}) catch {
            _ = std.os.linux.close(read_fd);
            return null;
        };

        var waited_ms: u32 = 0;
        while (!ctx.done and waited_ms < 2000) {
            if (self.display.display) |d| {
                if (self.display.primary_queue) |q| _ = d.dispatchQueuePending(q);
            }
            const ts = std.os.linux.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&ts, null);
            waited_ms += 1;
        }
        thread.join();
        if (ctx.n == 0) return null;
        return gpa.dupe(u8, ctx.buf[0..ctx.n]) catch null;
    }

    fn sourceListener(source: *zwlr.DataControlSourceV1, event: zwlr.DataControlSourceV1.Event, data: *DataControl) void {
        _ = source;
        switch (event) {
            .send => |s| {
                // 把 published_text 写入 fd
                data.lock();
                const text = data.published_text.items;
                if (text.len > 0) {
                    var off: usize = 0;
                    while (off < text.len) {
                        const w = std.os.linux.write(s.fd, text[off..].ptr, text.len - off);
                        if (std.os.linux.errno(w) == .SUCCESS) {
                            off += w;
                        } else break;
                    }
                }
                data.mutex.unlock();
                _ = std.os.linux.close(s.fd);
            },
            .cancelled => {
                // 新 selection 取代我们 → 销毁 source
                data.lock();
                if (data.source) |src| {
                    src.destroy();
                    data.source = null;
                }
                data.mutex.unlock();
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
                data.lock();
                for (data.offer_mimes.items) |m| data.gpa.free(m);
                data.offer_mimes.clearRetainingCapacity();
                data.mutex.unlock();
            },
            .selection => |sel| {
                data.lock();
                // 注意: 不能在这里清 mime 列表 — offer 的 mime 事件先于
                // selection 到达 (compositor 事件顺序), selection 时列表已填好。
                // 旧 offer 的 mime 在 data_offer 事件(新 offer 开始)时清理。
                if (data.offer != null and data.offer != sel.id) {
                    data.offer.?.destroy();
                }
                data.offer = sel.id;
                data.mutex.unlock();
            },
            .finished => {
                // compositor 销毁 device
                data.lock();
                data.device = null;
                data.mutex.unlock();
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
                data.lock();
                defer data.mutex.unlock();
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
