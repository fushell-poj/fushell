import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/icons.dart';
import 'package:icon_preview/icon_image.dart';
import 'package:icon_preview/main.dart';

class FixtureThemeResolver extends IconResolver {
  @override
  Future<String> resolveTheme() async => 'Fixture';
}

void main() {
  for (final width in [960.0, 480.0]) {
    testWidgets('preview controls look up an absolute SVG at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 680);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('icon-preview-ui-'),
      ))!;
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/preview.svg';
      await tester.runAsync(
        () => File(path).writeAsString(
          '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="red"/></svg>',
        ),
      );
      await tester.pumpWidget(IconPreviewApp(resolver: FixtureThemeResolver()));
      expect(find.text('Icon preview'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Icon name or absolute path'),
        path,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Size (logical px)'),
        '0',
      );
      final lookup = find.widgetWithText(FilledButton, 'Look up');
      await tester.ensureVisible(lookup);
      await tester.tap(lookup);
      await tester.pumpAndSettle();
      expect(
        find.text('Enter an icon name and positive integer size and scale.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Size (logical px)'),
        '32',
      );
      await tester.ensureVisible(lookup);
      await tester.tap(lookup);
      // Real filesystem IO needs a bounded wait outside Flutter's fake clock.
      for (
        var attempt = 0;
        attempt < 100 && find.text('Found').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Found'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == path,
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byType(IconFileImage),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(IconFileImage), findsOneWidget);
      expect(
        tester.widget<IconFileImage>(find.byType(IconFileImage)).result.format,
        'svg',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
