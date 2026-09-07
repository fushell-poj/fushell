#!/usr/bin/env bash
# Real Flutter scaffolding, YAML edit, analysis, UI tests and three-mode builds.
set -euo pipefail
binary=$(realpath "${1:-zig-out/bin/fushell}")
repo=$(pwd)
: "${FLUTTER_ROOT:?Set FLUTTER_ROOT to the initialized SDK}"
flutter="$FLUTTER_ROOT/bin/flutter"
dart="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
packages="$FLUTTER_ROOT/packages/flutter_tools/.dart_tool/package_config.json"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$dart" --packages="$packages" tests/create_pubspec_test.dart

for kind in multiple single; do
  target="$work/$kind"
  flags=()
  if [[ $kind == single ]]; then flags+=(--single-instance); fi
  "$binary" create --no-pub "${flags[@]}" "$target"
  test ! -e "$target/linux"
  test ! -e "$target/pubspec.lock"
  test -s "$target/.gitignore"
  test -s "$target/vendor/fushell/lib/fushell.dart"
  (
    cd "$target"
    "$flutter" pub get
    "$flutter" analyze --no-pub
    "$flutter" test --no-pub
    git init -q
    git check-ignore --no-index build/a linux/flutter/ephemeral/a linux/flutter/generated_plugin_registrant.cc linux/flutter/generated_plugins.cmake
    if git check-ignore --no-index vendor/fushell/lib/fushell.dart pubspec.lock .metadata fushell.json; then
      echo 'Project sources were incorrectly ignored' >&2
      exit 1
    fi
  )
done

# One project tests each production build mode; the single template also builds.
for mode in debug profile release; do
  "$binary" build "--$mode" "$work/multiple"
done
"$binary" build --debug "$work/single"
printf '%s\n' 'Real Flutter create, analyze, widget test and bundle build checks passed.'
