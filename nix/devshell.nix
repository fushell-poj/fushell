{
  lib,
  writeScriptBin,
  pkg-config,
  curl,
  zig,
  zls,
  mkShell,
  clang,
  lldb,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  mesa,
  libGL,
  zlib,
  fontconfig,
  freetype,
  dbus,
  stdenv,
  flutter,
  writeShellScriptBin,
  ...
}: let
  # Zig's Clang driver rejects some flags emitted by distro .pc files.
  custom-pkg-config = writeScriptBin "pkg-config" ''
    #!/usr/bin/env bash
    exec ${pkg-config}/bin/pkg-config "$@" | sed 's/-mfpmath=sse//g'
  '';

  # Match the local mika-shell ergonomics: keep useful colors while hiding noisy
  # "failed command" lines from common Zig build invocations.
  wrap-zig = writeScriptBin "zig" ''
    #!/usr/bin/env bash

    if [ "$#" -eq 0 ]; then
      exec ${zig}/bin/zig
    fi

    cmd="$1"
    shift

    case "$cmd" in
      build|build-exe|build-lib|build-obj|test|run|translate-c)
        exec ${zig}/bin/zig "$cmd" --color on "$@" \
          2> >(sed '/failed command:/d' >&2)
        ;;
      *)
        exec ${zig}/bin/zig "$cmd" "$@" \
          2> >(sed '/failed command:/d' >&2)
        ;;
    esac
  '';

  generate-nix-deps = writeShellScriptBin "generate-nix-deps" ''
    set -euo pipefail
    tmp=$(mktemp ./deps.nix.XXXXXXXX)
    trap 'rm -f -- "$tmp"' EXIT
    nix run github:nix-community/zon2nix > "$tmp"
    mv -- "$tmp" deps.nix
  '';
in
  mkShell {
    packages = [
      custom-pkg-config
      pkg-config
      curl
      wrap-zig
      zig
      zls
      clang
      lldb
      generate-nix-deps

      wayland
      wayland-protocols
      wayland-scanner
      libxkbcommon
      mesa
      libGL
      zlib
      fontconfig
      freetype
      dbus
      stdenv.cc.cc.lib
      flutter
    ];

    FUSHELL_NIX_FLUTTER_SDK = "${flutter}";
    FUSHELL_WAYLAND_PROTOCOLS = "${wayland-protocols}/share/wayland-protocols";

    shellHook = ''
      export PATH="$PATH:$PWD/zig-out/bin"
      export FLUTTER_SDK="''${FLUTTER_SDK:-$FUSHELL_NIX_FLUTTER_SDK}"
      export FUSHELL_NIX_LIBRARY_PATH="${lib.makeLibraryPath [
        wayland
        libxkbcommon
        mesa
        libGL
        zlib
        fontconfig
        freetype
        dbus
        stdenv.cc.cc.lib
      ]}"
      export LD_LIBRARY_PATH="$FUSHELL_NIX_LIBRARY_PATH:''${LD_LIBRARY_PATH:-}"
      echo "fushell dev shell"
      echo "  zig: $(zig version)"
      echo "  wayland protocols: $FUSHELL_WAYLAND_PROTOCOLS"
      echo "  FLUTTER_SDK: ''${FLUTTER_SDK:-<unset>}"
    '';
  }
