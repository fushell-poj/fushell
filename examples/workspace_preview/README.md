# Workspace preview

A standalone Material inspector for the public `Workspace` API in `package:fushell/workspace.dart`. Opens a resizable 960 × 680 Fushell window and connects to the compositor’s `ext_workspace_manager_v1` protocol. It does not start a server or use a native workspace backend fallback.

From the repository root, after building Fushell:

```sh
nix develop -c zig-out/bin/fushell run ./examples/workspace_preview
```

The inspector shows connection status, grouped and unassigned workspaces, output names/descriptions and session object IDs, optional persistent workspace IDs and coordinates, active/urgent/hidden flags, and advertised capabilities. Counts appear only while connected. **Active does not mean keyboard focused.** Empty groups remain visible; missing optional data is omitted.

**Activate** is enabled only for a connected workspace advertising `canActivate`. Activation happens only after an explicit click. A completed request means the SDK sent the request and commit, not that the compositor accepted the change; displayed state always comes from manager snapshots. No workspace is activated on startup. Remove, assign, deactivate and create capabilities are shown for inspection without exposing destructive controls.

Use the toolbar’s **Reconnect** action to close the previous subscription/connection and try again. Connection failures (including `UnsupportedProtocol`), stream errors, `lastError`, and activation errors appear inline. A compositor without `ext_workspace_manager_v1` produces a readable error rather than a fallback. **Quit** closes the connection and exits; closing the last native window also exits through `FushellWindowViews`. Generation guards discard late connections and actions after reconnect or disposal.

For isolated GUI validation, set `WORKSPACE_PREVIEW_SOCKET` to an **absolute Wayland socket path**. This overrides only the Workspace SDK connection; the preview window still uses its normal Fushell compositor. When absent, `Workspace.connect()` uses its default socket selection. For example, set the override in the environment before the command above. Inspecting a desktop socket is read-only until you explicitly press Activate; use a private test compositor for activation tests.

## Checks

```sh
cd examples/workspace_preview
flutter pub get --offline
dart format lib test
flutter analyze
flutter test
```

Widget tests use immutable presentation values in `lib/inspector.dart`, without connecting to Wayland. They cover grouped/unassigned entries, empty groups, metadata and capability rendering, explicit enabled/disabled activation callbacks, a 480-pixel viewport with long metadata, readable errors, reconnect and quit callbacks, and omission of unknown counts. They do not confirm real compositor behavior, native window closure, or asynchronous SDK lifecycle on a real desktop. GUI integration must be checked separately in an isolated compositor; the tests never activate a real desktop workspace.
