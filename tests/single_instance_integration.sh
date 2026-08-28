#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${FUSHELL_SINGLE_INSTANCE_TEST_MODE:-debug}"
case "$mode" in
debug | profile | release) ;;
*)
  echo "invalid FUSHELL_SINGLE_INSTANCE_TEST_MODE: $mode" >&2
  exit 64
  ;;
esac

if [[ "${FUSHELL_SINGLE_INSTANCE_TEST_BUILT:-}" != 1 ]]; then
  cd "$root"
  nix develop -c zig build
  nix develop -c "$root/zig-out/bin/fushell" build "--$mode" "$root/examples/singleton_app"
  export FUSHELL_SINGLE_INSTANCE_TEST_BUILT=1
fi

if ! command -v cage >/dev/null 2>&1; then
  exec nix shell nixpkgs#cage -c env \
    FUSHELL_SINGLE_INSTANCE_TEST_BUILT=1 \
    FUSHELL_SINGLE_INSTANCE_TEST_MODE="$mode" \
    bash "$0"
fi

bundle="$root/examples/singleton_app/build/linux/x64/$mode"
runner="$(find "$bundle" -maxdepth 1 -type f -perm -0100 -print -quit)"
[[ -n "$runner" && -x "$runner" ]] || {
  echo "missing bundle executable under: $bundle" >&2
  exit 1
}

tmp="$(mktemp -d)"
cleanup() {
  if [[ -n "${cage_pid:-}" ]]; then
    kill "$cage_pid" 2>/dev/null || true
    wait "$cage_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# Single-instance mode must fail explicitly when no session bus is available.
set +e
DBUS_SESSION_BUS_ADDRESS="unix:path=$tmp/missing-bus" "$runner" status \
  >"$tmp/no-bus.out" 2>"$tmp/no-bus.err"
no_bus_code=$?
set -e
[[ $no_bus_code -ne 0 ]]
grep -q 'SessionBusUnavailable' "$tmp/no-bus.err"

export XDG_RUNTIME_DIR="$tmp/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=headless
export WLR_HEADLESS_OUTPUTS=1
export WLR_LIBINPUT_NO_DEVICES=1

# shellcheck disable=SC2016 # The nested shell expands its own positional variables.
dbus-run-session -- bash -euo pipefail -c '
  runner=$1
  tmp=$2
  cage -- "$runner" >"$tmp/daemon.log" 2>&1 &
  cage_pid=$!
  trap '\''kill "$cage_pid" 2>/dev/null || true; wait "$cage_pid" 2>/dev/null || true'\'' EXIT

  ready=0
  for _ in $(seq 1 100); do
    if dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
      string:dev.fushell.SingletonExample 2>/dev/null | grep -q "boolean true"; then
      ready=1
      break
    fi
    sleep 0.05
  done
  [[ $ready == 1 ]]

  daemon_pid=$(pgrep -P "$cage_pid" | head -n1)
  [[ -n "$daemon_pid" ]]
  sleep 0.5
  read -r _ _ _ _ _ _ _ _ _ _ _ _ _ user_before system_before _ <"/proc/$daemon_pid/stat"
  fd_before=$(find "/proc/$daemon_pid/fd" -mindepth 1 -maxdepth 1 | wc -l)
  sleep 2
  read -r _ _ _ _ _ _ _ _ _ _ _ _ _ user_after system_after _ <"/proc/$daemon_pid/stat"
  fd_after=$(find "/proc/$daemon_pid/fd" -mindepth 1 -maxdepth 1 | wc -l)
  cpu_delta=$((user_after + system_after - user_before - system_before))
  (( cpu_delta <= 1 ))
  [[ $fd_after == "$fd_before" ]]

  status="$(cd /tmp && "$runner" status)"
  [[ "$status" == *"daemon running; windows=0; cwd=/tmp"* ]]

  LD_DEBUG=libs "$runner" status >"$tmp/loader.out" 2>"$tmp/loader.err"
  grep -q "daemon running" "$tmp/loader.out"
  ! grep -Eq "libflutter_engine|libwayland-client|libEGL" "$tmp/loader.err"

  context="$(cd /tmp && "$runner" context alpha beta)"
  [[ "$context" == "cwd=/tmp; initial=false; arguments=context|alpha|beta" ]]

  raw_arg=$(printf "\\377\\001A")
  raw="$("$runner" raw "$raw_arg")"
  [[ "$raw" == "ff0141" ]]

  view_id="$("$runner" open "Integration window")"
  [[ "$view_id" =~ ^[0-9]+$ ]]
  "$runner" list | grep -q "^${view_id}[[:space:]]Integration window$"
  "$runner" close "$view_id"
  [[ -z "$("$runner" list)" ]]

  set +e
  "$runner" unknown >"$tmp/unknown.out" 2>"$tmp/unknown.err"
  unknown_code=$?
  set -e
  [[ $unknown_code == 64 ]]
  grep -q "unknown command: unknown" "$tmp/unknown.err"

  # A waiting secondary receives normal terminal semantics on SIGINT while the
  # daemon remains alive and completes the asynchronous command later.
  "$runner" wait 800 >"$tmp/wait.out" 2>"$tmp/wait.err" &
  secondary_pid=$!
  sleep 0.1
  kill -INT "$secondary_pid"
  set +e
  wait "$secondary_pid"
  interrupt_code=$?
  set -e
  [[ $interrupt_code == 130 ]]
  sleep 0.9
  "$runner" status | grep -q "daemon running"

  "$runner" quit | grep -q "stopping daemon"
  wait "$cage_pid"
  cage_pid=
' bash "$runner" "$tmp"

# Two simultaneous launchers must deterministically produce one owner and one
# forwarding client, never two Flutter engines.
# shellcheck disable=SC2016 # The nested shell expands its own process variables.
dbus-run-session -- bash -euo pipefail -c '
  runner=$1
  tmp=$2
  cage -- "$runner" status >"$tmp/race-a.log" 2>&1 &
  first=$!
  cage -- "$runner" status >"$tmp/race-b.log" 2>&1 &
  second=$!
  trap '\''kill "$first" "$second" 2>/dev/null || true; wait "$first" "$second" 2>/dev/null || true'\'' EXIT

  ready=0
  for _ in $(seq 1 100); do
    if dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
      string:dev.fushell.SingletonExample 2>/dev/null | grep -q "boolean true"; then
      ready=1
      break
    fi
    sleep 0.05
  done
  [[ $ready == 1 ]]
  "$runner" quit >/dev/null
  wait "$first"
  wait "$second"
  first=
  second=

  engine_count=$(grep -h -c "Flutter engine is running" \
    "$tmp/race-a.log" "$tmp/race-b.log" | awk "{ total += \$1 } END { print total + 0 }")
  [[ $engine_count == 1 ]]
' bash "$runner" "$tmp"

echo "single-instance integration: PASS"
