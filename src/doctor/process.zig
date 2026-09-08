//! Bounded subprocess probes: explicit PATH/environment, both output streams,
//! a wall-clock deadline (also after EOF), and process-group cleanup on failure.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const Result = std.process.RunResult;
pub const Options = struct {
    argv: []const []const u8,
    environ: *const std.process.Environ.Map,
    cwd: std.process.Child.Cwd = .inherit,
    timeout_ms: u32 = 30_000,
    stdout_limit: usize = 1024 * 1024,
    stderr_limit: usize = 64 * 1024,
};

pub fn deinit(a: Allocator, result: Result) void {
    a.free(result.stdout);
    a.free(result.stderr);
}

/// Resolve argv[0] using the environment we actually give the subprocess, not
/// std.process.spawn's parent PATH. Returned paths are absolute and owned.
pub fn executable(a: Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const path = try std.fs.path.resolve(a, &.{ cwd, name });
        errdefer a.free(path);
        try Io.Dir.cwd().access(io, path, .{ .execute = true });
        if ((try Io.Dir.cwd().statFile(io, path, .{})).kind != .file) return error.NotExecutableFile;
        return path;
    }
    var parts = std.mem.splitScalar(u8, env.get("PATH") orelse "", ':');
    while (parts.next()) |part| {
        const path = try std.fs.path.resolve(a, &.{ cwd, if (part.len == 0) "." else part, name });
        const usable = blk: {
            Io.Dir.cwd().access(io, path, .{ .execute = true }) catch break :blk false;
            const stat = Io.Dir.cwd().statFile(io, path, .{}) catch break :blk false;
            break :blk stat.kind == .file;
        };
        if (usable) return path;
        a.free(path);
    }
    return error.FileNotFound;
}

pub fn run(a: Allocator, io: Io, options: Options) !Result {
    const path = try executable(a, io, options.environ, options.argv[0]);
    defer a.free(path);
    const argv = try a.dupe([]const u8, options.argv);
    defer a.free(argv);
    argv[0] = path;
    const deadline = Io.Timeout{ .deadline = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(options.timeout_ms) }) };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = options.environ,
        .cwd = options.cwd,
        .pgid = 0,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer {
        // Kill before reaping: the process-group ID cannot be recycled while its
        // leader is still ours. Includes descendants holding inherited pipes.
        if (child.id) |pid| _ = std.os.linux.kill(-pid, .KILL);
        child.kill(io);
    }
    var buffers: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(a, io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(4096, deadline)) |_| {
        if (reader.reader(0).buffered().len > options.stdout_limit or reader.reader(1).buffered().len > options.stderr_limit)
            return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    if (reader.reader(0).buffered().len > options.stdout_limit or reader.reader(1).buffered().len > options.stderr_limit) return error.StreamTooLong;
    const term = try wait(io, &child, deadline);
    const stdout = try reader.toOwnedSlice(0);
    errdefer a.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn wait(io: Io, child: *std.process.Child, deadline: Io.Timeout) !std.process.Child.Term {
    const Event = union(enum) { done: std.process.Child.WaitError!std.process.Child.Term, timeout: Io.Cancelable!void };
    var buffer: [2]Event = undefined;
    var select = Io.Select(Event).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.done, std.process.Child.wait, .{ child, io });
    try select.concurrent(.timeout, Io.Timeout.sleep, .{ deadline, io });
    switch (try select.await()) {
        .done => |result| return result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}

test "probe captures output and exit status" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const result = try run(std.testing.allocator, std.testing.io, .{ .environ = &env, .argv = &.{ "/bin/sh", "-c", "printf out; printf err >&2; exit 7" } });
    defer deinit(std.testing.allocator, result);
    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(@as(u8, 7), result.term.exited);
}

test "probe deadlines cover silence, output dribbling, and closed pipes" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "/bin/sleep 10", "exec 1>&- 2>&-; /bin/sleep 10", "while true; do printf x; /bin/sleep 0.01; done" }) |script| {
        try std.testing.expectError(error.Timeout, run(std.testing.allocator, std.testing.io, .{ .environ = &env, .argv = &.{ "/bin/sh", "-c", script }, .timeout_ms = 120 }));
    }
}

test "probe limits both output streams and honors the supplied PATH" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/nonexistent");
    try std.testing.expectError(error.FileNotFound, executable(std.testing.allocator, std.testing.io, &env, "sh"));
    try std.testing.expectError(error.StreamTooLong, run(std.testing.allocator, std.testing.io, .{ .environ = &env, .argv = &.{ "/bin/sh", "-c", "while true; do printf 123456789; done" }, .stdout_limit = 32 }));
}
