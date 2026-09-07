//! Parser regressions run without Flutter, a display, or a session bus.
const std = @import("std");
const cli = @import("root.zig");
const allocator = std.testing.allocator;

fn parse(args: []const []const u8) !cli.Command {
    var diagnostic: cli.Diagnostic = .{};
    return cli.parse(allocator, args, &diagnostic);
}

fn reject(args: []const []const u8, topic: cli.Topic, text: []const u8) !void {
    var diagnostic: cli.Diagnostic = .{};
    const result = cli.parse(allocator, args, &diagnostic);
    if (result) |_| return error.ExpectedParseFailure else |err| {
        try std.testing.expect(err != error.OutOfMemory);
        try std.testing.expectEqual(topic, diagnostic.topic);
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try diagnostic.report(&writer, err);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), text) != null);
        try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "error: "));
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--help") != null);
    }
}

test "bare invocation and general help" {
    for ([_][]const []const u8{ &.{}, &.{"help"}, &.{"--help"}, &.{"-h"}, &.{ "help", "help" } }) |args|
        try std.testing.expectEqual(cli.Topic.root, (try parse(args)).help);
}

test "all help spellings select the same command" {
    inline for (.{ "build", "run", "sdk" }, .{ cli.Topic.build, .run, .sdk }) |name, topic| {
        try std.testing.expectEqual(topic, (try parse(&.{ "help", name })).help);
        try std.testing.expectEqual(topic, (try parse(&.{ name, "--help" })).help);
        try std.testing.expectEqual(topic, (try parse(&.{ name, "-h" })).help);
        try std.testing.expectEqual(topic, (try parse(&.{ "--help", name })).help);
    }
}

test "default build run sdk values are command specific" {
    const build = (try parse(&.{"build"})).build;
    try std.testing.expectEqual(cli.Mode.debug, build.mode);
    try std.testing.expectEqualStrings(".", build.input);
    try std.testing.expect(build.output == null);
    const run = (try parse(&.{"run"})).run;
    try std.testing.expectEqual(cli.Mode.debug, run.build.mode);
    try std.testing.expect(run.hot_reload);
    try std.testing.expect(!run.devtools);
    try std.testing.expect(run.launch_browser);
    try std.testing.expect(run.vmServiceEnabled());
    try std.testing.expectEqual(@as(usize, 0), run.application_args.len);
    try std.testing.expectEqualStrings("vendor", (try parse(&.{"sdk"})).sdk.output);
}

test "build accepts both paths and options on either side" {
    const options = (try parse(&.{ "build", "app with spaces", "--profile", "my output" })).build;
    try std.testing.expectEqual(cli.Mode.profile, options.mode);
    try std.testing.expectEqualStrings("app with spaces", options.input);
    try std.testing.expectEqualStrings("my output", options.output.?);
    const entry = (try parse(&.{ "run", "lib/custom.dart", "dist", "--release" })).run;
    try std.testing.expectEqual(cli.Mode.release, entry.build.mode);
    try std.testing.expectEqualStrings("lib/custom.dart", entry.build.input);
    try std.testing.expectEqualStrings("dist", entry.build.output.?);
    try std.testing.expect(!entry.vmServiceEnabled());
}

test "mode flags remain mutually exclusive including repeated flags" {
    for ([_][]const u8{ "build", "run" }) |name| {
        for ([_][]const u8{ "--debug", "--profile", "--release" }) |a| {
            for ([_][]const u8{ "--debug", "--profile", "--release" }) |b| {
                try reject(&.{ name, a, b }, if (std.mem.eql(u8, name, "run")) .run else .build, "at most one");
            }
        }
    }
}

test "command declarations reject irrelevant options" {
    try reject(&.{ "build", "--devtools" }, .build, "--devtools");
    try reject(&.{ "build", "--vm-service-port=10" }, .build, "--vm-service-port");
    try reject(&.{ "sdk", "--debug" }, .sdk, "--debug");
    try reject(&.{ "sdk", "--no-hot-reload" }, .sdk, "--no-hot-reload");
    try reject(&.{ "run", "-z" }, .run, "-z");
    try reject(&.{ "run", "--devtools=yes" }, .run, "does not take a value");
    try reject(&.{"unknown"}, .root, "unknown");
    try reject(&.{ "help", "doctor" }, .root, "doctor");
    try reject(&.{ "create", "app" }, .root, "create");
}

test "run option constraints retain meaningful errors" {
    try reject(&.{ "run", "--no-launch-browser" }, .run, "requires --devtools");
    try reject(&.{ "run", "--profile", "--no-hot-reload" }, .run, "only valid in debug");
    try reject(&.{ "run", "--release", "--devtools" }, .run, "release mode");
    try reject(&.{ "run", "--release", "--vm-service-port=0" }, .run, "release mode");
    const options = (try parse(&.{ "run", "--devtools", "--no-launch-browser", "--no-hot-reload" })).run;
    try std.testing.expect(options.devtools);
    try std.testing.expect(!options.hot_reload);
    try std.testing.expect(!options.launch_browser);
    try std.testing.expect(options.vmServiceEnabled());
    try std.testing.expect(!(try parse(&.{ "run", "--no-hot-reload" })).run.vmServiceEnabled());
}

test "port supports equals and space with an unsigned decimal u16 range" {
    const equals = (try parse(&.{ "run", "--vm-service-port=8181" })).run;
    const spaced = (try parse(&.{ "run", "--vm-service-port", "8181" })).run;
    try std.testing.expectEqual(@as(?u16, 8181), equals.vm_service_port);
    try std.testing.expectEqual(equals.vm_service_port, spaced.vm_service_port);
    try std.testing.expectEqual(@as(?u16, 0), (try parse(&.{ "run", "--vm-service-port=0" })).run.vm_service_port);
    try std.testing.expectEqual(@as(?u16, 65535), (try parse(&.{ "run", "--vm-service-port=65535" })).run.vm_service_port);
    for ([_][]const u8{ "", "70000", "-1", "abc", "0x10" }) |value|
        try reject(&.{ "run", "--vm-service-port", value }, .run, "decimal integer");
    try reject(&.{ "run", "--vm-service-port" }, .run, "requires a value");
    try reject(&.{ "run", "--vm-service-port", "--", "9" }, .run, "requires a value");
}

test "run separator preserves every application byte and argv boundary" {
    const input = [_][]const u8{ "run", "app", "--", "", "\xff\x80", "--help", "--release", "--", "a b", "--vm-service-port=999999" };
    const command = try parse(&input);
    try std.testing.expect(command == .run);
    try std.testing.expectEqual(cli.Mode.debug, command.run.build.mode);
    try std.testing.expectEqualSlices([]const u8, input[3..], command.run.application_args);
    try std.testing.expect(command.run.application_args.ptr == input[3..].ptr);
    try std.testing.expectEqual(@as(usize, 0), (try parse(&.{ "run", "--" })).run.application_args.len);
    try std.testing.expect((try parse(&.{ "run", "--", "--help" })) == .run);
}

test "build and sdk separator introduces option-shaped paths" {
    const build = (try parse(&.{ "build", "--", "--project", "-output" })).build;
    try std.testing.expectEqualStrings("--project", build.input);
    try std.testing.expectEqualStrings("-output", build.output.?);
    try std.testing.expectEqualStrings("--help", (try parse(&.{ "sdk", "--", "--help" })).sdk.output);
    try std.testing.expectEqual(cli.Mode.debug, (try parse(&.{ "build", "--" })).build.mode);
}

test "excess positional arguments cannot silently overwrite an earlier path" {
    try reject(&.{ "build", "a", "b", "c" }, .build, "at most");
    try reject(&.{ "run", "a", "b", "c", "--", "opaque" }, .run, "at most");
    try reject(&.{ "sdk", "a", "b" }, .sdk, "at most one");
    try reject(&.{ "help", "run", "extra" }, .root, "at most one");
}

test "help bypasses semantic validation but not malformed syntax" {
    try std.testing.expectEqual(cli.Topic.run, (try parse(&.{ "run", "--release", "--devtools", "--help" })).help);
    try reject(&.{ "run", "--help", "--unknown" }, .run, "--unknown");
}

test "help is rendered from the active command declarations only" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try cli.help(&writer, .run);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "--vm-service-port") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "application arguments") != null);
    writer = .fixed(&buffer);
    try cli.help(&writer, .sdk);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--devtools") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--debug") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Usage: fushell sdk") != null);
    writer = .fixed(&buffer);
    try cli.help(&writer, .root);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Build and run") != null);
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var diag: cli.Diagnostic = .{};
    const result = try cli.parse(gpa, &.{ "run", "app", "dist", "--devtools", "--", "hello" }, &diag);
    try std.testing.expectEqualStrings("app", result.run.build.input);
    try std.testing.expectEqualStrings("dist", result.run.build.output.?);
    try std.testing.expectEqualStrings("hello", result.run.application_args[0]);
}

test "parsed command values survive temporary clap cleanup and allocation failures" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
