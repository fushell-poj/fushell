# Icon preview

An independent multi-view Fushell window for the pure Dart `package:fushell/icons.dart` API. It requires no tray host or session-bus item.

From the repository root, with Flutter initialized and Fushell on PATH:

```sh
fushell run ./examples/icon_preview
```

Enter an icon name (for example `folder`), a supported absolute image path, the theme directory name, logical size and integer scale. Extra search paths are entered one absolute path per line; these accept SNI-style icon directories as well as theme roots. Press **Look up** or Enter to search. The result shows the resolved path, format, source theme and scalable flag, with PNG/SVG rendering and a decoding error message when needed. Large requested icons are displayed at up to 256 logical pixels; lookup still uses the entered size and scale.

The theme input starts blank: this follows the current system icon theme, shown as **System: Fluent-dark** (or the detected theme). Enter a theme directory name and press **Look up** to override it; clear the field and apply again to return to automatic mode. **Installed themes** lists themes asynchronously from the standard resolver roots. **List themes** reloads the cached list; **Refresh cache** clears system-theme detection, lookup, theme-list and decoded-image caches before looking up again. `hicolor` is used only when system detection has no usable value. Common icon chips provide quick starting points. Empty results and lookup errors are shown separately.

The preview uses `runWidget`, `ViewCollection`, and `FushellWindow` like tray_preview. Closing the native window or pressing the close action exits the process. Lookup starts on submitted controls, never from build. The shared `IconThemeSelection` resolves one applied theme for each request; editing the theme invalidates pending detection. Generation checks discard outdated asynchronous results and prevent updates after disposal. The app accepts an optional resolver for deterministic automatic-theme and interaction tests.

`lib/icon_image.dart` contains the shared asynchronous lookup and Flutter PNG/SVG renderer used by tray_preview through a one-way path dependency. flutter_svg 2.3.0 was verified against https://pub.dev/api/packages/flutter_svg (Dart ^3.9.0, Flutter >=3.35.0). No new Flutter rendering or SVG dependency is added to the resolver library.

The resolver can also locate XPM files. Flutter does not decode XPM here, so these show the decode fallback while retaining the located path and metadata.

```sh
cd examples/icon_preview
flutter pub get
dart format lib test
flutter analyze
flutter test
```

Tests cover out-of-order requests, stable rebuilds, explicit refresh, late errors after disposal, missing/error fallbacks, and file rendering. GUI integration must be validated separately in an isolated compositor.
