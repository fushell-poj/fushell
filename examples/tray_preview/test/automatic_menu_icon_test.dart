import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/icons.dart';
import 'package:icon_preview/icon_image.dart';
import 'package:tray_preview/menu_icon.dart';

class AutomaticMenuResolver extends IconResolver {
  AutomaticMenuResolver(String root) : super(searchPaths: [root]);
  int detections = 0;
  String? requestedName;
  String? requestedTheme;
  @override
  Future<String> resolveTheme() async {
    ++detections;
    return 'TestAuto';
  }

  @override
  Future<IconLookupResult?> lookup({
    required String name,
    int size = 24,
    int scale = 1,
    String? theme,
    List<String> extraSearchPaths = const [],
  }) {
    requestedName = name;
    requestedTheme = theme;
    return super.lookup(
      name: name,
      size: size,
      scale: scale,
      theme: theme,
      extraSearchPaths: extraSearchPaths,
    );
  }
}

void main() {
  testWidgets('null menu theme resolves automatic theme and renders its SVG', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('auto-menu-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/TestAuto/scalable/actions/menu-test.svg';
    await tester.runAsync(() async {
      await File(path).parent.create(recursive: true);
      await File('${directory.path}/TestAuto/index.theme').writeAsString(
        '[Icon Theme]\nName=TestAuto\nDirectories=scalable/actions\n[scalable/actions]\nSize=24\nType=Scalable\nMinSize=1\nMaxSize=256\n',
      );
      await File(path).writeAsString(
        '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="red"/></svg>',
      );
    });
    final resolver = AutomaticMenuResolver(directory.path);
    await tester.pumpWidget(
      MaterialApp(
        home: TrayMenuIcon(resolver: resolver, name: 'menu-test'),
      ),
    );
    for (
      var attempt = 0;
      attempt < 100 && find.byType(IconFileImage).evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(resolver.requestedName, 'menu-test');
    expect(resolver.requestedTheme, isNull);
    expect(resolver.detections, 1);
    final image = tester.widget<IconFileImage>(find.byType(IconFileImage));
    expect(image.result.path, path);
    expect(image.result.format, 'svg');
    expect(image.result.theme, 'TestAuto');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'SvgPicture',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
