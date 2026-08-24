import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:fushell_flutter_smoke_app/main.dart';

void main() {
  testWidgets('shows fushell smoke page', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    var openRequests = 0;
    await tester.pumpWidget(
      FushellSmokeApp(
        onOpenSettingsWindow: () async {
          openRequests += 1;
        },
      ),
    );

    expect(find.text('fushell multi-view first frames'), findsOneWidget);
    expect(find.text('Open Settings Window'), findsOneWidget);
    expect(find.textContaining('Flutter views of one engine'), findsOneWidget);

    await tester.tap(find.text('Open Settings Window'));
    await tester.pump();
    expect(openRequests, 1);
  });
}
