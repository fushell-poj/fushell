{
  lib,
  stdenvNoCC,
  patchelf,
}:
{
  pname,
  version ? "0.1.0",
  bundle,
  executableName ? pname,
  meta ? { },
}:
stdenvNoCC.mkDerivation {
  inherit pname version;
  dontUnpack = true;
  nativeBuildInputs = [ patchelf ];

  installPhase = ''
    runHook preInstall
    app_dir="$out/libexec/${pname}"
    mkdir -p "$app_dir" "$out/bin"
    cp -R ${bundle}/. "$app_dir/"
    chmod -R u+w "$app_dir"
    test -x "$app_dir/${executableName}"
    ln -s "$app_dir/${executableName}" "$out/bin/${executableName}"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    runner="$out/libexec/${pname}/${executableName}"
    interpreter="$(patchelf --print-interpreter "$runner")"
    case "$interpreter" in
      /nix/store/*/lib/ld-linux*.so.*) ;;
      *)
        echo "error: application runner does not use a Nix store loader: $interpreter" >&2
        exit 1
        ;;
    esac
    rpath="$(patchelf --print-rpath "$runner")"
    if printf '%s\n' "$rpath" | grep -E '(/home/|/tmp/|/build/source)' >/dev/null; then
      echo "error: application RUNPATH contains a development path: $rpath" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  # Nix 的引用扫描会从复制后的 runner、Flutter engine 与运行库中保留完整
  # store closure；应用不需要也不应自行拼接 LD_LIBRARY_PATH。
  passthru = {
    inherit bundle;
  };

  meta = {
    description = "Fushell application ${pname}";
    platforms = lib.platforms.linux;
    mainProgram = executableName;
  } // meta;
}
