import 'package:flutter_test/flutter_test.dart';

import 'package:fushell_flutter_smoke_app/main.dart';

void main() {
  testWidgets('shows fushell smoke page', (WidgetTester tester) async {
    await tester.pumpWidget(const FushellSmokeApp());

    expect(find.text('fushell Flutter first frame'), findsOneWidget);
    expect(find.textContaining('Zig Wayland/EGL embedder'), findsOneWidget);
  });
}
