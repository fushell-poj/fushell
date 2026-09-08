//! Capture tool output without exposing temporary paths on successful creation.
//! Build output is replayed only after the concurrent Engine transfer has been
//! joined/cancelled, so curl is the sole owner of the progress line while active.
//! Each stream retains a bounded diagnostic tail; verbose tools are still drained
//! rather than killed or allowed to consume unbounded memory.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tail_limit = 1024 * 1024;

const Tail = struct {
    bytes: std.ArrayList(u8) = .empty,
    truncated: bool = false,

    fn append(self: *Tail, a: Allocator, data: []const u8) !void {
        if (data.len >= tail_limit) {
            self.truncated = self.truncated or self.bytes.items.len != 0 or data.len > tail_limit;
            self.bytes.clearRetainingCapacity();
            try self.bytes.appendSlice(a, data[data.len - tail_limit ..]);
            return;
        }
        if (self.bytes.items.len + data.len > tail_limit) {
            const discard = self.bytes.items.len + data.len - tail_limit;
            std.mem.copyForwards(u8, self.bytes.items, self.bytes.items[discard..]);
            self.bytes.items.len -= discard;
            self.truncated = true;
        }
        try self.bytes.appendSlice(a, data);
    }

    fn write(self: *const Tail, writer: *Io.Writer) !void {
        if (self.truncated) try writer.writeAll("[earlier tool output omitted; showing the final 1 MiB]\n");
        if (self.bytes.items.len == 0) return;
        try writer.writeAll(self.bytes.items);
        if (self.bytes.items[self.bytes.items.len - 1] != '\n') try writer.writeByte('\n');
    }
};

pub const Transcript = struct {
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    stdout: Tail = .{},
    stderr: Tail = .{},

    pub fn init(allocator: Allocator, io: Io, environ: *const std.process.Environ.Map) Transcript {
        return .{ .allocator = allocator, .io = io, .environ = environ };
    }

    pub fn deinit(self: *Transcript) void {
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
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = cwd,
            .environ_map = self.environ,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(self.io);
        var buffer: Io.File.MultiReader.Buffer(2) = undefined;
        var reader: Io.File.MultiReader = undefined;
        reader.init(self.allocator, self.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (true) {
            var ended = false;
            reader.fill(4096, .none) catch |err| switch (err) {
                error.EndOfStream => ended = true,
                else => return err,
            };
            inline for (.{ "stdout", "stderr" }, 0..) |name, index| {
                const stream = reader.reader(index);
                const data = stream.buffered();
                try @field(self, name).append(self.allocator, data);
                stream.toss(data.len);
            }
            if (ended) break;
        }
        try reader.checkAnyError();
        const term = try @import("child_wait.zig").wait(&child, self.io);
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
        try self.stdout.write(writer);
        try self.stderr.write(writer);
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
