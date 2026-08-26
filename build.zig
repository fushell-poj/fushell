const std = @import("std");
const Scanner = @import("wayland").Scanner;
const flutter_pull = @import("flutter_pull.zig");
const engine_build = @import("engine_build.zig");
const build_support = @import("build_support.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Flutter 引擎工作区 (pull-flutter / build-engine 共享), 无默认值, 必须指定:
    //   ① -Dflutter-workspace=X  ② FLUTTER_ENGINE_DIR  ③ ./flutter_engine_dir
    // zig 0.16: b.graph.io 自带完整环境, spawn 可解析 PATH (gclient/gn/ninja)。
    const io = b.graph.io;
    const flutter_workspace = build_support.resolveWorkspaceConfig(io, b.allocator, b.option([]const u8, "flutter-workspace", "Flutter engine workspace path (or FLUTTER_ENGINE_DIR, or ./flutter_engine_dir)")) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // zig build pull-flutter: 拉取引擎源码
    const pull_flutter = flutter_pull.PullFlutter.create(b, flutter_workspace);
    const pull_flutter_step = b.step("pull-flutter", "Fetch the Flutter engine source tree into the workspace via gclient");
    pull_flutter_step.dependOn(&pull_flutter.step);

    // zig build build-engine-release: 编译 release (AOT) 引擎
    // zig build build-engine-profile: 编译 profile (AOT+剖析) 引擎
    // zig build build-engine-debug:   编译 debug (JIT) 引擎
    const no_lto = b.option(bool, "no-lto", "Pass --no-lto to gn (faster first build, slower binaries; release only)") orelse false;
    const build_engine_release = engine_build.BuildEngine.create(b, flutter_workspace, no_lto, .release);
    const build_engine_release_step = b.step("build-engine-release", "Build the release (AOT) Flutter engine in the workspace");
    build_engine_release_step.dependOn(&build_engine_release.step);
    const build_engine_profile = engine_build.BuildEngine.create(b, flutter_workspace, no_lto, .profile);
    const build_engine_profile_step = b.step("build-engine-profile", "Build the profile (AOT + profiling) Flutter engine in the workspace");
    build_engine_profile_step.dependOn(&build_engine_profile.step);
    const build_engine_debug = engine_build.BuildEngine.create(b, flutter_workspace, no_lto, .debug);
    const build_engine_debug_step = b.step("build-engine-debug", "Build the debug (JIT) Flutter engine in the workspace");
    build_engine_debug_step.dependOn(&build_engine_debug.step);

    // 三个引擎 .so 全部内嵌进 fushell CLI (打包时按模式选), 各自可覆盖:
    //   debug   → 打包 JIT bundle (kernel_blob.bin)
    //   profile → 打包 AOT+剖析 bundle
    //   release → 打包 AOT bundle (默认)
    const flutter_engine_debug_so = b.option([]const u8, "flutter-engine-debug-so", "Path to the debug (JIT) Flutter engine shared library (default: <workspace>/engine/src/out/linux_debug_x64/libflutter_engine.so)") orelse
        b.pathJoin(&.{ flutter_workspace, "engine/src/out/linux_debug_x64/libflutter_engine.so" });
    const flutter_engine_profile_so = b.option([]const u8, "flutter-engine-profile-so", "Path to the profile (AOT+profiling) Flutter engine shared library (default: <workspace>/engine/src/out/linux_profile_x64/libflutter_engine.so)") orelse
        b.pathJoin(&.{ flutter_workspace, "engine/src/out/linux_profile_x64/libflutter_engine.so" });
    const flutter_engine_release_so = b.option([]const u8, "flutter-engine-release-so", "Path to the release (AOT) Flutter engine shared library (default: <workspace>/engine/src/out/linux_release_x64/libflutter_engine.so)") orelse
        b.pathJoin(&.{ flutter_workspace, "engine/src/out/linux_release_x64/libflutter_engine.so" });

    // 存在性检查: 缺失时给明确指引 (而不是 @embedFile 的裸错误)
    checkEngineSo(b, flutter_engine_debug_so, "debug");
    checkEngineSo(b, flutter_engine_profile_so, "profile");
    checkEngineSo(b, flutter_engine_release_so, "release");

    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    const c_headers = b.addWriteFiles();
    const c_header = c_headers.add("fushell_c_bindings.h",
        \\#include <dirent.h>
        \\#include <errno.h>
        \\#include <stdio.h>
        \\#include <stdlib.h>
        \\#include <sys/stat.h>
        \\#include <time.h>
        \\#include <unistd.h>
        \\#include <wayland-egl.h>
        \\#include <EGL/egl.h>
        \\#include <GLES2/gl2.h>
        \\#include <fontconfig/fontconfig.h>
        \\#include <poll.h>
        \\#include <flutter_embedder.h>
    );

    const flutter_embedder = b.dependency("flutter-embedder", .{});
    const translate_c = b.addTranslateC(.{
        .root_source_file = c_header,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(flutter_embedder.path("."));
    linkTranslateCLibraries(translate_c, dynamic_link_opts);
    const c_mod = translate_c.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("c", c_mod);

    const scanner = Scanner.create(b, .{
        // Custom protocols are added explicitly below, so this only satisfies
        // zig-wayland's scanner configuration shape.
        .wayland_protocols = b.path("."),
    });
    const wayland_protocols = b.dependency("wayland-protocols", .{});
    scanner.addCustomProtocol(wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"));
    scanner.addCustomProtocol(wayland_protocols.path("stable/viewporter/viewporter.xml"));
    scanner.addCustomProtocol(wayland_protocols.path("staging/fractional-scale/fractional-scale-v1.xml"));
    const wlr_protocols = b.dependency("wlr-protocols", .{});
    scanner.addCustomProtocol(wlr_protocols.path("unstable/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(wlr_protocols.path("unstable/wlr-data-control-unstable-v1.xml"));
    scanner.addCustomProtocol(wayland_protocols.path("unstable/text-input/text-input-unstable-v3.xml"));
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 8);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwlr_data_control_manager_v1", 2);
    scanner.generate("zwp_text_input_manager_v3", 2);
    // xdg_surface/xdg_toplevel are created from xdg_wm_base, not globals.
    // 版本 5: 兼容 wlroots 系 compositor (cage 等最高支持 5); v6 仅新增
    // popup repositioning, fushell 不需要 (实测 hyprland 支持 v6, cage 报 invalid version)。
    scanner.generate("xdg_wm_base", 5);
    const wayland_mod = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("wayland", wayland_mod);
    linkRuntimeLibraries(exe_mod, dynamic_link_opts);

    const exe = b.addExecutable(.{
        // pi-lens-ignore: zls
        .name = "fushell-runner",
        .root_module = exe_mod,
        .use_llvm = true,
    });

    const build_tool_mod = b.createModule(.{
        .root_source_file = b.path("src/fushell.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    build_tool_mod.addImport("build_support", b.createModule(.{
        .root_source_file = b.path("build_support.zig"),
        .target = target,
        .optimize = optimize,
    }));
    // fushell run: 进程内播放 (player.zig → flutter_runner → c/wayland/EGL)
    build_tool_mod.addImport("c", c_mod);
    build_tool_mod.addImport("wayland", wayland_mod);
    linkRuntimeLibraries(build_tool_mod, dynamic_link_opts);
    // workspace 解析后是绝对路径 (或相对构建根), 用 cwd_relative 支持两者
    // 目标平台 arch (Flutter 命名: x64/arm64/riscv64), 注入 fushell CLI
    // 用于默认 bundle 输出目录 build/linux/<arch>/<mode>
    const build_options = b.addOptions();
    {
        const arch_tag = @tagName(target.result.cpu.arch);
        const flutter_arch: []const u8 = if (std.mem.eql(u8, arch_tag, "x86_64"))
            "x64"
        else if (std.mem.eql(u8, arch_tag, "aarch64"))
            "arm64"
        else
            arch_tag;
        build_options.addOption([]const u8, "flutter_arch", flutter_arch);
    }
    build_tool_mod.addOptions("build_options", build_options);

    build_tool_mod.addAnonymousImport("flutter_engine_so_debug", .{
        .root_source_file = .{ .cwd_relative = flutter_engine_debug_so },
    });
    build_tool_mod.addAnonymousImport("flutter_engine_so_profile", .{
        .root_source_file = .{ .cwd_relative = flutter_engine_profile_so },
    });
    build_tool_mod.addAnonymousImport("flutter_engine_so_release", .{
        .root_source_file = .{ .cwd_relative = flutter_engine_release_so },
    });
    // runner 可执行文件内嵌进 fushell CLI: 打包时写出为 bundle 入口
    // (getEmittedBin LazyPath, 构建顺序自动: runner 先编译)
    build_tool_mod.addAnonymousImport("fushell_runner_bin", .{
        .root_source_file = exe.getEmittedBin(),
    });
    // fushell SDK 包文件内嵌: `fushell sdk` 释放给外部项目
    build_tool_mod.addAnonymousImport("fushell_sdk_pubspec", .{
        .root_source_file = b.path("packages/fushell/pubspec.yaml"),
    });
    build_tool_mod.addAnonymousImport("fushell_sdk_lib", .{
        .root_source_file = b.path("packages/fushell/lib/fushell.dart"),
    });
    build_tool_mod.addAnonymousImport("fushell_sdk_readme", .{
        .root_source_file = b.path("packages/fushell/README.md"),
    });
    const build_tool = b.addExecutable(.{
        .name = "fushell",
        .root_module = build_tool_mod,
        .use_llvm = true,
    });

    b.installArtifact(exe);
    b.installArtifact(build_tool);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run fushell-runner (plays the bundle in its own directory)");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    const build_tool_unit_tests = b.addTest(.{ .root_module = build_tool_mod });
    const run_build_tool_unit_tests = b.addRunArtifact(build_tool_unit_tests);
    test_step.dependOn(&run_build_tool_unit_tests.step);
}

/// 检查引擎 .so 是否存在, 缺失时给明确指引 (先构建对应引擎) 并退出。
fn checkEngineSo(b: *std.Build, path: []const u8, mode_name: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const exists = if (std.fs.path.isAbsolute(path))
        (std.Io.Dir.accessAbsolute(io, path, .{}) catch null) != null
    else blk: {
        const cwd = std.process.currentPathAlloc(io, b.allocator) catch break :blk false;
        defer b.allocator.free(cwd);
        const abs = std.fs.path.join(b.allocator, &.{ cwd, path }) catch break :blk false;
        defer b.allocator.free(abs);
        break :blk (std.Io.Dir.accessAbsolute(io, abs, .{}) catch null) != null;
    };
    if (!exists) {
        std.debug.print(
            \\error: Flutter engine shared library not found: {s}
            \\  Build it first: zig build build-engine-{s}
            \\  (or override with -Dflutter-engine-{s}-so=<path>)
            \\
        , .{ path, mode_name, mode_name });
        std.process.exit(1);
    }
}

fn linkRuntimeLibraries(module: *std.Build.Module, options: std.Build.Module.LinkSystemLibraryOptions) void {
    module.linkSystemLibrary("wayland-client", options);
    module.linkSystemLibrary("wayland-egl", options);
    module.linkSystemLibrary("EGL", options);
    module.linkSystemLibrary("GLESv2", options);
    module.linkSystemLibrary("xkbcommon", options);
    module.linkSystemLibrary("fontconfig", options);
    module.linkSystemLibrary("dl", options);
}

fn linkTranslateCLibraries(translate_c: *std.Build.Step.TranslateC, options: std.Build.Module.LinkSystemLibraryOptions) void {
    translate_c.linkSystemLibrary("wayland-client", options);
    translate_c.linkSystemLibrary("wayland-egl", options);
    translate_c.linkSystemLibrary("EGL", options);
    translate_c.linkSystemLibrary("GLESv2", options);
    translate_c.linkSystemLibrary("fontconfig", options);
}
