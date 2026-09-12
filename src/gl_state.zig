//! GLES 3.0 state touched by a compositor frame. Read framebuffer is never bound.
const c = @import("c");

pub const capabilities = [_]c.GLenum{
    c.GL_BLEND,               c.GL_CULL_FACE,          c.GL_DEPTH_TEST,               c.GL_STENCIL_TEST,
    c.GL_SCISSOR_TEST,        c.GL_RASTERIZER_DISCARD, c.GL_SAMPLE_ALPHA_TO_COVERAGE, c.GL_SAMPLE_COVERAGE,
    c.GL_POLYGON_OFFSET_FILL, c.GL_DITHER,
};

pub fn integer(name: c.GLenum) c.GLint {
    var value: c.GLint = 0;
    c.glGetIntegerv(name, &value);
    return value;
}

pub fn check() !void {
    var failed = false;
    while (c.glGetError() != c.GL_NO_ERROR) failed = true;
    if (failed) return error.OpenGLError;
}

pub const State = struct {
    draw_framebuffer: c.GLint,
    program: c.GLint,
    vao: c.GLint,
    vbo: c.GLint,
    active_texture: c.GLint,
    texture: c.GLint,
    sampler: c.GLint,
    viewport: [4]c.GLint,
    clear_color: [4]c.GLfloat,
    color_mask: [4]c.GLboolean,
    blend_src_rgb: c.GLint,
    blend_dst_rgb: c.GLint,
    blend_src_alpha: c.GLint,
    blend_dst_alpha: c.GLint,
    blend_equation_rgb: c.GLint,
    blend_equation_alpha: c.GLint,
    enabled: [capabilities.len]c.GLboolean,
    sample_mask: ?c.GLboolean,

    pub const sample_mask_capability: c.GLenum = 0x8E51;

    pub fn capture() State {
        var state: State = undefined;
        state.draw_framebuffer = integer(c.GL_DRAW_FRAMEBUFFER_BINDING);
        state.program = integer(c.GL_CURRENT_PROGRAM);
        state.vao = integer(c.GL_VERTEX_ARRAY_BINDING);
        state.vbo = integer(c.GL_ARRAY_BUFFER_BINDING);
        state.active_texture = integer(c.GL_ACTIVE_TEXTURE);
        c.glActiveTexture(c.GL_TEXTURE0);
        state.texture = integer(c.GL_TEXTURE_BINDING_2D);
        state.sampler = integer(c.GL_SAMPLER_BINDING);
        c.glActiveTexture(@intCast(state.active_texture));
        c.glGetIntegerv(c.GL_VIEWPORT, &state.viewport);
        c.glGetFloatv(c.GL_COLOR_CLEAR_VALUE, &state.clear_color);
        c.glGetBooleanv(c.GL_COLOR_WRITEMASK, &state.color_mask);
        state.blend_src_rgb = integer(c.GL_BLEND_SRC_RGB);
        state.blend_dst_rgb = integer(c.GL_BLEND_DST_RGB);
        state.blend_src_alpha = integer(c.GL_BLEND_SRC_ALPHA);
        state.blend_dst_alpha = integer(c.GL_BLEND_DST_ALPHA);
        state.blend_equation_rgb = integer(c.GL_BLEND_EQUATION_RGB);
        state.blend_equation_alpha = integer(c.GL_BLEND_EQUATION_ALPHA);
        for (capabilities, 0..) |cap, i| state.enabled[i] = c.glIsEnabled(cap);
        state.sample_mask = if (integer(c.GL_MAJOR_VERSION) > 3 or integer(c.GL_MINOR_VERSION) >= 1) c.glIsEnabled(sample_mask_capability) else null;
        return state;
    }

    pub fn restore(self: State) void {
        if (self.sample_mask) |enabled| {
            if (enabled == c.GL_TRUE) c.glEnable(sample_mask_capability) else c.glDisable(sample_mask_capability);
        }
        c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, @intCast(self.draw_framebuffer));
        c.glUseProgram(@intCast(self.program));
        c.glBindVertexArray(@intCast(self.vao));
        c.glBindBuffer(c.GL_ARRAY_BUFFER, @intCast(self.vbo));
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, @intCast(self.texture));
        c.glBindSampler(0, @intCast(self.sampler));
        c.glActiveTexture(@intCast(self.active_texture));
        c.glViewport(self.viewport[0], self.viewport[1], self.viewport[2], self.viewport[3]);
        c.glClearColor(self.clear_color[0], self.clear_color[1], self.clear_color[2], self.clear_color[3]);
        c.glColorMask(self.color_mask[0], self.color_mask[1], self.color_mask[2], self.color_mask[3]);
        c.glBlendFuncSeparate(@intCast(self.blend_src_rgb), @intCast(self.blend_dst_rgb), @intCast(self.blend_src_alpha), @intCast(self.blend_dst_alpha));
        c.glBlendEquationSeparate(@intCast(self.blend_equation_rgb), @intCast(self.blend_equation_alpha));
        for (capabilities, self.enabled) |cap, enabled| {
            if (enabled == c.GL_TRUE) c.glEnable(cap) else c.glDisable(cap);
        }
    }
};
