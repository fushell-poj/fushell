# fushell

Dart API for initializing and updating fushell's Wayland surface role.

Call `FushellSurface.init` exactly once before `runApp()`. Fushell does not create a fallback window role automatically; rendering before initialization is an error. The selected role is immutable after successful initialization.

## Window role

```dart
import 'package:flutter/material.dart';
import 'package:fushell/fushell.dart';

Future<void> main() async {
  await FushellSurface.init(
    const SurfaceRole.window(
      title: 'My App',
      appId: 'my.app',
      width: 800,
      height: 600,
    ),
  );

  runApp(const MyApp());
}
```

Window metadata can be updated after initialization:

```dart
await FushellSurface.updateWindow(
  const WindowSurfaceUpdate(
    title: 'New title',
    appId: 'my.app.updated',
  ),
);
```

## Layer role

```dart
await FushellSurface.init(
  const SurfaceRole.layer(
    namespace: 'my-panel',
    layer: LayerSurfaceLayer.top,
    anchors: {
      LayerSurfaceAnchor.top,
      LayerSurfaceAnchor.left,
      LayerSurfaceAnchor.right,
    },
    exclusiveZone: 32,
    width: 0,
    height: 32,
  ),
);
```

Mutable layer-shell properties can be updated after initialization:

```dart
await FushellSurface.updateLayer(
  const LayerSurfaceUpdate(
    height: 28,
    exclusiveZone: 28,
    margins: Margins(top: 4),
  ),
);
```

`width: 0` or `height: 0` asks the compositor to derive that dimension from anchors. For example, `top + left + right` with `width: 0` creates a top bar whose width is assigned by the compositor.

## What can hot reload change?

Flutter hot reload can update normal Dart UI state, colors, text, fonts, layout inside the existing Flutter view, and calls to `FushellSurface.updateLayer` / `FushellSurface.updateWindow` that run after reload.

Role selection remains immutable. Changing the initial `SurfaceRole.window(...)` versus `SurfaceRole.layer(...)` call, namespace, layer choice, initial anchors, or any code that only runs before `runApp()` may require a hot restart or a full fushell process restart. Calling `FushellSurface.init` again is rejected by fushell.

Dynamic updates do not switch roles or recreate surfaces. Calling `updateLayer` on a window role, or `updateWindow` on a layer role, returns a structured `FushellSurfaceException`.
