//! Bounds checks run before sending xdg_positioner requests.
const std = @import("std");

pub fn anchorFitsParent(x: i32, y: i32, width: i32, height: i32, parent_width: i32, parent_height: i32) bool {
    if (x < 0 or y < 0 or width <= 0 or height <= 0) return false;
    return @as(i64, x) + width <= parent_width and @as(i64, y) + height <= parent_height;
}

pub fn requireReactive(version: u32, reactive: bool) !void {
    if (reactive and version < 3) return error.PopupReactiveUnsupported;
}

pub fn requireReposition(version: u32) !void {
    if (version < 3) return error.PopupRepositionUnsupported;
}

test "version three gates dynamic positioning but not static tooltips" {
    for ([_]u32{ 1, 2 }) |version| {
        try requireReactive(version, false);
        try std.testing.expectError(error.PopupReactiveUnsupported, requireReactive(version, true));
        try std.testing.expectError(error.PopupRepositionUnsupported, requireReposition(version));
    }
    for ([_]u32{ 3, 5 }) |version| {
        try requireReactive(version, true);
        try requireReposition(version);
    }
}

test "anchor bounds include edges without signed overflow" {
    try std.testing.expect(anchorFitsParent(0, 0, 100, 50, 100, 50));
    try std.testing.expect(anchorFitsParent(99, 49, 1, 1, 100, 50));
    try std.testing.expect(!anchorFitsParent(-1, 0, 1, 1, 100, 50));
    try std.testing.expect(!anchorFitsParent(0, 0, 0, 1, 100, 50));
    try std.testing.expect(!anchorFitsParent(99, 49, 2, 1, 100, 50));
    try std.testing.expect(!anchorFitsParent(99, 49, 1, 2, 100, 50));
    try std.testing.expect(!anchorFitsParent(std.math.maxInt(i32), 0, std.math.maxInt(i32), 1, std.math.maxInt(i32), 1));
}
