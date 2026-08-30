#!/usr/bin/env bash
set -euo pipefail

source_root="${FUSHELL_SOURCE_ROOT:-$PWD}"
if [[ ! -f "$source_root/flake.nix" ]]; then
  echo "error: run build-local from the Fushell repository or set FUSHELL_SOURCE_ROOT" >&2
  exit 2
fi
source_root="$(realpath "$source_root")"

workspace=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  workspace="$1"
  shift
else
  workspace="${FLUTTER_ENGINE_DIR:-}"
fi
if [[ -z "$workspace" && -f "$source_root/flutter_engine_dir" ]]; then
  workspace="$(<"$source_root/flutter_engine_dir")"
fi
if [[ -z "$workspace" ]]; then
  echo "error: set FLUTTER_ENGINE_DIR or create flutter_engine_dir" >&2
  exit 2
fi
if [[ "$workspace" != /* ]]; then
  workspace="$source_root/$workspace"
fi
workspace="$(realpath "$workspace")"

case "$(uname -m)" in
x86_64) engine_arch=x64 ;;
aarch64) engine_arch=arm64 ;;
*)
  echo "error: unsupported host architecture: $(uname -m)" >&2
  exit 2
  ;;
esac

export FUSHELL_NIX_SOURCE_ROOT="$source_root"
export FUSHELL_NIX_ENGINE_DEBUG="$workspace/engine/src/out/linux_debug_$engine_arch/libflutter_engine.so"
export FUSHELL_NIX_ENGINE_PROFILE="$workspace/engine/src/out/linux_profile_$engine_arch/libflutter_engine.so"
export FUSHELL_NIX_ENGINE_RELEASE="$workspace/engine/src/out/linux_release_$engine_arch/libflutter_engine.so"

for artifact in \
  "$FUSHELL_NIX_ENGINE_DEBUG" \
  "$FUSHELL_NIX_ENGINE_PROFILE" \
  "$FUSHELL_NIX_ENGINE_RELEASE"; do
  if [[ ! -f "$artifact" ]]; then
    echo "error: missing Flutter engine artifact: $artifact" >&2
    exit 2
  fi
done

nix build --impure --expr '
  let
    sourceRoot = builtins.getEnv "FUSHELL_NIX_SOURCE_ROOT";
    flake = builtins.getFlake ("path:" + sourceRoot);
    pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
    importArtifact = name: variable:
      builtins.path {
        path = builtins.toPath (builtins.getEnv variable);
        inherit name;
      };
  in
    flake.lib.mkFushell {
      inherit pkgs;
      engineArtifacts = {
        debug = importArtifact "fushell-flutter-engine-debug.so" "FUSHELL_NIX_ENGINE_DEBUG";
        profile = importArtifact "fushell-flutter-engine-profile.so" "FUSHELL_NIX_ENGINE_PROFILE";
        release = importArtifact "fushell-flutter-engine-release.so" "FUSHELL_NIX_ENGINE_RELEASE";
      };
      zigDeps = flake.packages.${builtins.currentSystem}.zig-deps;
    }
' "$@"
