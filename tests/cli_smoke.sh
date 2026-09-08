#!/usr/bin/env bash
# Exercise the shipped entry point, not a test-only parser wrapper.
set -euo pipefail
binary=$(realpath "${1:-zig-out/bin/fushell}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# None of these commands should discover Flutter or initialize a project.
no_flutter() {
  env FLUTTER_ROOT=/nonexistent/fushell-test-sdk \
      FLUTTER_SDK=/nonexistent/fushell-test-sdk PATH=/nonexistent \
      "$binary" "$@"
}

no_flutter > "$work/root"
no_flutter --help > "$work/root-help"
cmp "$work/root" "$work/root-help"
for command in build run sdk create doctor; do
  no_flutter "$command" --help > "$work/$command-help"
  no_flutter "$command" -h > "$work/$command-alias"
  cmp "$work/$command-help" "$work/$command-alias"
  grep -q "Usage: fushell $command" "$work/$command-help"
done
! grep -q -- '--devtools' "$work/sdk-help"

expect_usage_error() {
  local status=0
  no_flutter "$@" > "$work/stdout" 2> "$work/stderr" || status=$?
  test "$status" -eq 2
  test ! -s "$work/stdout"
  grep -q '^error:' "$work/stderr"
  grep -q -- '--help' "$work/stderr"
}
expect_usage_error run --vm-service-port 70000
expect_usage_error run --release --devtools
expect_usage_error sdk --debug
expect_usage_error build --unknown
grep -q -- '--unknown' "$work/stderr"
expect_usage_error help
expect_usage_error create --overwrite app
expect_usage_error sdk one two
expect_usage_error doctor one two
expect_usage_error doctor --debug

no_flutter sdk "$work/sdk output" > "$work/sdk-stdout" 2> "$work/sdk-stderr"
test -s "$work/sdk output/fushell/pubspec.yaml"
test -s "$work/sdk output/fushell/lib/fushell.dart"
test -s "$work/sdk output/fushell/README.md"
printf '%s\n' 'CLI smoke checks passed (no Flutter SDK or display required).'

# Run diagnostic behavior as well as parser/help checks in the ordinary CI.
python3 "$(dirname "${BASH_SOURCE[0]}")/doctor_smoke.py" "$binary"
