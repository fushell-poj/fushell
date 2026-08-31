# NixOS packaging

Fushell 将 NixOS 作为当前正式支持的发布环境。跨发行版的 portable bundle 和 Flatpak 不在本阶段范围内。

## 依赖模型

完整的 `fushell` CLI 会内嵌 debug、profile、release 三种 Flutter engine。`mkFushell` 因此要求调用方提供共同的 40 位小写 revision，以及三份已经进入 Nix store 的 `libflutter_engine.so`：

```nix
fushell.lib.mkFushell {
  inherit pkgs;
  engineArtifacts = {
    revision = pkgs.flutter.engineVersion;
    debug = debugEngine;
    profile = profileEngine;
    release = releaseEngine;
  };
}
```

`revision` 是必填字段；旧的三路径结构不会被兼容。`mkFushell` 在求值阶段要求它等于所选 Flutter package 的 `engineVersion`，并在运行 Zig 前确认每种模式的二进制都实际包含该完整 revision。这样，Nix store path 只能证明内容稳定而不能证明 Flutter ABI 来源的问题会在构建时显式暴露。

`mkFushell` 是纯 derivation：它不读取 `$HOME`、`/disk/data` 或其他 flake 外路径。Zig 依赖由仓库根目录的 `deps.nix` 固定；该文件使用 zon2nix 生成。

## 使用本地 engine workspace

开发机已有匹配 revision 的 Flutter engine workspace 时，可将三份产物导入 Nix store 后构建：

```bash
nix run .#build-local -- /path/to/flutter-engine
```

也可通过环境变量或本机路径文件提供 workspace：

```bash
FLUTTER_ENGINE_DIR=/path/to/flutter-engine nix run .#build-local
printf '%s\n' /path/to/flutter-engine > flutter_engine_dir
nix run .#build-local
```

helper 只在 impure 导入阶段读取该路径；最终 Fushell derivation 只接收 store path，并将 flake 选择的 `pkgs.flutter.engineVersion` 作为期望 revision。若任一 workspace artifact 来自其他 checkout 或旧构建，验证会在 Zig 编译前指出失败模式、期望 revision 和 store path；helper 不会自动重建或替换它。位置参数之后的其他参数会传给内层 `nix build`，例如 `--no-link`。
构建结果写入常规 `result` symlink：

```bash
./result/bin/fushell help
nix profile install ./result
```

## 打包应用

从 Nix package 启动的 `fushell build` 会把 Nix loader、Flutter engine 和物化后的运行库放入应用 bundle。生成的 runner 使用 `$ORIGIN/lib`，不会引用开发机的 `/home/...` 或构建工作区。

已有 bundle 可包装为 Nix package：

```nix
fushell.lib.mkFushellApp {
  inherit pkgs;
  pname = "my-app";
  bundle = myBundle;
  executableName = "my_app"; # 必须与 bundle 根目录中的可执行文件名一致
}
```

图形驱动仍由 NixOS 的 `/run/opengl-driver/lib` 提供；session D-Bus 由宿主会话提供。

用于部署的应用应优先构建 Profile 或 Release bundle。Debug/JIT bundle 会为 VM Service、热重载和源码定位保留 Dart 源码 URI；这些字符串不是 ELF 动态依赖，也不参与 Nix closure 解析。开发路径检查只约束 CLI、runner 和动态库的解释器、RUNPATH 与实际运行时引用。

## 更新 Zig 依赖

修改 `build.zig.zon` 后重新生成：

```bash
nix run github:nix-community/zon2nix > deps.nix
```

`deps.nix` 保持为未经手工修改的生成文件。Flutter 官方 `linux-x64-embedder.zip` 是平铺归档，而 zon2nix 当前不能输出 `stripRoot = false`；flake 在调用生成文件时仅对该 URL 注入对应的 `fetchzip` 参数，使 fresh store 能重建依赖且不影响其他归档。

随后验证：

```bash
nix flake check
```

未提交的新 Nix 文件不会进入 Git flake 视图；开发期间可使用 `nix flake check path:.`。
