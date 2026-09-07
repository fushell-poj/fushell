//! Persistent-inode advisory lock for cooperating builders. Never unlink the
//! lock file: doing so allows concurrent callers to lock different inodes.
const std = @import("std");

pub const Lock = struct {
    file: std.Io.File,
    io: std.Io,

    /// Open/create a lock file and wait cancelably for exclusive ownership.
    pub fn acquire(io: std.Io, dir: std.Io.Dir, path: []const u8) !Lock {
        const file = try dir.createFile(io, path, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        try file.lock(io, .exclusive);
        return .{ .file = file, .io = io };
    }

    /// Release the lock and descriptor; the lock inode remains on disk.
    pub fn deinit(self: *Lock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

test "independent opens contend and the lock can be reacquired" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var lock = try Lock.acquire(io, tmp.dir, "lock");
    const other = try tmp.dir.openFile(io, "lock", .{ .mode = .read_write });
    defer other.close(io);
    try std.testing.expect(!try other.tryLock(io, .exclusive));
    lock.deinit();
    try std.testing.expect(try other.tryLock(io, .exclusive));
    other.unlock(io);
}
