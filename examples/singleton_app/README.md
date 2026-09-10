# fushell singleton daemon example

This application opts into Fushell's D-Bus single-instance mode. The first
process starts a headless Flutter daemon; later processes forward their raw
arguments to the daemon without initializing Flutter, Wayland, or EGL.

Build the example:

```bash
fushell build --debug .
```

Run these commands from separate terminals, using the generated executable:

```bash
APP=build/linux/x64/debug/fushell-app

# Terminal 1: become the daemon without opening a window.
"$APP"

# Terminal 2: commands are defined entirely by lib/main.dart.
"$APP" status
window_id=$("$APP" open 'First window')
"$APP" list
"$APP" close "$window_id"
"$APP" quit
```

Available example commands:

```text
open [title]       open a new window
list               list live windows
close <window-id>  close one window
closed             list completed window-close notifications
status             show daemon status
stream [milliseconds] show output before handler completion
interleaved        emit binary stdout/stderr frames
exact-limit        write exactly 8 MiB
overflow           exercise the output limit
late-write         issue a write before returning
throw              exercise handler diagnostics
wait <milliseconds> wait asynchronously
hang <milliseconds> ignore cancellation (integration testing)
quit               stop the daemon
help               show this help
```

The native runner treats these arguments as opaque bytes. `FushellApplication`
decodes and dispatches them to the Dart handler, and the handler decides their
syntax, behavior, output, and exit status. Business output uses
`invocation.output.writeStdout`, `writeStderr`, `writeStdoutText`, and
`writeStderrText`; each Future must be awaited before returning a result.
Production handlers should observe `invocation.cancelled` during long-running
work and check `invocation.isCancellationRequested` at safe boundaries so they
can release resources before Fushell's two-second recovery grace period expires.

Window content uses `FushellWindowViews` for stable per-view state. `FushellWindowController` owns each create/readiness operation and rolls back failed attachment; root disposal reclaims pending and ready windows. Closing the last native window deliberately keeps the daemon running; `quit` explicitly exits the process.
