# fushell

A Wayland Flutter embedder with official Flutter multi-view support. One Flutter
engine and isolate can create and manage multiple native windows from Dart.

## Build the tools

The project uses Zig 0.16 and a local Flutter engine workspace configured in
`build.zig.zon`.

```bash
zig build
```

This installs:

- `zig-out/bin/fushell` — development CLI
- `zig-out/bin/fushell-runner` — internal bundle player embedded by the CLI

## CLI

Bare `fushell` prints help and does not build implicitly.

```bash
# Build a bundle
fushell build [--debug|--profile|--release] ./app

# Build and run it
fushell run --debug ./app

# Export the Dart SDK package
fushell sdk ./vendor
```

Debug is the default mode. Build output is written to
`build/linux/<arch>/<mode>` unless an output directory is supplied.

## DevTools and VM Service

```bash
# Debug: hot reload and browser DevTools
fushell run --debug --devtools ./app

# Debug: DevTools without automatic hot reload or browser launch
fushell run --debug --no-hot-reload --devtools --no-launch-browser ./app

# Profile: performance profiling through DevTools
fushell run --profile --devtools ./app

# Stable local VM Service port
fushell run --debug --vm-service-port=8181 ./app
```

The VM Service binds to localhost and keeps its authentication token enabled.
For debug runs, `--devtools` starts a managed, non-interactive
`flutter attach --machine` bridge so DevTools receives Flutter's expression
compiler and exposes the Inspector and Debugger. DevTools and fushell hot reload
then share the bridge's authenticated DDS URI. Profile runs connect
`dart devtools` directly because they do not need source expression evaluation.
The CLI terminates both managed tools when the application exits; the raw VM
Service URI remains in the application log for manual clients. `SIGINT` and
`SIGTERM` use the same controlled shutdown path, so Flutter Tool pipes remain
valid until attach and DevTools are fully reaped. The `flutter` and `dart`
executables used by the project must therefore be available on `PATH` when
DevTools is enabled.

Release mode does not expose the VM Service and rejects DevTools options.

## Validation

```bash
zig build test
zig build -Doptimize=ReleaseFast
```

See [`packages/fushell/README.md`](packages/fushell/README.md) for the Dart API,
window ownership model, parent relationships, layer surfaces, and multi-view
widget binding.
