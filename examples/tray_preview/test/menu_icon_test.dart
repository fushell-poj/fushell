import 'dart:ui' as ui;

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/icons.dart';
import 'package:icon_preview/icon_image.dart';
import 'package:tray_preview/menu_icon.dart';

class MissingResolver extends IconResolver {
  String? lastName;
  List<String>? lastPaths;
  @override
  Future<IconLookupResult?> lookup({
    required String name,
    int size = 24,
    int scale = 1,
    String? theme,
    List<String> extraSearchPaths = const [],
  }) async {
    lastName = name;
    lastPaths = extraSearchPaths;
    return null;
  }
}

void main() {
  testWidgets(
    'menu encoded PNG decodes after named lookup misses, forwarding SNI paths',
    (tester) async {
      final resolver = MissingResolver();
      final bytes = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(
          recorder,
        ).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(2, 2);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        picture.dispose();
        image.dispose();
        return bytes;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: TrayMenuIcon(
            resolver: resolver,
            name: 'menu-icon',
            data: DBusArray.byte(bytes),
            extraPaths: const ['/tmp/app-icons'],
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(bytes),
          tester.element(find.byType(TrayMenuIcon)),
        ),
      );
      await tester.pumpAndSettle();
      expect(resolver.lastName, 'menu-icon');
      expect(resolver.lastPaths, ['/tmp/app-icons']);
      expect(find.byType(Image), findsOneWidget);
      final rendered = tester.widget<RawImage>(find.byType(RawImage));
      expect(rendered.image?.width, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('malformed DBus icon data remains a harmless fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TrayMenuIcon(
          resolver: MissingResolver(),
          name: '',
          data: const DBusString('not bytes'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ResolvedIcon), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
