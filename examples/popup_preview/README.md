# Popup preview

A standalone, command-driven SDK example for normal-window and layer-shell popup parents. Commands use FushellApplication single-instance dispatch. Build from this directory with `fushell build --debug .`, then use `build/linux/x64/debug/fushell_popup_preview` in the same D-Bus/Wayland session. The executable name comes from this package’s pubspec name. Start it without arguments in one terminal to keep the headless daemon running; issue commands from another.

```sh
APP=build/linux/x64/debug/fushell_popup_preview
"$APP" parent window
# Use the returned windowId below (IDs shown here are examples).
"$APP" popup 1
"$APP" popup 2 '{"x":20,"y":20,"width":120,"height":80}'
"$APP" reposition 2 '{"x":180,"y":100,"width":200,"height":120,"constraints":["slideX","slideY"]}'
"$APP" close 1
"$APP" parent layer '{"width":240,"height":48,"anchors":["top","right"]}'
# Substitute the layer windowId returned above for 4.
"$APP" popup 4 '{"x":180,"y":8,"anchorWidth":40,"anchorHeight":24,"constraints":["flipX","slideY"]}'
"$APP" list
"$APP" events
"$APP" quit
```

Commands return JSON. `close WINDOW_ID` closes any surface and cascades popup descendants. `cycle PARENT_ID COUNT [JSON]` repeatedly opens and closes a popup (1–1000 cycles). Only one popup child is allowed per parent; use the child ID to create a nested popup. The daemon stays alive after the last window closes.

`popup PARENT_ID [JSON]` and `reposition POPUP_ID [JSON]` accept the following options. Reposition replaces the entire positioner, so omitted fields return to these defaults.

```json
{
  "width": 180, "height": 100,
  "x": 80, "y": 60, "anchorWidth": 40, "anchorHeight": 24,
  "anchor": "bottom", "gravity": "bottomRight",
  "constraints": [], "offsetX": 0, "offsetY": 0,
  "reactive": false, "passthrough": false
}
```

Anchor and gravity accept `none`, `top`, `bottom`, `left`, `right`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight`. Constraints accept `slideX`, `slideY`, `flipX`, `flipY`, `resizeX`, `resizeY`. Passthrough is a creation option only; reposition does not change it. Negative offsets can overlap the parent for pointer-routing checks. Reposition and reactive positioners require xdg-shell v3.

`parent window [JSON]` accepts width/height (defaults 640×420). `parent layer [JSON]` defaults to a top, full-width layer 48 logical pixels high. Set explicit width with `anchors:["top","left"]` or `["top","right"]` for a small edge parent. Layer popups may extend beyond the layer bounds.

The parent is teal (`#126c8a`), first popup orange (`#ff9d2e`), nested popup magenta (`#c23bb8`). Popups have an 8-logical-pixel transparent margin. The parent marks the default anchor rectangle in cyan. `list` reports IDs, roles, parent relationships and current Flutter view dimensions; `events` drains up to 512 buffered metrics, pointerenter, button and closed records. Pointer positions are local to their receiving view. Flutter view metrics describe size and scale, not compositor-global placement.

The example retries only `PopupParentNotMapped` for at most three seconds, because view creation can finish before the first parent buffer is mapped. SDK primitives propagate this error directly. Native errors are returned as JSON on stderr with exit code 1.
