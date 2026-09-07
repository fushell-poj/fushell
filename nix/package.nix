{
  lib,
  stdenv,
  callPackage,
  zig,
  pkg-config,
  wayland,
  wayland-scanner,
  libxkbcommon,
  mesa,
  libGL,
  zlib,
  fontconfig,
  freetype,
  dbus,
  fetchzip,
}: let
  deps = callPackage ../deps.nix {
    fetchzip = args:
      fetchzip (
        args
        // lib.optionalAttrs
        (lib.hasSuffix "/linux-x64-embedder.zip" args.url)
        {
          stripRoot = false;
        }
      );
  };

  glibcVersion =
    lib.versions.majorMinor stdenv.cc.libc.version;

  target =
    if stdenv.hostPlatform.isx86_64
    then "x86_64-linux-gnu.${glibcVersion}"
    else if stdenv.hostPlatform.isAarch64
    then "aarch64-linux-gnu.${glibcVersion}"
    else throw "Unsupported system: ${stdenv.hostPlatform.system}";
in
  stdenv.mkDerivation {
    pname = "fushell";
    version = "0.1.0";

    src = ../.;

    nativeBuildInputs = [
      zig
      pkg-config
      wayland-scanner
    ];

    buildInputs = [
      wayland
      libxkbcommon
      mesa
      libGL
      zlib
      fontconfig
      freetype
      dbus
      stdenv.cc.cc.lib
    ];

    hardeningDisable = [
      "fortify"
    ];

    zigBuildFlags = [
      "--system"
      "${deps}"

      "-Doptimize=ReleaseFast"
      "-Dstrip=true"

      "-Dtarget=${target}"
    ];

    dontUseZigCheck = true;

    meta = {
      description = "Flutter multi-view Wayland shell";
      license = lib.licenses.mit;
      mainProgram = "fushell";
      platforms = lib.platforms.linux;
    };
  }
