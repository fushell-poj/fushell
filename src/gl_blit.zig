//! 对 Flutter compositor backing store 执行状态隔离合成的 GLES2 blitter。
//!
//! 调用前必须让目标窗口 context 与默认 framebuffer 处于 current 状态。返回前会
//! 恢复 blit 触及的每个 GL binding/capability，确保 Flutter 下一次 raster pass
//! 看到自己的状态。layer 几何使用左上角为原点的物理像素；顶点 Y 轴会为 GLES
//! NDC 坐标系翻转。
const std = @import("std");
const c = @import("c");

const vertex_shader_src: [:0]const u8 =
    \\attribute vec2 aPos;
    \\attribute vec2 aTex;
    \\varying vec2 vTex;
    \\void main() {
    \\  gl_Position = vec4(aPos, 0.0, 1.0);
    \\  vTex = aTex;
    \\}
;

const fragment_shader_src: [:0]const u8 =
    \\precision mediump float;
    \\varying vec2 vTex;
    \\uniform sampler2D uTex;
    \\void main() {
    \\  gl_FragColor = texture2D(uTex, vTex);
    \\}
;

const Vertex = struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
};

/// 延迟编译的 shader 程序与可复用顶点缓冲区。
///
/// GL 名称属于首次执行 `init` 时的 context share group，因此调用 `deinit` 时必须
/// 让兼容 context 处于 current 状态。该类型限制在渲染线程使用，不提供同步机制。
pub const Blitter = struct {
    program: c.GLuint = 0,
    vbo: c.GLuint = 0,
    inited: bool = false,
    log_errors: bool = true,

    /// 惰性初始化 (首次 present 时 GL context 已 current)。
    pub fn init(self: *Blitter) !void {
        if (self.inited) return;
        self.program = try linkProgram();
        errdefer if (self.program != 0) {
            c.glDeleteProgram(self.program);
            self.program = 0;
        };
        c.glGenBuffers(1, &self.vbo);
        if (self.vbo == 0) return error.GlBufferCreateFailed;
        self.inited = true;
    }

    pub fn deinit(self: *Blitter) void {
        if (!self.inited) return;
        if (self.vbo != 0) c.glDeleteBuffers(1, &self.vbo);
        if (self.program != 0) c.glDeleteProgram(self.program);
        self.* = .{};
    }

    /// 将纹理 layer 绘制到 (x, y, w, h) 物理像素区域, 视口 (vp_w, vp_h)。
    /// 保存并恢复 GL 状态。
    pub fn blitLayer(self: *Blitter, texture: c.GLuint, x: f32, y: f32, w: f32, h: f32, vp_w: f32, vp_h: f32) void {
        if (!self.inited) return;

        // ── 保存状态 ──────────────────────────────────
        var saved_viewport: [4]c.GLint = undefined;
        c.glGetIntegerv(c.GL_VIEWPORT, &saved_viewport);
        var prev_framebuffer: c.GLint = 0;
        c.glGetIntegerv(c.GL_FRAMEBUFFER_BINDING, &prev_framebuffer);
        var prev_program: c.GLint = 0;
        c.glGetIntegerv(c.GL_CURRENT_PROGRAM, &prev_program);
        var prev_active_texture: c.GLint = 0;
        c.glGetIntegerv(c.GL_ACTIVE_TEXTURE, &prev_active_texture);
        c.glActiveTexture(c.GL_TEXTURE0);
        var prev_texture_unit_zero: c.GLint = 0;
        c.glGetIntegerv(c.GL_TEXTURE_BINDING_2D, &prev_texture_unit_zero);
        var prev_vbo: c.GLint = 0;
        c.glGetIntegerv(c.GL_ARRAY_BUFFER_BINDING, &prev_vbo);
        const blend_was_on = c.glIsEnabled(c.GL_BLEND) == c.GL_TRUE;
        const scissor_was_on = c.glIsEnabled(c.GL_SCISSOR_TEST) == c.GL_TRUE;
        const depth_was_on = c.glIsEnabled(c.GL_DEPTH_TEST) == c.GL_TRUE;

        // eglMakeCurrent(window_surface) 只切 EGL drawable，不会重置 GL FBO
        // 绑定。Flutter 光栅化后仍绑定 backing-store FBO；若不显式切到 0，
        // blit 会画回离屏纹理，eglSwapBuffers 提交的窗口 buffer 仍为空。
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, @intFromFloat(vp_w), @intFromFloat(vp_h));
        c.glUseProgram(self.program);
        c.glDisable(c.GL_BLEND);
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glDisable(c.GL_DEPTH_TEST);
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glUniform1i(c.glGetUniformLocation(self.program, "uTex"), 0);

        // NDC 转换: surface 顶部原点 (y 向下) → NDC (y 向上)。
        const x0 = x / vp_w * 2.0 - 1.0;
        const x1 = (x + w) / vp_w * 2.0 - 1.0;
        const y0 = 1.0 - y / vp_h * 2.0;
        const y1 = 1.0 - (y + h) / vp_h * 2.0;
        // Skia renders backing-store textures with the framebuffer convention:
        // content top is v=1 and content bottom is v=0.
        // 故屏幕 TL ← tex(u=0,v=1), 屏幕 BR ← tex(u=1,v=0): u 正常, v 翻转。
        const verts = [6]Vertex{
            .{ .x = x0, .y = y0, .u = 0.0, .v = 1.0 }, // TL
            .{ .x = x1, .y = y0, .u = 1.0, .v = 1.0 }, // TR
            .{ .x = x0, .y = y1, .u = 0.0, .v = 0.0 }, // BL
            .{ .x = x0, .y = y1, .u = 0.0, .v = 0.0 }, // BL
            .{ .x = x1, .y = y0, .u = 1.0, .v = 1.0 }, // TR
            .{ .x = x1, .y = y1, .u = 1.0, .v = 0.0 }, // BR
        };
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(Vertex) * verts.len, &verts, c.GL_STREAM_DRAW);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), null);
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(2 * @sizeOf(f32)));
        c.glDrawArrays(c.GL_TRIANGLES, 0, verts.len);
        c.glDisableVertexAttribArray(0);
        c.glDisableVertexAttribArray(1);

        // ── 恢复状态 ──────────────────────────────────
        c.glBindBuffer(c.GL_ARRAY_BUFFER, @intCast(prev_vbo));
        c.glBindTexture(c.GL_TEXTURE_2D, @intCast(prev_texture_unit_zero));
        c.glActiveTexture(@intCast(prev_active_texture));
        c.glUseProgram(@intCast(prev_program));
        c.glViewport(saved_viewport[0], saved_viewport[1], saved_viewport[2], saved_viewport[3]);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(prev_framebuffer));
        if (blend_was_on) c.glEnable(c.GL_BLEND) else c.glDisable(c.GL_BLEND);
        if (scissor_was_on) c.glEnable(c.GL_SCISSOR_TEST) else c.glDisable(c.GL_SCISSOR_TEST);
        if (depth_was_on) c.glEnable(c.GL_DEPTH_TEST) else c.glDisable(c.GL_DEPTH_TEST);
    }
};

fn linkProgram() !c.GLuint {
    const vs = try compileShader(c.GL_VERTEX_SHADER, vertex_shader_src);
    defer c.glDeleteShader(vs);
    const fs = try compileShader(c.GL_FRAGMENT_SHADER, fragment_shader_src);
    defer c.glDeleteShader(fs);

    const program = c.glCreateProgram();
    if (program == 0) return error.GlProgramCreateFailed;
    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    // 固定 attribute 位置 (link 前绑定)。
    c.glBindAttribLocation(program, 0, "aPos");
    c.glBindAttribLocation(program, 1, "aTex");
    c.glLinkProgram(program);
    var status: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &status);
    if (status == c.GL_FALSE) {
        var log_buf: [1024]u8 = undefined;
        var log_len: c.GLsizei = 0;
        c.glGetProgramInfoLog(program, log_buf.len, &log_len, &log_buf);
        std.debug.print("[gl_blit] program link failed: {s}\n", .{log_buf[0..@intCast(@max(log_len, 0))]});
        c.glDeleteProgram(program);
        return error.GlProgramLinkFailed;
    }
    return program;
}

fn compileShader(kind: c.GLenum, source: [:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(kind);
    if (shader == 0) return error.GlShaderCreateFailed;
    const src_ptr: [*c]const c.GLchar = @ptrCast(source.ptr);
    c.glShaderSource(shader, 1, &src_ptr, null);
    c.glCompileShader(shader);
    var status: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &status);
    if (status == c.GL_FALSE) {
        var log_buf: [1024]u8 = undefined;
        var log_len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, log_buf.len, &log_len, &log_buf);
        std.debug.print("[gl_blit] shader compile failed: {s}\n", .{log_buf[0..@intCast(@max(log_len, 0))]});
        c.glDeleteShader(shader);
        return error.GlShaderCompileFailed;
    }
    return shader;
}
