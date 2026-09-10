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

The preview resolves icon names and absolute PNG/SVG paths with the Dart SDK's
`IconResolver`; SVG rendering lives only in the Flutter examples. The theme field
starts blank and follows the current system icon theme, with the resolved value
shown as **System: Fluent-dark** (or the detected theme). To override, enter a
theme directory name such as `Adwaita` or `breeze` and press **Apply / refresh icons**.
Clear the field and apply again to return to automatic mode. Refresh clears
system detection, lookup and decoded image caches. `hicolor` is the last fallback
when detection has no usable value. One applied theme is shared by tray icons
and menus; stale asynchronous detections cannot overwrite newer edits.

SNI `IconThemePath` is passed as an extra search path, including for menus.
NeedsAttention selects the attention icon name/pixmap when provided. Missing or
undecodable names fall back to the supplied ARGB pixmap, preserving straight-alpha
to premultiplied-alpha conversion. DBusMenu `icon-name` uses the same lookup;
`icon-data` is decoded as an encoded PNG fallback, never as a raw SNI pixmap.
Invalid image data does not prevent menu interaction. Overlay icons remain
available in the SDK but are not composited by this preview. Located XPM files
are not decoded by Flutter here and use the same pixmap/placeholder fallback.

Use `../icon_preview` to inspect lookup paths, formats, themes and scale choices
independently of a session bus. Both examples share `icon_preview/lib/icon_image.dart`.

Validation: `flutter pub get`, `flutter analyze`, and `flutter test`. Tests cover
menu PNG decoding and malformed data, plus the existing pixel alpha/compositing
regression. Shared renderer tests cover request races, disposal, and PNG/SVG.

Activation coordinates default to (0, 0), since Wayland does not generally expose
global window coordinates. Legacy XEmbed trays are not supported.
