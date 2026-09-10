const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const strip = b.option(bool, "strip", "Strip installed and embedded executables") orelse false;
    const optimize = b.standardOptimizeOption(.{});

    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("clap", clap.module("clap"));

    const c_header = b.path("src/fushell_c_bindings.h");

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
    translate_c.defineCMacro("FUSHELL_TRANSLATE_C", "1");
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
    exe_mod.linkSystemLibrary("dbus-1", dynamic_link_opts);

    const scanner = Scanner.create(b, .{
        // Custom protocols are added explicitly below, so this only satisfies
        // zig-wayland's scanner configuration shape.
        .wayland_protocols = b.path("."),
    });
    const wayland_protocols = b.dependency("wayland-protocols", .{});
    scanner.addCustomProtocol(wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"));
    scanner.addCustomProtocol(wayland_protocols.path("stable/viewporter/viewporter.xml"));
    scanner.addCustomProtocol(wayland_protocols.path("staging/fractional-scale/fractional-scale-v1.xml"));
    scanner.addCustomProtocol(wayland_protocols.path("staging/cursor-shape/cursor-shape-v1.xml"));
    // cursor-shape manager v2 的 XML 含 tablet_tool_v2 参数；即使客户端仅绑定
    // manager v1，zig-wayland 仍需该类型才能生成完整接口表。
    scanner.addCustomProtocol(wayland_protocols.path("unstable/tablet/tablet-unstable-v2.xml"));
    const wlr_protocols = b.dependency("wlr-protocols", .{});
    scanner.addCustomProtocol(wlr_protocols.path("unstable/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(wlr_protocols.path("unstable/wlr-data-control-unstable-v1.xml"));
    scanner.addCustomProtocol(wayland_protocols.path("unstable/text-input/text-input-unstable-v3.xml"));
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 8);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);
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
        .name = "fushell-runner",
        .root_module = exe_mod,
        .use_llvm = true,
    });
    // Embed the emitted runner; system library/loader policy belongs to packaging.
    const runner_bin = exe.getEmittedBin();

    const build_tool_mod = b.createModule(.{
        .root_source_file = b.path("src/fushell.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });

    // fushell run: 进程内播放 (player.zig → flutter_runner → c/wayland/EGL)
    build_tool_mod.addImport("cli", cli_mod);
    build_tool_mod.addImport("c", c_mod);
    build_tool_mod.addImport("wayland", wayland_mod);
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

    // runner 可执行文件内嵌进 fushell CLI: 打包时写出为 bundle 入口
    // (getEmittedBin LazyPath, 构建顺序自动: runner 先编译)
    build_tool_mod.addAnonymousImport("fushell_runner_bin", .{
        .root_source_file = runner_bin,
    });
    // fushell SDK 包文件内嵌: `fushell sdk` 释放给外部项目
    build_tool_mod.addAnonymousImport("fushell_sdk_pubspec", .{
        .root_source_file = b.path("packages/fushell/pubspec.yaml"),
    });
    build_tool_mod.addAnonymousImport("fushell_sdk_lib", .{
        .root_source_file = b.path("packages/fushell/lib/fushell.dart"),
    });
    inline for (.{ "tray", "src/tray/host", "src/tray/item", "src/tray/menu", "src/tray/watcher" }) |file| {
        build_tool_mod.addAnonymousImport("fushell_sdk_" ++ file, .{
            .root_source_file = b.path("packages/fushell/lib/" ++ file ++ ".dart"),
        });
    }
    build_tool_mod.addAnonymousImport("fushell_sdk_readme", .{
        .root_source_file = b.path("packages/fushell/README.md"),
    });
    const build_tool = b.addExecutable(.{
        .name = "fushell",
        .root_module = build_tool_mod,
        .use_llvm = true,
    });

    b.installArtifact(build_tool);

    const run_cmd = b.addRunArtifact(build_tool);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the fushell CLI");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const cli_tests = b.addTest(.{ .root_module = cli_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const cli_test_step = b.step("cli-test", "Test command parsing and help without Flutter or a display");
    cli_test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(cli_test_step);
    for ([_][]const u8{ "flutter_engine_store", "owned_arguments", "process_exit", "bundle_transaction", "flutter_toolchain", "source_snapshot" }) |name| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    const build_tool_unit_tests = b.addTest(.{ .root_module = build_tool_mod });
    const run_build_tool_unit_tests = b.addRunArtifact(build_tool_unit_tests);
    test_step.dependOn(&run_build_tool_unit_tests.step);

    const output_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/application_output.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const output_transport_tests = b.addTest(.{ .root_module = output_transport_mod });
    const run_output_transport_tests = b.addRunArtifact(output_transport_tests);
    test_step.dependOn(&run_output_transport_tests.step);

    const output_sink_mod = b.createModule(.{
        .root_source_file = b.path("src/output_sink_helper.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const output_sink_tests = b.addTest(.{ .root_module = output_sink_mod });
    const run_output_sink_tests = b.addRunArtifact(output_sink_tests);
    test_step.dependOn(&run_output_sink_tests.step);

    const retained_signal_mod = b.createModule(.{
        .root_source_file = b.path("src/retained_signal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const retained_signal_tests = b.addTest(.{ .root_module = retained_signal_mod });
    const run_retained_signal_tests = b.addRunArtifact(retained_signal_tests);
    test_step.dependOn(&run_retained_signal_tests.step);

    const broker_test_mod = b.createModule(.{
        .root_source_file = b.path("src/application_broker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    broker_test_mod.addImport("c", c_mod);
    broker_test_mod.linkSystemLibrary("dbus-1", dynamic_link_opts);
    const broker_tests = b.addTest(.{ .root_module = broker_test_mod });
    const run_broker_tests = b.addRunArtifact(broker_tests);
    test_step.dependOn(&run_broker_tests.step);

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
    const run_native_v2_fixture = b.addSystemCommand(&.{
        "bash",
        "tests/native_v2_fixture.sh",
    });
    run_native_v2_fixture.step.dependOn(&build_singleton_fixture.step);
    const native_v2_fixture_test_step = b.step(
        "native-v2-fixture-test",
        "Run the no-EGL private D-Bus V2 fixture",
    );
    native_v2_fixture_test_step.dependOn(&run_native_v2_fixture.step);

    const integration_test_step = b.step(
        "integration-test",
        "Run the native V2 fixture and real two-process singleton integration tests",
    );
    integration_test_step.dependOn(&run_single_instance_integration.step);
    integration_test_step.dependOn(&run_native_v2_fixture.step);
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
