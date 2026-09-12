//! GLES 3.0 premultiplied compositor. One instance belongs to one render context:
//! VAOs are not shared between contexts. All methods require that context current.
const std = @import("std");
const c = @import("c");
const gl = @import("gl_state.zig");

const vertex_source: [:0]const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec2 position;
    \\layout(location = 1) in vec2 texcoord;
    \\out vec2 uv;
    \\void main() { gl_Position = vec4(position, 0.0, 1.0); uv = texcoord; }
;
const fragment_source: [:0]const u8 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 uv;
    \\uniform sampler2D image;
    \\out vec4 color;
    \\void main() { color = texture(image, uv); }
;
const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32 };

pub const Blitter = struct {
    program: c.GLuint = 0,
    vao: c.GLuint = 0,
    vbo: c.GLuint = 0,

    pub fn init(self: *Blitter) !void {
        if (self.program != 0) return;
        try gl.check();
        if (gl.integer(c.GL_MAJOR_VERSION) < 3) return error.GLES3Required;
        const saved = gl.State.capture();
        defer saved.restore();
        errdefer self.deinit();
        self.program = try linkProgram();
        c.glGenVertexArrays(1, &self.vao);
        c.glGenBuffers(1, &self.vbo);
        if (self.vao == 0 or self.vbo == 0) return error.GlObjectCreateFailed;
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, 4 * @sizeOf(Vertex), null, c.GL_STREAM_DRAW);
        c.glEnableVertexAttribArray(0);
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), null);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(2 * @sizeOf(f32)));
        c.glUseProgram(self.program);
        const uniform = c.glGetUniformLocation(self.program, "image");
        if (uniform < 0) return error.GlUniformMissing;
        c.glUniform1i(uniform, 0);
        try gl.check();
    }

    /// Owned names never escape into caller bindings. Deleting an idle instance
    /// therefore preserves caller state; repeated deinit is harmless.
    pub fn deinit(self: *Blitter) void {
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
        if (self.vbo != 0) c.glDeleteBuffers(1, &self.vbo);
        if (self.program != 0) c.glDeleteProgram(self.program);
        self.* = .{};
    }

    pub fn beginFrame(self: *Blitter, width: u32, height: u32) !Frame {
        if (width == 0 or height == 0 or width > std.math.maxInt(c.GLsizei) or height > std.math.maxInt(c.GLsizei)) return error.InvalidViewport;
        try self.init();
        try gl.check();
        const saved = gl.State.capture();
        errdefer saved.restore();
        c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
        const default_draw_buffer: c.GLenum = @intCast(gl.integer(c.GL_DRAW_BUFFER0));
        errdefer restoreDefaultDrawBuffer(default_draw_buffer);
        const back: c.GLenum = c.GL_BACK;
        c.glDrawBuffers(1, &back);
        c.glViewport(0, 0, @intCast(width), @intCast(height));
        c.glColorMask(c.GL_TRUE, c.GL_TRUE, c.GL_TRUE, c.GL_TRUE);
        // A driver may return a newer context than the requested GLES 3.0.
        for (gl.capabilities) |cap| c.glDisable(cap);
        if (saved.sample_mask != null) c.glDisable(gl.State.sample_mask_capability);
        c.glClearColor(0, 0, 0, 0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glEnable(c.GL_BLEND);
        c.glBlendEquationSeparate(c.GL_FUNC_ADD, c.GL_FUNC_ADD);
        c.glBlendFuncSeparate(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glUseProgram(self.program);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindSampler(0, 0);
        try gl.check();
        return .{ .saved = saved, .default_draw_buffer = default_draw_buffer, .width = @floatFromInt(width), .height = @floatFromInt(height) };
    }
};

// Draw-buffer selection belongs to the default framebuffer, not the context.
// Restore it before restoring the caller's potentially different draw FBO.
fn restoreDefaultDrawBuffer(buffer: c.GLenum) void {
    c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
    c.glDrawBuffers(1, &buffer);
}

/// Scope with defer frame.end(). No per-layer state snapshots.
pub const Frame = struct {
    saved: gl.State,
    default_draw_buffer: c.GLenum,
    width: f32,
    height: f32,

    pub fn end(self: *const Frame) void {
        restoreDefaultDrawBuffer(self.default_draw_buffer);
        self.saved.restore();
    }

    pub fn draw(self: *const Frame, texture: c.GLuint, x: f32, y: f32, width: f32, height: f32) !void {
        if (texture == 0 or c.glIsTexture(texture) != c.GL_TRUE) return error.InvalidTexture;
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(width) or !std.math.isFinite(height) or width < 0 or height < 0) return error.InvalidLayerGeometry;
        if (width == 0 or height == 0) return;
        const left = x / self.width * 2 - 1;
        const right = (x + width) / self.width * 2 - 1;
        const top = 1 - y / self.height * 2;
        const bottom = 1 - (y + height) / self.height * 2;
        // Flutter's Skia GL backing stores have a bottom-left texture origin.
        // Screen geometry is top-left based, so its top samples texture v=1.
        const vertices = [_]Vertex{
            .{ .x = left, .y = top, .u = 0, .v = 1 },
            .{ .x = left, .y = bottom, .u = 0, .v = 0 },
            .{ .x = right, .y = top, .u = 1, .v = 1 },
            .{ .x = right, .y = bottom, .u = 1, .v = 0 },
        };
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
        try gl.check();
    }
};

fn linkProgram() !c.GLuint {
    const vertex = try compileShader(c.GL_VERTEX_SHADER, vertex_source);
    defer c.glDeleteShader(vertex);
    const fragment = try compileShader(c.GL_FRAGMENT_SHADER, fragment_source);
    defer c.glDeleteShader(fragment);
    const program = c.glCreateProgram();
    if (program == 0) return error.GlProgramCreateFailed;
    errdefer c.glDeleteProgram(program);
    c.glAttachShader(program, vertex);
    c.glAttachShader(program, fragment);
    c.glLinkProgram(program);
    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) return error.GlProgramLinkFailed;
    // No lingering attached shader ownership after linking.
    c.glDetachShader(program, vertex);
    c.glDetachShader(program, fragment);
    return program;
}

fn compileShader(kind: c.GLenum, source: [:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(kind);
    if (shader == 0) return error.GlShaderCreateFailed;
    errdefer c.glDeleteShader(shader);
    const ptr: [*c]const u8 = source.ptr;
    c.glShaderSource(shader, 1, &ptr, null);
    c.glCompileShader(shader);
    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) return error.GlShaderCompileFailed;
    return shader;
}
