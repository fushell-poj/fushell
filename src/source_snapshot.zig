//! Owned file snapshots for hot reload; additions, edits and deletions are all
//! invalidations. No raw getdents64 or signed errno conversions are required.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Stamp = struct { mtime: i96, size: u64 };

pub const Changes = struct {
    allocator: Allocator,
    paths: std.ArrayList([]const u8) = .empty,

    /// Release paths independently of either snapshot's lifetime.
    pub fn deinit(self: *Changes) void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.deinit(self.allocator);
    }

    fn append(self: *Changes, path: []const u8) !void {
        const copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(copy);
        try self.paths.append(self.allocator, copy);
    }
};

pub const Snapshot = struct {
    allocator: Allocator,
    files: std.StringHashMap(Stamp),

    /// Scan lib/ and the selected entrypoint, relative to the supplied project.
    pub fn scan(allocator: Allocator, io: Io, root: Io.Dir, entrypoint: []const u8) !Snapshot {
        var result: Snapshot = .{ .allocator = allocator, .files = std.StringHashMap(Stamp).init(allocator) };
        errdefer result.deinit();
        if (root.openDir(io, "lib", .{ .iterate = true })) |dir_value| {
            var dir = dir_value;
            defer dir.close(io);
            var walker = try dir.walk(allocator);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".dart")) continue;
                const path = try std.fs.path.join(allocator, &.{ "lib", entry.path });
                defer allocator.free(path);
                try result.addFile(io, root, path);
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try result.addFile(io, root, entrypoint);
        return result;
    }

    /// Release keys and map storage.
    pub fn deinit(self: *Snapshot) void {
        var iterator = self.files.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.files.deinit();
    }

    fn addFile(self: *Snapshot, io: Io, root: Io.Dir, path: []const u8) !void {
        const stat = root.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .file) return;
        try self.put(path, .{ .mtime = stat.mtime.nanoseconds, .size = stat.size });
    }

    fn put(self: *Snapshot, path: []const u8, stamp: Stamp) !void {
        if (self.files.getPtr(path)) |existing| {
            existing.* = stamp;
            return;
        }
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.files.put(owned, stamp);
    }

    /// O(N) expected comparison; results own their strings, including deletions.
    pub fn changes(old: *const Snapshot, new: *const Snapshot, allocator: Allocator) !Changes {
        var result: Changes = .{ .allocator = allocator };
        errdefer result.deinit();
        var current = new.files.iterator();
        while (current.next()) |entry| {
            const previous = old.files.get(entry.key_ptr.*);
            if (previous == null or !std.meta.eql(previous.?, entry.value_ptr.*)) try result.append(entry.key_ptr.*);
        }
        var previous = old.files.keyIterator();
        while (previous.next()) |path| {
            if (!new.files.contains(path.*)) try result.append(path.*);
        }
        return result;
    }
};

test "snapshot reports add edit delete and owns deleted filenames" {
    const allocator = std.testing.allocator;
    var old: Snapshot = .{ .allocator = allocator, .files = std.StringHashMap(Stamp).init(allocator) };
    var new: Snapshot = .{ .allocator = allocator, .files = std.StringHashMap(Stamp).init(allocator) };
    defer new.deinit();
    try old.put("removed.dart", .{ .mtime = 1, .size = 1 });
    try old.put("edited.dart", .{ .mtime = 1, .size = 1 });
    try new.put("edited.dart", .{ .mtime = 2, .size = 1 });
    try new.put("added.dart", .{ .mtime = 1, .size = 1 });
    var changes = try Snapshot.changes(&old, &new, allocator);
    defer changes.deinit();
    old.deinit();
    try std.testing.expectEqual(@as(usize, 3), changes.paths.items.len);
    var found_deleted = false;
    for (changes.paths.items) |path| if (std.mem.eql(u8, path, "removed.dart")) {
        found_deleted = true;
    };
    try std.testing.expect(found_deleted);
}

test "snapshot detects a selected entrypoint outside lib" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/custom.dart", .data = "main() {}" });
    var snapshot = try Snapshot.scan(std.testing.allocator, io, tmp.dir, "bin/custom.dart");
    defer snapshot.deinit();
    try std.testing.expect(snapshot.files.contains("bin/custom.dart"));
}
