const std = @import("std");
const managed_process = @import("managed_process.zig");

const poll_interval_ns: u64 = 20 * std.time.ns_per_ms;
const default_wait_timeout_ms: usize = 20_000;
const default_stop_grace_ms: usize = 2_000;

pub const Config = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8 = "flutter",
    wait_timeout_ms: usize = default_wait_timeout_ms,
    stop_grace_ms: usize = default_stop_grace_ms,
};

pub const Session = struct {
    config: Config,
    child: std.process.Child,
    reader_thread: std.Thread,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    app_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dds_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dds_uri_len: usize = 0,
    dds_uri_buf: [1024]u8 = undefined,

    pub fn create(config: Config, raw_vm_uri: []const u8) !*Session {
        var session = try config.allocator.create(Session);
        errdefer config.allocator.destroy(session);

        const argv = [_][]const u8{
            config.executable,
            "attach",
            "--machine",
            "--debug-url",
            raw_vm_uri,
        };
        session.* = .{
            .config = config,
            .child = try std.process.spawn(config.io, .{
                .argv = &argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
                .pgid = 0,
            }),
            .reader_thread = undefined,
        };
        errdefer session.child.kill(config.io);

        session.reader_thread = try std.Thread.spawn(.{}, readerThreadMain, .{session});
        return session;
    }

    pub fn destroy(self: *Session) void {
        self.stop.store(true, .release);
        managed_process.stopAndWait(
            self.config.io,
            &self.child,
            self.config.stop_grace_ms * std.time.ns_per_ms,
        );
        self.reader_thread.join();
        self.config.allocator.destroy(self);
    }

    pub fn waitForDdsUri(self: *Session, application_stop: *const std.atomic.Value(bool)) ![]const u8 {
        var waited_ms: usize = 0;
        while (!application_stop.load(.acquire)) {
            if (self.dds_ready.load(.acquire)) return self.dds_uri_buf[0..self.dds_uri_len];
            if (self.exited.load(.acquire)) return error.AttachExited;
            if (waited_ms >= self.config.wait_timeout_ms) return error.AttachTimeout;
            try std.Io.sleep(self.config.io, .{ .nanoseconds = poll_interval_ns }, .real);
            waited_ms += poll_interval_ns / std.time.ns_per_ms;
        }
        return error.Stopped;
    }

    pub fn isAlive(self: *const Session) bool {
        const pid = self.child.id orelse return false;
        return managed_process.isAlive(pid);
    }

    fn readerThreadMain(self: *Session) void {
        defer self.exited.store(true, .release);

        const stdout = self.child.stdout orelse return;
        var stream_buffer: [64 * 1024]u8 = undefined;
        var file_reader: std.Io.File.Reader = .initStreaming(stdout, self.config.io, &stream_buffer);
        const reader = &file_reader.interface;

        while (!self.stop.load(.acquire)) {
            const line = reader.takeDelimiter('\n') catch break orelse break;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            const event = parseMachineEvent(self.config.allocator, trimmed) orelse continue;
            switch (event) {
                .app_started => self.app_started.store(true, .release),
                .dds_uri => |dds_uri| {
                    defer self.config.allocator.free(dds_uri);
                    if (dds_uri.len > self.dds_uri_buf.len) {
                        std.debug.print("[flutter-attach] DDS URI exceeds {d} bytes.\n", .{self.dds_uri_buf.len});
                        continue;
                    }
                    @memcpy(self.dds_uri_buf[0..dds_uri.len], dds_uri);
                    self.dds_uri_len = dds_uri.len;
                    self.dds_ready.store(true, .release);
                },
            }
        }
    }
};

const MachineEvent = union(enum) {
    app_started,
    dds_uri: []u8,
};

fn parseMachineEvent(allocator: std.mem.Allocator, line: []const u8) ?MachineEvent {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .array or parsed.value.array.items.len == 0) return null;
    const message = parsed.value.array.items[0];
    if (message != .object) return null;
    const event = message.object.get("event") orelse return null;
    if (event != .string) return null;
    if (std.mem.eql(u8, event.string, "app.started")) return .app_started;
    if (!std.mem.eql(u8, event.string, "app.debugPort")) return null;

    const params = message.object.get("params") orelse return null;
    if (params != .object) return null;
    const ws_uri = params.object.get("wsUri") orelse return null;
    if (ws_uri != .string) return null;

    const scheme: []const u8 = if (std.mem.startsWith(u8, ws_uri.string, "ws://"))
        "http://"
    else if (std.mem.startsWith(u8, ws_uri.string, "wss://"))
        "https://"
    else
        return null;
    const scheme_len: usize = if (ws_uri.string[2] == ':') 5 else 6;
    var authority_and_path = ws_uri.string[scheme_len..];
    if (std.mem.endsWith(u8, authority_and_path, "/ws")) {
        authority_and_path = authority_and_path[0 .. authority_and_path.len - 2];
    }
    const uri = std.fmt.allocPrint(allocator, "{s}{s}", .{ scheme, authority_and_path }) catch return null;
    return .{ .dds_uri = uri };
}

test "parse Flutter attach machine lifecycle events" {
    const started = parseMachineEvent(std.testing.allocator,
        \\[{"event":"app.started","params":{"appId":"abc"}}]
    ) orelse return error.MissingStartedEvent;
    try std.testing.expect(started == .app_started);

    const debug_port = parseMachineEvent(std.testing.allocator,
        \\[{"event":"app.debugPort","params":{"appId":"abc","wsUri":"ws://127.0.0.1:123/token=/ws","baseUri":"file:///tmp/example/"}}]
    ) orelse return error.MissingDdsUri;
    const uri = switch (debug_port) {
        .dds_uri => |value| value,
        else => return error.MissingDdsUri,
    };
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("http://127.0.0.1:123/token=/", uri);
}

test "managed Flutter attach publishes DDS URI and is reaped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var fake = try tmp.dir.createFile(std.testing.io, "fake-flutter", .{ .permissions = .executable_file });
        defer fake.close(std.testing.io);
        try fake.writeStreamingAll(std.testing.io,
            \\#!/usr/bin/env bash
            \\dir="$(cd "$(dirname "$0")" && pwd)"
            \\printf '%s\n' "$@" > "$dir/args"
            \\printf '%s\n' '[{"event":"app.started","params":{"appId":"abc"}}]'
            \\printf '%s\n' '[{"event":"app.debugPort","params":{"wsUri":"ws://127.0.0.1:456/dds=/ws","baseUri":"file:///tmp/example/"}}]'
            \\trap 'printf TERM > "$dir/term"; exit 0' TERM
            \\while true; do sleep 0.05; done
            \\
        );
    }

    const executable = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/fake-flutter",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(executable);

    var application_stop = std.atomic.Value(bool).init(false);
    const session = try Session.create(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .executable = executable,
    }, "http://127.0.0.1:8181/raw=/");

    const dds_uri = try session.waitForDdsUri(&application_stop);
    try std.testing.expect(session.app_started.load(.acquire));
    try std.testing.expectEqualStrings("http://127.0.0.1:456/dds=/", dds_uri);
    session.destroy();

    const args = try tmp.dir.readFileAlloc(
        std.testing.io,
        "args",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(args);
    try std.testing.expect(std.mem.indexOf(u8, args, "attach\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "--machine\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "--debug-url\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "http://127.0.0.1:8181/raw=/") != null);

    const term = try tmp.dir.readFileAlloc(
        std.testing.io,
        "term",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(term);
    try std.testing.expectEqualStrings("TERM", term);
}

test "missing Flutter executable fails before attach session starts" {
    try std.testing.expectError(error.FileNotFound, Session.create(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .executable = "./definitely-missing-fushell-flutter",
    }, "http://127.0.0.1:8181/raw=/"));
}

test "Flutter attach early exit is reported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var fake = try tmp.dir.createFile(std.testing.io, "fake-flutter", .{ .permissions = .executable_file });
        defer fake.close(std.testing.io);
        try fake.writeStreamingAll(std.testing.io,
            \\#!/usr/bin/env bash
            \\exit 0
            \\
        );
    }

    const executable = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/fake-flutter",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(executable);

    var application_stop = std.atomic.Value(bool).init(false);
    const session = try Session.create(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .executable = executable,
    }, "http://127.0.0.1:8181/raw=/");
    defer session.destroy();
    try std.testing.expectError(error.AttachExited, session.waitForDdsUri(&application_stop));
}

test "Flutter attach DDS wait has a bounded timeout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var fake = try tmp.dir.createFile(std.testing.io, "fake-flutter", .{ .permissions = .executable_file });
        defer fake.close(std.testing.io);
        try fake.writeStreamingAll(std.testing.io,
            \\#!/usr/bin/env bash
            \\trap 'exit 0' TERM
            \\while true; do sleep 0.05; done
            \\
        );
    }

    const executable = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/fake-flutter",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(executable);

    var application_stop = std.atomic.Value(bool).init(false);
    const session = try Session.create(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .executable = executable,
        .wait_timeout_ms = 40,
    }, "http://127.0.0.1:8181/raw=/");
    defer session.destroy();
    try std.testing.expectError(error.AttachTimeout, session.waitForDdsUri(&application_stop));
}
