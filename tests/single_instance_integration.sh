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
    FUSHELL_SINGLE_INSTANCE_TEST_RUNNER="${FUSHELL_SINGLE_INSTANCE_TEST_RUNNER:-}" \
    bash "$0"
fi

if [[ -n "${FUSHELL_SINGLE_INSTANCE_TEST_RUNNER:-}" ]]; then
  runner="$FUSHELL_SINGLE_INSTANCE_TEST_RUNNER"
  [[ -x "$runner" ]] || {
    echo "configured test runner is not executable: $runner" >&2
    exit 1
  }
else
  bundle="$root/examples/singleton_app/build/linux/x64/$mode"
  runner="$(find "$bundle" -maxdepth 1 -type f -perm -0100 -print -quit)"
  [[ -n "$runner" && -x "$runner" ]] || {
    echo "missing bundle executable under: $bundle" >&2
    exit 1
  }
fi

tmp="$(mktemp -d)"
cleanup() {
  local status=$?
  if [[ $status != 0 ]]; then
    echo "single-instance integration failed; evidence directory retained: $tmp" >&2
    for log in "$tmp"/*.log "$tmp"/*.out "$tmp"/*.err; do
      [[ -f "$log" ]] || continue
      [[ "${log##*/}" == loader.err ]] && continue
      echo "--- $log ---" >&2
      cat "$log" >&2 || true
    done
  else
    rm -rf "$tmp"
  fi
  return "$status"
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

  monotonic_ms() {
    local uptime whole fraction
    IFS=" " read -r uptime _ </proc/uptime
    whole=${uptime%%.*}
    fraction=${uptime#*.}
    [[ "$fraction" == "$uptime" ]] && fraction=0
    fraction="${fraction}000"
    fraction=${fraction:0:3}
    whole=${whole:-0}
    printf "%d\n" "$((10#$whole * 1000 + 10#$fraction))"
  }
  proc_starttime() { awk "{print \$22}" "/proc/$1/stat" 2>/dev/null; }
  pid_identity_exists() {
    local pid=$1 expected=$2 current
    [[ -r "/proc/$pid/stat" ]] || return 1
    current=$(proc_starttime "$pid")
    [[ -n "$current" && "$current" == "$expected" ]]
  }
  pid_identity_running() {
    local pid=$1 expected=$2 state
    pid_identity_exists "$pid" "$expected" || return 1
    if ! { read -r _ _ state _ <"/proc/$pid/stat"; } 2>/dev/null; then
      return 1
    fi
    [[ "$state" != Z ]]
  }
  wait_pid_gone_or_reused() {
    local pid=$1 expected=$2 deadline_ms=$3
    while pid_identity_exists "$pid" "$expected"; do
      (( $(monotonic_ms) < deadline_ms )) || return 124
      sleep 0.01
    done
  }
  wait_process_with_deadline() {
    local pid expected timeout_ms deadline_ms
    pid=$1
    expected=$2
    timeout_ms=$3
    deadline_ms=$(( $(monotonic_ms) + timeout_ms ))
    while pid_identity_running "$pid" "$expected"; do
      (( $(monotonic_ms) < deadline_ms )) || return 124
      sleep 0.01
    done
    wait "$pid"
  }
  kill_identity() {
    local signal=$1 pid=$2 expected=$3
    pid_identity_running "$pid" "$expected" || return 1
    kill -"$signal" "$pid"
  }
  snapshot_fds() {
    local pid=$1 target
    for fd in /proc/$pid/fd/*; do
      [[ -e "$fd" ]] || continue
      target=$(readlink "$fd" 2>/dev/null) || continue
      printf "%s -> %s\n" "${fd##*/}" "$target"
    done | sort -V
  }
  wait_fd_snapshot_equal() {
    local pid=$1 expected=$2 label=$3 deadline=$(( $(monotonic_ms) + 5000 )) current
    while (( $(monotonic_ms) < deadline )); do
      current=$(snapshot_fds "$pid")
      if [[ "$current" == "$expected" ]]; then return 0; fi
      sleep 0.02
    done
    echo "FD snapshot mismatch after $label" >&2
    diff -u <(printf "%s\n" "$expected") <(printf "%s\n" "$current") >&2 || true
    return 1
  }
  dbus_owner_pid() {
    local owner pid starttime
    owner=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner \
      string:dev.fushell.SingletonExample | awk "\$1 == \"string\" { value=\$2; gsub(/\"/, \"\", value); print value; exit }")
    pid=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetConnectionUnixProcessID \
      "string:$owner" | awk "\$1 == \"uint32\" { print \$2; exit }")
    [[ "$pid" =~ ^[0-9]+$ ]]
    starttime=$(proc_starttime "$pid")
    [[ -n "$starttime" ]] && pid_identity_exists "$pid" "$starttime"
    printf "%s %s\n" "$pid" "$starttime"
  }

  cage -- "$runner" >"$tmp/daemon.log" 2>&1 &
  cage_pid=$!
  cage_starttime=$(proc_starttime "$cage_pid")
  [[ -n "$cage_starttime" ]] && pid_identity_running "$cage_pid" "$cage_starttime"
  nested_cleanup() {
    local status=$?
    if [[ $status != 0 ]]; then
      echo "nested daemon run failed; evidence directory: $tmp" >&2
      for log in "$tmp"/daemon.log "$tmp"/stream.err "$tmp"/interleaved.err "$tmp"/slow.err "$tmp"/probe.err "$tmp"/open.err; do
        [[ -f "$log" ]] || continue
        echo "--- $log ---" >&2
        cat "$log" >&2 || true
      done
    fi
    if pid_identity_running "$cage_pid" "$cage_starttime"; then
      kill_identity TERM "$cage_pid" "$cage_starttime" || true
    fi
    set +e
    wait_process_with_deadline "$cage_pid" "$cage_starttime" 5000
    cleanup_code=$?
    set -e
    if [[ $cleanup_code == 124 ]] && pid_identity_running "$cage_pid" "$cage_starttime"; then
      kill_identity KILL "$cage_pid" "$cage_starttime" || true
      wait_process_with_deadline "$cage_pid" "$cage_starttime" 5000 || true
    fi
    trap - EXIT
    exit "$status"
  }
  trap nested_cleanup EXIT

  ready=0
  for _ in $(seq 1 100); do
    reply=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
      string:dev.fushell.SingletonExample 2>/dev/null || true)
    if [[ "$reply" == *"boolean true"* ]]; then
      ready=1
      break
    fi
    sleep 0.05
  done
  [[ $ready == 1 ]]

  read -r daemon_pid daemon_starttime < <(dbus_owner_pid)
  pid_identity_running "$daemon_pid" "$daemon_starttime"
  sleep 0.5
  baseline_window_id=$("$runner" open "Baseline window")
  "$runner" list | grep -q "^${baseline_window_id}[[:space:]]Baseline window$"
  "$runner" close "$baseline_window_id"
  "$runner" closed | grep -q "^${baseline_window_id}$"
  read -r _ _ _ _ _ _ _ _ _ _ _ _ _ user_before system_before _ <"/proc/$daemon_pid/stat"
  clk_tck=$(getconf CLK_TCK)
  [[ "$clk_tck" =~ ^[1-9][0-9]*$ ]]
  idle_cpu_duration_ms=5000
  cpu_started_ms=$(monotonic_ms)
  # The original idle snapshot is retained for every later lifecycle check.
  idle_fd_snapshot=$(snapshot_fds "$daemon_pid")
  idle_fd_count=$(printf "%s\n" "$idle_fd_snapshot" | sed '/^$/d' | wc -l)

  sleep 5
  read -r _ _ _ _ _ _ _ _ _ _ _ _ _ user_after system_after _ <"/proc/$daemon_pid/stat"
  idle_fd_after=$(snapshot_fds "$daemon_pid")
  idle_fd_after_count=$(printf "%s\n" "$idle_fd_after" | sed '/^$/d' | wc -l)
  cpu_delta=$((user_after + system_after - user_before - system_before))
  cpu_elapsed_ms=$(( $(monotonic_ms) - cpu_started_ms ))
  # 1% of the five-second idle window catches sustained busy-polling while
  # allowing a short GC or scheduler interruption; round up and allow one tick.
  cpu_limit=$(( (clk_tck * idle_cpu_duration_ms + 99999) / 100000 ))
  (( cpu_limit >= 1 )) || cpu_limit=1
  if (( cpu_delta > cpu_limit )); then
    echo "idle CPU threshold exceeded: delta=$cpu_delta limit=$cpu_limit HZ=$clk_tck duration_ms=$cpu_elapsed_ms" >&2
    exit 1
  fi
  [[ "$idle_fd_after" == "$idle_fd_snapshot" ]]
  [[ $idle_fd_after_count == "$idle_fd_count" ]]

  status="$(cd /tmp && "$runner" status)"
  [[ "$status" == *"daemon running; windows=0; cwd=/tmp"* ]]

  set +e
  "$runner" exit124 >"$tmp/exit124.out" 2>"$tmp/exit124.err"
  exit124_code=$?
  set -e
  [[ $exit124_code == 124 ]]
  ! grep -q "timed out" "$tmp/exit124.err"
  "$runner" status | grep -q "daemon running"

  LD_DEBUG=libs "$runner" status >"$tmp/loader.out" 2>"$tmp/loader.err"
  grep -q "daemon running" "$tmp/loader.out"
  ! grep -Eq "libflutter_engine|libwayland-client|libEGL" "$tmp/loader.err"

  context="$(cd /tmp && "$runner" context alpha beta)"
  [[ "$context" == "cwd=/tmp; initial=false; arguments=context|alpha|beta" ]]

  raw_arg=$(printf "\\377\\001A")
  raw="$("$runner" raw "$raw_arg")"
  [[ "$raw" == "ff0141" ]]

  # 首帧应在 handler 完成前可见，而不是等 completion 才一次性出现。
  first_frame_release="$tmp/first-frame.release"
  [[ ! -e "$first_frame_release" ]]
  "$runner" gate "$first_frame_release" >"$tmp/first-frame.out" 2>"$tmp/first-frame.err" &
  first_frame_pid=$!
  first_frame_starttime=$(proc_starttime "$first_frame_pid")
  [[ -n "$first_frame_starttime" ]] && pid_identity_running "$first_frame_pid" "$first_frame_starttime"
  first_frame_seen=0
  for _ in $(seq 1 200); do
    if grep -q "waiting" "$tmp/first-frame.out" 2>/dev/null; then
      first_frame_seen=1
      break
    fi
    sleep 0.01
  done
  [[ $first_frame_seen == 1 ]]
  [[ ! -e "$first_frame_release" ]]
  pid_identity_running "$first_frame_pid" "$first_frame_starttime"
  touch "$first_frame_release"
  wait_process_with_deadline "$first_frame_pid" "$first_frame_starttime" 10000

  "$runner" interleaved >"$tmp/interleaved.out" 2>"$tmp/interleaved.err"
  printf "%b" "\\x00\\xff\\x01\\x03\\x00\\x04" >"$tmp/interleaved.expected.out"
  printf "%b" "\\xfe\\x00\\x02" >"$tmp/interleaved.expected.err"
  cmp -s "$tmp/interleaved.expected.out" "$tmp/interleaved.out" || {
    echo "interleaved stdout mismatch" >&2
    od -An -tx1 "$tmp/interleaved.expected.out" >&2
    od -An -tx1 "$tmp/interleaved.out" >&2
    exit 1
  }
  cmp -s "$tmp/interleaved.expected.err" "$tmp/interleaved.err" || {
    echo "interleaved stderr mismatch" >&2
    od -An -tx1 "$tmp/interleaved.err" >&2
    exit 1
  }

  "$runner" exact-limit >"$tmp/exact.out" 2>"$tmp/exact.err"
  [[ $(wc -c <"$tmp/exact.out") == 8388608 ]]

  # Keep the first output frame unread for a bounded interval.  The daemon must
  # still answer D-Bus while the secondary/helper is backpressured.
  slow_marker="$tmp/slow-consumer.ready"
  slow_release="$tmp/slow-consumer.release"
  slow_fifo="$tmp/slow-consumer.pipe"
  mkfifo "$slow_fifo"
  python3 -c "import os, pathlib, sys, time
first=os.read(0,32768)
pathlib.Path(sys.argv[1]).touch()
deadline=time.monotonic_ns()+30000000000
release=pathlib.Path(sys.argv[2])
out=open(sys.argv[3],chr(119)+chr(98))
while not release.exists() and time.monotonic_ns()<deadline:
    time.sleep(0.01)
if not release.exists():
    raise SystemExit(124)
out.write(first)
[out.write(data) for data in iter(lambda: os.read(0,1048576), bytes())]
out.close()" "$slow_marker" "$slow_release" "$tmp/slow.out" <"$slow_fifo" >/dev/null &
  slow_consumer_pid=$!
  slow_consumer_starttime=$(proc_starttime "$slow_consumer_pid")
  [[ -n "$slow_consumer_starttime" ]] && pid_identity_running "$slow_consumer_pid" "$slow_consumer_starttime"
  "$runner" exact-limit >"$slow_fifo" 2>"$tmp/slow.err" &
  slow_runner_pid=$!
  slow_runner_starttime=$(proc_starttime "$slow_runner_pid")
  [[ -n "$slow_runner_starttime" ]] && pid_identity_running "$slow_runner_pid" "$slow_runner_starttime"
  slow_ready=0
  for _ in $(seq 1 200); do
    if [[ -f "$slow_marker" ]]; then
      slow_ready=1
      break
    fi
    sleep 0.01
  done
  [[ $slow_ready == 1 ]]
  probe_reply=$(timeout 2s dbus-send --session --dest=dev.fushell.SingletonExample \
    --type=method_call --print-reply /dev/fushell/Application dev.fushell.Application2.GetProtocolVersion)
  [[ "$probe_reply" == *"uint32 2"* ]]
  queued_pids=()
  queued_starttimes=()
  queued_helper_pids=()
  queued_helper_starttimes=()
  for index in $(seq 1 31); do
    "$runner" status >"$tmp/queued-$index.out" 2>"$tmp/queued-$index.err" &
    queued_pid=$!
    queued_pids+=("$queued_pid")
    queued_starttime=$(proc_starttime "$queued_pid")
    [[ -n "$queued_starttime" ]] && pid_identity_running "$queued_pid" "$queued_starttime"
    queued_starttimes+=("$queued_starttime")
    sleep 0.02
  done
  for index in "${!queued_pids[@]}"; do
    queued_pid="${queued_pids[$index]}"
    queued_starttime="${queued_starttimes[$index]}"
    helper_pid=
    for _ in $(seq 1 100); do
      if pid_identity_running "$queued_pid" "$queued_starttime"; then
        helper_pid=$(pgrep -P "$queued_pid" 2>/dev/null | head -n1 || true)
        [[ -n "$helper_pid" ]] && break
      fi
      sleep 0.01
    done
    [[ -n "$helper_pid" ]]
    queued_helper_starttime=$(proc_starttime "$helper_pid")
    [[ -n "$queued_helper_starttime" ]] && pid_identity_running "$helper_pid" "$queued_helper_starttime"
    queued_helper_pids+=("$helper_pid")
    queued_helper_starttimes+=("$queued_helper_starttime")
  done
  for _ in $(seq 1 100); do
    all_alive=1
    for index in "${!queued_pids[@]}"; do
      pid_identity_running "${queued_pids[$index]}" "${queued_starttimes[$index]}" || all_alive=0
    done
    [[ $all_alive == 1 ]] && break
    sleep 0.01
  done
  for index in "${!queued_pids[@]}"; do
    pid_identity_running "${queued_pids[$index]}" "${queued_starttimes[$index]}"
  done
  pid_identity_running "$slow_runner_pid" "$slow_runner_starttime"
  pid_identity_running "$slow_consumer_pid" "$slow_consumer_starttime"
  busy_started=$(monotonic_ms)
  set +e
  timeout 5s "$runner" status >"$tmp/busy.out" 2>"$tmp/busy.err"
  busy_code=$?
  set -e
  busy_elapsed=$(( $(monotonic_ms) - busy_started ))
  [[ $busy_code == 75 ]]
  (( busy_elapsed < 2000 ))
  touch "$slow_release"
  for index in "${!queued_pids[@]}"; do
    set +e
    wait_process_with_deadline "${queued_pids[$index]}" "${queued_starttimes[$index]}" 60000
    queued_code=$?
    set -e
    [[ $queued_code == 0 ]]
    wait_pid_gone_or_reused "${queued_helper_pids[$index]}" "${queued_helper_starttimes[$index]}" $(( $(monotonic_ms) + 5000 ))
    [[ "$(<"$tmp/queued-$((index + 1)).out")" == *"daemon running"* ]]
  done
  set +e
  wait_process_with_deadline "$slow_runner_pid" "$slow_runner_starttime" 60000
  slow_code=$?
  wait_process_with_deadline "$slow_consumer_pid" "$slow_consumer_starttime" 60000
  slow_consumer_code=$?
  set -e
  printf "slow runner=%s consumer=%s bytes=%s\n" "$slow_code" "$slow_consumer_code" "$(wc -c <"$tmp/slow.out")" >&2
  [[ $slow_code == 0 && $slow_consumer_code == 0 ]] || { cat "$tmp/slow.err" >&2; exit 1; }
  [[ $(wc -c <"$tmp/slow.out") == 8388608 ]]
  wait_fd_snapshot_equal "$daemon_pid" "$idle_fd_snapshot" "slow-queue"

  set +e
  "$runner" overflow >"$tmp/overflow.out" 2>"$tmp/overflow.err"
  overflow_code=$?
  set -e
  [[ $overflow_code == 70 ]]
  [[ $(wc -c <"$tmp/overflow.out") == 8388608 ]]

  set +e
  "$runner" unknown >"$tmp/unknown.out" 2>"$tmp/unknown.err"
  unknown_code=$?
  set -e
  [[ $unknown_code == 64 ]]
  grep -q "unknown command: unknown" "$tmp/unknown.err"

  run_signal_case() {
    local signal=$1 expected_code=$2 label=$3
    local release="$tmp/$label.release" output="$tmp/$label.out" error="$tmp/$label.err"
    local secondary_pid secondary_starttime helper_pid helper_starttime waiting_seen=0 signal_code
    "$runner" gate "$release" >"$output" 2>"$error" &
    secondary_pid=$!
    secondary_starttime=$(proc_starttime "$secondary_pid")
    [[ -n "$secondary_starttime" ]] && pid_identity_running "$secondary_pid" "$secondary_starttime"
    for _ in $(seq 1 200); do
      if grep -q "waiting" "$output" 2>/dev/null; then
        waiting_seen=1
        break
      fi
      sleep 0.01
    done
    [[ $waiting_seen == 1 ]]
    pid_identity_running "$secondary_pid" "$secondary_starttime"
    helper_pid=
    for _ in $(seq 1 100); do
      if pid_identity_running "$secondary_pid" "$secondary_starttime"; then
        helper_pid=$(pgrep -P "$secondary_pid" 2>/dev/null | head -n1 || true)
        [[ -n "$helper_pid" ]] && break
      fi
      sleep 0.01
    done
    [[ -n "$helper_pid" ]]
    helper_starttime=$(proc_starttime "$helper_pid")
    [[ -n "$helper_starttime" ]] && pid_identity_running "$helper_pid" "$helper_starttime"
    kill_identity "$signal" "$secondary_pid" "$secondary_starttime"
    set +e
    wait_process_with_deadline "$secondary_pid" "$secondary_starttime" 10000
    signal_code=$?
    set -e
    [[ $signal_code == "$expected_code" ]]
    touch "$release"
    wait_pid_gone_or_reused "$helper_pid" "$helper_starttime" $(( $(monotonic_ms) + 5000 ))
    "$runner" status | grep -q "daemon running"
    wait_fd_snapshot_equal "$daemon_pid" "$idle_fd_snapshot" "$label"
  }

  run_signal_case INT 130 sigint
  run_signal_case TERM 143 sigterm

  # 回调在宽限期内完成时释放 active 槽，排队命令继续执行且 daemon 不重启。
  set +e
  "$runner" wait 60000 >"$tmp/grace.out" 2>"$tmp/grace.err"
  grace_code=$?
  set -e
  [[ $grace_code == 124 ]]
  grep -q "command timed out" "$tmp/grace.err"
  "$runner" status | grep -q "daemon running"
  reply=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
    --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
    string:dev.fushell.SingletonExample 2>/dev/null || true)
  if [[ "$reply" != *"boolean true"* ]]; then
    echo "daemon owner disappeared after cooperative timeout" >&2
    cat "$tmp/daemon.log" >&2
    exit 1
  fi
  wait_fd_snapshot_equal "$daemon_pid" "$idle_fd_snapshot" "cooperative-timeout"

  # 不协作的回调先收到超时回复；取消宽限期结束后 daemon 退出，避免永久阻塞命令队列。
  set +e
  "$runner" hang 35000 >"$tmp/timeout.out" 2>"$tmp/timeout.err"
  timeout_code=$?
  set -e
  [[ $timeout_code == 124 ]]
  grep -q "command timed out" "$tmp/timeout.err"
  # 有序恢复可能让 cage 子进程以正常或信号状态退出；协议断言是进程已结束
  # 且出现 restart marker，不固定要求某一个退出码。
  wait_process_with_deadline "$cage_pid" "$cage_starttime" 30000
  cage_pid=
  grep -q "Application command ignored cancellation; restarting daemon" "$tmp/daemon.log"

  # 超时调用不得重放；后续 launcher 成为新 primary，且其首次命令只执行一次。
  cage -- "$runner" status >"$tmp/restart.log" 2>&1 &
  cage_pid=$!
  cage_starttime=$(proc_starttime "$cage_pid")
  [[ -n "$cage_starttime" ]] && pid_identity_running "$cage_pid" "$cage_starttime"
  restarted=0
  for _ in $(seq 1 100); do
    if grep -q "daemon running" "$tmp/restart.log" 2>/dev/null; then
      restarted=1
      break
    fi
    if ! pid_identity_running "$cage_pid" "$cage_starttime"; then
      break
    fi
    sleep 0.05
  done
  [[ $restarted == 1 ]]
  [[ $(grep -c "daemon running" "$tmp/restart.log") == 1 ]]
  "$runner" status | grep -q "daemon running"
  "$runner" quit | grep -q "stopping daemon"
  wait_process_with_deadline "$cage_pid" "$cage_starttime" 30000
  cage_pid=
  trap - EXIT
' bash "$runner" "$tmp"

# A daemon crash while a secondary is active must fail the secondary promptly
# and leave its helper gone; this is isolated from the normal recovery matrix.
# shellcheck disable=SC2016 # The nested shell expands its own positional variables.
dbus-run-session -- bash -euo pipefail -c '
  runner=$1
  tmp=$2
  monotonic_ms() {
    local uptime whole fraction
    IFS=" " read -r uptime _ </proc/uptime
    whole=${uptime%%.*}
    fraction=${uptime#*.}
    [[ "$fraction" == "$uptime" ]] && fraction=0
    fraction="${fraction}000"
    fraction=${fraction:0:3}
    whole=${whole:-0}
    printf "%d\n" "$((10#$whole * 1000 + 10#$fraction))"
  }
  proc_starttime() { awk "{print \$22}" "/proc/$1/stat" 2>/dev/null; }
  pid_identity_exists() {
    local pid=$1 expected=$2 current
    [[ -r "/proc/$pid/stat" ]] || return 1
    current=$(proc_starttime "$pid")
    [[ -n "$current" && "$current" == "$expected" ]]
  }
  pid_identity_running() {
    local pid=$1 expected=$2 state
    pid_identity_exists "$pid" "$expected" || return 1
    if ! { read -r _ _ state _ <"/proc/$pid/stat"; } 2>/dev/null; then
      return 1
    fi
    [[ "$state" != Z ]]
  }
  wait_pid_gone_or_reused() {
    local pid=$1 expected=$2 deadline_ms=$3
    while pid_identity_exists "$pid" "$expected"; do
      (( $(monotonic_ms) < deadline_ms )) || return 124
      sleep 0.01
    done
  }
  wait_process_with_deadline() {
    local pid expected timeout_ms deadline_ms
    pid=$1
    expected=$2
    timeout_ms=$3
    deadline_ms=$(( $(monotonic_ms) + timeout_ms ))
    while pid_identity_running "$pid" "$expected"; do
      (( $(monotonic_ms) < deadline_ms )) || return 124
      sleep 0.01
    done
    wait "$pid"
  }
  kill_identity() {
    local signal=$1 pid=$2 expected=$3
    pid_identity_running "$pid" "$expected" || return 1
    kill -"$signal" "$pid"
  }
  dbus_owner_pid() {
    local owner pid starttime
    owner=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner \
      string:dev.fushell.SingletonExample | awk "\$1 == \"string\" { value=\$2; gsub(/\"/, \"\", value); print value; exit }")
    pid=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetConnectionUnixProcessID \
      "string:$owner" | awk "\$1 == \"uint32\" { print \$2; exit }")
    [[ "$pid" =~ ^[0-9]+$ ]]
    starttime=$(proc_starttime "$pid")
    [[ -n "$starttime" ]] && pid_identity_exists "$pid" "$starttime"
    printf "%s %s\n" "$pid" "$starttime"
  }
  cage -- "$runner" status >"$tmp/crash-daemon.log" 2>&1 &
  cage_pid=$!
  cage_starttime=$(proc_starttime "$cage_pid")
  cleanup_crash() {
    local status=$?
    if pid_identity_running "$cage_pid" "$cage_starttime"; then
      kill_identity TERM "$cage_pid" "$cage_starttime" || true
    fi
    if [[ -n "${secondary_pid:-}" ]] && pid_identity_running "$secondary_pid" "$secondary_starttime"; then
      kill_identity TERM "$secondary_pid" "$secondary_starttime" || true
    fi
    set +e
    wait_process_with_deadline "$cage_pid" "$cage_starttime" 5000
    if [[ -n "${secondary_pid:-}" && -n "${secondary_starttime:-}" ]]; then
      wait_process_with_deadline "$secondary_pid" "$secondary_starttime" 5000 || true
    fi
    set -e
    trap - EXIT
    exit "$status"
  }
  trap cleanup_crash EXIT

  ready=0
  for _ in $(seq 1 100); do
    reply=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
      string:dev.fushell.SingletonExample 2>/dev/null || true)
    if [[ "$reply" == *"boolean true"* ]]; then ready=1; break; fi
    sleep 0.05
  done
  [[ $ready == 1 ]]
  read -r daemon_pid daemon_starttime < <(dbus_owner_pid)
  pid_identity_running "$daemon_pid" "$daemon_starttime"
  release="$tmp/crash.release"
  "$runner" gate "$release" >"$tmp/crash-secondary.out" 2>"$tmp/crash-secondary.err" &
  secondary_pid=$!
  secondary_starttime=$(proc_starttime "$secondary_pid")
  [[ -n "$secondary_starttime" ]] && pid_identity_running "$secondary_pid" "$secondary_starttime"
  helper_seen=0
  helper_pid=
  for _ in $(seq 1 200); do
    if pid_identity_running "$secondary_pid" "$secondary_starttime"; then
      helper_pid=$(pgrep -P "$secondary_pid" 2>/dev/null | head -n1 || true)
      if [[ -n "$helper_pid" && -f "$tmp/crash-secondary.out" ]] && grep -q waiting "$tmp/crash-secondary.out"; then
        helper_seen=1
        break
      fi
    fi
    sleep 0.01
  done
  [[ $helper_seen == 1 ]]
  helper_starttime=$(proc_starttime "$helper_pid")
  [[ -n "$helper_starttime" ]] && pid_identity_running "$helper_pid" "$helper_starttime"
  crash_started_ms=$(monotonic_ms)
  kill_identity KILL "$daemon_pid" "$daemon_starttime"
  set +e
  wait_process_with_deadline "$secondary_pid" "$secondary_starttime" 10000
  secondary_code=$?
  set -e
  crash_elapsed_ms=$(( $(monotonic_ms) - crash_started_ms ))
  secondary_pid=
  [[ $secondary_code == 125 ]]
  (( crash_elapsed_ms <= 2000 ))
  wait_pid_gone_or_reused "$helper_pid" "$helper_starttime" $(( $(monotonic_ms) + 5000 ))
  grep -Eiq "owner disappeared|D-Bus connection was lost|daemon.*lost" "$tmp/crash-secondary.err"
  reply=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
    --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
    string:dev.fushell.SingletonExample 2>/dev/null || true)
  [[ "$reply" == *"boolean false"* ]]
  kill_identity TERM "$cage_pid" "$cage_starttime" || true
  set +e
  wait_process_with_deadline "$cage_pid" "$cage_starttime" 5000
  cage_code=$?
  set -e
  [[ $cage_code != 124 ]]
  cage_pid=
  trap - EXIT
' bash "$runner" "$tmp"

# Two simultaneous launchers must deterministically produce one owner and one
# forwarding client, never two Flutter engines.
# shellcheck disable=SC2016 # The nested shell expands its own process variables.
dbus-run-session -- bash -euo pipefail -c '
  runner=$1
  tmp=$2
  monotonic_ms() {
    local uptime whole fraction
    IFS=" " read -r uptime _ </proc/uptime
    whole=${uptime%%.*}
    fraction=${uptime#*.}
    [[ "$fraction" == "$uptime" ]] && fraction=0
    fraction="${fraction}000"
    fraction=${fraction:0:3}
    whole=${whole:-0}
    printf "%d\n" "$((10#$whole * 1000 + 10#$fraction))"
  }
  proc_starttime() { awk "{print \$22}" "/proc/$1/stat" 2>/dev/null; }
  pid_identity_exists() {
    local pid=$1 expected=$2 current
    [[ -r "/proc/$pid/stat" ]] || return 1
    current=$(proc_starttime "$pid")
    [[ -n "$current" && "$current" == "$expected" ]]
  }
  pid_identity_running() {
    local pid=$1 expected=$2 state
    pid_identity_exists "$pid" "$expected" || return 1
    if ! { read -r _ _ state _ <"/proc/$pid/stat"; } 2>/dev/null; then
      return 1
    fi
    [[ "$state" != Z ]]
  }
  wait_process_with_deadline() {
    local pid expected timeout_ms deadline_ms
    pid=$1
    expected=$2
    timeout_ms=$3
    deadline_ms=$(( $(monotonic_ms) + timeout_ms ))
    while pid_identity_running "$pid" "$expected"; do
      (( $(monotonic_ms) < deadline_ms )) || return 124
      sleep 0.01
    done
    wait "$pid"
  }
  kill_identity() {
    local signal=$1 pid=$2 expected=$3
    pid_identity_running "$pid" "$expected" || return 1
    kill -"$signal" "$pid"
  }
  cage -- "$runner" status >"$tmp/race-a.log" 2>&1 &
  first=$!
  first_starttime=$(proc_starttime "$first")
  [[ -n "$first_starttime" ]] && pid_identity_running "$first" "$first_starttime"
  cage -- "$runner" status >"$tmp/race-b.log" 2>&1 &
  second=$!
  second_starttime=$(proc_starttime "$second")
  [[ -n "$second_starttime" ]] && pid_identity_running "$second" "$second_starttime"
  nested_race_cleanup() {
    local status=$?
    if [[ $status != 0 ]]; then
      echo "nested race failed; evidence directory: $tmp" >&2
      for log in "$tmp"/race-a.log "$tmp"/race-b.log; do
        [[ -f "$log" ]] || continue
        echo "--- $log ---" >&2
        cat "$log" >&2 || true
      done
    fi
    kill_identity TERM "$first" "$first_starttime" 2>/dev/null || true
    kill_identity TERM "$second" "$second_starttime" 2>/dev/null || true
    set +e
    wait_process_with_deadline "$first" "$first_starttime" 5000
    wait_process_with_deadline "$second" "$second_starttime" 5000
    set -e
    trap - EXIT
    exit "$status"
  }
  trap nested_race_cleanup EXIT

  ready=0
  for _ in $(seq 1 100); do
    reply=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
      string:dev.fushell.SingletonExample 2>/dev/null || true)
    if [[ "$reply" == *"boolean true"* ]]; then
      ready=1
      break
    fi
    sleep 0.05
  done
  [[ $ready == 1 ]]
  "$runner" quit >/dev/null
  wait_process_with_deadline "$first" "$first_starttime" 30000
  wait_process_with_deadline "$second" "$second_starttime" 30000
  first=
  second=
  trap - EXIT

  engine_count=$(grep -h -c "Flutter engine is running" \
    "$tmp/race-a.log" "$tmp/race-b.log" | awk "{ total += \$1 } END { print total + 0 }")
  [[ $engine_count == 1 ]]
' bash "$runner" "$tmp"

echo "single-instance integration: PASS"
