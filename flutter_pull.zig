//! `zig build pull-flutter` 的实现:将 Flutter 引擎源码树拉取到工作区。
//!
//! 拉取机制 (Spike 结论, 2026-08):
//! - 官方机制 gclient 负责一切 (monorepo + DEPS 依赖 + CIPD 工具链)。
//! - managed:true 模式已实测可用: gclient sync 自行 clone 主仓库、按 revision
//!   checkout (通过 --revision 参数, gclient 不读 .gclient 的 revision 字段),
//!   再拉取 DEPS 依赖与 CIPD 工具链。
//! - 工作区需预先存在 (手动创建或符号链接到大分区), 由 build.zig 解析
//!   (-Dflutter-workspace / FLUTTER_ENGINE_DIR / flutter_engine_dir 文件) 并校验。
//! - 环境要求: git 需信任工作区 (NTFS 等无属主概念的分区需配置 safe.directory)。
//! - githooks 的 post-checkout 依赖 vpython3 + dart-sdk 特定路径 (本环境不可用),
//!   对构建无用途, sync 前后清理 core.hooksPath。

const std = @import("std");
const support = @import("build_support.zig");

const gclient_url = "https://github.com/flutter/flutter.git";

/// gclient sync 并行度: 过高会触发 googlesource HTTP 429 限流 (实测 -j 12 被限)。
const gclient_jobs = "4";

const prefix = "[flutter-pull]";

pub const PullFlutter = struct {
    step: std.Build.Step,
    workspace: []const u8,

    pub fn create(b: *std.Build, workspace: []const u8) *PullFlutter {
        const self = b.allocator.create(PullFlutter) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "flutter-pull",
                .owner = b,
                .makeFn = make,
            }),
            .workspace = workspace,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const self: *PullFlutter = @fieldParentPtr("step", step);
        const allocator = options.gpa;
        // zig 0.16: step.owner.graph.io 自带完整环境, spawn 可解析 PATH (gclient/git)。
        const io = step.owner.graph.io;

        // 相对路径基于当前目录解析为绝对路径
        const workspace = try support.resolveWorkspace(io, allocator, self.workspace);
        std.debug.print("{s} workspace: {s}\n", .{ prefix, workspace });
        std.debug.print("{s} engine commit: {s}\n", .{ prefix, support.engine_commit });

        // 1. 工作区必须已存在: 目录太大, 不自动创建。
        if ((std.Io.Dir.accessAbsolute(io, workspace, .{}) catch null) == null) {
            std.debug.print(
                \\
                \\{s} error: workspace does not exist: {s}
                \\  The Flutter engine source tree is large; fushell will not create it automatically.
                \\  Create it manually, e.g.:
                \\    mkdir -p {s}
                \\  or symlink it to a big partition:
                \\    ln -s /disk/data/fushell-engine {s}
                \\
            , .{ prefix, workspace, workspace, workspace });
            return error.WorkspaceMissing;
        }

        // 2. gclient 前置检查 (spawn 探测; 0.16 spawn 对 PATH 中不存在的
        //    命令返回 FileNotFound 或 OutOfMemory, 两者都视为未安装)
        probeGclient(io) catch |err| switch (err) {
            error.FileNotFound, error.OutOfMemory => {
                std.debug.print(
                    \\
                    \\{s} error: gclient not found in PATH.
                    \\  Install depot_tools and add it to PATH, e.g.:
                    \\    git clone https://chromium.googlesource.com/chromium/tools/depot_tools
                    \\    export PATH="$PWD/depot_tools:$PATH"
                    \\  or enter the fushell devshell (nix develop), which provides depot_tools.
                    \\
                , .{prefix});
                return error.GclientNotFound;
            },
            else => {
                std.debug.print("{s} gclient probe failed: {s}\n", .{ prefix, @errorName(err) });
                return err;
            },
        };

        // 3. 主仓库: 有效 git 仓库的标志是 .git/HEAD 存在 (空/损坏的 .git 不算)。
        const git_head = try std.fs.path.join(allocator, &.{ workspace, ".git/HEAD" });
        defer allocator.free(git_head);
        const git_ok = (std.Io.Dir.accessAbsolute(io, git_head, .{}) catch null) != null;

        const git_dir = try std.fs.path.join(allocator, &.{ workspace, ".git" });
        defer allocator.free(git_dir);
        const git_dir_exists = (std.Io.Dir.accessAbsolute(io, git_dir, .{}) catch null) != null;
        if (git_dir_exists and !git_ok) {
            std.debug.print(
                \\
                \\{s} error: {s} exists but is not a valid git repository
                \\  (likely an interrupted clone). Remove it manually, e.g.:
                \\    rm -rf {s}
                \\  then re-run pull-flutter.
                \\
            , .{ prefix, git_dir, git_dir });
            return error.InvalidGitState;
        }

        // 4. 生成 .gclient (幂等: 内容一致则跳过)
        //    custom_vars: 关闭 fuchsia (默认 linux-x64 为 True, 会拉 fuchsia 依赖
        //    且其 hooks 需要 vpython3)。版本对齐靠 sync 的 --revision 参数。
        const gclient_content = try std.fmt.allocPrint(allocator,
            \\solutions = [
            \\  {{
            \\    "name": ".",
            \\    "url": "{s}",
            \\    "deps_file": "DEPS",
            \\    "managed": True,
            \\    "custom_vars": {{
            \\      "download_fuchsia_deps": False,
            \\    }},
            \\  }},
            \\]
            \\
        , .{gclient_url});
        defer allocator.free(gclient_content);

        const gclient_path = try std.fs.path.join(allocator, &.{ workspace, ".gclient" });
        defer allocator.free(gclient_path);
        try support.writeIfChanged(io, prefix, gclient_path, gclient_content);

        // 5. 清理 githooks: post-checkout 等 hook 依赖 vpython3 + dart-sdk
        //    特定路径 (本环境不可用), 对构建引擎无用途。core.hooksPath 由
        //    sync 的 "Setup githooks" hook 设置, 所以 sync 前后各清一次。
        try unsetHooksPath(io, allocator, workspace);

        // 6. gclient sync: --revision 在拉取时对齐 HEAD 到钉住 commit,
        //    依赖按该 commit 的 DEPS 拉取 (gclient 不读 .gclient 的 revision 字段)。
        std.debug.print("{s} running gclient sync\n", .{prefix});
        try support.run(io, allocator, prefix, workspace, &.{
            "gclient", "sync", "-j", gclient_jobs, "--revision", support.engine_commit,
        });

        // sync 的 "Setup githooks" 会重设 core.hooksPath, 再清一次。
        try unsetHooksPath(io, allocator, workspace);

        // 7. HEAD 兜底对齐 (--revision 应已生效, 此处确保)
        try support.run(io, allocator, prefix, workspace, &.{ "git", "checkout", support.engine_commit });

        // 8. 诊断输出
        std.debug.print(
            \\
            \\{s} done.
            \\  workspace: {s}
            \\  engine commit: {s}
            \\  下一步: 引擎编译: zig build build-engine
            \\
        , .{ prefix, workspace, support.engine_commit });
    }
};

/// 移除 core.hooksPath (git config --unset 在键不存在时返回非零, 忽略之)。
fn unsetHooksPath(io: std.Io, allocator: std.mem.Allocator, workspace: []const u8) !void {
    support.run(io, allocator, prefix, workspace, &.{ "git", "config", "--unset", "core.hooksPath" }) catch |err| switch (err) {
        error.CommandFailed => {}, // 未设置过, 无需清理
        else => return err,
    };
}

/// 探测 gclient 是否可用: 运行 `gclient --version`, 失败则报错 (含 FileNotFound)。
/// 输出丢弃 (gclient --version 会打印 usage, 官方行为, 无需展示)。
fn probeGclient(io: std.Io) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "gclient", "--version" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.GclientProbeFailed,
        else => return error.GclientProbeFailed,
    }
}
