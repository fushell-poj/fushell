//! Capture tool output without exposing temporary paths on successful creation.
//! Build output is replayed only after the concurrent Engine transfer has been
//! joined/cancelled, so curl is the sole owner of the progress line while active.
//! Each stream retains a bounded diagnostic tail; verbose tools are still drained
//! rather than killed or allowed to consume unbounded memory.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tail_limit = 1024 * 1024;
const child_wait = @import("child_wait.zig");
const poll_ms = 20;
const drain_ms = 250;

const Tail = struct {
    bytes: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    total: usize = 0,

    fn append(self: *Tail, a: Allocator, data: []const u8) !void {
        // Advance only after successful append so allocation failures leave
        // absolute step boundaries consistent with the retained bytes.
        var appended = false;
        defer if (appended) {
            self.total += data.len;
        };
        if (data.len >= tail_limit) {
            self.truncated = self.truncated or self.bytes.items.len != 0 or data.len > tail_limit;
            self.bytes.clearRetainingCapacity();
            try self.bytes.appendSlice(a, data[data.len - tail_limit ..]);
            appended = true;
            return;
        }
        if (self.bytes.items.len + data.len > tail_limit) {
            const discard = self.bytes.items.len + data.len - tail_limit;
            std.mem.copyForwards(u8, self.bytes.items, self.bytes.items[discard..]);
            self.bytes.items.len -= discard;
            self.truncated = true;
        }
        try self.bytes.appendSlice(a, data);
        appended = true;
    }

    /// Slice absolute stream offsets against the retained tail. Step metadata
    /// stores offsets, never pointers invalidated by buffer growth or pruning.
    fn writeRange(self: *const Tail, writer: *Io.Writer, from: usize, to: usize) !void {
        const retained_start = self.total - self.bytes.items.len;
        const start = @max(from, retained_start);
        const end = @min(to, self.total);
        if (start >= end) return;
        const bytes = self.bytes.items[start - retained_start .. end - retained_start];
        try writer.writeAll(bytes);
        if (bytes[bytes.len - 1] != '\n') try writer.writeByte('\n');
    }
};

pub const Transcript = struct {
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    stdout: Tail = .{},
    stderr: Tail = .{},
    steps: std.ArrayList(Step) = .empty,

    const Step = struct { stdout: usize, stderr: usize };

    pub fn init(allocator: Allocator, io: Io, environ: *const std.process.Environ.Map) Transcript {
        return .{ .allocator = allocator, .io = io, .environ = environ };
    }

    pub fn deinit(self: *Transcript) void {
        self.steps.deinit(self.allocator);
        self.stdout.bytes.deinit(self.allocator);
        self.stderr.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Run argv directly with an explicit environment. Both pipes are drained
    /// concurrently; no subprocess output is inherited by the terminal. The
    /// caller chooses when (or whether) to show the transcript. All error paths
    /// terminate and reap the direct child before the caller can print it.
    pub fn run(self: *Transcript, cwd: std.process.Child.Cwd, argv: []const []const u8) !void {
        if (argv.len == 0) return error.CommandFailed;
        // Reclaim boundaries that precede both retained tails. This also bounds
        // metadata when a caller runs many silent or very chatty commands.
        const out_start = self.stdout.total - self.stdout.bytes.items.len;
        const err_start = self.stderr.total - self.stderr.bytes.items.len;
        while (self.steps.items.len > 1 and self.steps.items[1].stdout <= out_start and self.steps.items[1].stderr <= err_start)
            _ = self.steps.orderedRemove(0);
        const start: Step = .{ .stdout = self.stdout.total, .stderr = self.stderr.total };
        if (self.steps.items.len == 0 or !std.meta.eql(self.steps.items[self.steps.items.len - 1], start))
            try self.steps.append(self.allocator, start);
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = cwd,
            .environ_map = self.environ,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child_wait.terminate(&child, self.io);
        var buffer: Io.File.MultiReader.Buffer(2) = undefined;
        var reader: Io.File.MultiReader = undefined;
        reader.init(self.allocator, self.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        // init records per-stream allocation failures instead of returning them.
        // Check before waiting on any surviving stream, then after every fill.
        try reader.checkAnyError();
        var exit_seen: ?Io.Timestamp = null;
        while (true) {
            try self.io.checkCancel();
            if (exit_seen == null and try child_wait.exited(&child))
                exit_seen = Io.Timestamp.now(self.io, .awake);
            if (exit_seen) |when| {
                if (when.untilNow(self.io, .awake).toMilliseconds() >= drain_ms) {
                    try self.note("\n[tool exited; inherited output pipes did not close within 250 ms; remaining output omitted]\n", .{});
                    break;
                }
            }
            var ended = false;
            reader.fill(4096, .{ .duration = .{ .raw = .fromMilliseconds(poll_ms), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.EndOfStream => ended = true,
                else => return err,
            };
            try reader.checkAnyError();
            inline for (.{ "stdout", "stderr" }, 0..) |name, index| {
                const stream = reader.reader(index);
                const data = stream.buffered();
                try @field(self, name).append(self.allocator, data);
                stream.toss(data.len);
            }
            if (ended) break;
        }
        try reader.checkAnyError();
        // Cancel all pending reads BEFORE wait closes the underlying handles.
        reader.batch.cancel(self.io);
        const term = try child_wait.wait(&child, self.io);
        switch (term) {
            .exited => |code| if (code != 0) {
                var status_buffer: [96]u8 = undefined;
                try self.stderr.append(self.allocator, try std.fmt.bufPrint(&status_buffer, "\ntool exited with status {d}\n", .{code}));
                return error.CommandFailed;
            },
            .signal => |signal| {
                if (signal == .INT) return error.UserInterrupt;
                return error.CommandFailed;
            },
            else => return error.CommandFailed,
        }
    }

    /// Append Fushell's build diagnostics without competing with a live meter.
    pub fn note(self: *Transcript, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        if (self.stderr.bytes.items.len != 0 and self.stderr.bytes.items[self.stderr.bytes.items.len - 1] != '\n')
            try self.stderr.append(self.allocator, "\n");
        try self.stderr.append(self.allocator, text);
    }

    /// Serialize only at a point where no child owns a terminal progress line.
    /// A newline before replay also terminates an interrupted curl progress line.
    pub fn show(self: *const Transcript) void {
        if (self.stdout.bytes.items.len == 0 and self.stderr.bytes.items.len == 0) return;
        var buffer: [4096]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();
        stderr.file_writer.interface.writeByte('\n') catch return;
        self.write(&stderr.file_writer.interface) catch return;
    }

    pub fn write(self: *const Transcript, writer: *Io.Writer) !void {
        if (self.stdout.truncated) try writer.writeAll("[earlier stdout omitted; showing the final 1 MiB]\n");
        if (self.stderr.truncated) try writer.writeAll("[earlier stderr omitted; showing the final 1 MiB]\n");
        // Replay command 1's stdout/stderr before command 2's, not all stdout
        // followed by all stderr. Within a command the two streams have no
        // reliable total order, so preserve each stream's order separately.
        var previous: Step = .{ .stdout = 0, .stderr = 0 };
        for (self.steps.items) |step| {
            try self.stdout.writeRange(writer, previous.stdout, step.stdout);
            try self.stderr.writeRange(writer, previous.stderr, step.stderr);
            previous = step;
        }
        try self.stdout.writeRange(writer, previous.stdout, self.stdout.total);
        try self.stderr.writeRange(writer, previous.stderr, self.stderr.total);
    }
};

test "captured stdout and stderr retain diagnostics and the child exit code" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var output = Transcript.init(std.testing.allocator, std.testing.io, &env);
    defer output.deinit();
    try output.run(.inherit, &.{ "/bin/sh", "-c", "printf scaffold; printf warning >&2" });
    try std.testing.expectEqualStrings("scaffold", output.stdout.bytes.items);
    try std.testing.expectEqualStrings("warning", output.stderr.bytes.items);
    try std.testing.expectError(error.CommandFailed, output.run(.inherit, &.{ "/bin/sh", "-c", "printf failure >&2; exit 7" }));
    try std.testing.expect(std.mem.indexOf(u8, output.stderr.bytes.items, "failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr.bytes.items, "status 7") != null);
}

test "tail is bounded and marks omitted output without corrupting the suffix" {
    var tail: Tail = .{};
    defer tail.bytes.deinit(std.testing.allocator);
    const data = try std.testing.allocator.alloc(u8, tail_limit + 100);
    defer std.testing.allocator.free(data);
    @memset(data, 'x');
    try tail.append(std.testing.allocator, data);
    try tail.append(std.testing.allocator, "last diagnostic\n");
    try std.testing.expectEqual(tail_limit, tail.bytes.items.len);
    try std.testing.expect(tail.truncated);
    try std.testing.expect(std.mem.endsWith(u8, tail.bytes.items, "last diagnostic\n"));
}

test "replayed streams always end at a line boundary" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var output = Transcript.init(std.testing.allocator, std.testing.io, &env);
    defer output.deinit();
    try output.stdout.append(std.testing.allocator, "stdout without newline");
    try output.stderr.append(std.testing.allocator, "stderr without newline");
    var bytes: [128]u8 = undefined;
    var writer = Io.Writer.fixed(&bytes);
    try output.write(&writer);
    try std.testing.expectEqualStrings("stdout without newline\nstderr without newline\n", writer.buffered());
}

test "verbose tools are drained past the retained tail limit and allowed to finish" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var output = Transcript.init(std.testing.allocator, std.testing.io, &env);
    defer output.deinit();
    try output.run(.inherit, &.{ "/bin/sh", "-c", "i=0; while test $i -lt 1100; do printf '%01000d' 0; i=$((i+1)); done; printf 'last stdout\\n'; printf 'last stderr\\n' >&2" });
    try std.testing.expect(output.stdout.truncated);
    try std.testing.expectEqual(tail_limit, output.stdout.bytes.items.len);
    try std.testing.expect(std.mem.endsWith(u8, output.stdout.bytes.items, "last stdout\n"));
    try std.testing.expectEqualStrings("last stderr\n", output.stderr.bytes.items);
}

fn allocationFailureScenario(a: Allocator) !void {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var output = Transcript.init(a, std.testing.io, &env);
    defer output.deinit();
    // An unread stderr pipe fills up while stdout remains open. Failure to
    // allocate either reader or diagnostic tail must return, not wait for EOF.
    output.run(.inherit, &.{ "/bin/sh", "-c", "printf '%0200000d' 0 >&2; exit 7" }) catch |err| switch (err) {
        error.CommandFailed => return,
        else => return err,
    };
    return error.ExpectedCommandFailure;
}

test "every capture allocation failure unwinds without blocking on the other stream" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureScenario, .{});
}

test "direct child exit bounds drain even when a descendant holds the pipes" {
    const linux = std.os.linux;
    const io = std.testing.io;
    var previous: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&previous), 0, 0, 0)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0)));
    defer _ = linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), @intCast(previous), 0, 0, 0);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var output = Transcript.init(std.testing.allocator, io, &env);
    defer output.deinit();
    const start = Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.CommandFailed, output.run(.inherit, &.{ "/bin/sh", "-c", "/bin/sleep 30 & printf '%s' $!; exit 23" }));
    const pid = try std.fmt.parseInt(i32, output.stdout.bytes.items, 10);
    defer {
        // Test owns the adopted descendant. The production wrapper deliberately
        // owns only its direct child, never the shared terminal process group.
        _ = linux.kill(pid, .KILL);
        var status: u32 = undefined;
        while (linux.errno(linux.waitpid(pid, &status, 0)) == .INTR) {}
    }
    try std.testing.expect(start.untilNow(io, .awake).toMilliseconds() < 2_000);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr.bytes.items, "inherited output pipes") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr.bytes.items, "status 23") != null);
}

test "command boundaries retain warnings in the right step without joined lines" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var output = Transcript.init(std.testing.allocator, std.testing.io, &env);
    defer output.deinit();
    try output.run(.inherit, &.{ "/bin/sh", "-c", "printf first; printf warning >&2" });
    try output.run(.inherit, &.{ "/bin/sh", "-c", "printf second; printf error >&2; exit 0" });
    var buffer: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try output.write(&writer);
    try std.testing.expectEqualStrings("first\nwarning\nsecond\nerror\n", writer.buffered());
}

test "normal running command is not subject to the post-exit drain deadline" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var output = Transcript.init(std.testing.allocator, std.testing.io, &env);
    defer output.deinit();
    try output.run(.inherit, &.{ "/bin/sh", "-c", "/bin/sleep 0.35; printf complete" });
    try std.testing.expectEqualStrings("complete", output.stdout.bytes.items);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr.bytes.items, "omitted") == null);
}

test "capture cancellation reaps TERM-ignoring children with open or closed pipes" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const linux = std.os.linux;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    const Task = struct {
        fn run(output: *Transcript, directory: []const u8, script: []const u8) !void {
            try output.run(.{ .path = directory }, &.{ "/bin/sh", "-c", script });
        }
    };
    for ([_][]const u8{
        "trap '' TERM; printf '%s' $$ > pid; while :; do :; done",
        "trap '' TERM; exec 1>&- 2>&-; printf '%s' $$ > pid; while :; do :; done",
    }) |script| {
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var output = Transcript.init(a, io, &env);
        defer output.deinit();
        var task = try io.concurrent(Task.run, .{ &output, cwd, script });
        defer task.cancel(io) catch {};
        const started = Io.Timestamp.now(io, .awake);
        const pid = while (true) {
            const text = tmp.dir.readFileAlloc(io, "pid", a, .limited(32)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (text) |value| {
                defer a.free(value);
                if (value.len != 0) break try std.fmt.parseInt(i32, value, 10);
            }
            if (started.untilNow(io, .awake).toMilliseconds() > 3_000) return error.ChildNotReady;
            try Io.sleep(io, .fromMilliseconds(1), .awake);
        };
        const cancel_started = Io.Timestamp.now(io, .awake);
        try std.testing.expectError(error.Canceled, task.cancel(io));
        try std.testing.expect(cancel_started.untilNow(io, .awake).toMilliseconds() < 2_000);
        var status: u32 = undefined;
        try std.testing.expectEqual(linux.E.CHILD, linux.errno(linux.waitpid(pid, &status, linux.W.NOHANG)));
        try tmp.dir.deleteFile(io, "pid");
    }
}
