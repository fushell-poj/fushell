//! Flutter backing-store lifecycle and frame presentation on current GLES3 contexts.
const std = @import("std");
const c = @import("c");
const gl_blit = @import("gl_blit.zig");
const gl = @import("gl_state.zig");

/// Allocation is transactional: output is published only after GL succeeds.
/// A current shared resource/render context is required. GL errors are reported
/// and drained, including errors already pending on entry; they are not hidden.
pub fn createBackingStore(config: *const c.FlutterBackingStoreConfig, output: *c.FlutterBackingStore) !void {
    const w = config.size.width;
    const h = config.size.height;
    if (!std.math.isFinite(w) or !std.math.isFinite(h) or w <= 0 or h <= 0) return error.InvalidBackingStoreSize;
    try gl.check();
    const max_size = gl.integer(c.GL_MAX_TEXTURE_SIZE);
    if (@ceil(w) > @as(f64, @floatFromInt(max_size)) or @ceil(h) > @as(f64, @floatFromInt(max_size))) return error.BackingStoreTooLarge;
    const width: c.GLsizei = @intFromFloat(@ceil(w));
    const height: c.GLsizei = @intFromFloat(@ceil(h));
    // Work on the current texture unit, leaving both the active selector and
    // every other unit untouched. Null upload pointers must not address a PBO.
    const previous_texture = gl.integer(c.GL_TEXTURE_BINDING_2D);
    const previous_unpack = gl.integer(c.GL_PIXEL_UNPACK_BUFFER_BINDING);
    defer c.glBindTexture(c.GL_TEXTURE_2D, @intCast(previous_texture));
    defer c.glBindBuffer(c.GL_PIXEL_UNPACK_BUFFER, @intCast(previous_unpack));
    var texture: c.GLuint = 0;
    c.glGenTextures(1, &texture);
    if (texture == 0) return error.GlTextureCreateFailed;
    errdefer c.glDeleteTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glBindBuffer(c.GL_PIXEL_UNPACK_BUFFER, 0);
    c.glTexStorage2D(c.GL_TEXTURE_2D, 1, c.GL_RGBA8, width, height);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    try gl.check();
    var store = std.mem.zeroes(c.FlutterBackingStore);
    store.struct_size = @sizeOf(c.FlutterBackingStore);
    store.type = c.kFlutterBackingStoreTypeOpenGL;
    store.unnamed_0.open_gl.type = c.kFlutterOpenGLTargetTypeTexture;
    store.unnamed_0.open_gl.unnamed_0.texture = .{
        .target = c.GL_TEXTURE_2D,
        .name = texture,
        .format = c.GL_RGBA8,
        .user_data = null,
        .destruction_callback = textureReleased,
        .width = @intCast(width),
        .height = @intCast(height),
    };
    output.* = store;
}

/// Skia's texture release notification does not transfer a second ownership.
/// The backing-store collection callback is the sole owner of GL deletion,
/// including the engine's early failure path before a render target is built.
fn textureReleased(_: ?*anyopaque) callconv(.c) void {}

fn backingTexture(store: *const c.FlutterBackingStore) !c.FlutterOpenGLTexture {
    if (store.type != c.kFlutterBackingStoreTypeOpenGL) return error.UnsupportedBackingStore;
    if (store.unnamed_0.open_gl.type != c.kFlutterOpenGLTargetTypeTexture) return error.UnsupportedOpenGLTarget;
    const texture = store.unnamed_0.open_gl.unnamed_0.texture;
    if (texture.target != c.GL_TEXTURE_2D or texture.format != c.GL_RGBA8) return error.UnsupportedTextureFormat;
    if (texture.name == 0) return error.InvalidTexture;
    return texture;
}

/// Flutter calls once when the backing store is no longer used. The caller
/// makes a compatible resource context current before entering this function.
pub fn collectBackingStore(store: *const c.FlutterBackingStore) !void {
    const texture = try backingTexture(store);
    c.glDeleteTextures(1, &texture.name);
    try gl.check();
}

/// Current destination surface, top-left physical-pixel layer coordinates.
/// Caller swaps only on success. Every frame clears, including an empty frame;
/// defer restores the caller's GL state on successful and rejected layers alike.
pub fn presentFrame(blitter: *gl_blit.Blitter, info: *const c.FlutterPresentViewInfo, viewport_width: u32, viewport_height: u32) !void {
    const frame = try blitter.beginFrame(viewport_width, viewport_height);
    defer frame.end();
    if (info.layers_count != 0 and info.layers == null) return error.InvalidLayers;
    for (0..info.layers_count) |index| {
        if (info.layers[index] == null) return error.InvalidLayer;
        const layer: *const c.FlutterLayer = @ptrCast(info.layers[index]);
        if (layer.type != c.kFlutterLayerContentTypeBackingStore) return error.UnsupportedLayer;
        if (layer.unnamed_0.backing_store == null) return error.InvalidBackingStore;
        const texture = try backingTexture(@ptrCast(layer.unnamed_0.backing_store));
        try frame.draw(texture.name, @floatCast(layer.offset.x), @floatCast(layer.offset.y), @floatCast(layer.size.width), @floatCast(layer.size.height));
    }
}
