import 'dart:typed_data';

import 'package:fushell/tray.dart';

/// Converts the SNI ARGB bytes for Flutter's PixelFormat.rgba8888.
Uint8List premultipliedRgba(TrayIconPixmap pixmap) {
  final argb = pixmap.bytes;
  final rgba = Uint8List(argb.length);
  for (var i = 0; i < argb.length; i += 4) {
    // SNI uses straight alpha; Flutter requires premultiplied color channels.
    final alpha = argb[i];
    rgba[i] = (argb[i + 1] * alpha + 127) ~/ 255;
    rgba[i + 1] = (argb[i + 2] * alpha + 127) ~/ 255;
    rgba[i + 2] = (argb[i + 3] * alpha + 127) ~/ 255;
    rgba[i + 3] = alpha;
  }
  return rgba;
}
