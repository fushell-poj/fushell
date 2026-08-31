{
  lib,
  stdenv,
  buildEnv,
  runCommand,
  zig,
  pkg-config,
  patchelf,
  makeWrapper,
  removeReferencesTo,
  wayland,
  wayland-scanner,
  libxkbcommon,
  mesa,
  libGL,
  zlib,
  fontconfig,
  freetype,
  dbus,
  flutter,
}:
{
  engineArtifacts,
  zigDeps,
  version ? "0.1.0",
}:
assert lib.assertMsg (engineArtifacts ? revision)
  "mkFushell requires engineArtifacts.revision";
assert lib.assertMsg (engineArtifacts ? debug && engineArtifacts ? profile && engineArtifacts ? release)
  "mkFushell requires engineArtifacts.debug, engineArtifacts.profile, and engineArtifacts.release";
assert lib.assertMsg (builtins.isString engineArtifacts.revision && builtins.match "[0-9a-f]{40}" engineArtifacts.revision != null)
  "mkFushell requires engineArtifacts.revision to be 40 lowercase hexadecimal characters";
assert lib.assertMsg (flutter ? engineVersion)
  "mkFushell requires the selected Flutter package to expose engineVersion";
assert lib.assertMsg (engineArtifacts.revision == flutter.engineVersion)
  "mkFushell engine artifact revision ${engineArtifacts.revision} does not match Flutter SDK engine revision ${flutter.engineVersion}";
let
  root = ../.;
  engineRevision = engineArtifacts.revision;
  engineArtifactValidator = ./validate-engine-artifacts.sh;
  glibcVersion = lib.versions.majorMinor stdenv.cc.libc.version;
  runtimeLibraryLinks = buildEnv {
    name = "fushell-runtime-library-links";
    paths = [
      wayland
      libxkbcommon
      libGL
      fontconfig.lib
      dbus.lib
    ];
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };
  runtimeLibraries = runCommand "fushell-runtime-libraries" { } ''
    mkdir -p "$out/lib"
    for library in ${runtimeLibraryLinks}/lib/*.so*; do
      cp -L --no-clobber "$library" "$out/lib/$(basename "$library")"
    done
  '';
  source = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../build_support.zig
      ../engine_build.zig
      ../flutter_pull.zig
      ../src
      ../packages/fushell
    ];
  };
  zigCacheSetup = ''
    export HOME="$TMPDIR/home"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
    export PKG_CONFIG_PATH="${wayland-scanner.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    mkdir -p "$HOME" "$XDG_CACHE_HOME" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "fushell";
  inherit version;
  src = source;

  inherit zigDeps;

  strictDeps = true;
  # Zig 0.16 的 translate-c 尚不能正确翻译 glibc fortify 包装器中的布尔表达式。
  hardeningDisable = [ "fortify" ];
  nativeBuildInputs = [
    zig
    pkg-config
    patchelf
    makeWrapper
    removeReferencesTo
    wayland-scanner
    wayland-scanner.dev
  ];
  buildInputs = [
    wayland
    libxkbcommon
    mesa
    libGL
    zlib
    fontconfig.dev
    fontconfig.lib
    freetype
    dbus.dev
    dbus.lib
    stdenv.cc.cc.lib
  ];

  zigBuildFlags = [
    "--system"
    zigDeps
    "-Doptimize=ReleaseFast"
    "-Dstrip=true"
    "-Drunner-interpreter=${stdenv.cc.bintools.dynamicLinker}"

    "-Dtarget=${
      if stdenv.hostPlatform.isx86_64
      then "x86_64-linux-gnu.${glibcVersion}"
      else if stdenv.hostPlatform.isAarch64
      then "aarch64-linux-gnu.${glibcVersion}"
      else throw "Fushell does not support ${stdenv.hostPlatform.system}"
    }"
    "-Dflutter-engine-debug-so=${engineArtifacts.debug}"
    "-Dflutter-engine-profile-so=${engineArtifacts.profile}"
    "-Dflutter-engine-release-so=${engineArtifacts.release}"
    "-Ddbus-lib-dir=${dbus.lib}/lib"
  ];

  buildPhase = ''
    runHook preBuild
    ${zigCacheSetup}
    bash ${engineArtifactValidator} \
      ${lib.escapeShellArg engineRevision} \
      ${lib.escapeShellArg (toString engineArtifacts.debug)} \
      ${lib.escapeShellArg (toString engineArtifacts.profile)} \
      ${lib.escapeShellArg (toString engineArtifacts.release)}
    zig build ${lib.escapeShellArgs finalAttrs.zigBuildFlags}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    ${zigCacheSetup}
    zig build install --prefix "$out" ${lib.escapeShellArgs finalAttrs.zigBuildFlags}
    runHook postInstall
  '';

  postInstall = ''
    patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} "$out/bin/fushell"
    remove-references-to -t ${zig} -t ${source} "$out/bin/fushell"
    rm "$out/bin/fushell-runner"

    wrapProgram "$out/bin/fushell" \
      --set-default FLUTTER_ROOT ${flutter} \
      --set FUSHELL_RUNTIME_LIBS ${runtimeLibraries} \
      --prefix PATH : ${lib.makeBinPath [ flutter ]} \
      --prefix LD_LIBRARY_PATH : ${runtimeLibraries}/lib:/run/opengl-driver/lib
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    cli="$out/bin/.fushell-wrapped"
    test -x "$cli"
    test ! -e "$out/bin/fushell-runner"

    interpreter="$(patchelf --print-interpreter "$cli")"
    case "$interpreter" in
      /nix/store/*/lib/ld-linux*.so.*) ;;
      *)
        echo "error: unexpected fushell interpreter: $interpreter" >&2
        exit 1
        ;;
    esac

    rpath="$(patchelf --print-rpath "$cli")"
    if printf '%s\n' "$rpath" | grep -E '(/home/|/tmp/|/build/source)' >/dev/null; then
      echo "error: fushell RUNPATH contains a development path: $rpath" >&2
      exit 1
    fi
    if grep -aF '${source}' "$cli" >/dev/null; then
      echo "error: fushell retains a reference to its source tree" >&2
      exit 1
    fi

    "$out/bin/fushell" help >/dev/null
    runHook postInstallCheck
  '';

  passthru = {
    inherit engineArtifacts engineRevision runtimeLibraries;
  };

  meta = {
    description = "Flutter multi-view Wayland shell and application bundler";
    homepage = "https://github.com/HumXC/fushell";
    license = lib.licenses.mit;
    mainProgram = "fushell";
    platforms = lib.platforms.linux;
  };
})
