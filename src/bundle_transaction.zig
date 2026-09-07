//! Safe bundle publication. Only staging directories created here are removed
//! on failure; the previous bundle stays available until the new one is ready.
const std = @import("std");
const application_config = @import("application_config.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const marker = ".fushell-bundle";
const marker_contents = "fushell bundle v1\n";

/// True when child is equal to, or lies below, parent (absolute Linux paths).
fn contains(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (std.mem.eql(u8, parent, "/")) return true;
    return std.mem.startsWith(u8, child, parent) and child.len > parent.len and child[parent.len] == '/';
}

/// Reject the project itself, its ancestors, and source/intermediate trees.
fn validateOutput(allocator: Allocator, project: []const u8, output: []const u8) !void {
    if (contains(output, project)) return error.UnsafeBundleDirectory;
    const reserved = [_][]const u8{
        ".git",                 ".dart_tool", "lib",                      "assets",                       "packages", "test", "tests", "examples",
        "build/flutter_assets", "build/lib",  "build/fushell_debug_info", "build/fushell_flutter_engine",
    };
    for (reserved) |name| {
        const path = try std.fs.path.join(allocator, &.{ project, name });
        defer allocator.free(path);
        if (contains(output, path) or contains(path, output)) return error.UnsafeBundleDirectory;
    }
}

/// Open/create one directory component at a time, never following a symlink.
fn openParent(io: Io, absolute: []const u8) !Io.Dir {
    var dir = try Io.Dir.openDirAbsolute(io, "/", .{});
    errdefer dir.close(io);
    var parts = std.mem.tokenizeScalar(u8, absolute, '/');
    while (parts.next()) |part| {
        const next = dir.openDir(io, part, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                dir.createDir(io, part, .default_dir) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                break :blk try dir.openDir(io, part, .{ .follow_symlinks = false });
            },
            else => return err,
        };
        dir.close(io);
        dir = next;
    }
    return dir;
}

/// Permit empty directories and recognized old/new Fushell bundles only.
fn existingAllowed(allocator: Allocator, io: Io, parent: Io.Dir, name: []const u8) !bool {
    var dir = parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    if (try iterator.next(io) == null) return true;
    if (dir.readFileAlloc(io, marker, allocator, .limited(64))) |bytes| {
        defer allocator.free(bytes);
        if (std.mem.eql(u8, bytes, marker_contents)) return true;
    } else |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => {},
        else => return err,
    }
    // Upgrade a legacy bundle only when its manifest and Engine are present.
    const bytes = dir.readFileAlloc(io, "data/fushell_application.json", allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return error.UnownedBundleDirectory,
        else => return err,
    };
    defer allocator.free(bytes);
    var config = application_config.parse(allocator, bytes) catch return error.UnownedBundleDirectory;
    defer config.deinit(allocator);
    const stat = dir.statFile(io, "lib/libflutter_engine.so", .{}) catch return error.UnownedBundleDirectory;
    if (stat.kind != .file) return error.UnownedBundleDirectory;
    return true;
}

pub const Transaction = struct {
    allocator: Allocator,
    io: Io,
    parent: Io.Dir,
    lock_file: Io.File,
    output_path: []u8,
    staging_path: []u8,
    staging_name: []u8,
    backup_name: []u8,
    committed: bool = false,

    /// Validate the destination, lock publication, and create a private sibling
    /// staging directory. The root handle is borrowed only during this call.
    pub fn begin(allocator: Allocator, io: Io, root: Io.Dir, output: []const u8) !Transaction {
        if (output.len == 0 or std.mem.indexOfScalar(u8, output, 0) != null) return error.UnsafeBundleDirectory;
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try root.realPath(io, &root_buffer);
        const project = root_buffer[0..root_len];
        const target = try std.fs.path.resolve(allocator, &.{ project, output });
        errdefer allocator.free(target);
        try validateOutput(allocator, project, target);
        const parent_path = std.fs.path.dirname(target) orelse return error.UnsafeBundleDirectory;
        const basename = std.fs.path.basename(target);
        var parent = try openParent(io, parent_path);
        errdefer parent.close(io);
        const lock_name = try std.fmt.allocPrint(allocator, ".{s}.fushell-lock", .{basename});
        defer allocator.free(lock_name);
        var lock_file = try parent.createFile(io, lock_name, .{ .truncate = false });
        errdefer lock_file.close(io);
        try lock_file.lock(io, .exclusive);
        errdefer lock_file.unlock(io);
        _ = try existingAllowed(allocator, io, parent, basename);

        var random: [16]u8 = undefined;
        io.random(&random);
        const staging_name = try std.fmt.allocPrint(allocator, ".{s}.fushell-stage-{x}", .{ basename, random });
        errdefer allocator.free(staging_name);
        const backup_name = try std.fmt.allocPrint(allocator, ".{s}.fushell-backup-{x}", .{ basename, random });
        errdefer allocator.free(backup_name);
        const staging_path = try std.fs.path.join(allocator, &.{ parent_path, staging_name });
        errdefer allocator.free(staging_path);
        try parent.createDir(io, staging_name, .default_dir);
        return .{ .allocator = allocator, .io = io, .parent = parent, .lock_file = lock_file, .output_path = target, .staging_name = staging_name, .staging_path = staging_path, .backup_name = backup_name };
    }

    /// Publish a complete staging tree; roll back a failed replacement. If
    /// rollback itself fails the backup is retained and its location is logged.
    /// This provides error rollback, not a crash/power-loss transaction.
    pub fn commit(self: *Transaction) !void {
        if (self.committed) return error.BundleAlreadyCommitted;
        const target = std.fs.path.basename(self.output_path);
        const had_old = try existingAllowed(self.allocator, self.io, self.parent, target);
        var staging = try self.parent.openDir(self.io, self.staging_name, .{ .follow_symlinks = false });
        defer staging.close(self.io);
        try staging.writeFile(self.io, .{ .sub_path = marker, .data = marker_contents });
        // Once publication starts, finish it or roll it back before observing cancellation.
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        if (had_old) try self.parent.renamePreserve(target, self.parent, self.backup_name, self.io);
        self.parent.renamePreserve(self.staging_name, self.parent, target, self.io) catch |err| {
            if (had_old) {
                self.parent.renamePreserve(self.backup_name, self.parent, target, self.io) catch |rollback_err| {
                    std.log.err("bundle rollback failed ({s}); old bundle retained at {s}/{s}", .{
                        @errorName(rollback_err), std.fs.path.dirname(self.output_path).?, self.backup_name,
                    });
                    return error.BundleRollbackFailed;
                };
            }
            return err;
        };
        self.committed = true;
        if (had_old) self.parent.deleteTree(self.io, self.backup_name) catch |err| {
            std.log.warn("bundle published; old bundle retained at {s}/{s}: {s}", .{
                std.fs.path.dirname(self.output_path).?, self.backup_name, @errorName(err),
            });
        };
    }

    /// Clean up only our staging directory, then release the publication lock.
    pub fn deinit(self: *Transaction) void {
        const io = self.io;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        if (!self.committed) self.parent.deleteTree(self.io, self.staging_name) catch {};
        self.lock_file.unlock(self.io);
        self.lock_file.close(self.io);
        self.parent.close(self.io);
        self.allocator.free(self.output_path);
        self.allocator.free(self.staging_path);
        self.allocator.free(self.staging_name);
        self.allocator.free(self.backup_name);
        self.* = undefined;
    }
};

test "reject destructive source and intermediate destinations" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "/", "/work", "/work/app", "/work/app/lib", "/work/app/lib/out", "/work/app/build", "/work/app/.dart_tool/out" }) |output| {
        try std.testing.expectError(error.UnsafeBundleDirectory, validateOutput(allocator, "/work/app", output));
    }
    try validateOutput(allocator, "/work/app", "/work/app/build/linux/x64/debug");
    try validateOutput(allocator, "/work/app", "/tmp/my-bundle");
}

test "failed staging preserves old bundle; success replaces it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dist");
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/" ++ marker, .data = marker_contents });
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/old", .data = "old" });
    {
        var tx = try Transaction.begin(allocator, io, tmp.dir, "dist");
        defer tx.deinit();
        // Aborted build: do not commit.
    }
    var old = try tmp.dir.openFile(io, "dist/old", .{});
    old.close(io);
    {
        var tx = try Transaction.begin(allocator, io, tmp.dir, "dist");
        defer tx.deinit();
        var stage = try Io.Dir.openDirAbsolute(io, tx.staging_path, .{});
        defer stage.close(io);
        try stage.writeFile(io, .{ .sub_path = "new", .data = "new" });
        try tx.commit();
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "dist/old", .{}));
    var new = try tmp.dir.openFile(io, "dist/new", .{});
    new.close(io);
}

test "refuse to replace an unrelated nonempty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "important");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "important/user-file", .data = "keep" });
    try std.testing.expectError(error.UnownedBundleDirectory, Transaction.begin(std.testing.allocator, std.testing.io, tmp.dir, "important"));
}
