//! Resolve one Flutter installation once and use it for every build/dev tool.
const std = @import("std");
const store = @import("flutter_engine_store.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Toolchain = struct {
    allocator: Allocator,
    executable: []u8,
    root: []u8,
    dart_executable: []u8,
    info: store.FlutterInfo,

    /// Prefer an explicit SDK root, otherwise select the executable from PATH.
    /// Query this exact executable, not a second independently-resolved Flutter.
    pub fn discover(allocator: Allocator, io: Io, environ: *const std.process.Environ.Map) !Toolchain {
        const explicit_root = nonempty(environ.get("FLUTTER_ROOT")) orelse nonempty(environ.get("FLUTTER_SDK"));
        const executable = if (explicit_root) |root|
            try absolute(allocator, io, &.{ root, "bin", "flutter" })
        else
            try findFlutter(allocator, io, environ.get("PATH") orelse "");
        errdefer allocator.free(executable);
        try Io.Dir.cwd().access(io, executable, .{ .execute = true });
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ executable, "--version", "--machine" },
            .environ_map = environ,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.log.err("Flutter version query failed: {s}", .{result.stderr});
                return error.FlutterCommandFailed;
            },
            else => return error.FlutterCommandFailed,
        }
        var info = try store.parseFlutterInfoJson(allocator, result.stdout);
        errdefer info.deinit(allocator);
        const parsed = try std.json.parseFromSlice(struct { flutterRoot: ?[]const u8 = null }, allocator, result.stdout, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const resolved_executable = try Io.Dir.cwd().realPathFileAlloc(io, executable, allocator);
        defer allocator.free(resolved_executable);
        const inferred_root = std.fs.path.dirname(std.fs.path.dirname(resolved_executable) orelse return error.FlutterRootUnavailable) orelse return error.FlutterRootUnavailable;
        const root = try absolute(allocator, io, &.{nonempty(parsed.value.flutterRoot) orelse explicit_root orelse inferred_root});
        errdefer allocator.free(root);
        const dart_executable = try std.fs.path.join(allocator, &.{ root, "bin", "cache", "dart-sdk", "bin", "dart" });
        errdefer allocator.free(dart_executable);
        try Io.Dir.cwd().access(io, dart_executable, .{ .execute = true });
        return .{ .allocator = allocator, .executable = executable, .root = root, .dart_executable = dart_executable, .info = info };
    }

    /// Release the paths and version information owned by this toolchain.
    pub fn deinit(self: *Toolchain) void {
        self.info.deinit(self.allocator);
        self.allocator.free(self.executable);
        self.allocator.free(self.root);
        self.allocator.free(self.dart_executable);
        self.* = undefined;
    }
};

/// Empty overrides should behave like unset variables.
fn nonempty(value: ?[]const u8) ?[]const u8 {
    return if (value) |v| if (v.len != 0) v else null else null;
}

/// Construct an owned absolute path without changing process cwd.
fn absolute(allocator: Allocator, io: Io, parts: []const []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, parts);
    defer allocator.free(path);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

/// Search PATH in order; an empty component denotes the current directory.
fn findFlutter(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, path, ':');
    while (parts.next()) |part| {
        const candidate = try absolute(allocator, io, &.{ if (part.len == 0) "." else part, "flutter" });
        Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch |err| {
            allocator.free(candidate);
            switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                else => return err,
            }
        };
        return candidate;
    }
    return error.FlutterUnavailable;
}

/// Encode a local filename as a URI, including spaces, '#', '%' and non-ASCII bytes.
pub fn fileUri(allocator: Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.ExpectedAbsolutePath;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("file://");
    try (std.Uri.Component{ .raw = path }).formatPath(&output.writer);
    return output.toOwnedSlice();
}

test "file URI escapes filenames instead of treating them as URL syntax" {
    const result = try fileUri(std.testing.allocator, "/tmp/my app/a#b%.dart");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("file:///tmp/my%20app/a%23b%25.dart", result);
}

test "explicit SDK wins over a different flutter on PATH" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sdk/bin/cache/dart-sdk/bin");
    const script =
        "#!/bin/sh\n" ++
        "printf '%s\\n' '{\"frameworkVersion\":\"test-sdk\",\"engineRevision\":\"0123456789012345678901234567890123456789\",\"dartSdkVersion\":\"test-dart\"}'\n";
    var flutter = try tmp.dir.createFile(io, "sdk/bin/flutter", .{ .permissions = .executable_file });
    try flutter.writeStreamingAll(io, script);
    flutter.close(io);
    var dart = try tmp.dir.createFile(io, "sdk/bin/cache/dart-sdk/bin/dart", .{ .permissions = .executable_file });
    dart.close(io);
    const sdk = try tmp.dir.realPathFileAlloc(io, "sdk", allocator);
    defer allocator.free(sdk);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("FLUTTER_SDK", sdk);
    try env.put("PATH", "/nonexistent/other-sdk/bin");
    var toolchain = try Toolchain.discover(allocator, io, &env);
    defer toolchain.deinit();
    try std.testing.expectEqualStrings("test-sdk", toolchain.info.flutter_version);
    try std.testing.expectEqualStrings(sdk, toolchain.root);
}
