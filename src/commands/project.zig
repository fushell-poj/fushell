//! Resolve build paths at execution time, after syntax validation has succeeded.
const std = @import("std");
const cli = @import("cli");

/// Paths borrow input argv or storage from the caller's arena.
/// Run-only switches are intentionally absent from the build plan.
pub const Plan = struct {
    mode: cli.Mode,
    entrypoint: []const u8,
    bundle_dir: []const u8,
};

/// Keep the established path semantics: a directory selects cwd, otherwise the
/// input is a Dart entrypoint. Relative output paths belong to the chosen cwd.
pub fn prepare(init: std.process.Init, options: cli.build.Options) !Plan {
    const io = init.io;
    const is_directory = blk: {
        var dir = std.Io.Dir.cwd().openDir(io, options.input, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => break :blk false,
            else => return err,
        };
        dir.close(io);
        break :blk true;
    };
    if (is_directory) {
        try std.Io.Threaded.chdir(options.input);
        std.debug.print("working directory: {s}\n", .{options.input});
    }
    return .{
        .mode = options.mode,
        .entrypoint = if (is_directory) "lib/main.dart" else options.input,
        .bundle_dir = options.output orelse try std.fmt.allocPrint(
            init.arena.allocator(),
            "build/linux/{s}/{s}",
            .{ @import("build_options").flutter_arch, @tagName(options.mode) },
        ),
    };
}
