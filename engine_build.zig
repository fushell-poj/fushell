//! `zig build build-engine-release` / `zig build build-engine-debug` /
//! `zig build build-engine-profile` 的实现: 编译 Flutter 引擎。
//!
//! 编译参数 (官方文档 + 实测):
//!   gn:    flutter/tools/gn --target-os=linux --linux-cpu=x64 --runtime-mode={release|debug|profile}
//!          (cwd = engine/src, gn 根; tools/gn 的 shebang 是 vpython3, devshell 提供)
//!   ninja: ninja -C out/linux_{release|debug|profile}_x64 flutter_engine [gen_snapshot]
//!   (gn/ninja 来自工作区: third_party/gn/gn 与 devshell 的 nix ninja)
//!
//! 产物: engine/src/out/linux_{release|debug|profile}_x64/
//!   release:  libflutter_engine.so (AOT) + gen_snapshot + icudtl.dat
//!   profile:  libflutter_engine.so (AOT + 剖析) + gen_snapshot + icudtl.dat
//!   debug:    libflutter_engine.so (JIT) + icudtl.dat

const std = @import("std");
const support = @import("build_support.zig");

const prefix = "[build-engine]";

const gn_relative = "flutter/tools/gn";

/// 引擎构建模式: release (AOT, 播 libapp.so)、profile (AOT + 剖析) 或 debug (JIT, 播 kernel_blob.bin)。
pub const Mode = enum { debug, profile, release };

pub const BuildEngine = struct {
    step: std.Build.Step,
    workspace: []const u8,
    no_lto: bool,
    mode: Mode,

    pub fn create(b: *std.Build, workspace: []const u8, no_lto: bool, mode: Mode) *BuildEngine {
        const self = b.allocator.create(BuildEngine) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = switch (mode) {
                    .release => "engine-build-release",
                    .profile => "engine-build-profile",
                    .debug => "engine-build-debug",
                },
                .owner = b,
                .makeFn = make,
            }),
            .workspace = workspace,
            .no_lto = no_lto,
            .mode = mode,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const self: *BuildEngine = @fieldParentPtr("step", step);
        const allocator = options.gpa;
        // zig 0.16: step.owner.graph.io 自带完整环境, spawn 可解析 PATH (gclient/gn/ninja)。
        const io = step.owner.graph.io;

        const workspace = try support.resolveWorkspace(io, allocator, self.workspace);
        std.debug.print("{s} workspace: {s}\n", .{ prefix, workspace });
        std.debug.print("{s} engine commit: {s}\n", .{ prefix, support.engine_commit });

        // 1. 工作区必须已存在 (与 pull-flutter 相同约定)
        if ((std.Io.Dir.accessAbsolute(io, workspace, .{}) catch null) == null) {
            std.debug.print(
                \\
                \\{s} error: workspace does not exist: {s}
                \\  Run pull-flutter first to fetch the engine source tree:
                \\    zig build pull-flutter
                \\
            , .{ prefix, workspace });
            return error.WorkspaceMissing;
        }

        // 2. HEAD 必须对齐钉住的 commit (依赖按该 commit 的 DEPS 拉取)
        if (!headAligned(io, allocator, workspace)) {
            std.debug.print(
                \\
                \\{s} error: workspace HEAD is not {s}
                \\  Run pull-flutter to align the workspace:
                \\    zig build pull-flutter
                \\
            , .{ prefix, support.engine_commit });
            return error.HeadMisaligned;
        }

        // 3. 工具链检查
        //    gn: 工作区 cipd 二进制 (third_party/gn/gn)。
        //    ninja: 工作区 depot_tools/ninja 是 python 包装 (import pipes,
        //    Python 3.13 已移除) 不可用 → 用 devshell 的 nix ninja (PATH)。
        const engine_src = try std.fs.path.join(allocator, &.{ workspace, "engine/src" });
        defer allocator.free(engine_src);
        const flutter_dir = try std.fs.path.join(allocator, &.{ engine_src, "flutter" });
        defer allocator.free(flutter_dir);
        const gn_path = try std.fs.path.join(allocator, &.{ flutter_dir, "third_party/gn/gn" });
        defer allocator.free(gn_path);

        const gn_ok = (std.Io.Dir.accessAbsolute(io, gn_path, .{}) catch null) != null;
        if (!gn_ok) {
            std.debug.print(
                \\
                \\{s} error: gn not found: {s}
                \\  Run pull-flutter to fetch the toolchain:
                \\    zig build pull-flutter
                \\
            , .{ prefix, gn_path });
            return error.ToolchainMissing;
        }
        if (!probeNinja(io)) {
            std.debug.print(
                \\
                \\{s} error: ninja not found in PATH.
                \\  Enter the fushell devshell (nix develop), which provides ninja.
                \\
            , .{prefix});
            return error.ToolchainMissing;
        }

        // 4. gn 生成 (cwd = engine/src; tools/gn 由 vpython3 执行, devshell 提供)
        //    额外 gn args: 42d3d75a 的 tools/gn 只在 is_host_build 时设置这些
        //    angle 参数 (target 构建缺省会报错: wayland_dir 未定义、angle 子模块
        //    路径不存在等)。补上与官方 host 构建一致的配置。两种模式都需要。
        const runtime_mode_arg = switch (self.mode) {
            .release => "--runtime-mode=release",
            .profile => "--runtime-mode=profile",
            .debug => "--runtime-mode=debug",
        };
        var gn_argv = std.array_list.Managed([]const u8).init(allocator);
        defer gn_argv.deinit();
        try gn_argv.appendSlice(&.{ "vpython3", gn_relative, "--target-os=linux", "--linux-cpu=x64", runtime_mode_arg });
        try gn_argv.appendSlice(&.{
            "--gn-args=angle_use_x11=false",
            "--gn-args=angle_use_wayland=false",
            "--gn-args=angle_enable_commit_id=false",
            "--gn-args=angle_build_all=false",
            "--gn-args=angle_has_astc_encoder=false",
            "--gn-args=angle_enable_libdrm=false",
            "--gn-args=angle_enable_vulkan_validation_layers=false",
            "--gn-args=angle_vulkan_headers_dir=\"//flutter/third_party/vulkan-deps/vulkan-headers/src\"",
            "--gn-args=angle_vulkan_loader_dir=\"//flutter/third_party/vulkan-deps/vulkan-loader/src\"",
            "--gn-args=angle_vulkan_tools_dir=\"//flutter/third_party/vulkan-deps/vulkan-tools/src\"",
            "--gn-args=angle_lunarg_vulkantools_dir=\"//flutter/third_party/vulkan-deps/lunarg-vulkantools/src\"",
        });
        if (self.no_lto and self.mode == .release) try gn_argv.append("--no-lto");
        std.debug.print("{s} generating build files (gn, {s})\n", .{ prefix, runtime_mode_arg });
        try support.run(io, allocator, prefix, engine_src, gn_argv.items);

        // 5. ninja 编译 (PATH 的 nix ninja, 工作区 python 包装版不可用)
        //    flutter_engine: 引擎本体; gen_snapshot: AOT 编译器
        //    (release/profile 的 libapp.so 依赖它, 配对契约; debug 模式不需要)。
        const out_dir_name = switch (self.mode) {
            .release => "out/linux_release_x64",
            .profile => "out/linux_profile_x64",
            .debug => "out/linux_debug_x64",
        };
        const out_dir = try std.fs.path.join(allocator, &.{ engine_src, out_dir_name });
        defer allocator.free(out_dir);
        switch (self.mode) {
            .release, .profile => {
                std.debug.print("{s} compiling engine (ninja, target: flutter_engine + gen_snapshot)\n", .{prefix});
                try support.run(io, allocator, prefix, null, &.{ "ninja", "-C", out_dir, "flutter_engine", "gen_snapshot" });
            },
            .debug => {
                std.debug.print("{s} compiling engine (ninja, target: flutter_engine)\n", .{prefix});
                try support.run(io, allocator, prefix, null, &.{ "ninja", "-C", out_dir, "flutter_engine" });
            },
        }

        // 6. 诊断输出
        const engine_so = try std.fs.path.join(allocator, &.{ out_dir, "libflutter_engine.so" });
        defer allocator.free(engine_so);
        const icu_dat = try std.fs.path.join(allocator, &.{ out_dir, "icudtl.dat" });
        defer allocator.free(icu_dat);
        std.debug.print(
            \\
            \\{s} done.
            \\  engine: {s}
            \\  commit: {s}
            \\  mode:   {s}
            \\  artifacts in {s}:
            \\    libflutter_engine.so  ({s})
            \\    icudtl.dat
            \\{s}
            \\  打包: zig build -Dflutter-engine-so={s}
            \\
        , .{
            prefix,
            engine_so,
            support.engine_commit,
            @tagName(self.mode),
            out_dir,
            switch (self.mode) {
                .release => "AOT engine",
                .profile => "AOT engine (profiling)",
                .debug => "JIT engine",
            },
            if (self.mode == .debug) "" else "    gen_snapshot          (AOT compiler)",
            engine_so,
        });
    }
};

/// 探测 ninja 是否可用 (spawn ninja --version; 0.16 spawn 对 PATH 中不存在的
/// 命令返回 FileNotFound 或 OutOfMemory, 两者都视为未安装)。
fn probeNinja(io: std.Io) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "ninja", "--version" },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound, error.OutOfMemory => return false,
        else => return false,
    };
    const term = child.wait(io) catch return false;
    switch (term) {
        .exited => |code| return code == 0,
        else => return false,
    }
}

/// detached HEAD 时 .git/HEAD 内容即 commit hash; 与钉住 commit 比较。
fn headAligned(io: std.Io, allocator: std.mem.Allocator, workspace: []const u8) bool {
    const head_path = std.fs.path.join(allocator, &.{ workspace, ".git/HEAD" }) catch return false;
    defer allocator.free(head_path);
    const content = support.readSmallFile(io, head_path) orelse return false;
    defer std.heap.page_allocator.free(content); // readSmallFile 内部用 page_allocator 分配
    const trimmed = std.mem.trim(u8, content, " \n\r");
    return std.mem.eql(u8, trimmed, support.engine_commit);
}
