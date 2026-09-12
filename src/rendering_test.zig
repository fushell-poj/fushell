//! Native rendering and window-lifecycle regression suite; no display required.
test {
    _ = @import("flutter_runner.zig");
    _ = @import("window_registry.zig");
    _ = @import("wayland_egl_host.zig");
    _ = @import("window_geometry_test.zig");
}
