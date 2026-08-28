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

## Single-instance applications

Applications default to multiple independent processes. To opt into a
single-instance daemon, add `fushell.json` at the Flutter project root:

```json
{
  "schemaVersion": 1,
  "applicationId": "dev.example.MyApp",
  "instance": "single"
}
```

The first process owns the application ID on the session D-Bus and starts the
headless Flutter engine. Later executions forward their opaque argv and working
directory to the daemon without initializing Flutter, Wayland, or EGL. Command
syntax and behavior remain entirely application-defined through
`FushellApplication.run`; fushell does not reserve application arguments.
Single-instance bundles fail explicitly when no session D-Bus is available.

The bundle contains its validated application manifest and `libdbus-1` runtime;
the internal runner locates those resources relative to itself. See
[`examples/singleton_app`](examples/singleton_app) for a complete daemon that
implements application-defined `open`, `list`, `close`, `status`, `quit`, and
`help` commands while managing a dynamic `ViewCollection`.

## Validation

```bash
zig build test
zig build integration-test
zig build -Doptimize=ReleaseFast
```

The integration step uses a private session bus and headless Cage compositor.
It covers primary/secondary startup, binary argv and cwd transport, output and
exit-code propagation, application-defined window commands, signal handling,
ownership races, secondary fast-path loading, and idle CPU/FD stability.

See [`packages/fushell/README.md`](packages/fushell/README.md) for the Dart API,
window ownership model, parent relationships, layer surfaces, and multi-view
widget binding.
