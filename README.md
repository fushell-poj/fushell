# fushell

A Wayland Flutter embedder with official Flutter multi-view support. One Flutter
engine and isolate can create and manage multiple native windows from Dart.

## Build the tools

The project targets **Zig 0.16.0**. Native development dependencies include
Wayland, EGL/GLES, xkbcommon, Fontconfig, D-Bus and `pkg-config`/`wayland-scanner`.

```bash
nix develop
zig build
zig build test
```

The installed command is `zig-out/bin/fushell`. Its native bundle runner and the
Dart SDK files are embedded at build time; Flutter Engine binaries are **not**.
The `flutter-embedder` Zig dependency supplies the C ABI header for compilation,
not the runtime Engine selected for an application.

## NixOS package

```bash
nix build
./result/bin/fushell help
```

The package uses `nix/package.nix` and the root `deps.nix` package cache. It provides
runtime `curl` and coreutils through a PATH wrapper, without fixing the application's
Flutter SDK. Update Zig dependencies with `generate-nix-deps` inside `nix develop`,
or run `nix run github:nix-community/zon2nix > deps.nix` explicitly.

Select a Flutter SDK with `FLUTTER_ROOT`, then `FLUTTER_SDK`, or the `flutter` on
PATH. Fushell resolves this once and uses the same SDK for compilation, version
queries, ICU data, frontend_server and DevTools. The SDK must already be initialized.

Generated bundles carry the application, assets and matching Flutter Engine.
System libraries and the ELF loader still depend on the build/target environment;
this is **not** a promise of a universally portable Linux binary. In NixOS those
libraries must remain reachable in the Nix closure or runtime library search paths.
`FUSHELL_RUNTIME_LIBS` remains an optional explicit bundle-library source.

## Flutter Engine cache and safe publication

Fushell reads `engineRevision` from the selected SDK's `flutter --version --machine`,
then downloads the matching `engine-<revision>` release from
`fushell-poj/fushell-engine-builds`. Set `FUSHELL_ENGINE_REPOSITORY` to a compatible
repository URL to override it. curl honors the environment's proxy configuration.

The cache is `build/fushell_flutter_engine/<arch>/<revision>/`, with metadata,
SHA-256 verified shared libraries, an origin record and a persistent lock file.
Changing repositories invalidates cached metadata. Cooperating processes serialize
cache publication; failed downloads never become final Engine files.

Engine acquisition overlaps Dart compilation. A project lock protects Flutter's
shared intermediate outputs. Bundles are assembled in a private sibling staging
directory and published only on success. Replacing existing nonempty directories
requires a recognized Fushell bundle; project/source/intermediate directories are
rejected. On ordinary publication failure the previous bundle is restored. This
provides rollback on errors, not a power-loss-atomic directory transaction.

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

## Pointer input and system cursors

Pointer focus follows Wayland `wl_pointer.enter` independently from keyboard focus, so motion, button, scroll, and Flutter hover updates remain routed to the entered view even though those later protocol events do not carry a surface. Flutter `SystemMouseCursors` are translated through `flutter/mousecursor` to compositor-managed cursor-shape-v1 shapes, including directional resize cursors and `SystemMouseCursors.none`.

cursor-shape-v1 is optional. A compositor without it keeps its default cursor; fushell does not add a client-side cursor theme or `libwayland-cursor` fallback.

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

The bundle contains its validated application manifest; `libdbus-1` is a system dependency, and
the internal runner locates those resources relative to itself. Command handlers use
`invocation.output.writeStdout`, `writeStderr`, `writeStdoutText`, and
`writeStderrText`; `FushellCommandResult` only carries an exit code, while output
frames are streamed with 32 KiB frame and 8 MiB invocation limits. The internal
Application2 final reply carries `terminalKind=completed` or `timedOut`, so a
normal business exit code 124 is not confused with a timeout diagnostic. See
[`examples/singleton_app`](examples/singleton_app) for a complete daemon that
implements application-defined `open`, `list`, `close`, `status`, `quit`, and
`help` commands while managing a dynamic `ViewCollection`.

## Validation

```bash
zig build test
zig build integration-test
zig build -Doptimize=ReleaseFast
```

`zig build integration-test` runs the native V2 fixture and the real two-process
singleton integration; it uses a private session bus and headless Cage compositor.
It covers primary/secondary startup, binary argv and cwd transport, streaming
stdout/stderr frames and exit-code propagation, application-defined window commands, command timeout
recovery, signal handling, ownership races, secondary fast-path loading, and
idle CPU/FD stability.

See [`packages/fushell/README.md`](packages/fushell/README.md) for the Dart API,
window ownership model, parent relationships, layer surfaces, and multi-view
widget binding.

## Architecture and timing

See [docs/architecture.md](docs/architecture.md) for process ownership, build flow
and testing boundaries. The current frame scheduler is a bounded **60 Hz software
fallback**, not Wayland compositor presentation feedback. It responds only to
requested frames and does not wake idle engines periodically. Hardware refresh
rate synchronization remains a separate rendering integration task.
