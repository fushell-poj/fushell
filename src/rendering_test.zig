//! Native rendering and window-lifecycle regression suite; no display required.
test {
    _ = @import("flutter_runner.zig");
    _ = @import("window_registry.zig");
    _ = @import("wayland_egl_host.zig");
    _ = @import("window_geometry_test.zig");
    _ = @import("popup_geometry.zig");
    _ = @import("input_provenance.zig");
    _ = @import("pointer_buttons.zig");
}

test "host loads Fontconfig before the dynamic Flutter engine" {
    const std = @import("std");
    const c = std.c;
    // Inspect existing process dependencies; loading Fontconfig here would hide
    // a missing DT_NEEDED entry and the resulting standalone startup failure.
    const process = c.dlopen(null, .{ .NOW = true }) orelse return error.ProcessSymbolsUnavailable;
    defer _ = c.dlclose(process);
    try std.testing.expect(c.dlsym(process, "FcFontMatch") != null);
}
