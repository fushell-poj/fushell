//! Flutter compositor callbacks and OpenGL backing-store presentation.
//! Backing-store resources are created and collected on the render thread;
//! each presented layer is routed to the platform-owned window by view id.

const std = @import("std");
const c = @import("c");
const gl_blit = @import("gl_blit.zig");

const gl_rgba8: c.GLint = 0x8058;

pub fn createBackingStore(config: *const c.FlutterBackingStoreConfig, output: *c.FlutterBackingStore) bool {
    const width: c.GLsizei = @intFromFloat(@ceil(@max(config.size.width, 1.0)));
    const height: c.GLsizei = @intFromFloat(@ceil(@max(config.size.height, 1.0)));
    var texture: c.GLuint = 0;
    c.glGenTextures(1, &texture);
    if (texture == 0) {
        std.debug.print("[error] glGenTextures failed for backing store {d}x{d}\n", .{ width, height });
        return false;
    }
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, gl_rgba8, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    output.* = std.mem.zeroes(c.FlutterBackingStore);
    output.struct_size = @sizeOf(c.FlutterBackingStore);
    output.type = c.kFlutterBackingStoreTypeOpenGL;
    output.unnamed_0.open_gl.type = c.kFlutterOpenGLTargetTypeTexture;
    output.unnamed_0.open_gl.unnamed_0.texture.target = c.GL_TEXTURE_2D;
    output.unnamed_0.open_gl.unnamed_0.texture.name = texture;
    output.unnamed_0.open_gl.unnamed_0.texture.format = @intCast(gl_rgba8);
    output.unnamed_0.open_gl.unnamed_0.texture.width = @intCast(width);
    output.unnamed_0.open_gl.unnamed_0.texture.height = @intCast(height);
    return true;
}

pub fn collectBackingStore(backing_store: *const c.FlutterBackingStore) bool {
    if (backing_store.type != c.kFlutterBackingStoreTypeOpenGL) return true;
    const texture = backing_store.unnamed_0.open_gl.unnamed_0.texture;
    if (texture.name != 0) {
        const name = texture.name;
        c.glDeleteTextures(1, &name);
    }
    return true;
}

pub fn blitLayers(blitter: *gl_blit.Blitter, info: *const c.FlutterPresentViewInfo, viewport_width: f32, viewport_height: f32) void {
    for (0..info.layers_count) |index| {
        const layer: *const c.FlutterLayer = @ptrCast(info.layers[index]);
        switch (layer.type) {
            c.kFlutterLayerContentTypeBackingStore => {
                const backing_store: *const c.FlutterBackingStore = @ptrCast(layer.unnamed_0.backing_store);
                const texture = backing_store.unnamed_0.open_gl.unnamed_0.texture;
                blitter.blitLayer(
                    texture.name,
                    @floatCast(layer.offset.x),
                    @floatCast(layer.offset.y),
                    @floatCast(layer.size.width),
                    @floatCast(layer.size.height),
                    viewport_width,
                    viewport_height,
                );
            },
            else => std.debug.print("unsupported layer type in present: {}\n", .{layer.type}),
        }
    }
}
