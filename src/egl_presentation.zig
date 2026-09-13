//! EGL policy shared by native presentation and injectable headless tests.
const std = @import("std");
const c = @import("c");

pub const Api = struct {
    choose_config: @TypeOf(&c.eglChooseConfig) = &c.eglChooseConfig,
    get_config_attrib: @TypeOf(&c.eglGetConfigAttrib) = &c.eglGetConfigAttrib,
    make_current: @TypeOf(&c.eglMakeCurrent) = &c.eglMakeCurrent,
    swap_interval: @TypeOf(&c.eglSwapInterval) = &c.eglSwapInterval,
    swap_buffers: @TypeOf(&c.eglSwapBuffers) = &c.eglSwapBuffers,
};

pub fn chooseConfig(api: Api, allocator: std.mem.Allocator, display: c.EGLDisplay) !c.EGLConfig {
    const attributes = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT | c.EGL_PBUFFER_BIT,
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_NONE,
    };
    var count: c.EGLint = 0;
    if (api.choose_config(display, &attributes, null, 0, &count) != c.EGL_TRUE) return error.EglChooseConfigFailed;
    if (count <= 0) return error.OpenGles3Unavailable;
    const configs = try allocator.alloc(c.EGLConfig, @intCast(count));
    defer allocator.free(configs);
    if (api.choose_config(display, &attributes, configs.ptr, count, &count) != c.EGL_TRUE) return error.EglChooseConfigFailed;
    if (count < 0 or count > configs.len) return error.EglChooseConfigFailed;
    for (configs[0..@intCast(count)]) |config| {
        var minimum: c.EGLint = 0;
        var maximum: c.EGLint = 0;
        if (api.get_config_attrib(display, config, c.EGL_MIN_SWAP_INTERVAL, &minimum) != c.EGL_TRUE or
            api.get_config_attrib(display, config, c.EGL_MAX_SWAP_INTERVAL, &maximum) != c.EGL_TRUE) return error.EglConfigIntervalQueryFailed;
        // eglSwapInterval may succeed while silently clamping: query both bounds.
        if (minimum <= 0 and maximum >= 0) return config;
    }
    return error.EglZeroSwapIntervalUnavailable;
}

pub fn bindWindow(api: Api, display: c.EGLDisplay, context: c.EGLContext, bootstrap: c.EGLSurface, surface: c.EGLSurface) !void {
    if (surface == c.EGL_NO_SURFACE) return error.EglInvalidSurface;
    if (api.make_current(display, surface, surface, context) != c.EGL_TRUE) return error.EglWindowBindFailed;
    // Called on the raster thread for EVERY window bind, including recreated
    // surfaces. This removes Wayland frame-callback pacing, not GPU/buffer waits.
    // Software frame_clock remains the pacing source; resource context is untouched.
    if (api.swap_interval(display, 0) != c.EGL_TRUE) {
        // The caller's normal bootstrap defer is not installed until we succeed.
        // Never unlock the host with a failed post-bind operation still attached.
        if (api.make_current(display, bootstrap, bootstrap, context) != c.EGL_TRUE)
            std.debug.panic("Cannot release view drawable after swap interval failure", .{});
        return error.EglSwapIntervalFailed;
    }
}
