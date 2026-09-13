const std = @import("std");
const c = @import("c");
const policy = @import("egl_presentation.zig");
const RenderContext = @import("wayland_egl_host.zig").RenderContext;
const DisplayState = @import("wl_display_state.zig").DisplayState;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Fake = struct {
    var trace: [128]u8 = undefined;
    var len: usize = 0;
    var minimum: c.EGLint = 0;
    var maximum: c.EGLint = 1;
    var query_fails: bool = false;
    var choose_fails: bool = false;
    var bind_fails: bool = false;
    var interval_fails: bool = false;
    var current: c.EGLSurface = null;
    const api: policy.Api = .{ .choose_config = choose, .get_config_attrib = attrib, .make_current = bind, .swap_interval = interval, .swap_buffers = swap };
    fn reset() void {
        len = 0;
        minimum = 0;
        maximum = 1;
        query_fails = false;
        choose_fails = false;
        bind_fails = false;
        interval_fails = false;
        current = @ptrFromInt(10);
    }
    fn record(event: u8) void {
        trace[len] = event;
        len += 1;
    }
    fn choose(_: c.EGLDisplay, attrs: [*c]const c.EGLint, configs: [*c]c.EGLConfig, size: c.EGLint, count: [*c]c.EGLint) callconv(.c) c.EGLBoolean {
        const expected = [_]c.EGLint{ c.EGL_SURFACE_TYPE, c.EGL_WINDOW_BIT | c.EGL_PBUFFER_BIT, c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT, c.EGL_RED_SIZE, 8, c.EGL_GREEN_SIZE, 8, c.EGL_BLUE_SIZE, 8, c.EGL_ALPHA_SIZE, 8, c.EGL_NONE };
        std.debug.assert(std.mem.eql(c.EGLint, &expected, attrs[0..expected.len]));
        record('C');
        if (choose_fails) return c.EGL_FALSE;
        count.* = 2;
        if (configs != null) {
            std.debug.assert(size == 2);
            configs[0] = @ptrFromInt(1);
            configs[1] = @ptrFromInt(2);
        }
        return c.EGL_TRUE;
    }
    fn attrib(_: c.EGLDisplay, config: c.EGLConfig, attr: c.EGLint, value: [*c]c.EGLint) callconv(.c) c.EGLBoolean {
        record(if (attr == c.EGL_MIN_SWAP_INTERVAL) 'm' else 'M');
        if (query_fails) return c.EGL_FALSE;
        value.* = if (attr == c.EGL_MIN_SWAP_INTERVAL) (if (@intFromPtr(config) == 1) 1 else minimum) else maximum;
        return c.EGL_TRUE;
    }
    fn bind(_: c.EGLDisplay, draw: c.EGLSurface, read: c.EGLSurface, context: c.EGLContext) callconv(.c) c.EGLBoolean {
        std.debug.assert(draw == read and @intFromPtr(context) == 20);
        record(if (@intFromPtr(draw) == 10) 'R' else @intCast(@intFromPtr(draw)));
        if (bind_fails) return c.EGL_FALSE;
        current = draw;
        return c.EGL_TRUE;
    }
    fn interval(_: c.EGLDisplay, value: c.EGLint) callconv(.c) c.EGLBoolean {
        std.debug.assert(value == 0 and @intFromPtr(current) != 10);
        record('I');
        return if (interval_fails) c.EGL_FALSE else c.EGL_TRUE;
    }
    fn swap(_: c.EGLDisplay, surface: c.EGLSurface) callconv(.c) c.EGLBoolean {
        std.debug.assert(current == surface and trace[len - 1] == 'I');
        record('S');
        return c.EGL_TRUE;
    }
    fn events(expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, trace[0..len]);
    }
};

// Exercise the actual RenderContext methods, not a duplicate bind/interval policy.
fn present(context: *RenderContext, surface: c.EGLSurface) !void {
    try context.makeSurfaceCurrent(surface);
    defer context.makeCurrent() catch unreachable;
    try context.swapBuffers(surface);
}

test "production EGL config skips interval-one first choice for zero-capable alternative" {
    Fake.reset();
    const config = try policy.chooseConfig(Fake.api, std.testing.allocator, null);
    try expectEqual(@as(usize, 2), @intFromPtr(config));
    try Fake.events("CCmMmM");
}

test "production EGL config fails closed on clamping bounds and query failures" {
    Fake.reset();
    Fake.minimum = 1;
    try std.testing.expectError(error.EglZeroSwapIntervalUnavailable, policy.chooseConfig(Fake.api, std.testing.allocator, null));
    Fake.reset();
    Fake.maximum = -1;
    try std.testing.expectError(error.EglZeroSwapIntervalUnavailable, policy.chooseConfig(Fake.api, std.testing.allocator, null));
    Fake.reset();
    Fake.query_fails = true;
    try std.testing.expectError(error.EglConfigIntervalQueryFailed, policy.chooseConfig(Fake.api, std.testing.allocator, null));
    Fake.reset();
    Fake.choose_fails = true;
    try std.testing.expectError(error.EglChooseConfigFailed, policy.chooseConfig(Fake.api, std.testing.allocator, null));
}

test "RenderContext binds interval swaps restores for A B and recreated A" {
    Fake.reset();
    var state: DisplayState = .{};
    var context: RenderContext = .{ .display_state = &state, .egl = Fake.api, .egl_context = @ptrFromInt(20), .bootstrap_surface = @ptrFromInt(10) };
    for ([_]usize{ 'A', 'B', 'A', 'C' }) |surface| try present(&context, @ptrFromInt(surface));
    try Fake.events("AISRBISRAISRCISR");
    try expectEqual(@as(usize, 10), @intFromPtr(Fake.current));
}

test "RenderContext bind failure does not set interval or swap" {
    Fake.reset();
    var state: DisplayState = .{};
    var context: RenderContext = .{ .display_state = &state, .egl = Fake.api, .egl_context = @ptrFromInt(20), .bootstrap_surface = @ptrFromInt(10) };
    Fake.bind_fails = true;
    try std.testing.expectError(error.EglWindowBindFailed, present(&context, @ptrFromInt('A')));
    try Fake.events("A");
    try expectEqual(@as(usize, 10), @intFromPtr(Fake.current));
}

test "RenderContext interval failure restores bootstrap before returning without swap" {
    Fake.reset();
    var state: DisplayState = .{};
    var context: RenderContext = .{ .display_state = &state, .egl = Fake.api, .egl_context = @ptrFromInt(20), .bootstrap_surface = @ptrFromInt(10) };
    Fake.interval_fails = true;
    try std.testing.expectError(error.EglSwapIntervalFailed, present(&context, @ptrFromInt('B')));
    try Fake.events("BIR");
    try expectEqual(@as(usize, 10), @intFromPtr(Fake.current));
    Fake.interval_fails = false;
    try present(&context, @ptrFromInt('A'));
    try Fake.events("BIRAISR");
    try expect(context.resource_context == null);
}
