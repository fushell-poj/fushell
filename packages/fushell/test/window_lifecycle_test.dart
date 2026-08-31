import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';

const String _channelName = 'dev.fushell/window-events';
const StringCodec _codec = StringCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('closed emits the completed native window id', () async {
    final List<int> received = <int>[];
    final StreamSubscription<FushellWindowClosedEvent> subscription =
        FushellWindow.closed.listen(
          (FushellWindowClosedEvent event) => received.add(event.windowId),
        );
    addTearDown(subscription.cancel);

    await _dispatch(<String, Object?>{
      'event': 'window.closed',
      'windowId': 42,
    });

    expect(received, <int>[42]);
  });

  test('closed broadcasts every valid event to every subscriber', () async {
    final List<int> first = <int>[];
    final List<int> second = <int>[];
    final StreamSubscription<FushellWindowClosedEvent> firstSubscription =
        FushellWindow.closed.listen(
          (FushellWindowClosedEvent event) => first.add(event.windowId),
        );
    final StreamSubscription<FushellWindowClosedEvent> secondSubscription =
        FushellWindow.closed.listen(
          (FushellWindowClosedEvent event) => second.add(event.windowId),
        );
    addTearDown(firstSubscription.cancel);
    addTearDown(secondSubscription.cancel);

    await _dispatch(<String, Object?>{
      'event': 'window.closed',
      'windowId': 17,
    });
    await _dispatch(<String, Object?>{
      'event': 'window.closed',
      'windowId': 17,
    });

    expect(first, <int>[17, 17]);
    expect(second, <int>[17, 17]);
  });

  test('closed ignores malformed and unrelated native events', () async {
    final List<int> received = <int>[];
    final StreamSubscription<FushellWindowClosedEvent> subscription =
        FushellWindow.closed.listen(
          (FushellWindowClosedEvent event) => received.add(event.windowId),
        );
    addTearDown(subscription.cancel);

    await _dispatch(<String, Object?>{'event': 'window.opened', 'windowId': 9});
    await _dispatch(<String, Object?>{
      'event': 'window.closed',
      'windowId': 'not-an-id',
    });

    expect(received, isEmpty);
  });
}

Future<void> _dispatch(Object? message) async {
  final Completer<ByteData?> response = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channelName,
        _codec.encodeMessage(jsonEncode(message)),
        response.complete,
      );
  await response.future;
}
