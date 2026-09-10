import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/icons.dart';
import 'package:icon_preview/icon_image.dart';
import 'package:tray_preview/icon_choice.dart';

class RecordingResolver extends IconResolver {
  final names = <String>[];
  @override
  Future<IconLookupResult?> lookup({
    required String name,
    int size = 24,
    int scale = 1,
    String? theme,
    List<String> extraSearchPaths = const [],
  }) async {
    names.add(name);
    return null;
  }
}

void main() {
  testWidgets('attention-only pixmap does not start normal themed lookup', (
    tester,
  ) async {
    final resolver = RecordingResolver();
    final name = trayIconName(
      needsAttention: true,
      normalName: 'normal-icon',
      attentionName: '',
      hasAttentionPixmap: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedIcon(
          resolver: resolver,
          name: name,
          fallback: const Text('attention pixmap'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(name, isEmpty);
    expect(resolver.names, isEmpty);
    expect(find.text('attention pixmap'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test(
    'normal name is used only when attention resources are unavailable or inactive',
    () {
      expect(
        trayIconName(
          needsAttention: true,
          normalName: 'normal',
          attentionName: 'attention',
          hasAttentionPixmap: false,
        ),
        'attention',
      );
      expect(
        trayIconName(
          needsAttention: true,
          normalName: 'normal',
          attentionName: '',
          hasAttentionPixmap: false,
        ),
        'normal',
      );
      expect(
        trayIconName(
          needsAttention: false,
          normalName: 'normal',
          attentionName: 'attention',
          hasAttentionPixmap: true,
        ),
        'normal',
      );
    },
  );
}
