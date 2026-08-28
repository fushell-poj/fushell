const std = @import("std");

pub const Command = enum {
    help,
    build,
    run,
    sdk,
};

pub const Mode = enum {
    debug,
    profile,
    release,
};

pub const Options = struct {
    command: Command = .help,
    help: bool = false,
    mode: Mode = .debug,
    positionals: [2][]const u8 = .{ "", "" },
    positional_count: u8 = 0,
    hot_reload: bool = true,
    devtools: bool = false,
    launch_browser: bool = true,
    vm_service_port: ?u16 = null,
    /// Opaque application argv after `--`; parsed only by the Dart application.
    application_args: []const [:0]const u8 = &.{},

    pub fn positional(self: Options, index: usize) ?[]const u8 {
        return if (index < self.positional_count) self.positionals[index] else null;
    }

    pub fn vmServiceEnabled(self: Options) bool {
        return self.command == .run and
            ((self.mode == .debug and self.hot_reload) or self.devtools or self.vm_service_port != null);
    }
};

pub fn parse(args: []const [:0]const u8) !Options {
    if (args.len == 0) return .{};

    var options: Options = .{};
    options.command = if (std.mem.eql(u8, args[0], "build"))
        .build
    else if (std.mem.eql(u8, args[0], "run"))
        .run
    else if (std.mem.eql(u8, args[0], "sdk"))
        .sdk
    else if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))
        .help
    else
        return error.UnknownCommand;

    if (options.command == .help) {
        if (args.len != 1) return error.UnexpectedArgument;
        return options;
    }

    var mode_seen = false;
    var positional_only = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            if (options.command == .run) {
                options.application_args = args[index + 1 ..];
                break;
            }
            positional_only = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            options.help = true;
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "--release")) {
                if (mode_seen) return error.ConflictingModes;
                mode_seen = true;
                options.mode = if (std.mem.eql(u8, arg, "--debug")) .debug else if (std.mem.eql(u8, arg, "--profile")) .profile else .release;
            } else if (std.mem.eql(u8, arg, "--devtools")) {
                options.devtools = true;
            } else if (std.mem.eql(u8, arg, "--no-launch-browser")) {
                options.launch_browser = false;
            } else if (std.mem.eql(u8, arg, "--no-hot-reload")) {
                options.hot_reload = false;
            } else if (std.mem.startsWith(u8, arg, "--vm-service-port=")) {
                const value = arg["--vm-service-port=".len..];
                if (value.len == 0) return error.InvalidVmServicePort;
                options.vm_service_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidVmServicePort;
            } else {
                return error.UnknownOption;
            }
            continue;
        }

        if (options.positional_count >= options.positionals.len) return error.TooManyArguments;
        options.positionals[options.positional_count] = arg;
        options.positional_count += 1;
    }

    if (options.help) return options;
    try validate(options, mode_seen);
    return options;
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownCommand => "unknown command (expected build, run, sdk, or help)",
        error.UnexpectedArgument => "the help command does not accept arguments",
        error.ConflictingModes => "choose exactly one of --debug, --profile, or --release",
        error.UnknownOption => "unknown option",
        error.TooManyArguments => "too many positional arguments",
        error.InvalidVmServicePort => "--vm-service-port must be an integer from 0 to 65535",
        error.RunOptionRequiresRunCommand => "DevTools and VM Service options are only valid for fushell run",
        error.NoLaunchBrowserRequiresDevTools => "--no-launch-browser requires --devtools",
        error.NoHotReloadRequiresDebug => "--no-hot-reload is only valid with --debug",
        error.ReleaseDoesNotSupportVmService => "--release does not support DevTools or VM Service",
        error.OptionNotSupportedBySdk => "fushell sdk does not accept build or run options",
        else => @errorName(err),
    };
}

fn validate(options: Options, mode_seen: bool) !void {
    switch (options.command) {
        .build => {
            if (options.devtools or !options.launch_browser or !options.hot_reload or options.vm_service_port != null) {
                return error.RunOptionRequiresRunCommand;
            }
        },
        .run => {
            if (!options.launch_browser and !options.devtools) return error.NoLaunchBrowserRequiresDevTools;
            if (!options.hot_reload and options.mode != .debug) return error.NoHotReloadRequiresDebug;
            if (options.mode == .release and (options.devtools or options.vm_service_port != null)) {
                return error.ReleaseDoesNotSupportVmService;
            }
        },
        .sdk => {
            if (options.positional_count > 1) return error.TooManyArguments;
            if (mode_seen or options.devtools or !options.launch_browser or !options.hot_reload or options.vm_service_port != null) {
                return error.OptionNotSupportedBySdk;
            }
        },
        .help => unreachable,
    }
}

fn argv(comptime values: []const []const u8) [values.len][:0]const u8 {
    var result: [values.len][:0]const u8 = undefined;
    inline for (values, 0..) |value, index| result[index] = value;
    return result;
}

test "bare invocation shows help" {
    const args = argv(&.{});
    const options = try parse(&args);
    try std.testing.expectEqual(Command.help, options.command);
}

test "dispatches build run and sdk commands" {
    const build_args = argv(&.{ "build", "--profile", "app", "out" });
    const build_options = try parse(&build_args);
    try std.testing.expectEqual(Command.build, build_options.command);
    try std.testing.expectEqual(Mode.profile, build_options.mode);
    try std.testing.expectEqualStrings("app", build_options.positional(0).?);
    try std.testing.expectEqualStrings("out", build_options.positional(1).?);

    const run_args = argv(&.{ "run", "--debug", "--devtools", "--no-launch-browser", "--vm-service-port=8181", "app" });
    const run_options = try parse(&run_args);
    try std.testing.expectEqual(Command.run, run_options.command);
    try std.testing.expect(run_options.devtools);
    try std.testing.expect(!run_options.launch_browser);
    try std.testing.expectEqual(@as(?u16, 8181), run_options.vm_service_port);
    try std.testing.expect(run_options.vmServiceEnabled());

    const sdk_args = argv(&.{ "sdk", "dist" });
    const sdk_options = try parse(&sdk_args);
    try std.testing.expectEqual(Command.sdk, sdk_options.command);
    try std.testing.expectEqualStrings("dist", sdk_options.positional(0).?);
}

test "rejects old implicit build and unknown commands" {
    const implicit = argv(&.{"./app"});
    try std.testing.expectError(error.UnknownCommand, parse(&implicit));

    const unknown = argv(&.{"wat"});
    try std.testing.expectError(error.UnknownCommand, parse(&unknown));
}

test "rejects conflicting modes and misplaced run options" {
    const conflicting = argv(&.{ "run", "--debug", "--profile" });
    try std.testing.expectError(error.ConflictingModes, parse(&conflicting));

    const build_devtools = argv(&.{ "build", "--devtools" });
    try std.testing.expectError(error.RunOptionRequiresRunCommand, parse(&build_devtools));

    const browser_without_devtools = argv(&.{ "run", "--no-launch-browser" });
    try std.testing.expectError(error.NoLaunchBrowserRequiresDevTools, parse(&browser_without_devtools));

    const sdk_mode = argv(&.{ "sdk", "--debug" });
    try std.testing.expectError(error.OptionNotSupportedBySdk, parse(&sdk_mode));
}

test "run forwards opaque application arguments after separator" {
    const args = argv(&.{
        "run",
        "--debug",
        "./app",
        "--",
        "open",
        "window",
        "--application-owned",
    });
    const options = try parse(&args);
    try std.testing.expectEqualStrings("./app", options.positional(0).?);
    try std.testing.expectEqual(@as(usize, 3), options.application_args.len);
    try std.testing.expectEqualStrings("open", options.application_args[0]);
    try std.testing.expectEqualStrings("window", options.application_args[1]);
    try std.testing.expectEqualStrings("--application-owned", options.application_args[2]);
}

test "enforces mode-specific VM service rules" {
    const profile_no_reload = argv(&.{ "run", "--profile", "--no-hot-reload" });
    try std.testing.expectError(error.NoHotReloadRequiresDebug, parse(&profile_no_reload));

    const release_devtools = argv(&.{ "run", "--release", "--devtools" });
    try std.testing.expectError(error.ReleaseDoesNotSupportVmService, parse(&release_devtools));

    const bad_port = argv(&.{ "run", "--vm-service-port=70000" });
    try std.testing.expectError(error.InvalidVmServicePort, parse(&bad_port));
}
