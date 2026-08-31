#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "error: usage: validate-engine-artifacts <revision> <debug.so> <profile.so> <release.so>" >&2
  exit 2
fi

revision="$1"
shift
if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: Flutter engine revision must be 40 lowercase hexadecimal characters: $revision" >&2
  exit 2
fi

modes=(debug profile release)
artifacts=("$@")
for index in "${!modes[@]}"; do
  mode="${modes[$index]}"
  artifact="${artifacts[$index]}"
  if [[ ! -f "$artifact" ]]; then
    echo "error: missing Flutter engine artifact for $mode: $artifact" >&2
    exit 2
  fi
  if ! LC_ALL=C grep -aF -- "$revision" "$artifact" >/dev/null; then
    echo "error: Flutter engine artifact for $mode does not contain expected revision $revision: $artifact" >&2
    exit 2
  fi
done
