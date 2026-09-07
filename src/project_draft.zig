//! New-project staging, deliberately separate from replaceable build bundles.
//! Never replace an existing entry. Existing empty directories keep their inode
//! (including `create .`); ordinary publication errors roll back moved entries.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Open parents component by component so symlinked destinations are rejected.
fn openParent(io: Io, path: []const u8) !Io.Dir {
    var dir = try Io.Dir.openDirAbsolute(io, "/", .{});
    errdefer dir.close(io);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
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

/// Use a fresh directory stream each time; never reuse an exhausted iterator.
fn requireEmpty(io: Io, directory: Io.Dir) !void {
    var scan = try directory.openDir(io, ".", .{ .iterate = true });
    defer scan.close(io);
    var iterator = scan.iterate();
    if (try iterator.next(io) != null) return error.ProjectDirectoryNotEmpty;
}

pub const Draft = struct {
    allocator: Allocator,
    io: Io,
    parent: Io.Dir,
    workspace: Io.Dir,
    existing: ?Io.Dir,
    output_path: []u8,
    workspace_name: []u8,
    workspace_path: []u8,
    project_path: []u8,
    published: bool = false,
    preserve_workspace: bool = false,

    /// Resolve against `root` without chdir. Only absent/empty destinations are
    /// accepted. Parent directories may be created, but are never deleted here.
    pub fn begin(allocator: Allocator, io: Io, root: Io.Dir, output: []const u8) !Draft {
        if (output.len == 0 or std.mem.indexOfScalar(u8, output, 0) != null) return error.InvalidProjectDirectory;
        const cwd = try root.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd);
        const target = try std.fs.path.resolve(allocator, &.{ cwd, output });
        errdefer allocator.free(target);
        if (std.mem.eql(u8, target, "/")) return error.InvalidProjectDirectory;
        const parent_path = std.fs.path.dirname(target).?;
        var parent = try openParent(io, parent_path);
        errdefer parent.close(io);
        const existing = parent.openDir(io, std.fs.path.basename(target), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        errdefer if (existing) |dir| dir.close(io);
        if (existing) |dir| try requireEmpty(io, dir);
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = try std.fmt.allocPrint(allocator, ".fushell-create-{x}", .{random});
        errdefer allocator.free(name);
        const work_path = try std.fs.path.join(allocator, &.{ parent_path, name });
        errdefer allocator.free(work_path);
        const project_path = try std.fs.path.join(allocator, &.{ work_path, "project" });
        errdefer allocator.free(project_path);
        try parent.createDir(io, name, .fromMode(0o700));
        errdefer parent.deleteTree(io, name) catch {};
        var workspace = try parent.openDir(io, name, .{ .follow_symlinks = false });
        errdefer workspace.close(io);
        return .{ .allocator = allocator, .io = io, .parent = parent, .workspace = workspace, .existing = existing, .output_path = target, .workspace_name = name, .workspace_path = work_path, .project_path = project_path };
    }

    /// Commit prepared sources before running pub, since package-config paths
    /// must refer to the final directory. Every rename is NOREPLACE.
    pub fn publish(self: *Draft) !void {
        if (self.published) return error.ProjectAlreadyPublished;
        const io = self.io;
        if (self.existing) |target| {
            try requireEmpty(io, target);
            var project = try self.workspace.openDir(io, "project", .{ .iterate = true, .follow_symlinks = false });
            defer project.close(io);
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |name| self.allocator.free(name);
                names.deinit(self.allocator);
            }
            var iterator = project.iterate();
            while (try iterator.next(io)) |entry| {
                const name = try self.allocator.dupe(u8, entry.name);
                errdefer self.allocator.free(name);
                try names.append(self.allocator, name);
            }
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            var moved: usize = 0;
            errdefer {
                // Roll back only names we moved; never delete the destination.
                while (moved > 0) {
                    moved -= 1;
                    target.renamePreserve(names.items[moved], project, names.items[moved], io) catch |err| {
                        self.preserve_workspace = true;
                        std.log.err("project rollback incomplete ({s}); recover from {s}", .{ @errorName(err), self.workspace_path });
                    };
                }
            }
            for (names.items) |name| {
                try project.renamePreserve(name, target, name, io);
                moved += 1;
            }
        } else {
            try self.workspace.renamePreserve("project", self.parent, std.fs.path.basename(self.output_path), io);
        }
        self.published = true;
    }

    /// Deletes only this private scratch directory, never the target project.
    /// A forced kill/power loss may leave scratch files; no recovery is hidden.
    pub fn deinit(self: *Draft) void {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        if (self.existing) |dir| dir.close(self.io);
        self.workspace.close(self.io);
        if (!self.preserve_workspace) self.parent.deleteTree(self.io, self.workspace_name) catch |err| {
            std.log.warn("temporary project retained at {s}: {s}", .{ self.workspace_path, @errorName(err) });
        };
        self.parent.close(self.io);
        self.allocator.free(self.output_path);
        self.allocator.free(self.project_path);
        self.allocator.free(self.workspace_path);
        self.allocator.free(self.workspace_name);
    }
};

fn seed(draft: *Draft) !void {
    try draft.workspace.createDirPath(draft.io, "project/lib");
    try draft.workspace.writeFile(draft.io, .{ .sub_path = "project/lib/main.dart", .data = "hello" });
    try draft.workspace.writeFile(draft.io, .{ .sub_path = "project/.gitignore", .data = "/build/\n" });
}

test "publish a new project and an existing empty directory without replacing it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "empty");
    for ([_][]const u8{ "new", "empty" }) |name| {
        var draft = try Draft.begin(a, io, tmp.dir, name);
        defer draft.deinit();
        try seed(&draft);
        try draft.publish();
        var target = try tmp.dir.openDir(io, name, .{});
        defer target.close(io);
        const bytes = try target.readFileAlloc(io, "lib/main.dart", a, .limited(20));
        defer a.free(bytes);
        try std.testing.expectEqualStrings("hello", bytes);
        try std.testing.expectError(error.ProjectAlreadyPublished, draft.publish());
    }
}

test "abort removes scratch only and refuses all nonempty destinations including dotgit" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git");
    try std.testing.expectError(error.ProjectDirectoryNotEmpty, Draft.begin(a, io, tmp.dir, "repo"));
    {
        var draft = try Draft.begin(a, io, tmp.dir, "new");
        defer draft.deinit();
        try seed(&draft);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "new", .{}));
    var retained = try tmp.dir.openDir(io, "repo/.git", .{});
    retained.close(io);
}

test "a destination populated during generation is not overwritten" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "new", "empty" }) |name| {
        if (std.mem.eql(u8, name, "empty")) try tmp.dir.createDirPath(io, name);
        var draft = try Draft.begin(a, io, tmp.dir, name);
        defer draft.deinit();
        try seed(&draft);
        try tmp.dir.createDirPath(io, name);
        var target = try tmp.dir.openDir(io, name, .{});
        defer target.close(io);
        try target.writeFile(io, .{ .sub_path = "keep", .data = "untouched" });
        if (draft.publish()) |_| return error.ExpectedConflict else |_| {}
        const bytes = try target.readFileAlloc(io, "keep", a, .limited(20));
        defer a.free(bytes);
        try std.testing.expectEqualStrings("untouched", bytes);
        try std.testing.expectError(error.FileNotFound, target.openDir(io, "lib", .{}));
    }
}

test "create dot uses a real directory and leaves that directory usable" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var draft = try Draft.begin(a, io, tmp.dir, ".");
    defer draft.deinit();
    try seed(&draft);
    try draft.publish();
    const bytes = try tmp.dir.readFileAlloc(io, "lib/main.dart", a, .limited(20));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
}
