const std = @import("std");
const Scanner = @import("wayland").Scanner;
const flutter_pull = @import("flutter_pull.zig");
const engine_build = @import("engine_build.zig");
const build_support = @import("build_support.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const runner_interpreter = b.option([]const u8, "runner-interpreter", "ELF interpreter written into installed and embedded runners");
    const strip = b.option(bool, "strip", "Strip installed and embedded executables") orelse false;
    const optimize = b.standardOptimizeOption(.{});

    const io = b.graph.io;
    const workspace_option = b.option([]const u8, "flutter-workspace", "Flutter engine workspace path (or FLUTTER_ENGINE_DIR, or ./flutter_engine_dir)");
    const engine_debug_option = b.option([]const u8, "flutter-engine-debug-so", "Path to the debug (JIT) Flutter engine shared library");
    const engine_profile_option = b.option([]const u8, "flutter-engine-profile-so", "Path to the profile (AOT+profiling) Flutter engine shared library");
    const engine_release_option = b.option([]const u8, "flutter-engine-release-so", "Path to the release (AOT) Flutter engine shared library");
    const has_explicit_engines = engine_debug_option != null and engine_profile_option != null and engine_release_option != null;

    // Nix derivation 将三种 engine artifact 作为独立 store 输入传入，此时不应要求
    // 仅用于源码管理的 Flutter workspace。只要有一种 artifact 未显式提供，就继续
    // 要求完整 workspace，避免部分模式悄悄回退到开发机路径。
    const flutter_workspace: ?[]const u8 = if (has_explicit_engines) null else build_support.resolveWorkspaceConfig(io, b.allocator, workspace_option) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // 源码管理与 engine 编译步骤只在 workspace 模式下存在。显式 artifact 模式只
    // 消费预构建输入，不能宣称支持 pull/build engine。
    if (flutter_workspace) |workspace| {
        const pull_flutter = flutter_pull.PullFlutter.create(b, workspace);
        const pull_flutter_step = b.step("pull-flutter", "Fetch the Flutter engine source tree into the workspace via gclient");
        pull_flutter_step.dependOn(&pull_flutter.step);

        const no_lto = b.option(bool, "no-lto", "Pass --no-lto to gn (faster first build, slower binaries; release only)") orelse false;
        const build_engine_release = engine_build.BuildEngine.create(b, workspace, no_lto, .release);
        const build_engine_release_step = b.step("build-engine-release", "Build the release (AOT) Flutter engine in the workspace");
        build_engine_release_step.dependOn(&build_engine_release.step);
        const build_engine_profile = engine_build.BuildEngine.create(b, workspace, no_lto, .profile);
        const build_engine_profile_step = b.step("build-engine-profile", "Build the profile (AOT + profiling) Flutter engine in the workspace");
        build_engine_profile_step.dependOn(&build_engine_profile.step);
        const build_engine_debug = engine_build.BuildEngine.create(b, workspace, no_lto, .debug);
        const build_engine_debug_step = b.step("build-engine-debug", "Build the debug (JIT) Flutter engine in the workspace");
        build_engine_debug_step.dependOn(&build_engine_debug.step);
    }

    // 三个引擎 .so 全部内嵌进 fushell CLI (打包时按模式选)。
    const flutter_engine_debug_so = engine_debug_option orelse
        b.pathJoin(&.{ flutter_workspace.?, "engine/src/out/linux_debug_x64/libflutter_engine.so" });
    const flutter_engine_profile_so = engine_profile_option orelse
        b.pathJoin(&.{ flutter_workspace.?, "engine/src/out/linux_profile_x64/libflutter_engine.so" });
    const flutter_engine_release_so = engine_release_option orelse
        b.pathJoin(&.{ flutter_workspace.?, "engine/src/out/linux_release_x64/libflutter_engine.so" });

    // 存在性检查: 缺失时给明确指引 (而不是 @embedFile 的裸错误)
    checkEngineSo(b, flutter_engine_debug_so, "debug");
    checkEngineSo(b, flutter_engine_profile_so, "profile");
    checkEngineSo(b, flutter_engine_release_so, "release");

    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };
    const dbus_lib_dir = b.option([]const u8, "dbus-lib-dir", "Directory containing libdbus-1.so.3") orelse
        b.graph.environ_map.get("FUSHELL_DBUS_LIB_DIR") orelse {
        std.debug.print("error: D-Bus runtime not configured; enter `nix develop` or pass -Ddbus-lib-dir=<path>\n", .{});
        std.process.exit(1);
    };
    const dbus_runtime_so = b.pathJoin(&.{ dbus_lib_dir, "libdbus-1.so.3" });
    checkRuntimeFile(b, dbus_runtime_so, "D-Bus runtime");

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
        \\#include <dbus/dbus.h>
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
    // Zig 0.16 的 translate-c 会把 glibc fortify 包装器里的比较表达式翻译成
    // bool，但 std 的 object_size builtin 仍要求 c_int；显式关闭仅影响头文件翻译，
    // 不改变 Zig 代码的 ReleaseSafe 检查或最终链接器加固。
    translate_c.defineCMacro("_FORTIFY_SOURCE", "0");
    linkTranslateCLibraries(translate_c, dynamic_link_opts);
    const c_mod = translate_c.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    exe_mod.addImport("c", c_mod);
    exe_mod.addLibraryPath(.{ .cwd_relative = dbus_lib_dir });

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
    // Packaged app runners resolve bundled runtime libraries before system paths.
    exe_mod.addRPathSpecial("$ORIGIN/lib");

    const exe = b.addExecutable(.{
        // pi-lens-ignore: zls
        .name = "fushell-runner",
        .root_module = exe_mod,
        .use_llvm = true,
    });
    // NixOS bundle 不能依赖事后的 install fixup：CLI 会在编译期内嵌 runner。
    // 因此先复制并修补 emitted binary，再同时用于安装和 @embedFile。
    const runner_bin = if (runner_interpreter) |interpreter| blk: {
        const patch_runner = b.addSystemCommand(&.{
            "sh",
            "-c",
            "set -eu; cp \"$1\" \"$2\"; chmod u+w \"$2\"; patchelf --set-interpreter \"$3\" \"$2\"",
            "_",
        });
        patch_runner.addFileArg(exe.getEmittedBin());
        const output = patch_runner.addOutputFileArg("fushell-runner");
        patch_runner.addArg(interpreter);
        break :blk output;
    } else exe.getEmittedBin();

    const build_tool_mod = b.createModule(.{
        .root_source_file = b.path("src/fushell.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    build_tool_mod.addImport("build_support", b.createModule(.{
        .root_source_file = b.path("build_support.zig"),
        .target = target,
        .optimize = optimize,
    }));
    // fushell run: 进程内播放 (player.zig → flutter_runner → c/wayland/EGL)
    build_tool_mod.addImport("c", c_mod);
    build_tool_mod.addImport("wayland", wayland_mod);
    build_tool_mod.addLibraryPath(.{ .cwd_relative = dbus_lib_dir });
    linkRuntimeLibraries(build_tool_mod, dynamic_link_opts);
    build_tool_mod.addRPathSpecial("$ORIGIN/../lib");
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
        .root_source_file = runner_bin,
    });
    build_tool_mod.addAnonymousImport("dbus_runtime", .{
        .root_source_file = .{ .cwd_relative = dbus_runtime_so },
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

    if (runner_interpreter != null) {
        const install_runner = b.addInstallFileWithDir(runner_bin, .bin, "fushell-runner");
        b.getInstallStep().dependOn(&install_runner.step);
    } else {
        b.installArtifact(exe);
    }
    b.installArtifact(build_tool);
    const install_dbus_runtime = b.addInstallFileWithDir(
        .{ .cwd_relative = dbus_runtime_so },
        .lib,
        "libdbus-1.so.3",
    );
    b.getInstallStep().dependOn(&install_dbus_runtime.step);

    const run_cmd = b.addRunArtifact(build_tool);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the fushell CLI");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    const build_tool_unit_tests = b.addTest(.{ .root_module = build_tool_mod });
    const run_build_tool_unit_tests = b.addRunArtifact(build_tool_unit_tests);
    test_step.dependOn(&run_build_tool_unit_tests.step);

    const build_singleton_fixture = b.addRunArtifact(build_tool);
    build_singleton_fixture.step.dependOn(b.getInstallStep());
    build_singleton_fixture.addArgs(&.{ "build", "--debug", "examples/singleton_app" });
    const run_single_instance_integration = b.addSystemCommand(&.{
        "bash",
        "tests/single_instance_integration.sh",
    });
    run_single_instance_integration.setEnvironmentVariable(
        "FUSHELL_SINGLE_INSTANCE_TEST_BUILT",
        "1",
    );
    run_single_instance_integration.step.dependOn(&build_singleton_fixture.step);
    const integration_test_step = b.step(
        "integration-test",
        "Run the single-instance D-Bus integration test",
    );
    integration_test_step.dependOn(&run_single_instance_integration.step);
}

/// 检查引擎 .so 是否存在, 缺失时给明确指引 (先构建对应引擎) 并退出。
fn checkRuntimeFile(b: *std.Build, path: []const u8, description: []const u8) void {
    const io = b.graph.io;
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
        std.debug.print("error: {s} not found: {s}\n", .{ description, path });
        std.process.exit(1);
    }
}

fn checkEngineSo(b: *std.Build, path: []const u8, mode_name: []const u8) void {
    const io = b.graph.io;
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
    module.linkSystemLibrary("dbus-1", options);
    module.linkSystemLibrary("dl", options);
}

fn linkTranslateCLibraries(translate_c: *std.Build.Step.TranslateC, options: std.Build.Module.LinkSystemLibraryOptions) void {
    translate_c.linkSystemLibrary("wayland-client", options);
    translate_c.linkSystemLibrary("wayland-egl", options);
    translate_c.linkSystemLibrary("EGL", options);
    translate_c.linkSystemLibrary("GLESv2", options);
    translate_c.linkSystemLibrary("fontconfig", options);
    translate_c.linkSystemLibrary("dbus-1", options);
}
