//! Read-only Engine compatibility checks. Metadata/schema/hash rules are shared
//! with the store; no ensure(), repair, .part file, or .so download is performed.
const std = @import("std");
const store_mod = @import("../flutter_engine_store.zig");
const native = @import("native.zig");
const deadline = @import("deadline.zig");
const process = @import("process.zig");
const Report = @import("report.zig").Report;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn check(report: *Report, init: std.process.Init, tools: ?native.Flutter, project_root: ?[]const u8) !void {
    const tools_value = tools orelse return report.add("engine", "Fushell Engine", .info, "not checked: Flutter is unavailable", &.{}, null);
    const arch = store_mod.nativeArch() catch return report.add("engine", "Fushell Engine", .@"error", "unsupported architecture", &.{}, null);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const repository = init.environ_map.get(store_mod.repository_env) orelse store_mod.default_repository;
    validateRepository(repository) catch return report.add("engine", "Fushell Engine", .@"error", "invalid FUSHELL_ENGINE_REPOSITORY", &.{}, "Use an HTTP(S) repository base URL without credentials, a query, or a fragment.");
    const details = &.{
        try std.fmt.allocPrint(a, "revision: {s}", .{tools_value.engine_revision}),
        try std.fmt.allocPrint(a, "repository: {s}", .{repository}),
        try std.fmt.allocPrint(a, "architecture: {s}", .{arch.name()}),
    };
    var cached: store_mod.CacheInspection = .{ .state = .missing };
    if (project_root) |root| {
        const dir = try Io.Dir.cwd().openDir(init.io, root, .{});
        defer dir.close(init.io);
        var info: store_mod.FlutterInfo = .{ .flutter_version = tools_value.flutter_version, .dart_version = tools_value.dart_version, .engine_revision = tools_value.engine_revision };
        const store = store_mod.Store.initWith(a, init.io, init.environ_map, dir, repository, store_mod.default_cache_root, &info, .curl());
        cached = deadline.call(init.io, 10_000, store_mod.Store.inspectCache, .{ &store, arch }) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            return report.add("engine.cache", "Engine cache", .@"error", "cache inspection did not complete", &.{@errorName(err)}, "Check cache permissions or disk health. Doctor did not alter the cache.");
        };
        const cache_path = try std.fs.path.join(a, &.{ root, try store.engineDir(arch) });
        switch (cached.state) {
            .busy => return report.add("engine.cache", "Engine cache", .warning, "another build is publishing this cache; verification skipped", &.{cache_path}, "Retry when the build finishes; doctor does not wait for or replace the lock."),
            .unlocked => try report.add("engine.cache", "Engine cache", .warning, "cache has no usable publication lock; existing binaries were not trusted", &.{cache_path}, "Let a normal Fushell build initialize the cache."),
            .invalid_metadata => try report.add("engine.cache", "Engine cache", .warning, "cached metadata is invalid; existing binaries were not trusted", &.{cache_path}, "A normal build can fetch metadata again; doctor leaves files unchanged."),
            .origin_mismatch => try report.add("engine.cache", "Engine cache", .info, "cache belongs to a different repository", &.{cache_path}, null),
            .missing, .inspected => {},
        }
    }
    if (cached.verifiedCount() == 3) {
        try report.add("engine", "Fushell Engine", .ok, "all three modes are cached and SHA-256 verified; no network request made", details, null);
        return addModes(report, cached, true);
    }
    const url = try std.fmt.allocPrint(a, "{s}/releases/download/engine-{s}/metadata.json", .{ std.mem.trimEnd(u8, repository, "/"), tools_value.engine_revision });
    const response = process.run(a, init.io, .{
        .argv = &.{ "curl", "--disable", "--globoff", "--location", "--proto", "=http,https", "--proto-redir", "=http,https", "--silent", "--show-error", "--connect-timeout", "5", "--max-time", "15", "--max-filesize", "1048576", "--write-out", "\n%{http_code}", "--url", url },
        .environ = init.environ_map,
        .timeout_ms = 20_000,
        .stdout_limit = 1024 * 1024 + 32,
    }) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        const failure: Failure = switch (err) {
            error.FileNotFound => .{ .summary = "curl is unavailable; uncached Engine modes cannot be checked", .remedy = "Install curl or correct PATH. No Engine binaries were downloaded." },
            error.Timeout => curlFailure(28),
            error.StreamTooLong => curlFailure(63),
            else => .{ .summary = "could not execute the metadata probe", .remedy = "Check curl and process permissions." },
        };
        try report.add("engine", "Fushell Engine", .@"error", failure.summary, details, failure.remedy);
        return addModes(report, cached, false);
    };
    defer process.deinit(a, response);
    const exit_code: u8 = switch (response.term) {
        .exited => |code| code,
        else => 255,
    };
    if (exit_code != 0) {
        const failure = curlFailure(exit_code);
        try report.add("engine", "Fushell Engine", .@"error", failure.summary, details, failure.remedy);
        return addModes(report, cached, false);
    }
    const http = parseResponse(response.stdout) catch {
        try report.add("engine", "Fushell Engine", .@"error", "curl returned an invalid HTTP probe response", details, "Check the curl executable in PATH.");
        return addModes(report, cached, false);
    };
    if (http.status != 200) {
        const failure = httpFailure(http.status);
        const summary = try std.fmt.allocPrint(a, "{s} (HTTP {d})", .{ failure.summary, http.status });
        try report.add("engine", "Fushell Engine", .@"error", summary, details, failure.remedy);
        return addModes(report, cached, false);
    }
    var parsed = store_mod.parseReleaseMetadata(a, http.body, tools_value.engine_revision, arch) catch |err| {
        if (err == error.OutOfMemory) return err;
        const summary = try std.fmt.allocPrint(a, "release metadata failed validation: {s}", .{@errorName(err)});
        try report.add("engine", "Fushell Engine", .@"error", summary, details, "Publish valid metadata with the selected revision and architecture; do not rename a mismatched Engine.");
        return addModes(report, cached, false);
    };
    defer parsed.deinit();
    try report.add("engine", "Fushell Engine", .ok, "matching metadata lists debug/profile/release; uncached binaries were not downloaded or hash-verified", details, null);
    try addModes(report, cached, true);
}

fn addModes(report: *Report, cached: store_mod.CacheInspection, remote_ok: bool) !void {
    inline for (.{ "debug", "profile", "release" }, 0..) |mode, i| {
        const state = cached.modes[i];
        const verified = state == .verified;
        const damaged = state == .hash_mismatch or state == .invalid_file or state == .unreadable;
        try report.add("engine." ++ mode, "Engine " ++ mode, if (verified) .ok else if (!remote_ok or damaged) .warning else .info, if (verified) "local file verified against cached metadata" else if (damaged) "local file is not usable; doctor did not repair or delete it" else if (remote_ok) "listed in remote metadata; downloaded on first build" else "not verified locally; remote availability could not be established", if (damaged) &.{@tagName(state)} else &.{}, if (damaged) "A successful normal build can download a verified replacement." else null);
    }
}

fn validateRepository(text: []const u8) !void {
    const uri = try std.Uri.parse(text);
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidRepository;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidRepository;
    if (uri.host.?.isEmpty()) return error.InvalidRepository;
}

const Http = struct { status: u16, body: []const u8 };
fn parseResponse(bytes: []const u8) !Http {
    const end = std.mem.lastIndexOfScalar(u8, bytes, '\n') orelse return error.InvalidResponse;
    const status_text = bytes[end + 1 ..];
    if (status_text.len != 3) return error.InvalidResponse;
    const status = try std.fmt.parseInt(u16, status_text, 10);
    if (status < 100 or status > 599) return error.InvalidResponse;
    if (end > 1024 * 1024) return error.InvalidResponse;
    return .{ .status = status, .body = bytes[0..end] };
}

const Failure = struct { summary: []const u8, remedy: []const u8 };
fn curlFailure(code: u8) Failure {
    return switch (code) {
        5 => .{ .summary = "proxy host could not be resolved", .remedy = "Check the configured proxy hostname and DNS; proxy credentials are not included in this report." },
        6 => .{ .summary = "repository host could not be resolved", .remedy = "Check DNS and network access." },
        7 => .{ .summary = "could not connect to the repository or proxy", .remedy = "Check connectivity, the proxy port, and firewall rules." },
        28 => .{ .summary = "Engine metadata request timed out", .remedy = "Check network/proxy connectivity and retry." },
        35, 51, 58, 60, 77 => .{ .summary = "TLS or certificate validation failed", .remedy = "Check system time, CA certificates and proxy trust; do not disable TLS verification." },
        47 => .{ .summary = "too many metadata redirects", .remedy = "Check the repository URL or mirror configuration." },
        63 => .{ .summary = "metadata response exceeded the 1 MiB limit", .remedy = "Check that the URL serves metadata JSON, not an Engine or error page." },
        else => .{ .summary = "metadata transport failed", .remedy = "Check curl, network and proxy configuration; this is not proof that an Engine release is missing." },
    };
}
fn httpFailure(status: u16) Failure {
    return switch (status) {
        401, 403 => .{ .summary = "repository access was denied", .remedy = "Check repository access, server restrictions or rate limits." },
        404 => .{ .summary = "no matching metadata was found at the configured repository", .remedy = "Check the repository/revision and access permissions, or publish the matching Engine. Private repositories can also return 404." },
        407 => .{ .summary = "proxy authentication is required", .remedy = "Correct your proxy authentication settings." },
        429 => .{ .summary = "repository rate limit was reached", .remedy = "Retry after the server's rate limit resets." },
        500...599 => .{ .summary = "repository server failed", .remedy = "Retry later or check the configured mirror; changing Flutter is not the remedy for a server error." },
        else => .{ .summary = "unexpected metadata HTTP status", .remedy = "Check the configured repository and its HTTP response." },
    };
}

test "HTTP parsing is bounded and transport failures are not missing releases" {
    const response = try parseResponse("{}\n200");
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{}", response.body);
    for ([_][]const u8{ "", "{}", "{}\n000", "{}\n999", "{}\n200junk" }) |bad|
        try std.testing.expectError(error.InvalidResponse, parseResponse(bad));
    try std.testing.expect(std.mem.indexOf(u8, curlFailure(5).summary, "proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, curlFailure(28).summary, "timed out") != null);
    try std.testing.expect(std.mem.indexOf(u8, httpFailure(404).remedy, "Private") != null);
    try std.testing.expect(std.mem.indexOf(u8, httpFailure(503).summary, "server") != null);
}

test "repository URLs reject credential/query leakage and invalid schemes" {
    try validateRepository("https://github.com/fushell-poj/fushell-engine-builds/");
    for ([_][]const u8{ "", "file:///tmp/repo", "https://user:secret@example.com/repo", "https://example.com/repo?token=secret" }) |value| {
        if (validateRepository(value)) |_| return error.ExpectedFailure else |_| {}
    }
}
