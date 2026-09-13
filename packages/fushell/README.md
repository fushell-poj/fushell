# fushell

Dart API for the fushell headless shell: create Wayland windows backed by
Flutter views in a single engine, bind parent/child relationships, and exit
the process explicitly.

fushell starts **headless** (no implicit window). The Dart `main()` runs as a
shell: it creates windows via `FushellWindow.openWindow` and renders each
window's content to the corresponding `FlutterView` with the framework's
`View`/`ViewCollection` widgets. Closing **all** windows does not exit the
process; call `FushellProcess.exit` to terminate. Framework `SystemMouseCursors` work automatically through the native Wayland cursor-shape protocol when the compositor supports it; no Dart-side cursor API is required.

## Fonts

Flutter's engine discovers system fonts through Fontconfig. Fushell requires a
Fontconfig-enabled Linux engine; installing a font does not make it available to
an engine built only to scan /usr/share/fonts. The Dart SDK does not copy system
fonts into application assets or register replacement font aliases.

Use generic families such as `sans-serif`, `serif`, and `monospace` for desktop
preferences, or declare application-owned fonts in Flutter's `pubspec.yaml`.
System font selection follows the Fontconfig configuration visible to the running
process, including on NixOS. After installing or changing system fonts, refresh
the Fontconfig cache with `fc-cache -f` and restart the application so its engine
can discover the updated fonts.

## Native tooltips

Import `package:fushell/tooltip.dart` and replace Material Tooltip with
`NativeTooltip(message: ..., child: ...)` to render outside the parent window.
Wrap your application-owned root views in `NativeTooltipHost`. The host adds
and renders its own popup views; do not also include those views in a list of
all PlatformDispatcher views. It must be above the explicit View/ViewCollection
tree, not inside a parent View.

For explicit lifetime management, pass a `NativeTooltipController` to the host
and await `controller.dispose()` before terminating the application. Tooltip
themes, direction, localization and text scaling are captured from the hovered
widget. `animationDuration` controls the fade; reduced-motion settings disable
it. Native popup input is passthrough, and no input grab is requested.

## Status notifier tray host

Import `package:fushell/tray.dart` for the pure Dart SNI host and DBusMenu client.
The transport uses the session D-Bus and needs no Flutter plugin registration.

```dart
import 'package:fushell/tray.dart';

final host = await TrayHost.connect();
void renderItems() {
  for (final item in host.items) {
    print('${item.title}: ${item.status}');
  }
}
final subscription = host.changes.listen((_) => renderItems());
renderItems(); // Also render the current snapshot.
// await item.activate();
// final menu = await item.loadMenu();
// await menu?.event(menuItemId);
// await menu?.close();
// At shutdown:
await subscription.cancel();
await host.close();
```

A host reuses an existing `org.kde.StatusNotifierWatcher`. If none exists,
it exports a fallback watcher without replacing or queueing behind another
owner. Multiple hosts may coexist; each registers a unique host name. Watcher
owner changes clear stale items and trigger registration and discovery again.
Applications must re-register after a watcher disappears; their old registry
cannot be recovered from D-Bus. Reconnect the host if the session bus itself is
restarted. `lastError` and `watcherOwner` are available for diagnostics.

`TrayItem` exposes metadata, status, tooltip, theme icon names/paths and raw
ARGB pixmaps (including attention and overlay icons). It supports activation,
secondary activation, context menus and scrolling. Each item is bound to its
unique service owner, so stale handles never send actions to a replacement app.
`TrayMenu` exposes a live immutable layout, `AboutToShow` and menu events.
Menu nodes preserve visibility, enabled state, separators, toggles and submenus.
Rendering and screen coordinates belong to the application. For theme names,
use `IconResolver` from `package:fushell/icons.dart` (see below).
Close menu transports when done. Sharing an explicitly supplied `DBusClient`
is supported; close all hosts before closing that client. The host only closes
a client it created itself.

This supports modern StatusNotifierItem/DBusMenu trays, not legacy XEmbed.
See `examples/tray_preview` in the repository for a live Flutter inspector and
a standalone demo item. Run protocol integration tests with `flutter test`
from `packages/fushell`; the tray tests create their own private `dbus-daemon`.

## Command-line interface

The installed developer tool is `fushell`, and all operations use explicit
subcommands.

```bash
# Build the current Flutter project into build/fushell.
fushell build

# Build another project or select a mode.
fushell build --debug ./examples/smoke_app
fushell build --profile ./examples/smoke_app
fushell build --release ./examples/smoke_app

# Build and run. Debug keeps hot reload enabled by default.
fushell run --debug ./examples/smoke_app
fushell run --profile ./examples/smoke_app

# Export the canonical Dart SDK package.
fushell sdk ./vendor
```

Debug runs enable the localhost Dart VM Service automatically. Profile runs
enable it when DevTools or an explicit service port is requested:

```bash
# Start browser DevTools and connect it to this fushell process.
fushell run --debug --devtools ./examples/smoke_app

# Profile with DevTools but do not open a browser automatically.
fushell run --profile --devtools --no-launch-browser ./examples/smoke_app

# Bind a deterministic localhost port for manual tooling connections.
fushell run --debug --vm-service-port=8181 ./examples/smoke_app
```

The CLI prints the authenticated VM Service URI. For debug runs it manages a
non-interactive `flutter attach --machine` bridge, then connects both
`dart devtools` and fushell hot reload to the bridge's DDS URI. This supplies
the Flutter expression compiler required by the Inspector and Debugger. Profile
runs connect DevTools directly. All managed tool processes are terminated when
the application exits. VM Service authentication remains enabled, binding is
loopback-only, and a requested busy port is reported as an error before the
application starts. DevTools and VM Service options are not available for
release runs.

## Single-instance daemon and application commands

Multiple independent processes are the default; in that mode the runner passes
application arguments through unchanged to `main(List<String> arguments)`. Opt
into a single-instance application with a project-root `fushell.json`:

```json
{
  "schemaVersion": 1,
  "applicationId": "dev.example.MyApp",
  "instance": "single"
}
```

The first execution owns `dev.example.MyApp` on the session D-Bus and starts the
headless Flutter engine. Later executions forward argv and cwd to the daemon
without initializing Flutter, Wayland, or EGL. Fushell treats argv as opaque
bytes: the application owns all command names, parsing, help, output, and exit
codes.

```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:fushell/fushell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FushellApplication.run(
    onCommand: (FushellCommandInvocation command) async {
      final FushellCommandOutput output = command.output;
      final args = command.arguments
          .map((bytes) => utf8.decode(bytes))
          .toList(growable: false);

      switch (args) {
        case ['open', 'window']:
          final id = await FushellWindow.openWindow(
            title: 'My App',
            appId: 'dev.example.MyApp',
          );
          await output.writeStdoutText('$id\n');
          return FushellCommandResult();
        case ['quit']:
          Timer(const Duration(milliseconds: 50), FushellProcess.exit);
          await output.writeStdoutText('stopping\n');
          return FushellCommandResult();
        default:
          await output.writeStderrText('unknown command\n');
          return FushellCommandResult(exitCode: 64);
      }
    },
  );
}
```

`FushellCommandOutput` 提供 `writeStdout`、`writeStderr` 以及对应的 text helper。
raw frame 最大 32 KiB，stdout 与 stderr 合计最多 8 MiB；每个 invocation 同时只能有
一个 write 在途。`FushellCommandResult` 只携带 0..255 的 `exitCode`，handler 必须在
返回前等待业务 output Future。text helper 会先完整 UTF-8 编码，再按 bytes 分片。

For example, after the first process is running headlessly:

```bash
./my_app open window
./my_app quit
```

`FushellCommandInvocation.arguments` and `workingDirectory` preserve raw Unix
bytes; applications may choose their own decoding policy. `isInitial` marks the
first process invocation. Commands are processed in arrival order with one
active callback at a time. Secondary processes receive streaming stdout/stderr
frames before the handler completes and the final exit code afterward. A handler
exception becomes exit code 70. A started output write that fails also makes the
command complete with 70, even if the handler catches the write error, returns
another exit code, or does not await the write. This rule is independent of whether
the failure arrives before or after the handler returns. The failed writer closes;
synchronous size, quota, and concurrent-write preflight errors do not close it.

If a callback exceeds 30 seconds, its caller receives 124, the active invocation's `cancelled`
future completes, and `isCancellationRequested` becomes true. The handler then
has a two-second grace period to release resources and return. If it still does not
finish, the daemon rejects queued calls, exits cleanly, and the next invocation
starts a fresh daemon; timed-out commands are never replayed. Closing every
window does not stop the single-instance daemon.

Single-instance startup fails explicitly if the session D-Bus is unavailable.
The runner uses a private native `libdbus-1` connection; applications do not
need a Dart D-Bus package for this protocol. A complete dynamic-window example
is available at [`examples/singleton_app`](../../examples/singleton_app).

## Creating windows

```dart
import 'package:flutter/material.dart';
import 'package:fushell/fushell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final int mainWindowId = await FushellWindow.openWindow(
    title: 'My App',
    appId: 'my.app',
    width: 800,
    height: 600,
  );
  // Child window: xdg set_parent (transient). The compositor unparents it
  // when the parent closes; closing a parent does NOT cascade-close children.
  final int settingsWindowId = await FushellWindow.openWindow(
    title: 'Settings',
    appId: 'my.app.settings',
    width: 480,
    height: 360,
    parent: mainWindowId,
  );

  final mainView = await FushellWindow.viewById(mainWindowId);
  final settingsView = await FushellWindow.viewById(settingsWindowId);

  // ViewCollection is the root of multiple independent render trees, so use
  // runWidget rather than runApp (which installs a single-view wrapper).
  runWidget(ViewCollection(views: [
    View(view: mainView, child: const MainApp()),
    View(view: settingsView, child: const SettingsApp()),
  ]));
}
```

`openWindow` returns the window id, which equals the `FlutterView.viewId`.
`viewById` waits for the view to appear in `PlatformDispatcher.views`.

## Closing windows & exiting

```dart
// Removes the view and destroys the window's Wayland surface.
await FushellWindow.closeWindow(settingsWindowId);

// compositor 的关闭请求（例如标题栏关闭按钮）同样经过异步 RemoveView 生命周期。
// 无论关闭由应用还是 compositor 发起，都要同步移除 ViewCollection 中的状态。
final subscription = FushellWindow.closed.listen((event) {
  removeViewWidget(event.windowId); // 该更新必须幂等。
});

// Explicit process exit (headless shell termination).
await FushellProcess.exit(0);
```

Exit codes outside `0..255` fail locally with `RangeError`. Exit remains fire-and-forget:
its Future does not wait for a native response. A synchronous transport failure
reaches the caller; a later asynchronous send failure is logged.

## Optional window helpers

Import `package:fushell/windows.dart` for lifecycle helpers layered over the primitive
window API. `FushellWindowViews` rebuilds a keyed `ViewCollection` as views change;
its builder runs below each `View` so `View.of(context)` is available. Use
`runWidget` for this root. The optional `onLastViewClosed` callback lets the
application choose whether to exit; initial emptiness does not invoke it.

```dart
import 'package:fushell/fushell.dart';
import 'package:fushell/windows.dart';

final windows = FushellWindowController();
final window = await windows.open(
  create: () => FushellWindow.openWindow(title: 'Settings', appId: 'my.settings'),
);
// window.windowId and window.view are ready; window.close() is idempotent.
await window.close();
await windows.dispose();
```

The controller exposes ready handles through `windows` and implements
`Listenable`. Disposing it cancels view-readiness waits and closes owned windows,
including IDs returned by an already-pending native create. A native create that
never replies keeps disposal pending. Failed closes retain ownership so cleanup
can be retried; callers must await or handle open, close, and disposal failures.
For an owned subset, pass `views: () => windows.windows.map((w) => w.view)` and
`listenable: windows` to `FushellWindowViews`. The controller and widget expose
optional view/event/close callbacks for local testing without global overrides.

Surface requests use Flutter's standard `BinaryMessenger`; tests can mock
`dev.fushell/surface` directly. Malformed JSON, UTF-8, and non-object replies
raise `FushellSurfaceException` with code `InvalidResponse`. Missing replies use
`NoResponse`, and native failure replies preserve their error code and message.

## Layer-shell windows

Pass `layer` to `openWindow` (mutually exclusive with a regular window;
`title`/`appId` are ignored):

```dart
final int topBarId = await FushellWindow.openWindow(
  title: 'unused',
  appId: 'unused',
  layer: const LayerSurfaceRole(
    namespace: 'my-panel',
    layer: LayerSurfaceLayer.top,
    anchors: {
      LayerSurfaceAnchor.top,
      LayerSurfaceAnchor.left,
      LayerSurfaceAnchor.right,
    },
    exclusiveZone: LayerExclusiveZone.fixed(32),
    height: 32,
  ),
);
```

Mutable layer-shell properties are updated with `FushellWindow.updateLayer`:

```dart
await FushellWindow.updateLayer(
  topBarId,
  const LayerSurfaceUpdate(height: 28, exclusiveZone: LayerExclusiveZone.fixed(28), margins: Margins(top: 4)),
);
```

Exclusive zones intentionally use the immutable `LayerExclusiveZone` API instead
of integers (a breaking change, with no integer compatibility shim).
Use `LayerExclusiveZone.none` (the default, protocol 0) to reserve nothing while
respecting other zones; `LayerExclusiveZone.ignoreOtherZones` (protocol -1) ignores
other zones and **does not** request automatic calculation. Use
`const LayerExclusiveZone.fixed(32)` for a positive logical-pixel reservation;
serialization validates positive signed 32-bit values in release builds too.
`LayerExclusiveZone.auto` serializes as `"auto"`: native resolves the actual
logical surface height (top/bottom) or width (left/right) plus the **opposite**
margin, never painted/transparent bounds or the anchored margin. Auto requires
an unambiguous anchored edge and a positive requested thickness: height for
top/bottom, width for left/right. Protocol zero dimensions require opposite
anchors, so zero thickness cannot be used for the first map; zero cross-axis
stretch is supported. Unsupported combinations are rejected natively, including
after merging updates. Auto does not predict other bars' reservations.
A null update exclusiveZone preserves the current policy.

`width: 0` / `height: 0` asks the compositor to derive that dimension from
anchors. Compositors without layer-shell support (e.g. older cage) reject the
window with a `LayerShellUnavailable` exception — catch it if you want to
degrade gracefully.

Window metadata updates:

```dart
await FushellWindow.updateWindow(
  mainWindowId,
  const WindowSurfaceUpdate(title: 'New title', appId: 'my.app.updated'),
);
```

## What can hot reload change?

Flutter hot reload can update Dart UI state, colors, text, fonts, and layout
inside each existing Flutter view, plus `FushellWindow.updateWindow` /
`FushellWindow.updateLayer` calls that run after reload.

Hot reload does not rerun `main()`, so changing startup `openWindow` calls
requires a full fushell process restart. Reloaded callbacks and timers can
still call `openWindow` to create additional views. Calling `updateLayer` on
a window role, or `updateWindow` on a layer role, returns a structured
`FushellSurfaceException`.

## Bundle requirements

Debug/JIT bundles contain `data/flutter_assets/kernel_blob.bin`. Release/AOT
bundles must contain both `lib/libapp.so` and its matching split debug-info
artifact at `lib/libapp.so.symbols`. `fushell build --release` generates and
packages both; the runner rejects incomplete AOT bundles instead of silently
starting without symbolization support.

When an application does not bundle Flutter's default font families, fushell
exposes a fontconfig-selected system font under a stable runtime asset path.
The SDK registers only the missing aliases before the first window is added;
font families already declared by the application remain untouched.

## Concurrency model (for embedder maintainers)

The native renderer uses one engine, one Wayland connection, one event loop
(main thread), and one shared
EGL render context. Each window is a `FlutterView` (id 1, 2, …) rendered via
the FlutterCompositor path: the engine rasterizes into GL backing-store
textures and `present_view_callback` blits them to the window's EGL surface.
Present runs on an engine thread; `present_mutex` serializes it with main
thread resizes. Window destruction is asynchronous: `closeWindow` submits
`FlutterEngineRemoveView` and destroys the surface only after the
`remove_view_callback` confirms the engine no longer touches the view.

The platform thread blocks on the Wayland display fd, Flutter's task `eventfd`,
and an active clipboard-transfer fd. Flutter deadlines determine the poll
timeout, so an idle headless process has no periodic wakeup while `Timer` and
`Future` callbacks still run at their requested deadlines. Clipboard reads are
non-blocking state machines with a 16 MiB resource limit and a 5 second timeout;
they never synchronously block the platform thread.

## SDK source of truth

`packages/fushell` is the canonical SDK source used by in-repository examples.
`fushell sdk` exports that same package for external consumers; no
checked-in vendored SDK copy is maintained.

## Linux theme icon lookup

Import `package:fushell/icons.dart` for a pure Dart filesystem resolver. It does
not require a Flutter platform channel, GTK, or a running Fushell engine.
The resolver returns file metadata; image decoding and SVG rendering belong to
the application.

```dart
import 'package:fushell/icons.dart';

final icons = IconResolver(); // Follow the configured desktop icon theme.
print(await icons.resolveTheme()); // e.g. Fluent-dark
final result = await icons.lookup(
  name: 'network-wireless',
  size: 24,
  scale: 2,
  extraSearchPaths: [], // e.g. a tray item's IconThemePath
);
if (result != null) {
  print(result.path);
}
icons.clearCache(); // After installing icons or changing theme files.
```

Without an explicit theme, the resolver reads the desktop's configured icon
theme. GNOME-family sessions prefer GSettings; KDE prefers the Icons/Theme
setting in kdeglobals; other desktops (including Hyprland) prefer GTK settings.
GTK configuration respects XDG_CONFIG_HOME and XDG_CONFIG_DIRS. GSettings is an
optional, bounded command fallback; no GTK plugin is required. If no usable
setting is available, the selected theme falls back to `hicolor`.

Use `await icons.resolveTheme()` to inspect the selected theme. A constructor
`theme` or a per-lookup `theme` overrides automatic selection. `clearCache()`
invalidates system-theme detection as well as icon metadata; filesystem and
desktop-setting changes are not watched automatically. Searches honor theme
inheritance, size/scale matching and fallback paths. A custom `searchPaths`
list replaces the default theme roots for private installations and tests.
Missing icons return null.

See `examples/icon_preview` for an independent lookup inspector and
`examples/tray_preview` for tray and DBusMenu integration.

## Wayland workspaces

Import `package:fushell/workspace.dart` for a pure Dart, asynchronous client for
`ext-workspace-v1`. It owns an independent Wayland connection and does not require
a running Fushell engine, GTK, a Flutter platform channel, or a native plugin.
The compositor must advertise the protocol; otherwise connecting throws
`WorkspaceException` with code `UnsupportedProtocol`.

```dart
import 'package:fushell/workspace.dart';

final workspace = await Workspace.connect();
void printSnapshot() {
  for (final entry in workspace.workspaces) {
    print('${entry.name ?? entry.id ?? entry.objectId} active=${entry.isActive}');
  }
}
printSnapshot();
final subscription = workspace.changes.listen((_) => printSnapshot());

// In response to a user action, using an entry from this connection:
// await workspace.activate(entry);

// When the owner is disposed:
await subscription.cancel();
await workspace.close();
```

`Workspace.connect()` discovers the socket from `WAYLAND_DISPLAY` and
`XDG_RUNTIME_DIR`; `socketPath` can override it for private compositors and tests.
Connection and initial discovery have a bounded `timeout`. The initial snapshot
is ready when connect completes. Subsequent workspace changes are published
atomically after the protocol's `done` event. Treat `workspaces` and `groups` as
immutable snapshots; subscribe to `changes` to obtain replacements.

Entries expose optional persistent IDs and names, coordinates, active/urgent/
hidden states, group membership, and operation capabilities. Group outputs
expose optional names and descriptions. Object IDs identify one connection's
protocol objects; they are not persistent workspace identifiers. Operations
validate the entry's lifetime and the latest capabilities before sending a
request followed by `commit`. Available methods are `activate(entry)`,
`deactivate(entry)`, `remove(entry)`, `assign(entry, group)`, and
`createWorkspace(group, name)`. A completed operation means the request was sent;
the compositor's subsequent snapshot is authoritative and may reject or ignore
a request according to its policy.

An active workspace is not necessarily the keyboard-focused workspace. This
protocol does not provide window counts, window membership, or global keyboard
focus. No compositor-specific IPC fallback is included. Closing is idempotent;
a disconnection terminates this client and records `lastError` when applicable.
The last snapshot remains readable after closure, but operations fail.
Create a new `Workspace` to reconnect. The preview at
`examples/workspace_preview` shows outputs, states, capabilities, and explicit
activation controls.

The wire bindings are generated from pinned official XML snapshots, rather than
hand-maintained message opcodes. See the protocol and generator files shipped
with the SDK for provenance and reproducible regeneration instructions.
