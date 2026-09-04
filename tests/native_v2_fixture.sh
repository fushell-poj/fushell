#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="${FUSHELL_NATIVE_V2_RUNNER:-$root/examples/singleton_app/build/linux/x64/debug/fushell_singleton_example}"
[[ -x "$runner" ]] || {
  echo "missing secondary runner: $runner" >&2
  exit 1
}

tmp="$(mktemp -d)"
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
proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
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
cleanup() {
  if [[ -n "${daemon_pid:-}" && -n "${daemon_starttime:-}" ]]; then
    kill_identity TERM "$daemon_pid" "$daemon_starttime" 2>/dev/null || true
    wait_process_with_deadline "$daemon_pid" "$daemon_starttime" 5000 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

cat >"$tmp/native_v2_daemon.c" <<'EOF'
#define _DEFAULT_SOURCE
#include <dbus/dbus.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static const char *const application_name = "dev.fushell.SingletonExample";
static const char *mode;
static int held_output_fd = -1;

static void put_u32(unsigned char *out, uint32_t value) {
  out[0] = (unsigned char)(value >> 24);
  out[1] = (unsigned char)(value >> 16);
  out[2] = (unsigned char)(value >> 8);
  out[3] = (unsigned char)value;
}

static void put_u64(unsigned char *out, uint64_t value) {
  for (int i = 7; i >= 0; --i) {
    out[i] = (unsigned char)value;
    value >>= 8;
  }
}

static int send_frame(int fd, unsigned char stream, uint64_t sequence,
                      const unsigned char *payload, uint32_t length) {
  unsigned char frame[84];
  if (length > 64) return 0;
  memcpy(frame, "FSO2", 4);
  frame[4] = stream;
  frame[5] = 0;
  frame[6] = 0;
  frame[7] = 0;
  put_u64(frame + 8, sequence);
  put_u32(frame + 16, length);
  memcpy(frame + 20, payload, length);
  return send(fd, frame, 20 + length, MSG_NOSIGNAL) == (ssize_t)(20 + length);
}

static DBusHandlerResult handle_message(DBusConnection *connection,
                                         DBusMessage *message, void *data) {
  (void)data;
  if (dbus_message_is_method_call(message, "dev.fushell.Application2",
                                  "GetProtocolVersion")) {
    DBusMessage *reply = dbus_message_new_method_return(message);
    if (!reply) return DBUS_HANDLER_RESULT_NEED_MEMORY;
    if (strcmp(mode, "probe-sigint") == 0 || strcmp(mode, "probe-sigterm") == 0) {
      fprintf(stderr, "PROBE_PENDING\n");
      fflush(stderr);
      usleep(500000);
    }
    uint32_t version = strcmp(mode, "version1") == 0 ? 1 : 2;
    dbus_message_append_args(reply, DBUS_TYPE_UINT32, &version,
                             DBUS_TYPE_INVALID);
    dbus_connection_send(connection, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (!dbus_message_is_method_call(message, "dev.fushell.Application2",
                                   "CommandLine"))
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

  DBusMessageIter iterator;
  int output_fd = -1;
  if (!dbus_message_iter_init(message, &iterator) ||
      dbus_message_iter_get_arg_type(&iterator) != DBUS_TYPE_ARRAY) {
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }
  if (!dbus_message_iter_next(&iterator) ||
      dbus_message_iter_get_arg_type(&iterator) != DBUS_TYPE_UNIX_FD) {
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }
  dbus_message_iter_get_basic(&iterator, &output_fd);
  if (strcmp(mode, "probe-sigint") == 0 || strcmp(mode, "probe-sigterm") == 0)
    fprintf(stderr, "PROBE_COMMANDLINE_RECEIVED\n");

  if (strcmp(mode, "owner-loss") == 0) {
    close(output_fd);
    usleep(100000);
    _exit(0);
  }
  if (strcmp(mode, "disconnect") == 0) {
    held_output_fd = output_fd;
    fprintf(stderr, "COMMANDLINE_PENDING\n");
    fflush(stderr);
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  static const unsigned char stdout_payload[] = "native-v2";
  static const unsigned char stderr_payload[] = "err";
  if (strcmp(mode, "eof-no-summary") == 0) {
    close(output_fd);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(mode, "integrity") == 0) {
    unsigned char malformed[21] = { 'N', 'O', 'P', 'E', 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff };
    send(output_fd, malformed, sizeof(malformed), MSG_NOSIGNAL);
    close(output_fd);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (!send_frame(output_fd, 1, 0, stdout_payload,
                  (uint32_t)(sizeof(stdout_payload) - 1)) ||
      !send_frame(output_fd, 2, 1, stderr_payload,
                  (uint32_t)(sizeof(stderr_payload) - 1))) {
    close(output_fd);
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }

  DBusMessage *reply = dbus_message_new_method_return(message);
  if (!reply) return DBUS_HANDLER_RESULT_NEED_MEMORY;
  DBusMessageIter append;
  dbus_message_iter_init_append(reply, &append);
  uint32_t terminal_kind = strcmp(mode, "timed-out") == 0 ? 1 : 0;
  int32_t exit_code = strcmp(mode, "completed124") == 0 || terminal_kind == 1 ? 124 : 0;
  uint64_t frame_count = strcmp(mode, "counter-mismatch") == 0 ? 1 : 2;
  uint64_t stdout_bytes = sizeof(stdout_payload) - 1;
  uint64_t stderr_bytes = sizeof(stderr_payload) - 1;
  if (strcmp(mode, "invalid-final-signature") == 0) {
    uint32_t invalid_terminal_kind = 0;
    dbus_message_iter_append_basic(&append, DBUS_TYPE_UINT32, &invalid_terminal_kind);
    shutdown(output_fd, SHUT_WR);
    close(output_fd);
    dbus_connection_send(connection, reply, NULL);
    dbus_connection_flush(connection);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(mode, "invalid-terminal") == 0) terminal_kind = 2;
  dbus_message_iter_append_basic(&append, DBUS_TYPE_UINT32, &terminal_kind);
  dbus_message_iter_append_basic(&append, DBUS_TYPE_INT32, &exit_code);
  dbus_message_iter_append_basic(&append, DBUS_TYPE_UINT64, &frame_count);
  dbus_message_iter_append_basic(&append, DBUS_TYPE_UINT64, &stdout_bytes);
  dbus_message_iter_append_basic(&append, DBUS_TYPE_UINT64, &stderr_bytes);
  if (strcmp(mode, "reply-first") == 0) {
    dbus_connection_send(connection, reply, NULL);
    dbus_connection_flush(connection);
  }
  shutdown(output_fd, SHUT_WR);
  close(output_fd);
  if (strcmp(mode, "eof-first") == 0) usleep(100000);
  if (strcmp(mode, "reply-first") != 0) {
    dbus_connection_send(connection, reply, NULL);
    dbus_connection_flush(connection);
  }
  dbus_message_unref(reply);
  return DBUS_HANDLER_RESULT_HANDLED;
}

int main(int argc, char **argv) {
  mode = argc > 1 ? argv[1] : "normal";
  DBusError error;
  dbus_error_init(&error);
  DBusConnection *connection = dbus_bus_get_private(DBUS_BUS_SESSION, &error);
  if (!connection) {
    fprintf(stderr, "dbus connect failed: %s\n", error.message ?: "unknown");
    dbus_error_free(&error);
    return 1;
  }
  dbus_connection_set_exit_on_disconnect(connection, FALSE);
  int request = dbus_bus_request_name(connection, application_name,
                                      DBUS_NAME_FLAG_DO_NOT_QUEUE, &error);
  if (request != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
    fprintf(stderr, "name request failed: %s\n", error.message ?: "unknown");
    dbus_error_free(&error);
    dbus_connection_close(connection);
    dbus_connection_unref(connection);
    return 1;
  }
  if (!dbus_connection_add_filter(connection, handle_message, NULL, NULL))
    return 1;
  while (dbus_connection_read_write_dispatch(connection, -1)) {}
  if (held_output_fd >= 0) close(held_output_fd);
  dbus_connection_remove_filter(connection, handle_message, NULL);
  dbus_connection_close(connection);
  dbus_connection_unref(connection);
  return 0;
}
EOF
read -r -a dbus_flags <<<"$(pkg-config --cflags --libs dbus-1)"
cc -std=c11 -O2 -Wall -Wextra "$tmp/native_v2_daemon.c" \
  -o "$tmp/native-v2-daemon" "${dbus_flags[@]}"

run_case() {
  local mode="$1"
  # shellcheck disable=SC2016 # Inner bash expands its own positional parameters/variables; the outer shell must not expand them. 内层 bash 按自己的位置参数/变量展开，外层 shell 不应展开。
  dbus-run-session -- bash -euo pipefail -c '
    runner=$1
    daemon=$2
    mode=$3
    tmp=$4
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
      local pid=$1 expected=$2 timeout_ms=$3 deadline_ms
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
    "$daemon" "$mode" >"$tmp/daemon.log" 2>&1 &
    daemon_pid=$!
    daemon_starttime=$(proc_starttime "$daemon_pid")
    [[ -n "$daemon_starttime" ]] && pid_identity_exists "$daemon_pid" "$daemon_starttime"
    cleanup_case() {
      local status=$?
      if [[ $status != 0 ]]; then
        echo "native-v2 fixture failed: mode=$mode; evidence directory=$tmp" >&2
        cat "$tmp/daemon.log" >&2 || true
      fi
      kill_identity TERM "$daemon_pid" "$daemon_starttime" 2>/dev/null || true
      set +e
      wait_process_with_deadline "$daemon_pid" "$daemon_starttime" 5000 || true
      set -e
      trap - EXIT
      exit "$status"
    }
    trap cleanup_case EXIT

    ready=0
    for _ in $(seq 1 100); do
      reply=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
        --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
        string:dev.fushell.SingletonExample 2>/dev/null || true)
      if [[ "$reply" == *"boolean true"* ]]; then
        ready=1
        break
      fi
      sleep 0.01
    done
    [[ $ready == 1 ]]

    snapshot_fds() {
      local target
      for fd in /proc/$daemon_pid/fd/*; do
        [[ -e "$fd" ]] || continue
        target=$(readlink "$fd" 2>/dev/null) || continue
        printf "%s -> %s\n" "${fd##*/}" "$target"
      done | sort -V
    }
    fd_before=$(snapshot_fds)
    fd_before_count=0
    [[ -z "$fd_before" ]] || fd_before_count=$(printf "%s\n" "$fd_before" | wc -l)
    set +e
    if [[ "$mode" == probe-sigint || "$mode" == probe-sigterm ]]; then
      "$runner" status >"$tmp/stdout" 2>"$tmp/stderr" &
      client_pid=$!
      client_starttime=$(proc_starttime "$client_pid")
      [[ -n "$client_starttime" ]] && pid_identity_running "$client_pid" "$client_starttime"
      probe_deadline=$(( $(monotonic_ms) + 2000 ))
      probe_pending=0
      while (( $(monotonic_ms) < probe_deadline )); do
        if grep -q "PROBE_PENDING" "$tmp/daemon.log" 2>/dev/null; then
          probe_pending=1
          break
        fi
        sleep 0.01
      done
      [[ $probe_pending == 1 ]]
      pid_identity_running "$client_pid" "$client_starttime"
      if [[ "$mode" == probe-sigint ]]; then
        kill_identity INT "$client_pid" "$client_starttime"
      else
        kill_identity TERM "$client_pid" "$client_starttime"
      fi
      wait_process_with_deadline "$client_pid" "$client_starttime" 10000
      code=$?
    elif [[ "$mode" == eof-no-summary ]]; then
      FUSHELL_TEST_NO_HELPER_SUMMARY=1 "$runner" status >"$tmp/stdout" 2>"$tmp/stderr"
      code=$?
    else
      "$runner" status >"$tmp/stdout" 2>"$tmp/stderr"
      code=$?
    fi
    set -e
    output=$(<"$tmp/stdout")
    diagnostic=$(<"$tmp/stderr")
    case "$mode" in
      normal)
        [[ $code == 0 ]]
        [[ "$output" == native-v2 ]]
        [[ "$diagnostic" == err ]]
        ;;
      completed124)
        [[ $code == 124 ]]
        [[ "$diagnostic" == err ]]
        ;;
      timed-out)
        [[ $code == 124 ]]
        [[ "$diagnostic" == *"timed out"* ]]
        ;;
      reply-first|eof-first)
        [[ $code == 0 ]]
        [[ "$output" == native-v2 ]]
        [[ "$diagnostic" == err ]]
        ;;
      eof-no-summary|integrity|invalid-terminal|invalid-final-signature)
        [[ $code == 125 ]]
        ;;
      version1)
        [[ $code == 76 ]]
        [[ "$diagnostic" == *"incompatible"* ]]
        ;;
      owner-loss|counter-mismatch)
        [[ $code == 125 ]]
        ;;
      probe-sigint)
        [[ $code == 130 ]]
        ! grep -q "PROBE_COMMANDLINE_RECEIVED" "$tmp/daemon.log"
        ;;
      probe-sigterm)
        [[ $code == 143 ]]
        ! grep -q "PROBE_COMMANDLINE_RECEIVED" "$tmp/daemon.log"
        ;;
    esac
    sleep 0.2
    dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
      string:dev.fushell.SingletonExample >/dev/null 2>&1 || true
    sleep 0.2
    if kill -0 "$daemon_pid" 2>/dev/null; then
      fd_after=$(snapshot_fds)
      fd_after_count=0
      [[ -z "$fd_after" ]] || fd_after_count=$(printf "%s\n" "$fd_after" | wc -l)
      if ! diff -u <(printf "%s\n" "$fd_before") <(printf "%s\n" "$fd_after"); then
        echo "native-v2 fixture FD baseline mismatch (per-FD targets above)" >&2
        exit 1
      fi
      fd_after_display=$fd_after_count
    else
      fd_after_display=exited
    fi
    printf "native-v2 fixture mode=%s code=%s fd=%s->%s\n" "$mode" "$code" "$fd_before_count" "$fd_after_display"
    if [[ "$mode" == owner-loss ]]; then
      [[ "$fd_after_display" == exited ]]
    fi
  ' bash "$runner" "$tmp/native-v2-daemon" "$mode" "$tmp"
}

run_disconnect_case() {
  dbus-daemon --help >/dev/null 2>&1 || true
  dbus-daemon --session --nofork --nopidfile --print-address=3 --print-pid=4 \
    3>"$tmp/private-bus.address" 4>"$tmp/private-bus.pid" &
  local bus_pid=$! bus_starttime bus_address daemon_pid daemon_starttime
  bus_starttime=$(proc_starttime "$bus_pid")
  cleanup_disconnect() {
    local status=$?
    if [[ $status != 0 ]]; then
      echo "native-v2 disconnect failed; evidence directory=$tmp" >&2
      for log in "$tmp/disconnect-daemon.log" "$tmp/disconnect-client.err"; do
        [[ -f "$log" ]] || continue
        echo "--- $log ---" >&2
        cat "$log" >&2 || true
      done
    fi
    set +e
    if [[ -n "${client_pid:-}" && -n "${client_starttime:-}" ]]; then
      kill_identity TERM "$client_pid" "$client_starttime" 2>/dev/null || true
      wait_process_with_deadline "$client_pid" "$client_starttime" 5000 || true
    fi
    if [[ -n "${daemon_pid:-}" && -n "${daemon_starttime:-}" ]]; then
      kill_identity TERM "$daemon_pid" "$daemon_starttime" 2>/dev/null || true
      wait_process_with_deadline "$daemon_pid" "$daemon_starttime" 5000 || true
    fi
    kill_identity TERM "$bus_pid" "$bus_starttime" 2>/dev/null || true
    wait_process_with_deadline "$bus_pid" "$bus_starttime" 5000 || true
    set -e
    trap - RETURN
    return "$status"
  }
  trap cleanup_disconnect RETURN

  for _ in $(seq 1 100); do
    if [[ -s "$tmp/private-bus.address" && -s "$tmp/private-bus.pid" ]]; then break; fi
    sleep 0.01
  done
  bus_address=$(<"$tmp/private-bus.address")
  [[ -n "$bus_address" ]]
  export DBUS_SESSION_BUS_ADDRESS="$bus_address"
  "$tmp/native-v2-daemon" disconnect >"$tmp/disconnect-daemon.log" 2>&1 &
  daemon_pid=$!
  daemon_starttime=$(proc_starttime "$daemon_pid")
  for _ in $(seq 1 100); do
    reply=$(dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
      string:dev.fushell.SingletonExample 2>/dev/null || true)
    if [[ "$reply" == *"boolean true"* ]]; then break; fi
    sleep 0.01
  done
  [[ "$reply" == *"boolean true"* ]]
  "$runner" status >"$tmp/disconnect-client.out" 2>"$tmp/disconnect-client.err" &
  local client_pid=$! client_starttime helper_pid helper_starttime client_code
  client_starttime=$(proc_starttime "$client_pid")
  for _ in $(seq 1 200); do
    if [[ -f "$tmp/disconnect-daemon.log" ]] && grep -q COMMANDLINE_PENDING "$tmp/disconnect-daemon.log"; then break; fi
    sleep 0.01
  done
  grep -q COMMANDLINE_PENDING "$tmp/disconnect-daemon.log"
  helper_pid=
  for _ in $(seq 1 100); do
    if pid_identity_running "$client_pid" "$client_starttime"; then
      helper_pid=$(pgrep -P "$client_pid" 2>/dev/null | head -n1 || true)
      [[ -n "$helper_pid" ]] && break
    fi
    sleep 0.01
  done
  [[ -n "$helper_pid" ]]
  helper_starttime=$(proc_starttime "$helper_pid")
  kill_identity TERM "$bus_pid" "$bus_starttime"
  set +e
  wait_process_with_deadline "$client_pid" "$client_starttime" 10000
  client_code=$?
  wait_process_with_deadline "$daemon_pid" "$daemon_starttime" 5000
  daemon_code=$?
  set -e
  printf "native-v2 disconnect client=%s daemon=%s\n" "$client_code" "$daemon_code" >&2
  cat "$tmp/disconnect-client.err" >&2 || true
  [[ $client_code == 125 ]]
  [[ $daemon_code == 0 || $daemon_code == 1 ]]
  wait_pid_gone_or_reused "$helper_pid" "$helper_starttime" $(( $(monotonic_ms) + 5000 ))
  grep -Eiq "owner disappeared|D-Bus connection was lost|daemon.*lost" "$tmp/disconnect-client.err"
  set +e
  wait_process_with_deadline "$bus_pid" "$bus_starttime" 5000
  bus_code=$?
  set -e
  [[ $bus_code != 124 ]]
  trap - RETURN
  return 0
}

for mode in normal completed124 timed-out reply-first eof-first eof-no-summary integrity invalid-terminal invalid-final-signature version1 counter-mismatch owner-loss probe-sigint probe-sigterm; do
  run_case "$mode"
done
run_disconnect_case
printf 'native-v2 fixture: PASS (no EGL/Wayland)\n'
