# fushell

A Wayland Flutter embedder with official Flutter multi-view support. One Flutter
engine and isolate can create and manage multiple native windows from Dart.
Native [popups](docs/popups.md) provide independently rendered, parent-relative
surfaces for tooltips and popovers, including children of layer-shell bars.
The Dart `NativeTooltip` widget in `package:fushell/tooltip.dart` manages native
popup views, hover timing and theme propagation; see [Tooltip integration](docs/popups.md).
Its `verticalOffset` uses Material's target-center semantics; `edgeGap` explicitly
requests spacing from the target edge instead.

Layer surfaces use typed `LayerExclusiveZone` policies: `auto`, `none`,
`ignoreOtherZones`, or `fixed(logicalPixels)`. Automatic reservation follows the
native surface's logical size and the opposite-edge margin, without counting the
anchored margin twice. It does not measure Flutter content or transparent pixels.
See the [Dart SDK](packages/fushell/README.md) for API and migration details.

## Build the tools

The project targets **Zig 0.16.0**. Native development dependencies include
Wayland, EGL/GLES, xkbcommon, Fontconfig, D-Bus and `pkg-config`/`wayland-scanner`.
Running graphical applications requires **OpenGL ES 3.0 or newer**, including
an EGL configuration with an alpha channel. Unsupported contexts fail at startup.

The runtime Flutter Engine must be built with `--enable-fontconfig`. It discovers
system fonts and applies Fontconfig matching and fallback itself. Fushell uses the
application assets directly; it does not create system-font overlays or register
font aliases through Dart. The native launcher retains an explicit Fontconfig
runtime link so independently launched bundles can load the Engine on NixOS.
Fontconfig, its runtime dependencies and installed fonts must remain available.
Application font assets declared in `pubspec.yaml` continue to be managed by Flutter.

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
./result/bin/fushell --help
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

The cache is `build/fushell_flutter_engine/fontconfig-v1/<arch>/<revision>/`, with
metadata, SHA-256 verified shared libraries, an origin record and a persistent lock
file. The contract namespace also applies to custom cache roots. Changing
repositories invalidates cached metadata. Cooperating processes serialize cache
publication; failed downloads never become final Engine files.

The `fontconfig-v1` consumer contract separates native-font-discovery engines from
older, same-SDK-revision builds. Old unversioned caches are left untouched but are
never used as a fallback. The first build after this migration needs network access
to obtain current metadata and its verified Engine; subsequent builds can reuse
the compatible cache offline. This avoids silently copying a pre-Fontconfig Engine
whose checksum still matches an obsolete local catalog. Existing application
bundles retain their own Engine and must also be rebuilt with the updated CLI.

Within a contract namespace, cached metadata is still revision-pinned rather than
periodically refreshed. Engine publishers must not treat reusing the Flutter SDK
revision as a consumer cache invalidation mechanism; capability changes need an
explicit consumer contract migration. A custom repository must provide Engines
meeting the native Fontconfig contract, not merely a matching revision string.

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

Use `fushell <command> -h` or `fushell <command> --help` for command-specific
usage. Option values accept both `--vm-service-port=8181` and
`--vm-service-port 8181`. Syntax errors exit with status 2 and identify the
relevant command; help exits successfully without requiring a Flutter SDK.

`fushell run ./app -- <arguments...>` forwards every argument after `--` to the
application unchanged. For `build` and `sdk`, `--` instead introduces positional
paths, including paths starting with `-`. Relative output directories are resolved
inside the selected project, as before.

The CLI uses zig-clap pinned to `8d97efa1ee1e575443c7888d5c38e1c3fc145cf5`, the
upstream commit immediately before its Zig 0.17 migration. Both `build.zig.zon`
and generated `deps.nix` pin that source. `zig build cli-test` runs the parser and
help regressions; `tests/cli_smoke.sh` checks the compiled executable's public
entry point without Flutter or a display.

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

`zig build rendering-test` runs native window-lifecycle and geometry regressions
without a display; it is also included in `zig build test`. The separate pixel
suite uses a real headless EGL surface and requires an EGL driver:

```bash
EGL_PLATFORM=surfaceless LIBGL_ALWAYS_SOFTWARE=1 zig build test-render
```

With Mesa, this selects software rendering without connecting to the desktop.
The suite checks transparent empty/partial frames, premultiplied layer blending,
GL state and vertex-array isolation, allocation validation and resource cleanup.

See [`packages/fushell/README.md`](packages/fushell/README.md) for the Dart API,
window ownership model, parent relationships, layer surfaces, and multi-view
widget binding.

## Architecture and timing

See [docs/architecture.md](docs/architecture.md) for process ownership, build flow
and testing boundaries. The current frame scheduler is a bounded **60 Hz software
fallback**, not Wayland compositor presentation feedback. It responds only to
requested frames and does not wake idle engines periodically. Hardware refresh
rate synchronization remains a separate rendering integration task.

## Create a project

```sh
fushell create my_app
fushell create --single-instance --org dev.example my_app
fushell create --project-name my_app "a directory with spaces"
fushell create --no-pub my_app
fushell create --help
```

Without an output directory, `fushell create` opens a line-oriented terminal
wizard. With a directory it uses flags/defaults without prompting;
`--interactive` explicitly requests the wizard. Supplied flags are never asked
again. Piped/non-terminal input is rejected when prompting is required. All
questions finish before filesystem writes. There is no `help` subcommand:
use `-h` or `--help` on each command; bare `fushell` shows general help.

Only absent or empty directories are accepted, including `create .` in an
empty directory. Even a directory containing only `.git` is nonempty. There is
no overwrite/force mode or existing-project migration. Symlink destinations
and symlinked parent components are rejected. Files are generated in a private
sibling workspace and published with no-replace renames. Existing empty
folders retain their inode. Ordinary errors roll back; a crash or forced kill
can leave scratch files and is not a power-loss transaction.

Creation calls the selected Flutter SDK's `create --template=app --empty
--platforms=linux --no-pub`. It then exports the canonical SDK to
`vendor/fushell`, adds a relative dependency, writes a minimal view-aware app,
UI test, README and `fushell.json`, and removes the generated GTK/CMake `linux/`
host. Pubspec edits use the YAML AST from the initialized Flutter tools package
configuration; no extra `pub get` is needed for this helper, and SDK bounds and
unrelated pubspec content are preserved. Flutter's existing `.gitignore` is
retained and missing generated-file rules are appended idempotently, including
`/linux/flutter/ephemeral/` and generated plugin metadata. `vendor/fushell`,
`pubspec.lock`, `.metadata` and `fushell.json` remain version-controlled.

The final `flutter pub get` runs in the published project, not the scratch
path. If it fails, the command fails but keeps usable sources and explains how
to retry. `--no-pub` skips this final dependency resolution; it does not prevent
Flutter itself from initializing its SDK caches. Creation does not download
Fushell Engine assets, compile or launch an application, initialize Git, change
Flutter's global settings, or require a display/session bus connection.

Both templates keep the process alive when windows close; use the explicit
Exit button/`FushellProcess.exit()` or Ctrl+C. The single-instance template uses
`FushellApplication.run`, opens at most one window on a no-argument invocation,
and implements a minimal application-owned `quit` command. This does not alter
runtime lifecycle policy. Use Fushell to run/build: official `flutter build
linux` and automatic GTK native-plugin registration are not supported by the
created project.

The creation suite tests parser/TTY behavior and failure safety with fake SDK
processes, then verifies the YAML helper, generated UI tests, static analysis
and Debug/Profile/Release bundle builds with an actual Flutter 3.41.9 SDK in CI.
No Wayland/GPU runtime test is implied by these checks.

## Diagnose the environment

```sh
fushell doctor
fushell doctor --verbose
fushell doctor --machine ./my_app
```

Doctor checks the selected Flutter SDK, Engine metadata or verified project
cache, and desktop sessions. A project path additionally checks real YAML,
resolved SDK/package URIs and single-instance requirements. It does not build,
repair project/cache files, or download Engine binaries. Failures are isolated
and time-bounded; machine output is schema-versioned JSON. Warnings exit 0,
required-check failures exit 1, and syntax errors exit 2.

See [docs/doctor.md](docs/doctor.md) for exact checks, limitations, network/privacy
behavior and regression tests.
