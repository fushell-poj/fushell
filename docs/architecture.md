# Runtime and build boundaries

## Two entry points, one player

`fushell` (`src/fushell.zig`) only parses and dispatches commands. `src/cli/`
contains the side-effect-free zig-clap declarations, per-command Options, typed
Command union, diagnostics and generated help. Parser strings borrow argv; clap's
temporary allocations are released before returning. The run parser splits at
`--` before invoking clap, so application arguments are never interpreted.

`src/commands/build.zig`, `run.zig` and `sdk.zig` implement their respective
operations. The shared project helper resolves input/output paths only after
parsing succeeds. Help and SDK export do not discover Flutter. Build and run use
a build-only plan; run options are not carried through the packaging pipeline.
Command cleanup completes before the entry point maps failures to process status
(2 for command syntax/validation, 1 for operational failures, 130 for an interrupted
run). Normal application exit status is preserved.

Development runs call `player.runPlayer` in-process. A shipped bundle starts at
`src/main.zig`, locates resources relative to its executable, and calls the same
player. A shipped app does not need Flutter SDK or network access.

The runner is embedded in the CLI. Flutter Engine is downloaded at bundle-build
time and dynamically loaded from the bundle by `flutter_embedder.zig`. A successful
symbol lookup checks the required entry points, not universal compatibility with
all possible future engine versions.

## Single instance remains native

`application_config.zig` selects the instance policy. `application_broker.zig`
claims the session-bus name before initializing Flutter/Wayland/EGL. Secondary
invocations forward byte-preserving arguments/cwd, stream output and return the
command's status. The primary owns the broker; Runner borrows it. This says nothing
about which DSOs the operating-system ELF loader maps before `main`.

Command completion status and requested process exit status are separate. A
process exit request is preserved while the active command reply is flushed, then
returned through Runner -> player -> entry point after orderly shutdown.

## One engine, explicit views

`flutter_runner.zig` owns one Engine and coordinates services. `DisplayState`
owns a shared Wayland connection and globals. `platform_event_loop.zig` borrows
that state and multiplexes Wayland, Flutter tasks, D-Bus, clipboard and shutdown
FDs on the platform thread. There is no dummy window Host to own the event loop.

`window_registry.zig` owns stable-address entries. Each real `Host` owns one
surface role and EGL surface. Dart opens/closes views via platform channels.
Raster callbacks use the shared RenderContext with per-window presentation locks;
the resource context is separate and shares GL objects. No visible window is
created until Dart asks, but Wayland/EGL are still initialized during engine startup.

The frame clock queues VSync batons and releases them on software deadlines. This
prevents immediate recursive frame scheduling. It is explicitly a fallback and
has not been validated as physical display synchronization.

## Build ownership

`flutter_toolchain.zig` chooses one SDK. `flutter_engine_store.zig` owns neither
the SDK info nor the environment; both outlive its async task. `cache_lock.zig`
uses persistent-inode advisory locks. curl receives the supplied directory and
environment. `Child.kill` in cleanup terminates/reaps canceled downloads. HTTP
hashes streamed bytes; curl files are hashed after successful process completion.
`copy` hashes while copying into an atomic temporary output, so invalid content
never replaces an existing target.

`bundle_transaction.zig` rejects destructive destinations and stages all artifacts.
Its publish operation rolls back ordinary errors. A forced crash between directory
renames can leave a named backup to recover manually. Advisory locks coordinate
Fushell processes; they are not a security boundary against a hostile same-user
process replacing files behind them.

`source_snapshot.zig` owns file maps and change lists. Deletions are retained after
an old snapshot is released. The hot-reload frontend receives the actual entrypoint
and escaped file URIs. Shutdown interrupts the initial VM-service wait.

## Validation

The supported baseline is Zig 0.16.0. CI builds Debug and ReleaseFast and runs
`zig build test`, including standalone Store, filesystem, scheduler and ownership
regressions. Fake curl subprocess tests do not require Internet or Flutter.

`zig build integration-test` and `zig build native-v2-fixture-test` remain opt-in;
they need Flutter/Engine assets and extra session-bus/compositor dependencies.
Passing compiler/unit tests does not establish NixOS closure portability, GPU
correctness, high-refresh behavior or full graphical shutdown correctness.

## Project creation

Help is a `ParseResult` outcome, not an executable `Command`. The command union
contains only build/run/sdk/create; no help alias or compatibility parser exists.
`create_prompt.zig` handles defaults and terminal questions without filesystem
writes. `project_draft.zig` stages new project files and never replaces existing
entries; it deliberately does not reuse replaceable bundle transactions.
`commands/create.zig` orchestrates Flutter, SDK export, template configuration,
publication and the final pub get, using one SDK and an explicit environment.
The small Dart configuration helper uses Flutter's existing YAML dependency and
AST spans rather than implementing a second YAML parser in Zig. All template
files live under `src/project_templates` and are embedded at compile time.
The final pub get follows publication so it cannot leave absolute staging paths
in package configuration. Download or dependency errors do not erase delivered
sources. Crashes can leave private staging directories for manual recovery.
