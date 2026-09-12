//! Allocator-owned multi-view window registry and lifecycle state machine.
//! Shared entry and host access is protected by the registry mutex. Entries
//! remain alive until an engine completion is published or the engine shuts down.

const std = @import("std");
const c = @import("c");
const egl = @import("wayland_egl_host.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;

pub const Lifecycle = enum { adding, active, removing };

/// Copied before completion is published; its target must outlive engine shutdown.
/// Notification never accesses the entry whose completion it announces.
pub const LifecycleNotification = struct {
    context: *anyopaque,
    wake: *const fn (*anyopaque) void,

    pub fn notify(self: LifecycleNotification) void {
        self.wake(self.context);
    }
};

pub const Entry = struct {
    registry: *Registry,
    lifecycle: Lifecycle = .adding,
    view_id: i64,
    parent_view_id: ?i64 = null,
    add_result: ?bool = null,
    remove_result: ?bool = null,
    lifecycle_notification: ?LifecycleNotification = null,
    pending_open_response: ?*const c.FlutterPlatformMessageResponseHandle = null,
    pending_open_request_id: i64 = 0,
    pending_close_response: ?*const c.FlutterPlatformMessageResponseHandle = null,
    pending_close_request_id: i64 = 0,
    host: egl.Host = .{},
};

/// Allocator-owned registry with stable record addresses and indexed lookups.
/// Entry and Host access requires the mutex, except an activeHostForPlatform borrow.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(*Entry) = .empty,
    by_view_id: std.AutoHashMap(i64, *Entry),
    by_surface: std.AutoHashMap(*wl.Surface, *Entry),
    next_view_id: i64 = 1,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Registry {
        return .{
            .allocator = allocator,
            .io = io,
            .by_view_id = std.AutoHashMap(i64, *Entry).init(allocator),
            .by_surface = std.AutoHashMap(*wl.Surface, *Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        std.debug.assert(self.entries.items.len == 0);
        self.entries.deinit(self.allocator);
        self.by_view_id.deinit();
        self.by_surface.deinit();
    }

    pub fn lock(self: *Registry) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Registry) void {
        self.mutex.unlock(self.io);
    }

    /// The engine owns entry until this call publishes its completion. Only the
    /// returned notification may be used afterward: a consumer can free entry.
    pub fn completeAdd(self: *Registry, entry: *Entry, added: bool) ?LifecycleNotification {
        self.lock();
        defer self.unlock();
        if (entry.lifecycle != .adding or entry.add_result != null) return null;
        const notification = entry.lifecycle_notification;
        entry.add_result = added;
        return notification;
    }

    pub fn completeRemove(self: *Registry, entry: *Entry, removed: bool) ?LifecycleNotification {
        self.lock();
        defer self.unlock();
        if (entry.lifecycle != .removing or entry.remove_result != null) return null;
        const notification = entry.lifecycle_notification;
        entry.remove_result = removed;
        return notification;
    }

    pub fn findByViewIdLocked(self: *Registry, view_id: i64) ?*Entry {
        return self.by_view_id.get(view_id);
    }

    /// Platform thread only: return a borrowed host without retaining the lock,
    /// so host operations may dispatch Wayland callbacks that reenter the registry.
    /// Entries are reclaimed only by platform lifecycle processing, which must
    /// not run inside nested Wayland dispatch while this borrow is in use.
    pub fn activeHostForPlatform(self: *Registry, view_id: i64) !*egl.Host {
        self.lock();
        defer self.unlock();
        const entry = self.findByViewIdLocked(view_id) orelse return error.WindowNotFound;
        if (entry.lifecycle != .active) return error.WindowNotReady;
        return &entry.host;
    }

    pub fn findHostBySurfaceLocked(self: *Registry, surface: ?*wl.Surface) ?*egl.Host {
        const entry = self.by_surface.get(surface orelse return null) orelse return null;
        return &entry.host;
    }

    pub fn reserveLocked(self: *Registry, parent_view_id: ?i64) !*Entry {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        const view_id = self.next_view_id;
        self.next_view_id = std.math.add(i64, view_id, 1) catch return error.ViewIdExhausted;
        entry.* = .{
            .registry = self,
            .view_id = view_id,
            .parent_view_id = parent_view_id,
        };

        try self.entries.append(self.allocator, entry);
        errdefer _ = self.entries.pop();
        try self.by_view_id.putNoClobber(view_id, entry);
        return entry;
    }

    pub fn indexSurfaceLocked(self: *Registry, entry: *Entry) !void {
        const surface = entry.host.surface orelse return error.MissingSurface;
        try self.by_surface.putNoClobber(surface, entry);
    }

    pub fn unindexSurfaceLocked(self: *Registry, entry: *Entry) void {
        if (entry.host.surface) |surface| _ = self.by_surface.remove(surface);
    }

    pub fn releaseLocked(self: *Registry, entry: *Entry) void {
        _ = self.by_view_id.remove(entry.view_id);
        self.unindexSurfaceLocked(entry);

        for (self.entries.items, 0..) |candidate, index| {
            if (candidate == entry) {
                _ = self.entries.swapRemove(index);
                self.allocator.destroy(entry);
                return;
            }
        }
        @panic("attempted to release an unknown window record");
    }

    pub fn detachChildrenLocked(self: *Registry, parent_view_id: i64) void {
        for (self.entries.items) |entry| {
            if (entry.parent_view_id == parent_view_id) entry.parent_view_id = null;
        }
    }
};

test "registry keeps record addresses stable while growing beyond 64 windows" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    registry.lock();
    defer registry.unlock();

    const first = try registry.reserveLocked(null);
    const first_address = @intFromPtr(first);
    for (0..256) |_| _ = try registry.reserveLocked(null);
    try std.testing.expectEqual(first_address, @intFromPtr(registry.findByViewIdLocked(first.view_id).?));

    while (registry.entries.items.len > 0) {
        registry.releaseLocked(registry.entries.items[registry.entries.items.len - 1]);
    }
}

test "surface index resolves the owning host and is removed on release" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    registry.lock();
    defer registry.unlock();

    const entry = try registry.reserveLocked(null);
    var surface_stub: u8 = 0;
    const surface: *wl.Surface = @ptrCast(&surface_stub);
    entry.host.surface = surface;
    try registry.indexSurfaceLocked(entry);
    try std.testing.expectEqual(&entry.host, registry.findHostBySurfaceLocked(surface).?);
    registry.releaseLocked(entry);
    try std.testing.expect(registry.findHostBySurfaceLocked(surface) == null);
}

test "registry indexes ids and detaches children before releasing a parent" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    registry.lock();
    defer registry.unlock();

    const parent = try registry.reserveLocked(null);
    const child = try registry.reserveLocked(parent.view_id);
    try std.testing.expectEqual(parent, registry.findByViewIdLocked(parent.view_id).?);
    registry.detachChildrenLocked(parent.view_id);
    try std.testing.expectEqual(null, child.parent_view_id);
    registry.releaseLocked(parent);
    try std.testing.expect(registry.findByViewIdLocked(parent.view_id) == null);
    registry.releaseLocked(child);
}

test "repeated reserve and release leaves no stale id records" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    registry.lock();
    defer registry.unlock();

    var previous_view_id: i64 = 0;
    for (0..10_000) |_| {
        const entry = try registry.reserveLocked(null);
        try std.testing.expect(entry.view_id > previous_view_id);
        previous_view_id = entry.view_id;
        entry.lifecycle = .active;
        entry.lifecycle = .removing;
        registry.releaseLocked(entry);
    }
    try std.testing.expect(registry.findByViewIdLocked(previous_view_id) == null);
    try std.testing.expectEqual(@as(usize, 0), registry.entries.items.len);
}

const CompletionProbe = struct {
    registry: *Registry,
    view_id: i64,
    notified: bool = false,

    fn wake(context: *anyopaque) void {
        const self: *CompletionProbe = @ptrCast(@alignCast(context));
        self.registry.lock();
        defer self.registry.unlock();
        // The completion consumer has already reclaimed the callback record.
        std.debug.assert(self.registry.findByViewIdLocked(self.view_id) == null);
        self.notified = true;
    }
};

test "completion notifications survive reclamation before wake" {
    inline for (.{ Lifecycle.adding, Lifecycle.removing }) |lifecycle| {
        var registry = Registry.init(std.testing.allocator, std.testing.io);
        defer registry.deinit();
        registry.lock();
        const entry = registry.reserveLocked(null) catch |err| {
            registry.unlock();
            return err;
        };
        var probe = CompletionProbe{ .registry = &registry, .view_id = entry.view_id };
        entry.lifecycle = lifecycle;
        entry.lifecycle_notification = .{ .context = &probe, .wake = CompletionProbe.wake };
        registry.unlock();

        // Exercise the production publication API. Force the adverse scheduling
        // order: platform consumes/frees before the engine thread can notify.
        const notification = if (lifecycle == .adding)
            registry.completeAdd(entry, false).?
        else
            registry.completeRemove(entry, true).?;
        registry.lock();
        const result = if (lifecycle == .adding) entry.add_result else entry.remove_result;
        registry.releaseLocked(entry);
        registry.unlock();
        try std.testing.expectEqual(lifecycle == .removing, result.?);
        notification.notify();
        try std.testing.expect(probe.notified);
    }
}

test "platform host borrow permits reentrant lookup and rejects inactive views" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    registry.lock();
    const entry = registry.reserveLocked(null) catch |err| {
        registry.unlock();
        return err;
    };
    const view_id = entry.view_id;
    registry.unlock();
    defer {
        registry.lock();
        registry.releaseLocked(entry);
        registry.unlock();
    }

    try std.testing.expectError(error.WindowNotFound, registry.activeHostForPlatform(view_id + 1));
    try std.testing.expectError(error.WindowNotReady, registry.activeHostForPlatform(view_id));
    registry.lock();
    entry.lifecycle = .active;
    registry.unlock();

    const host = try registry.activeHostForPlatform(view_id);
    const NestedDispatch = struct {
        fn lookup(current: *Registry, id: i64, borrowed: *egl.Host) !void {
            // Model a synchronous Wayland callback. tryLock makes a retained
            // lock fail the assertion instead of hanging the regression test.
            const acquired = current.mutex.tryLock();
            try std.testing.expect(acquired);
            defer current.unlock();
            const found = current.findByViewIdLocked(id).?;
            try std.testing.expectEqual(borrowed, &found.host);
        }
    };
    try NestedDispatch.lookup(&registry, view_id, host);

    registry.lock();
    entry.lifecycle = .removing;
    registry.unlock();
    try std.testing.expectError(error.WindowNotReady, registry.activeHostForPlatform(view_id));
}
