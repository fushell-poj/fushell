# Tray preview

A Fushell window for inspecting live StatusNotifierItem applications on the
session bus. It uses the SDK's `TrayHost` and renders DBusMenu locally.

From the repository root, with an initialized Flutter SDK and Fushell on PATH:

```sh
fushell run ./examples/tray_preview
```

Start an optional test item in a second terminal on the same session bus:

```sh
cd examples/tray_preview
flutter pub get
dart run tool/demo_item.dart
```

The demo appears in **every** tray on that bus. To keep testing separate from
your desktop, launch both commands in one `dbus-run-session` (and an isolated
Wayland compositor when testing rendering).

Select an item to inspect its service, object path, status, icon name and pixel
sizes. **Activate**, middle click and wheel input call the corresponding SNI
methods. Right click or **Menu** opens a live menu with disabled items,
separators, toggles and expandable submenus. Menu actions and transport errors
appear under Activity. **Reconnect** recreates the host; the close button exits
the preview process. Closing the native window exits too.

The header reports whether the host uses a local fallback watcher or an
external watcher. Existing Waybar/Quickshell watchers are not replaced. After a
watcher exits, the host discovers its replacement or creates a fallback; items
appear again when applications re-register. Multiple preview processes may run
simultaneously. This is a protocol preview, not a replacement desktop panel.

The preview renders ARGB pixmaps and absolute raster icon filenames. Theme-only
names and SVG files use a placeholder; their names and theme paths remain
visible for inspection. The SDK exposes attention/overlay pixmaps and all raw
menu properties for applications with a full theme renderer. Activation
coordinates default to (0, 0), since Wayland does not generally expose global
window coordinates. Legacy XEmbed trays are not supported.
