{
  lib,
  stdenv,
  callPackage,
  zig,
  pkg-config,
  makeWrapper,
  curl,
  coreutils,
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
  assert lib.assertMsg (zig.version == "0.16.0") "Fushell requires Zig 0.16.0";
  stdenv.mkDerivation {
    pname = "fushell";
    version = "0.1.0";

    src = ../.;

    nativeBuildInputs = [
      zig
      pkg-config
      makeWrapper
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

    # Unit tests run in CI; graphical/integration fixtures are opt-in.
    dontUseZigCheck = true;

    postFixup = ''
      wrapProgram "$out/bin/fushell" \
        --prefix PATH : "${lib.makeBinPath [ curl coreutils ]}"
    '';

    meta = {
      description = "Flutter multi-view Wayland shell";
      license = lib.licenses.mit;
      mainProgram = "fushell";
      platforms = lib.platforms.linux;
    };
  }
