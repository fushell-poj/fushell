# depot_tools 的 gclient 包装 (nixpkgs 无 depot_tools 包)。
#
# 官方 depot_tools 是 "clone 即用" 的脚本集, 其 bash 包装走 vpython
# (首次运行需下载 CIPD 虚拟环境, 本机网络下会静默失败)。本包绕开 vpython,
# 直接用 python3 调 gclient.py 入口, 并补上 .vpython3 锁定的依赖
# (httplib2 0.13.1, 带 socks 模块; nixpkgs 0.32 已移除)。
{
  fetchgit,
  fetchurl,
  fetchzip,
  python3,
  writeScriptBin,
  buildEnv,
  stdenv,
  ...
}: let
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromium/tools/depot_tools";
    rev = "fa1fac8477c70532274e7244777a846537004750";
    sha256 = "sha256-tu3VkneveuvnABAy1gm6+s2o6ye8FrBjQ3xf9svYMg4=";
  };
  # httplib2 0.13.1 (带 socks 模块, nixpkgs 0.32 已移除)。
  # fetchzip 解压后去掉顶层目录, $out 直接是 python3/ 与 python2/。
  httplib2 = fetchzip {
    url = "https://files.pythonhosted.org/packages/source/h/httplib2/httplib2-0.13.1.tar.gz";
    sha256 = "sha256-dXVqg8gqYzB31LcKwcyGzh3akV6qVkcOzEufw9AC9v0=";
  };
  # CIPD 客户端 (depot_tools/cipd 的 bootstrap 目标, 版本见 cipd_client_version)。
  # 用 CUSTOM_CIPD_CLIENT 钩子注入, 避免 bootstrap 写入只读的 nix store。
  cipd_client = stdenv.mkDerivation {
    pname = "cipd-client";
    version = "2947bd98";
    src = fetchurl {
      url = "https://chrome-infra-packages.appspot.com/client?platform=linux-amd64&version=git_revision:2947bd98a9c59d4f552df3a043c5883651448e0a";
      sha256 = "sha256-cKqUj1/wm1Xi94Aunkv4e/hc+SExgmScZKctWqPjOrw=";
    };
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      install -D -m755 $src $out/bin/cipd
    '';
  };
  gclient = writeScriptBin "gclient" ''
    #!/usr/bin/env bash
    export PYTHONPATH="${httplib2}/python3:${src}:$PYTHONPATH"
    # 注意: gclient 的 --version 输出 usage 是官方行为 (execute 不解析全局选项),
    # 此处仅用于探测 gclient 可用性 (exit 0 = 可用)。
    # 设置 sys.argv[0] 让 usage 显示 "gclient" 而非 python -c 的 "-c"。
    exec ${python3}/bin/python3 -c "import sys, gclient; sys.argv[0] = 'gclient'; sys.exit(gclient.main(sys.argv[1:]))" "$@"
  '';
  cipd = writeScriptBin "cipd" ''
    #!/usr/bin/env bash
    export CUSTOM_CIPD_CLIENT="${cipd_client}/bin/cipd"
    exec ${src}/cipd "$@"
  '';
  # vpython3: depot_tools 的虚拟 python 包装。工作区脚本 (githooks, flutter/tools/gn 等)
  # shebang 是 vpython3; 本包绕开 vpython 的 CIPD 虚拟环境, 直接映射到 python3。
  vpython3 = writeScriptBin "vpython3" ''
    #!/usr/bin/env bash
    export PYTHONPATH="${src}:$PYTHONPATH"
    exec ${python3}/bin/python3 "$@"
  '';
in
  buildEnv {
    name = "depot-tools";
    paths = [
      gclient
      cipd
      vpython3
    ];
  }
