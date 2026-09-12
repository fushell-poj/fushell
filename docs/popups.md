# Native popups

Fushell popups are separate Wayland `xdg_popup` surfaces with their own Flutter views. They can extend outside the parent window and do not reserve desktop space.

A normal window or another popup supplies an `xdg_surface` parent. A layer-shell parent attaches the popup through `zwlr_layer_surface_v1.get_popup`. The parent cannot be changed after creation.

## SDK

```dart
final popupId = await FushellWindow.openPopup(
  parent: parentViewId,
  popup: const PopupSurfaceRole(
    inputPassthrough: true,
    positioner: PopupPositioner(
      width: 220,
      height: 40,
      anchorRect: PopupAnchorRect(x: 20, y: 8, width: 32, height: 32),
      anchor: PopupAnchor.bottom,
      gravity: PopupGravity.bottom,
      constraintAdjustment: {
        PopupConstraintAdjustment.flipY,
        PopupConstraintAdjustment.slideX,
      },
    ),
  ),
);
```

Render the returned view through the same `FushellWindowViews` or `ViewCollection` mechanism as other windows. Creating the native popup does not supply its Flutter content. Propagate the application theme to that view explicitly.

All positioner coordinates and dimensions are integer **logical pixels**, relative to the parent window geometry, not physical output pixels or global desktop coordinates. Convert a Flutter control rectangle into its parent view coordinate space before constructing the anchor rectangle. Width and height must be positive; the anchor rectangle must fit inside the parent geometry.

The anchor chooses a point on the parent rectangle; gravity selects the direction in which the popup extends from that point. Offset shifts the result. Constraint adjustments authorize the compositor to flip, slide, or resize on each axis when the preferred placement is constrained. The compositor controls the final placement and size; use the resulting Flutter view metrics for layout.

`FushellWindow.repositionPopup(popupId, positioner)` replaces the complete positioner. Omitted options take their defaults; this is not a patch operation. Its Future acknowledges submission, not final compositor placement. Repositioning and `reactive: true` require xdg-shell version 3 or newer; unsupported requests fail explicitly. Reactive placement allows the compositor to respond to parent changes. Moving a particular Flutter control still requires the application to submit an updated anchor rectangle.

## Ownership and readiness

The parent must have presented its first buffer before a popup can be created. `openWindow` completes when Flutter accepts its view, which can be earlier than the first presentation. Opening too soon returns `PopupParentNotMapped`; the primitive does not silently retry. The preview example uses a bounded retry for this specific transient condition.

Each parent may have **one live popup child**, including children being added or removed. Open further levels using the preceding popup as parent. Opening a sibling returns `PopupParentHasPopup`; close the existing child before replacing it. Independent root windows may each own a popup chain. This rule makes destruction order explicit and prevents Wayland non-topmost-popup errors.

Close a popup with `FushellWindow.closeWindow(popupId)` and observe `FushellWindow.closed` as for other windows. Popup ownership differs from the transient relationship between ordinary toplevel windows: closing a parent removes its popup descendants first, waiting for Flutter removal and native cleanup. New popup creation against a closing parent is rejected. If a descendant cannot be removed, waiting ancestor close requests fail and the parent remains alive.

## Input and Tooltip integration

These popups do not request an explicit Wayland input grab. `inputPassthrough: true` creates an empty input region for the entire popup so a tooltip does not intercept pointer input. This option is fixed at creation. A transparent pixel by itself does not create an input hole.

Ordinary popups can receive pointer input, but the API does not promise menu-style keyboard focus or automatic dismissal on outside clicks. Handle application dismissal and native close events. The compositor can dismiss a popup independently; the native `popup_done` event enters the same owned close path.

The standard Flutter Material `Tooltip` continues to draw inside its current view. Replace it explicitly with `NativeTooltip` from `package:fushell/tooltip.dart`; native popups cannot automatically intercept Material tooltips.

### NativeTooltip

Install one non-rendering host above your explicit application views:

```dart
final tooltips = NativeTooltipController();
runWidget(NativeTooltipHost(
  controller: tooltips,
  child: ViewCollection(views: [
    for (final view in applicationRootViews)
      View(view: view, child: const MyApp()),
  ]),
));

// Below MaterialApp / Theme and the source View:
NativeTooltip(
  message: 'Open settings',
  child: IconButton(icon: const Icon(Icons.settings), onPressed: openSettings),
)

// Before opening a menu on the same parent, or exiting:
await tooltips.dismissAll();
// During application shutdown:
await tooltips.dispose();
```

The child collection must include **only application-owned views**, never every `PlatformDispatcher.views` entry: the host renders its own popup views. This prevents duplicate views and application roots being mounted in a tooltip. The host is used with `runWidget`, above the application's `View`s, and performs no ambient `View.of` lookup. Popup content is built below its own `View`. Multiple root windows work independently; if separate hosts can target the same parent, share their controller so replacement remains serialized per parent.

`NativeTooltip` supports `message`, `child`, `waitDuration`, `showDuration`, `exitDuration`, `preferBelow`, `verticalOffset`, `decoration`, `textStyle`, `padding`, `margin`, `constraints`, `excludeFromSemantics` and `animationDuration`. Nullable presentation/timing options resolve from the nearest `TooltipTheme` before desktop Material defaults. Default wait is 500 ms, exit delay 100 ms, focus display 1500 ms, and fade-in 150 ms. Set animationDuration to zero for immediate appearance; `MediaQuery.disableAnimations` also disables fading. Dismissal has no animation. Stationary hover is never truncated by showDuration; that duration limits keyboard-focus display. Focus on a descendant can trigger the tooltip, without introducing an extra tab stop.

The source supplies its captured inherited themes, localization delegates/locale, direction and media settings, including text scaling. Text is measured with those settings before native creation, with a default maximum text-box width of 320 logical pixels. Explicit constraints are bounded to 4096 logical pixels on each axis, independent of the parent dimensions: a 48-pixel panel can display a taller multiline tooltip. Padding, decoration border padding and margin participate in measurement. Compositor-provided popup metrics constrain final rendering. The source exposes its message as tooltip semantics; the popup excludes duplicate semantics. Empty messages do not open a popup. Rich text, long-press/touch triggers, interactive content and nested tooltips are outside this API's scope.

Anchors use the source RenderBox transform into its actual parent Flutter view, clipped and rounded inward to valid integer geometry. They are never global desktop coordinates or coordinates from another root. Invalid/offscreen anchors do not open. Placement allows compositor flipY, slideX and slideY, requests no grab, and always sets inputPassthrough. verticalOffset is signed in the initially preferred direction; xdg-positioner offsets are absolute and are **not inverted** by a compositor flip. Use zero for exact edge attachment where symmetric flipping matters. The widget dismisses on pointer down, parent metrics changes, source geometry changes on subsequent layout frames, presentation changes or unmount; it does not continuously schedule idle frames or silently reopen after movement. Re-enter to show again.

Opening, view readiness, cancellation and replacement are serialized per parent. A cancelled open closes its eventual native ID; cancellation during readiness does not wait for a missing Flutter view. No new sibling opens before the previous close succeeds. Native dismissal also clears presentation ownership. Readiness/open errors are reported through `NativeTooltipController.onError` (FlutterError by default). Close failure retains the native handle and blocks replacement until a later cleanup attempt succeeds or a native close event confirms removal. Await dismissAll/dispose when cleanup matters; disposal can be retried after failure. A host-created controller is cleaned up on unmount, but an explicitly owned controller is recommended when the application must await cleanup. The viewById and closed constructor seams support deterministic widget tests with a fake surface channel; they do not bypass production popup serialization.

## Example and tests

[`examples/popup_preview`](../examples/popup_preview) exercises normal and layer parents, nested popups, repositioning, input passthrough and close/reopen cycles through application commands. It uses the canonical SDK package directly. Build the current native CLI before packaging the example so the embedded runner includes popup support.

`zig build rendering-test` covers native parsing, ownership, geometry bounds and protocol-version checks without a display. The SDK popup tests are in `packages/fushell/test/popup_test.dart`. Actual placement and input routing require a compositor; compiler and unit-test results do not establish graphical correctness.

## Protocol contract

The `dev.fushell/surface` channel opens a popup using `window.open`, with a required `parent` window ID and a `role` containing `kind: "popup"`, `positioner`, and optional `inputPassthrough`. `popup.reposition` takes `windowId` and a full `positioner`. Existing window open, close, response and close-event framing is reused. Unknown fields and malformed coordinates are rejected before protocol requests are issued.

Positioner fields are `width`, `height`, `anchorRect: {x,y,width,height}`, `anchor`, `gravity`, `constraintAdjustment`, `offset: {x,y}`, and `reactive`. Anchor and gravity default to `none`; adjustments default to an empty list; offset defaults to zero; reactive defaults to false.

References: [xdg-shell](https://wayland.app/protocols/xdg-shell), [layer-shell popup parenting](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#zwlr_layer_surface_v1:request:get_popup).
