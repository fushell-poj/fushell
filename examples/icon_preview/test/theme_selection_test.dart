import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/icons.dart';
import 'package:icon_preview/main.dart';

class ControlledThemeResolver extends IconResolver {
  String systemTheme = 'Fluent-dark';
  String? _cached;
  bool defer = false;
  int clears = 0;
  final pending = <Completer<String>>[];
  final lookupThemes = <String?>[];
  @override
  Future<String> resolveTheme() {
    if (defer) {
      final request = Completer<String>();
      pending.add(request);
      return request.future;
    }
    return Future.value(_cached ??= systemTheme);
  }

  @override
  void clearCache() {
    super.clearCache();
    _cached = null;
    ++clears;
  }

  @override
  Future<List<String>> listThemes() async => [
    'Fluent-dark',
    'Adwaita',
    'breeze',
  ];
  @override
  Future<IconLookupResult?> lookup({
    required String name,
    int size = 24,
    int scale = 1,
    String? theme,
    List<String> extraSearchPaths = const [],
  }) async {
    lookupThemes.add(theme);
    return null;
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    ControlledThemeResolver resolver,
  ) async {
    tester.view.physicalSize = const Size(960, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(IconPreviewApp(resolver: resolver));
    await tester.pumpAndSettle();
  }

  final input = find.widgetWithText(TextField, 'Theme (blank = system)');
  Future<void> apply(WidgetTester tester, {bool refresh = false}) async {
    final button = refresh
        ? find.widgetWithText(OutlinedButton, 'Refresh cache')
        : find.widgetWithText(FilledButton, 'Look up');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'automatic theme, explicit override, clearing, and cache refresh',
    (tester) async {
      final resolver = ControlledThemeResolver();
      await mount(tester, resolver);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(find.text('System: Fluent-dark'), findsOneWidget);
      await apply(tester);
      expect(resolver.lookupThemes.last, 'Fluent-dark');
      await tester.enterText(input, 'Adwaita');
      await apply(tester);
      expect(find.text('Override: Adwaita'), findsOneWidget);
      expect(resolver.lookupThemes.last, 'Adwaita');
      await tester.enterText(input, '');
      await apply(tester);
      expect(find.text('System: Fluent-dark'), findsOneWidget);
      expect(resolver.lookupThemes.last, 'Fluent-dark');
      resolver.systemTheme = 'breeze';
      await apply(tester, refresh: true);
      expect(resolver.clears, 1);
      expect(find.text('System: breeze'), findsOneWidget);
      expect(resolver.lookupThemes.last, 'breeze');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late system detection cannot override a manual edit or newer mode',
    (tester) async {
      final resolver = ControlledThemeResolver()..defer = true;
      await mount(tester, resolver);
      await tester.enterText(input, 'Adwaita');
      resolver.pending[0].complete('old-system');
      await tester.pumpAndSettle();
      expect(find.text('System: old-system'), findsNothing);
      expect(tester.widget<TextField>(input).controller!.text, 'Adwaita');
      await apply(tester);
      expect(find.text('Override: Adwaita'), findsOneWidget);
      await tester.enterText(input, '');
      // Keep this detection pending while switching back to a manual choice.
      final button = find.widgetWithText(FilledButton, 'Look up');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.enterText(input, 'breeze');
      resolver.pending[1].complete('stale-system');
      await tester.pumpAndSettle();
      expect(find.text('System: stale-system'), findsNothing);
      await apply(tester);
      expect(find.text('Override: breeze'), findsOneWidget);
      expect(resolver.lookupThemes, ['Adwaita', 'breeze']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('system detection finishing after disposal is ignored', (
    tester,
  ) async {
    final resolver = ControlledThemeResolver()..defer = true;
    await mount(tester, resolver);
    await tester.pumpWidget(const SizedBox());
    resolver.pending.single.completeError(StateError('late detection failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
