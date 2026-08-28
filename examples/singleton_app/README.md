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
status             show daemon status
quit               stop the daemon
help               show this help
```

The native runner treats these arguments as opaque bytes. `FushellApplication`
decodes and dispatches them to the Dart handler, and the handler decides their
syntax, behavior, output, and exit status.
