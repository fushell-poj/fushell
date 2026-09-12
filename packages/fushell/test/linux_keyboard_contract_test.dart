import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // These are the native encoder's exact Linux/GTK wire fields. In particular,
  // a keysym is not a Flutter logicalKey, and unicodeScalarValues is required.
  final cases =
      <
        ({
          String name,
          int keyCode,
          int scalar,
          int scanCode,
          int modifiers,
          LogicalKeyboardKey logical,
        })
      >[
        (
          name: 'Escape',
          keyCode: 65307,
          scalar: 27,
          scanCode: 9,
          modifiers: 0,
          logical: LogicalKeyboardKey.escape,
        ),
        (
          name: 'ArrowLeft',
          keyCode: 65361,
          scalar: 0,
          scanCode: 113,
          modifiers: 0,
          logical: LogicalKeyboardKey.arrowLeft,
        ),
        (
          name: 'Control-C',
          keyCode: 99,
          scalar: 99,
          scanCode: 54,
          modifiers: 4,
          logical: LogicalKeyboardKey.keyC,
        ),
      ];
  for (final entry in cases) {
    test('native GTK payload decodes ${entry.name}', () {
      // Native still uses Flutter's legacy Linux key channel, so test that
      // exact decoder rather than a synthetic modern KeyEvent.
      // ignore: deprecated_member_use
      final event = RawKeyEvent.fromMessage(<String, Object>{
        'type': 'keydown',
        'keymap': 'linux',
        'keyCode': entry.keyCode,
        'modifiers': entry.modifiers,
        'unicodeScalarValues': entry.scalar,
        'scanCode': entry.scanCode,
        'toolkit': 'gtk',
      });
      expect(event.logicalKey, entry.logical);
      // Inspect this decoded event, not the process-wide HardwareKeyboard state.
      // ignore: deprecated_member_use
      expect(event.data.isControlPressed, entry.modifiers == 4);
    });
  }
}
