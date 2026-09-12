import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';
import 'package:fushell/windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const missing = FushellSurfaceException(
    code: 'WindowNotFound',
    message: 'Surface already destroyed',
  );

  test(
    'confirmed native close settles an in-flight missing-window close',
    () async {
      final events = StreamController<FushellWindowClosedEvent>.broadcast(
        sync: true,
      );
      final response = Completer<void>();
      var attempts = 0;
      final owner = FushellWindowController(
        viewById: (_) async => ui.PlatformDispatcher.instance.implicitView!,
        closeWindow: (_) {
          attempts++;
          return response.future;
        },
        closed: events.stream,
      );
      final window = await owner.open(create: () async => 41);
      final closing = window.close();
      events.add(const FushellWindowClosedEvent(windowId: 41));
      response.completeError(missing);
      await closing;
      await window.close();
      expect(window.isClosed, isTrue);
      expect(owner.windows, isEmpty);
      expect(attempts, 1);
      await owner.dispose();
      await events.close();
    },
  );

  test(
    'unconfirmed missing-window failure retains ownership and retries',
    () async {
      var attempts = 0;
      final owner = FushellWindowController(
        viewById: (_) async => ui.PlatformDispatcher.instance.implicitView!,
        closeWindow: (_) async {
          if (++attempts == 1) throw missing;
        },
        closed: const Stream.empty(),
      );
      final window = await owner.open(create: () async => 41);
      await expectLater(window.close(), throwsA(same(missing)));
      expect(window.isClosed, isFalse);
      expect(owner.windows.single, same(window));
      await window.close();
      expect(attempts, 2);
      await owner.dispose();
    },
  );

  test('native closure does not hide an unrelated close error', () async {
    final events = StreamController<FushellWindowClosedEvent>.broadcast(
      sync: true,
    );
    final response = Completer<void>();
    const failure = FushellSurfaceException(
      code: 'WindowCloseFailed',
      message: 'Engine rejected close',
    );
    final owner = FushellWindowController(
      viewById: (_) async => ui.PlatformDispatcher.instance.implicitView!,
      closeWindow: (_) => response.future,
      closed: events.stream,
    );
    final window = await owner.open(create: () async => 41);
    final rejected = expectLater(window.close(), throwsA(same(failure)));
    events.add(const FushellWindowClosedEvent(windowId: 41));
    response.completeError(failure);
    await rejected;
    await owner.dispose();
    await events.close();
  });
}
