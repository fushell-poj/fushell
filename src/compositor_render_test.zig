//! Standalone real-GLES regression executable. Run with EGL_PLATFORM=surfaceless
//! and LIBGL_ALWAYS_SOFTWARE=1; needs only the c module, EGL, GLESv2 and libc.
const std = @import("std");
const c = @import("c");
const compositor = @import("flutter_compositor.zig");
const gl = @import("gl_state.zig");
const Blitter = @import("gl_blit.zig").Blitter;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

pub fn main() !void {
    const display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
    if (display == c.EGL_NO_DISPLAY) return error.NoEGLDisplay;
    if (c.eglInitialize(display, null, null) != c.EGL_TRUE) return error.EGLInitializeFailed;
    defer _ = c.eglTerminate(display);
    if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE) return error.EGLBindAPIFailed;
    const attributes = [_]c.EGLint{
        c.EGL_SURFACE_TYPE, c.EGL_PBUFFER_BIT,
        c.EGL_RENDERABLE_TYPE, 0x0040, // EGL_OPENGL_ES3_BIT
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_NONE,
    };
    var config: c.EGLConfig = null;
    var count: c.EGLint = 0;
    if (c.eglChooseConfig(display, &attributes, &config, 1, &count) != c.EGL_TRUE or count != 1) return error.NoRGBA8ES3Config;
    const surface_attributes = [_]c.EGLint{ c.EGL_WIDTH, 8, c.EGL_HEIGHT, 8, c.EGL_NONE };
    const surface = c.eglCreatePbufferSurface(display, config, &surface_attributes);
    if (surface == c.EGL_NO_SURFACE) return error.EGLSurfaceFailed;
    defer _ = c.eglDestroySurface(display, surface);
    const context_attributes = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 3, c.EGL_NONE };
    const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, &context_attributes);
    if (context == c.EGL_NO_CONTEXT) return error.EGLContextFailed;
    defer _ = c.eglDestroyContext(display, context);
    if (c.eglMakeCurrent(display, surface, surface, context) != c.EGL_TRUE) return error.EGLMakeCurrentFailed;
    defer _ = c.eglMakeCurrent(display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
    for (0..8) |_| try runLifecycle();
    std.debug.print("GLES3 compositor pbuffer regression: 8 lifecycle rounds passed\n", .{});
}

fn runLifecycle() !void {
    var caller_vao: c.GLuint = 0;
    var caller_vbo: c.GLuint = 0;
    var unpack: c.GLuint = 0;
    var sampler: c.GLuint = 0;
    var textures: [2]c.GLuint = undefined;
    var framebuffers: [2]c.GLuint = undefined;
    c.glGenVertexArrays(1, &caller_vao);
    defer c.glDeleteVertexArrays(1, &caller_vao);
    c.glGenBuffers(1, &caller_vbo);
    defer c.glDeleteBuffers(1, &caller_vbo);
    c.glGenBuffers(1, &unpack);
    defer c.glDeleteBuffers(1, &unpack);
    c.glGenSamplers(1, &sampler);
    defer c.glDeleteSamplers(1, &sampler);
    c.glGenTextures(2, &textures);
    defer c.glDeleteTextures(2, &textures);
    c.glGenFramebuffers(2, &framebuffers);
    defer c.glDeleteFramebuffers(2, &framebuffers);
    c.glBindVertexArray(caller_vao);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, caller_vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, 128, null, c.GL_STATIC_DRAW);
    c.glEnableVertexAttribArray(0);
    c.glDisableVertexAttribArray(1);
    c.glVertexAttribPointer(0, 3, c.GL_FLOAT, c.GL_TRUE, 24, @ptrFromInt(4));
    c.glVertexAttribPointer(1, 2, c.GL_SHORT, c.GL_FALSE, 12, @ptrFromInt(8));
    c.glVertexAttribDivisor(0, 3);
    c.glBindBuffer(c.GL_PIXEL_UNPACK_BUFFER, unpack);
    c.glBufferData(c.GL_PIXEL_UNPACK_BUFFER, 1, null, c.GL_STATIC_DRAW);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, textures[0]);
    c.glBindSampler(0, sampler);
    c.glSamplerParameteri(sampler, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST_MIPMAP_NEAREST);
    c.glActiveTexture(c.GL_TEXTURE3);
    c.glBindTexture(c.GL_TEXTURE_2D, textures[1]);
    c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, framebuffers[0]);
    c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, framebuffers[1]);
    c.glViewport(2, 3, 5, 6);
    c.glClearColor(0.25, 0.5, 0.75, 1);
    c.glColorMask(c.GL_FALSE, c.GL_TRUE, c.GL_FALSE, c.GL_FALSE);
    for (gl.capabilities) |cap| c.glEnable(cap);
    if (gl.integer(c.GL_MINOR_VERSION) >= 1) c.glEnable(gl.State.sample_mask_capability);
    c.glScissor(7, 7, 1, 1);
    c.glCullFace(c.GL_FRONT_AND_BACK);
    c.glDepthFunc(c.GL_NEVER);
    c.glStencilFunc(c.GL_NEVER, 0, 0);
    c.glSampleCoverage(0, c.GL_FALSE);
    c.glBlendFuncSeparate(c.GL_DST_COLOR, c.GL_SRC_COLOR, c.GL_ZERO, c.GL_ONE);
    c.glBlendEquationSeparate(c.GL_FUNC_REVERSE_SUBTRACT, c.GL_FUNC_SUBTRACT);
    try gl.check();

    // A second independently owned program seeds a real nonzero caller program.
    var caller_program: Blitter = .{};
    try caller_program.init();
    defer caller_program.deinit();
    c.glUseProgram(caller_program.program);
    defer c.glUseProgram(0);
    const before = gl.State.capture();
    const attribs = captureAttributes();
    var blitter: Blitter = .{};
    defer blitter.deinit();
    try blitter.init();
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);

    var config = std.mem.zeroes(c.FlutterBackingStoreConfig);
    config.struct_size = @sizeOf(c.FlutterBackingStoreConfig);
    config.size = .{ .width = 1, .height = 1 };
    var red = std.mem.zeroes(c.FlutterBackingStore);
    var blue = std.mem.zeroes(c.FlutterBackingStore);
    try compositor.createBackingStore(&config, &red);
    errdefer compositor.collectBackingStore(&red) catch {};
    try compositor.createBackingStore(&config, &blue);
    errdefer compositor.collectBackingStore(&blue) catch {};
    try expectEqual(@as(u32, c.GL_RGBA8), red.unnamed_0.open_gl.unnamed_0.texture.format);
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);
    try upload(red, .{ 128, 0, 0, 128 });
    try upload(blue, .{ 0, 0, 128, 128 });

    var untouched = std.mem.zeroes(c.FlutterBackingStore);
    untouched.struct_size = 42;
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64), 1e30 }) |bad| {
        config.size.width = bad;
        if (compositor.createBackingStore(&config, &untouched)) |_| return error.AcceptedInvalidSize else |_| {}
        try expectEqual(@as(usize, 42), untouched.struct_size);
    }
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);

    var info = std.mem.zeroes(c.FlutterPresentViewInfo);
    info.struct_size = @sizeOf(c.FlutterPresentViewInfo);
    try compositor.presentFrame(&blitter, &info, 8, 8);
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);
    try pixel(4, 4, .{ 0, 0, 0, 0 });

    var red_layer = layer(&red, 0, 0, 4, 4);
    var blue_layer = layer(&blue, 0, 0, 4, 4);
    var layers = [_][*c]const c.FlutterLayer{ &red_layer, &blue_layer };
    info.layers = &layers;
    info.layers_count = 1;
    try compositor.presentFrame(&blitter, &info, 8, 8);
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);
    try pixel(1, 6, .{ 128, 0, 0, 128 });
    try pixel(6, 1, .{ 0, 0, 0, 0 });
    info.layers_count = 2;
    try compositor.presentFrame(&blitter, &info, 8, 8);
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);
    try pixel(1, 6, .{ 64, 0, 128, 192 });
    try pixel(6, 1, .{ 0, 0, 0, 0 });

    // Exercise the error path after the transaction has changed GL state.
    blue_layer.type = c.kFlutterLayerContentTypePlatformView;
    try std.testing.expectError(error.UnsupportedLayer, compositor.presentFrame(&blitter, &info, 8, 8));
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);
    blue_layer.type = c.kFlutterLayerContentTypeBackingStore;
    blue.unnamed_0.open_gl.type = c.kFlutterOpenGLTargetTypeFramebuffer;
    try std.testing.expectError(error.UnsupportedOpenGLTarget, compositor.presentFrame(&blitter, &info, 8, 8));
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);
    blue.unnamed_0.open_gl.type = c.kFlutterOpenGLTargetTypeTexture;
    info.layers_count = 0;
    try compositor.presentFrame(&blitter, &info, 8, 8);
    try pixel(1, 6, .{ 0, 0, 0, 0 });
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);

    try textureOriginRegression(&blitter);
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);
    try defaultDrawBufferRegression(&red, &blue);

    const red_name = red.unnamed_0.open_gl.unnamed_0.texture.name;
    const blue_name = blue.unnamed_0.open_gl.unnamed_0.texture.name;
    // Engine release notification must not delete collection-owned names.
    red.unnamed_0.open_gl.unnamed_0.texture.destruction_callback.?(null);
    try expect(c.glIsTexture(red_name) == c.GL_TRUE);
    try compositor.collectBackingStore(&red);
    try compositor.collectBackingStore(&blue);
    try expect(c.glIsTexture(red_name) == c.GL_FALSE);
    try expect(c.glIsTexture(blue_name) == c.GL_FALSE);
    const program = blitter.program;
    const vao = blitter.vao;
    const vbo = blitter.vbo;
    blitter.deinit();
    blitter.deinit();
    try expect(c.glIsProgram(program) == c.GL_FALSE);
    try expect(c.glIsVertexArray(vao) == c.GL_FALSE);
    try expect(c.glIsBuffer(vbo) == c.GL_FALSE);
    try unchanged(before, attribs, framebuffers[1], textures[1], unpack);
    try gl.check();
}

fn textureOriginRegression(blitter: *Blitter) !void {
    var config = std.mem.zeroes(c.FlutterBackingStoreConfig);
    config.struct_size = @sizeOf(c.FlutterBackingStoreConfig);
    config.size = .{ .width = 2, .height = 2 };
    var store = std.mem.zeroes(c.FlutterBackingStore);
    try compositor.createBackingStore(&config, &store);
    defer compositor.collectBackingStore(&store) catch @panic("texture collection failed");
    {
        const previous_texture = gl.integer(c.GL_TEXTURE_BINDING_2D);
        const previous_unpack = gl.integer(c.GL_PIXEL_UNPACK_BUFFER_BINDING);
        defer c.glBindTexture(c.GL_TEXTURE_2D, @intCast(previous_texture));
        defer c.glBindBuffer(c.GL_PIXEL_UNPACK_BUFFER, @intCast(previous_unpack));
        c.glBindBuffer(c.GL_PIXEL_UNPACK_BUFFER, 0);
        c.glBindTexture(c.GL_TEXTURE_2D, store.unnamed_0.open_gl.unnamed_0.texture.name);
        // GL upload rows start at the texture's bottom. Flutter Skia backing
        // stores use that bottom-left origin: bottom blue/green, top red/yellow.
        const colors = [_][4]u8{
            .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 255 },
            .{ 255, 0, 0, 255 }, .{ 255, 255, 0, 255 },
        };
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 2, 2, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &colors);
        try gl.check();
    }
    var colored_layer = layer(&store, 2, 1, 4, 4);
    var layers = [_][*c]const c.FlutterLayer{&colored_layer};
    var info = std.mem.zeroes(c.FlutterPresentViewInfo);
    info.struct_size = @sizeOf(c.FlutterPresentViewInfo);
    info.layers = &layers;
    info.layers_count = 1;
    try compositor.presentFrame(blitter, &info, 8, 8);
    // The layer's screen top-left is (2,1). ReadPixels instead counts from
    // the bottom: its top row is y=6 and its bottom row is y=3 in an 8px view.
    try pixel(2, 6, .{ 255, 0, 0, 255 }); // screen top-left: red
    try pixel(5, 6, .{ 255, 255, 0, 255 }); // screen top-right: yellow
    try pixel(2, 3, .{ 0, 0, 255, 255 }); // screen bottom-left: blue
    try pixel(5, 3, .{ 0, 255, 0, 255 }); // screen bottom-right: green
    try pixel(1, 6, .{ 0, 0, 0, 0 }); // outside the nonzero horizontal offset
    try pixel(2, 7, .{ 0, 0, 0, 0 }); // above the nonzero vertical offset
    try pixel(2, 2, .{ 0, 0, 0, 0 }); // below the layer
}

fn defaultDrawBufferRegression(red: *const c.FlutterBackingStore, blue: *const c.FlutterBackingStore) !void {
    const original_draw = gl.integer(c.GL_DRAW_FRAMEBUFFER_BINDING);
    const original_read = gl.integer(c.GL_READ_FRAMEBUFFER_BINDING);
    c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
    const original_selection: c.GLenum = @intCast(gl.integer(c.GL_DRAW_BUFFER0));
    defer {
        c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
        c.glDrawBuffers(1, &original_selection);
        c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, @intCast(original_draw));
    }
    const none: c.GLenum = c.GL_NONE;
    c.glDrawBuffers(1, &none);
    var red_layer = layer(red, 0, 0, 4, 4);
    var blue_layer = layer(blue, 0, 0, 4, 4);
    var layers = [_][*c]const c.FlutterLayer{ &red_layer, &blue_layer };
    var info = std.mem.zeroes(c.FlutterPresentViewInfo);
    info.struct_size = @sizeOf(c.FlutterPresentViewInfo);
    info.layers = &layers;
    // First use also tests lazy initialization under the hostile selection.
    for ([_]c.GLint{ original_draw, 0 }) |incoming_draw| {
        c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, @intCast(incoming_draw));
        const before = gl.State.capture();
        var blitter: Blitter = .{};
        defer blitter.deinit();
        info.layers_count = 2;
        try compositor.presentFrame(&blitter, &info, 8, 8);
        try expect(std.meta.eql(before, gl.State.capture()));
        try expectDefaultDrawNone(incoming_draw);
        try pixel(1, 6, .{ 64, 0, 128, 192 });
        try pixel(6, 1, .{ 0, 0, 0, 0 });
        blue_layer.type = c.kFlutterLayerContentTypePlatformView;
        try std.testing.expectError(error.UnsupportedLayer, compositor.presentFrame(&blitter, &info, 8, 8));
        try expect(std.meta.eql(before, gl.State.capture()));
        try expectDefaultDrawNone(incoming_draw);
        blue_layer.type = c.kFlutterLayerContentTypeBackingStore;
        info.layers_count = 0;
        try compositor.presentFrame(&blitter, &info, 8, 8);
        try pixel(1, 6, .{ 0, 0, 0, 0 });
        try expect(std.meta.eql(before, gl.State.capture()));
        try expectDefaultDrawNone(incoming_draw);
        try expectEqual(original_read, gl.integer(c.GL_READ_FRAMEBUFFER_BINDING));
        try gl.check();
    }
}

fn expectDefaultDrawNone(incoming_draw: c.GLint) !void {
    try expectEqual(incoming_draw, gl.integer(c.GL_DRAW_FRAMEBUFFER_BINDING));
    c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
    defer c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, @intCast(incoming_draw));
    try expectEqual(@as(c.GLint, c.GL_NONE), gl.integer(c.GL_DRAW_BUFFER0));
}

fn layer(store: *const c.FlutterBackingStore, x: f64, y: f64, width: f64, height: f64) c.FlutterLayer {
    var result = std.mem.zeroes(c.FlutterLayer);
    result.struct_size = @sizeOf(c.FlutterLayer);
    result.type = c.kFlutterLayerContentTypeBackingStore;
    result.unnamed_0.backing_store = store;
    result.offset = .{ .x = x, .y = y };
    result.size = .{ .width = width, .height = height };
    return result;
}

fn upload(store: c.FlutterBackingStore, rgba: [4]u8) !void {
    const texture = gl.integer(c.GL_TEXTURE_BINDING_2D);
    const unpack = gl.integer(c.GL_PIXEL_UNPACK_BUFFER_BINDING);
    defer c.glBindTexture(c.GL_TEXTURE_2D, @intCast(texture));
    defer c.glBindBuffer(c.GL_PIXEL_UNPACK_BUFFER, @intCast(unpack));
    c.glBindBuffer(c.GL_PIXEL_UNPACK_BUFFER, 0);
    c.glBindTexture(c.GL_TEXTURE_2D, store.unnamed_0.open_gl.unnamed_0.texture.name);
    c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 1, 1, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &rgba);
    try gl.check();
}

fn pixel(x: c.GLint, y: c.GLint, expected: [4]u8) !void {
    const read = gl.integer(c.GL_READ_FRAMEBUFFER_BINDING);
    defer c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, @intCast(read));
    c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, 0);
    var rgba: [4]u8 = undefined;
    c.glReadPixels(x, y, 1, 1, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &rgba);
    try gl.check();
    for (rgba, expected) |actual, wanted| try expect(@abs(@as(i32, actual) - @as(i32, wanted)) <= 1);
}

const attrib_parameters = [_]c.GLenum{ c.GL_VERTEX_ATTRIB_ARRAY_ENABLED, c.GL_VERTEX_ATTRIB_ARRAY_SIZE, c.GL_VERTEX_ATTRIB_ARRAY_STRIDE, c.GL_VERTEX_ATTRIB_ARRAY_TYPE, c.GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, c.GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, c.GL_VERTEX_ATTRIB_ARRAY_DIVISOR };
const Attributes = struct { values: [2][attrib_parameters.len]c.GLint, pointers: [2]?*anyopaque };
fn captureAttributes() Attributes {
    var result: Attributes = undefined;
    for (0..2) |i| {
        for (attrib_parameters, 0..) |parameter, j| c.glGetVertexAttribiv(@intCast(i), parameter, &result.values[i][j]);
        c.glGetVertexAttribPointerv(@intCast(i), c.GL_VERTEX_ATTRIB_ARRAY_POINTER, &result.pointers[i]);
    }
    return result;
}
fn unchanged(before: gl.State, attribs: Attributes, read: c.GLuint, texture: c.GLuint, unpack: c.GLuint) !void {
    try expect(std.meta.eql(before, gl.State.capture()));
    try expect(std.meta.eql(attribs, captureAttributes()));
    try expectEqual(read, @as(c.GLuint, @intCast(gl.integer(c.GL_READ_FRAMEBUFFER_BINDING))));
    try expectEqual(texture, @as(c.GLuint, @intCast(gl.integer(c.GL_TEXTURE_BINDING_2D))));
    try expectEqual(unpack, @as(c.GLuint, @intCast(gl.integer(c.GL_PIXEL_UNPACK_BUFFER_BINDING))));
    try gl.check();
}
