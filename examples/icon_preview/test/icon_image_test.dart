import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/icons.dart';
import 'package:icon_preview/icon_image.dart';

class DeferredResolver extends IconResolver {
  final requests = <Completer<IconLookupResult?>>[];
  final names = <String>[];
  @override
  Future<IconLookupResult?> lookup({
    required String name,
    int size = 24,
    int scale = 1,
    String? theme,
    List<String> extraSearchPaths = const [],
  }) {
    names.add(name);
    final request = Completer<IconLookupResult?>();
    requests.add(request);
    return request.future;
  }
}

const resultA = IconLookupResult(
  path: '/missing/old.png',
  format: 'png',
  theme: 'a',
  isScalable: false,
);
const resultB = IconLookupResult(
  path: '/missing/new.png',
  format: 'png',
  theme: 'b',
  isScalable: false,
);

void main() {
  testWidgets(
    'only latest lookup wins; rebuilds do not restart; dispose is safe',
    (tester) async {
      final resolver = DeferredResolver();
      Widget host(String name, {int revision = 0}) => MaterialApp(
        home: ResolvedIcon(
          resolver: resolver,
          name: name,
          revision: revision,
          fallback: const Text('fallback'),
        ),
      );
      await tester.pumpWidget(host('old'));
      await tester.pumpWidget(host('new'));
      resolver.requests[1].complete(resultB);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<IconFileImage>(find.byType(IconFileImage)).result.path,
        resultB.path,
      );
      resolver.requests[0].complete(resultA);
      await tester.pump();
      expect(
        tester.widget<IconFileImage>(find.byType(IconFileImage)).result.path,
        resultB.path,
      );
      await tester.pumpWidget(host('new'));
      expect(resolver.names, ['old', 'new']);
      await tester.pumpWidget(host('new', revision: 1));
      expect(resolver.names.length, 3);
      await tester.pumpWidget(const SizedBox());
      resolver.requests[2].completeError(StateError('late failure'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing and failed lookups preserve the fallback', (
    tester,
  ) async {
    final resolver = DeferredResolver();
    Future<void> mount(String name) => tester.pumpWidget(
      MaterialApp(
        home: ResolvedIcon(
          resolver: resolver,
          name: name,
          fallback: const Text('fallback'),
        ),
      ),
    );
    await mount('missing');
    resolver.requests[0].complete(null);
    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);
    await mount('error');
    resolver.requests[1].completeError(StateError('lookup failed'));
    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SVG and PNG render; a missing file shows the error widget', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('icon-render-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final svgFile = File('${directory.path}/icon.svg');
    final pngFile = File('${directory.path}/icon.png');
    await tester.runAsync(() async {
      await svgFile.writeAsString(
        '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>',
      );
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 8);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      await pngFile.writeAsBytes(bytes);
      image.dispose();
      picture.dispose();
    });
    for (final file in [svgFile, pngFile]) {
      await tester.runAsync(() async {
        if (file == svgFile) {
          final loader = SvgFileLoader(file);
          await svg.cache.putIfAbsent(
            loader.cacheKey(null),
            () => loader.loadBytes(null),
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: IconFileImage(
              result: IconLookupResult(
                path: file.path,
                format: file == svgFile ? 'svg' : 'png',
                theme: null,
                isScalable: file == svgFile,
              ),
            ),
          ),
        );
        if (file == pngFile)
          await precacheImage(
            FileImage(file),
            tester.element(find.byType(IconFileImage)),
          );
      });
      await tester.pumpAndSettle();
      expect(find.byType(file == svgFile ? SvgPicture : Image), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: IconFileImage(
            result: IconLookupResult(
              path: '${directory.path}/absent.png',
              format: 'png',
              theme: null,
              isScalable: false,
            ),
          ),
        ),
      );
      await precacheImage(
        FileImage(File('${directory.path}/absent.png')),
        tester.element(find.byType(IconFileImage)),
        onError: (_, _) {},
      );
    });
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
