//! AOT side outputs, isolated by compilation inputs and archived outside bundles.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// NUL separators make field boundaries unambiguous (paths cannot contain NUL).
pub fn inputKey(fields: []const []const u8) [64]u8 {
    var hash = Sha256.init(.{});
    for (fields) |field| {
        hash.update(field);
        hash.update(&.{0});
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

pub fn fileHash(io: Io, dir: Io.Dir, path: []const u8) ![64]u8 {
    const file = try dir.openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var chunk: [8192]u8 = undefined;
    var hash = Sha256.init(.{});
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        hash.update(chunk[0..n]);
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

fn isBuildId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Open a generated relative output path without following any component.
fn openOutput(io: Io, path: []const u8) !Io.Dir {
    var dir = try Io.Dir.cwd().openDir(io, ".", .{});
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeAotRecoveryPath;
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}

fn readMetadata(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, limit: Io.Limit) ![]u8 {
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, limit);
}

/// Flutter filters intermediates from --build-outputs. After successful assemble,
/// output/.last_build_id selects the exact cache entry, including on cache hits.
/// Cross-check its outputs.json against this keyed output before unlinking app.so.
pub fn invalidateAot(gpa: Allocator, io: Io, output: []const u8) !void {
    var output_dir = try openOutput(io, output);
    defer output_dir.close(io);
    const id = try readMetadata(gpa, io, output_dir, ".last_build_id", .limited(33));
    defer gpa.free(id);
    if (!isBuildId(id)) return error.UnsafeAotRecoveryPath;
    var dart_tool = try Io.Dir.cwd().openDir(io, ".dart_tool", .{ .follow_symlinks = false });
    defer dart_tool.close(io);
    var cache = try dart_tool.openDir(io, "flutter_build", .{ .follow_symlinks = false });
    defer cache.close(io);
    var entry = try cache.openDir(io, id, .{ .follow_symlinks = false });
    defer entry.close(io);
    const bytes = try readMetadata(gpa, io, entry, "outputs.json", .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);
    const outputs = try std.json.parseFromSlice([]const []const u8, gpa, bytes, .{});
    defer outputs.deinit();
    const root = try output_dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const expected = try std.fs.path.join(gpa, &.{ root, "lib", "libapp.so" });
    defer gpa.free(expected);
    var matches: usize = 0;
    for (outputs.value) |path| {
        if (std.mem.eql(u8, path, expected)) matches += 1;
    }
    if (matches != 1) return error.MissingAotRecoveryPath;
    // Only the tracked AOT output; kernels, stamps and other builds survive.
    try entry.deleteFile(io, "app.so");
}

/// Content-addressed, non-replacing publication. Metadata identifies both files
/// and the compilation inputs; runtime bundles contain neither archive nor symbols.
pub fn archive(gpa: Allocator, io: Io, app: []const u8, symbols: []const u8, inputs: []const []const u8) ![]u8 {
    var build = try Io.Dir.cwd().openDir(io, "build", .{ .follow_symlinks = false });
    defer build.close(io);
    var artifacts = try build.createDirPathOpen(io, "fushell_debug_info", .{ .open_options = .{ .follow_symlinks = false } });
    defer artifacts.close(io);
    var root = try artifacts.createDirPathOpen(io, "archives", .{ .open_options = .{ .follow_symlinks = false } });
    defer root.close(io);
    var random: [16]u8 = undefined;
    io.random(&random);
    const stage = try std.fmt.allocPrint(gpa, ".stage-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer gpa.free(stage);
    try root.createDir(io, stage, .default_dir);
    defer root.deleteTree(io, stage) catch {};
    var dir = try root.openDir(io, stage, .{ .follow_symlinks = false });
    defer dir.close(io);
    try Io.Dir.cwd().copyFile(symbols, dir, "libapp.so.symbols", io, .{});
    // Hash the actual delivered app and copied archive bytes, not a source
    // which might change between hashing and copying.
    const app_hash = try fileHash(io, .cwd(), app);
    const symbol_hash = try fileHash(io, dir, "libapp.so.symbols");
    const input_hash = inputKey(inputs);
    const archive_key = inputKey(&.{ &input_hash, &app_hash, &symbol_hash });
    const destination = try std.fs.path.join(gpa, &.{ "build/fushell_debug_info/archives", &archive_key });
    errdefer gpa.free(destination);
    var metadata: Io.Writer.Allocating = .init(gpa);
    defer metadata.deinit();
    try std.json.Stringify.value(.{
        .schema = @as(u32, 1),
        .app_sha256 = app_hash[0..],
        .symbols_sha256 = symbol_hash[0..],
        .inputs = inputs,
    }, .{ .whitespace = .indent_2 }, &metadata.writer);
    try dir.writeFile(io, .{ .sub_path = "pair.json", .data = metadata.written() });
    root.renamePreserve(stage, root, &archive_key, io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Existing archives are immutable, even if damaged.
            var old = try root.openDir(io, &archive_key, .{ .follow_symlinks = false });
            defer old.close(io);
            if (!std.mem.eql(u8, &(try fileHash(io, old, "libapp.so.symbols")), &symbol_hash)) return error.SymbolArchiveMismatch;
            const metadata_file = try old.openFile(io, "pair.json", .{ .follow_symlinks = false });
            defer metadata_file.close(io);
            var reader = metadata_file.reader(io, &.{});
            const bytes = try reader.interface.allocRemaining(gpa, .limited(1024 * 1024));
            defer gpa.free(bytes);
            if (!std.mem.eql(u8, bytes, metadata.written())) return error.SymbolArchiveMismatch;
        },
        else => return err,
    };
    return destination;
}

test "input key separates modes entrypoints toolchains and field boundaries" {
    const a = inputKey(&.{ "release", "lib/main.dart", "engine-a" });
    try std.testing.expect(!std.mem.eql(u8, &a, &inputKey(&.{ "profile", "lib/main.dart", "engine-a" })));
    try std.testing.expect(!std.mem.eql(u8, &a, &inputKey(&.{ "release", "lib/other.dart", "engine-a" })));
    try std.testing.expect(!std.mem.eql(u8, &a, &inputKey(&.{ "release", "lib/main.dart", "engine-b" })));
    try std.testing.expect(!std.mem.eql(u8, &inputKey(&.{ "ab", "c" }), &inputKey(&.{ "a", "bc" })));
}

test "recovery accepts only exact Flutter build identifiers" {
    try std.testing.expect(isBuildId("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isBuildId("../0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isBuildId("0123456789abcdef0123456789abcdef/"));
    try std.testing.expect(!isBuildId("g123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isBuildId(""));
}

test "targeted recovery and non-replacing symbol archive" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try Io.Threaded.chdir(root);
    defer Io.Threaded.chdir(cwd) catch @panic("restore cwd");
    const cached = ".dart_tool/flutter_build/0123456789abcdef0123456789abcdef";
    try tmp.dir.createDirPath(io, cached);
    try tmp.dir.writeFile(io, .{ .sub_path = cached ++ "/app.so", .data = "aot" });
    try tmp.dir.writeFile(io, .{ .sub_path = cached ++ "/app.dill", .data = "kernel" });
    const output = "build/keyed";
    try tmp.dir.createDirPath(io, output);
    try tmp.dir.writeFile(io, .{ .sub_path = output ++ "/.last_build_id", .data = "0123456789abcdef0123456789abcdef" });
    const metadata = try std.fmt.allocPrint(gpa, "[\"{s}/{s}/lib/libapp.so\"]", .{ root, output });
    defer gpa.free(metadata);
    try tmp.dir.writeFile(io, .{ .sub_path = cached ++ "/outputs.json", .data = metadata });
    try invalidateAot(gpa, io, output);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, cached ++ "/app.so", .{}));
    try tmp.dir.access(io, cached ++ "/app.dill", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = cached ++ "/app.so", .data = "keep outside target" });
    try tmp.dir.writeFile(io, .{ .sub_path = cached ++ "/outputs.json", .data = "[\"/foreign/lib/libapp.so\"]" });
    try std.testing.expectError(error.MissingAotRecoveryPath, invalidateAot(gpa, io, output));
    try tmp.dir.access(io, cached ++ "/app.so", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = cached ++ "/outputs.json", .data = metadata });
    try tmp.dir.writeFile(io, .{ .sub_path = output ++ "/.last_build_id", .data = "../escape" });
    try std.testing.expectError(error.UnsafeAotRecoveryPath, invalidateAot(gpa, io, output));
    try tmp.dir.writeFile(io, .{ .sub_path = output ++ "/.last_build_id", .data = "0123456789abcdef0123456789abcdef" });
    try tmp.dir.rename(cached, tmp.dir, "moved-cache", io);
    try tmp.dir.symLink(io, "../../moved-cache", cached, .{ .is_directory = true });
    if (invalidateAot(gpa, io, output)) |_| return error.SymlinkRecoveryAccepted else |_| {}
    const kept = try tmp.dir.readFileAlloc(io, "moved-cache/app.so", gpa, .limited(1024));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("keep outside target", kept);
    try tmp.dir.writeFile(io, .{ .sub_path = "app.so", .data = "compiled application" });
    try tmp.dir.writeFile(io, .{ .sub_path = "symbols", .data = "matching diagnostics" });
    try tmp.dir.createDirPath(io, "build");
    const first = try archive(gpa, io, "app.so", "symbols", &.{ "release", "lib/main.dart", "engine" });
    defer gpa.free(first);
    const second = try archive(gpa, io, "app.so", "symbols", &.{ "release", "lib/main.dart", "engine" });
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
    var archived = try tmp.dir.openDir(io, first, .{});
    defer archived.close(io);
    try archived.writeFile(io, .{ .sub_path = "pair.json", .data = "keep damaged archive untouched" });
    try std.testing.expectError(error.SymbolArchiveMismatch, archive(gpa, io, "app.so", "symbols", &.{ "release", "lib/main.dart", "engine" }));
    // A symlinked archive root must never redirect publication outside build.
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.rename("build/fushell_debug_info/archives", tmp.dir, "saved-archives", io);
    try tmp.dir.symLink(io, "../../outside", "build/fushell_debug_info/archives", .{ .is_directory = true });
    if (archive(gpa, io, "app.so", "symbols", &.{ "release", "lib/main.dart", "engine" })) |unexpected| {
        gpa.free(unexpected);
        return error.SymlinkArchiveAccepted;
    } else |_| {}
    var outside = try tmp.dir.openDir(io, "outside", .{ .iterate = true });
    defer outside.close(io);
    var iterator = outside.iterate();
    try std.testing.expect((try iterator.next(io)) == null);
}
