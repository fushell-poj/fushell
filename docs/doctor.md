# Doctor diagnostics

```sh
fushell doctor
fushell doctor --verbose
fushell doctor --machine ./my_app
fushell doctor --help
```

With no path, doctor checks the environment only, even if the current directory
is a Flutter project. A supplied path opts into project checks and that project's
Engine cache. It never requires an official `linux/` host, GTK/CMake/Ninja, Zig,
ZLS or Nix to develop a Fushell application.

## What is checked

- Linux and the running executable's x86_64/aarch64 architecture.
- The actual SDK selected by `Toolchain.discover`: `FLUTTER_ROOT`, then
  `FLUTTER_SDK`, then PATH. Its exact Flutter executable supplies the machine
  version and full Engine revision. The selected Dart executable is run, and
  the Flutter tools package configuration and packaging ICU artifact are checked.
  Presence is not a claim that every compiler target or native plugin will build.
- Project metadata, only with an explicit project path: readable pubspec,
  the optional manifest using the same application-config parser as the runtime,
  and the conventional `lib/main.dart` entrypoint. A missing conventional entry
  is a warning because build/run accept a custom Dart entrypoint.
- Actual YAML dependency mappings using the selected SDK's `package:yaml`, not
  substring searches. Comments and dev_dependencies do not satisfy the Fushell
  dependency. Local dependencies and dependency_overrides/pubspec_overrides are
  resolved; hosted/git sources are allowed instead of assuming `vendor/fushell`.
  Package config schema 2, unique package names, local root/package URIs, the
  effective SDK path, SDK pubspec/library, and selected Flutter package root are
  checked. Shared parent package configurations are recognized for workspaces.
  This is not a complete pub dependency solver or a static Dart analyzer.
- Matching Engine metadata and any supplied project's cached modes. Network
  probes fetch **only metadata**, never an Engine binary. Remote success means
  metadata lists valid entries, not that all remote binary bytes were fetched
  or verified. Cached modes are individually SHA-256 verified using the store's
  metadata, origin, filename and digest rules.
- A real Wayland connection and sync round trip, without a surface/window/EGL
  context. Absolute display paths work without XDG_RUNTIME_DIR. Inherited
  WAYLAND_SOCKET connections are not consumed. Optional protocols and GPU
  rendering are outside this diagnostic's scope.
- A temporary private session D-Bus connection, Hello registration and Unix FD
  transport capability, without claiming the application name. Doctor uses an
  explicit session address or the conventional user bus, never autolaunch.
  Single-instance policy is checked even when Flutter discovery has failed.

## Results and exit status

Human output always displays warning/error details and remedies. `--verbose`
(or `-v`) also displays successful check details. `--machine` emits one JSON
object on stdout, with no progress output and all diagnostic details:

```json
{"schemaVersion":1,"status":"warning","checks":[{"id":"wayland","title":"Wayland session","status":"warning","summary":"not_configured","details":[],"remedy":"Building/creation do not require a display; running windows requires a working Wayland session."}]}
```

Statuses are `ok`, `info`, `warning`, and `error`. IDs such as `flutter`,
`project.pubspec`, `project.packages`, `engine.debug`, `engine.profile`, and
`engine.release` are stable; additional checks may be added. A skipped check is
not a success. Warning/error details are not hidden by the verbosity flag.
Exit 0 allows warnings, exit 1 means a required check failed, and exit 2 is a
command-line usage error. SIGINT/SIGTERM cancel active probes and return 130/143.
A missing Wayland session is a warning for build-only/headless usage. A missing
session bus is an error for a project explicitly configured as single-instance.

## Read-only cache and bounded probes

Doctor never calls Store.ensure, repairs/removes files, creates cache locks,
runs a build, runs project hooks, invokes pub get in the inspected project, or
changes global Flutter settings. It takes a nonblocking shared lock on an
**existing regular** cache lock. Busy caches are skipped with a warning; absent
locks, wrong origins, malformed metadata, nonregular files and bad hashes are
not trusted. A fully verified three-mode cache requires no network/curl call.
Partial cache results remain visible when a remote query fails. Broken bytes
are preserved so normal build recovery, not diagnostics, owns replacement.

Remote requests use the configured Engine repository and inherited proxy/CA
environment, with bounded output and TLS verification. DNS/proxy/connect/TLS/
timeout errors are distinguished from HTTP 401/403/404/407/429/5xx. A 404 is not
proof that a private release does not exist. Reports never echo raw curl stderr
or proxy credentials; credential/query-bearing repository URLs are rejected.
Paths and other diagnostic text have control/non-UTF-8 bytes escaped for safe
terminal and JSON output.

Flutter discovery and native session calls run in isolated child processes of
this exact Fushell executable. The private probe entrypoint is an internal
protocol, not another user-facing command or a compatibility layer. This keeps
blocked/crashing native libraries from taking the report process with them.
Wall-clock limits include silence, slow output, and children that close their
pipes without exiting. Cancellation terminates owned process groups and reaps direct probe children.
Current limits are 30 seconds for Flutter discovery, 3 seconds per session
probe, 5 seconds for Dart version, 15 seconds for YAML inspection, 20 seconds
for curl supervision (curl itself gets 15), and 10 seconds for cache hashing.
These limits are per check, not a promise of a single total command duration.

The YAML helper is written to a private temporary directory and removed after
use; project files are only read. Invoking Flutter's version command may trigger
**Flutter's own SDK bootstrap/cache maintenance**. Read-only project diagnostics
are not a promise that the Flutter executable never writes its SDK cache or
contacts the network. Runtime compatibility is not guaranteed merely because
the ELF loader allowed Fushell to start; doctor does not validate every bundle's
loader, dynamic library closure, GPU driver or application code.

## Regression coverage

`zig build test` includes report ownership/escaping/allocation failures, bounded
subprocess behavior, shared store validation, cache integrity and CLI syntax.
`tests/cli_smoke.sh` includes `tests/doctor_smoke.py`, which uses fake SDK/curl
processes plus real files/hashes, a private Wayland protocol fixture and (when
installed) a private dbus-daemon. It tests failure classification, partial and
corrupt caches, locking, no implicit project, JSON, and signal cleanup.

`tests/doctor_flutter_smoke.sh` requires an initialized FLUTTER_ROOT. It runs
`tests/doctor_project_test.dart` against the SDK's real YAML parser, creates a
real Fushell project and checks the compiled doctor's read-only project flow.
Only its Engine HTTP response is stubbed. The formal CI runs this after the Zig
and CLI suites. None of these checks imply a GPU/window rendering test.
