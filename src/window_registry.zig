//! Allocator-owned multi-view window registry and lifecycle state machine.
//! All entry and host dereferences happen while the registry mutex is held;
//! entries have stable addresses until their RemoveView result is consumed.

const std = @import("std");
const c = @import("c");
const egl = @import("wayland_egl_host.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;

pub const Lifecycle = enum { adding, active, removing };

pub const Entry = struct {
    registry: *Registry,
    lifecycle: Lifecycle = .adding,
    view_id: i64,
    parent_view_id: ?i64 = null,
    add_result: ?bool = null,
    remove_result: ?bool = null,
    lifecycle_wake_context: ?*anyopaque = null,
    pending_open_response: ?*const c.FlutterPlatformMessageResponseHandle = null,
    pending_open_request_id: i64 = 0,
    pending_close_response: ?*const c.FlutterPlatformMessageResponseHandle = null,
    pending_close_request_id: i64 = 0,
    host: egl.Host = .{},
};

/// Allocator-owned registry with stable record addresses and indexed lookups.
/// Callers must hold `mutex` while dereferencing an Entry or Host obtained here.
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

    pub fn findByViewIdLocked(self: *Registry, view_id: i64) ?*Entry {
        return self.by_view_id.get(view_id);
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
    const surface: *wl.Surface = @ptrFromInt(@alignOf(wl.Surface));
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
