import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/tray.dart';
import 'package:tray_preview/tray_pixels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // DSH retains its blue RGB in transparent and antialiased pixels.
  final source = TrayIconPixmap(3, 1, [
    0,
    77,
    107,
    254,
    128,
    77,
    107,
    254,
    255,
    77,
    107,
    254,
  ]);

  test('premultiplies alpha without changing the source pixels', () {
    expect(premultipliedRgba(source), [
      0,
      0,
      0,
      0,
      39,
      54,
      127,
      128,
      77,
      107,
      254,
      255,
    ]);
    expect(source.bytes, [
      0,
      77,
      107,
      254,
      128,
      77,
      107,
      254,
      255,
      77,
      107,
      254,
    ]);
  });

  test(
    'Flutter compositing preserves transparent backgrounds and blends edges',
    () async {
      final decoded = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        premultipliedRgba(source),
        3,
        1,
        ui.PixelFormat.rgba8888,
        decoded.complete,
      );
      final image = await decoded.future;
      addTearDown(image.dispose);

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawColor(const ui.Color(0xff14283c), ui.BlendMode.src);
      canvas.drawImage(
        image,
        ui.Offset.zero,
        ui.Paint()..filterQuality = ui.FilterQuality.none,
      );
      final picture = recorder.endRecording();
      addTearDown(picture.dispose);
      final composed = await picture.toImage(3, 1);
      addTearDown(composed.dispose);
      final bytes = (await composed.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();

      expect(bytes.sublist(0, 4), [20, 40, 60, 255]);
      for (var channel = 0; channel < 3; channel++) {
        expect(bytes[4 + channel], closeTo([49, 74, 157][channel], 1));
      }
      expect(bytes[7], 255);
      expect(bytes.sublist(8, 12), [77, 107, 254, 255]);
    },
  );
}
