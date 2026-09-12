//! Native diagnostics only: CLI/protocol output and unclassified Flutter/Dart
//! callback text must not be routed through this severity filter.
const std = @import("std");
const builtin = @import("builtin");

/// Keep all diagnostics in Debug; compile out info/debug in every Release mode.
/// Warnings and errors remain visible, using the standard scoped stderr sink.
pub const options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .warn,
};
