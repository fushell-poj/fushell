import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';

const String _channelName = 'dev.fushell/surface';
const StringCodec _codec = StringCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<Map<String, Object?>> requests;
  late Future<ByteData?> Function(Map<String, Object?>) respond;

  setUp(() {
    requests = <Map<String, Object?>>[];
    respond = (_) async => _codec.encodeMessage('{"ok":true}');
    messenger.setMockMessageHandler(_channelName, (ByteData? data) {
      final request =
          jsonDecode(_codec.decodeMessage(data)!) as Map<String, Object?>;
      requests.add(request);
      return respond(request);
    });
  });

  tearDown(() => messenger.setMockMessageHandler(_channelName, null));

  test(
    'surface mutations preserve JSON requests and await native reply',
    () async {
      final reply = Completer<ByteData?>();
      respond = (_) => reply.future;
      bool closed = false;
      final closing = FushellWindow.closeWindow(42).then((_) => closed = true);
      expect(requests.single['method'], 'window.close');
      expect(requests.single['windowId'], 42);
      expect(closed, isFalse);
      reply.complete(_codec.encodeMessage('{"ok":true}'));
      await closing;
      expect(closed, isTrue);

      respond = (_) async => _codec.encodeMessage('{"ok":true}');
      await FushellWindow.updateWindow(
        42,
        const WindowSurfaceUpdate(title: 'Next'),
      );
      expect(requests.last['update'], <String, Object?>{'title': 'Next'});
      expect(requests.last['method'], 'window.update');
      expect(requests.last['id'], isNot(requests.first['id']));
      await FushellWindow.updateLayer(
        7,
        const LayerSurfaceUpdate(exclusiveZone: LayerExclusiveZone.none),
      );
      expect(requests.last['method'], 'layer.update');
      expect(requests.last['update'], <String, Object?>{'exclusiveZone': 0});
    },
  );

  for (final entry in <String?, String>{
    null: 'NoResponse',
    '[]': 'InvalidResponse',
    '{"ok":false}': 'SurfaceRequestFailed',
    '{"ok":false,"error":{"code":"WindowNotFound","message":"gone"}}':
        'WindowNotFound',
    '{"ok":false,"error":{"code":12}}': 'SurfaceRequestFailed',
  }.entries) {
    test('surface response ${entry.key} reports ${entry.value}', () async {
      respond = (_) async => _codec.encodeMessage(entry.key);
      await expectLater(
        FushellWindow.closeWindow(42),
        throwsA(
          isA<FushellSurfaceException>().having(
            (error) => error.code,
            'code',
            entry.value,
          ),
        ),
      );
    });
  }

  test('malformed JSON response reports InvalidResponse', () async {
    respond = (_) async => _codec.encodeMessage('{');
    await expectLater(
      FushellWindow.closeWindow(42),
      throwsA(
        isA<FushellSurfaceException>().having(
          (error) => error.code,
          'code',
          'InvalidResponse',
        ),
      ),
    );
  });

  test('malformed UTF-8 response reports InvalidResponse', () async {
    respond = (_) async => ByteData.sublistView(Uint8List.fromList(<int>[255]));
    await expectLater(
      FushellWindow.closeWindow(42),
      throwsA(
        isA<FushellSurfaceException>().having(
          (error) => error.code,
          'code',
          'InvalidResponse',
        ),
      ),
    );
  });

  test('transport failure reaches the surface caller', () async {
    respond = (_) => throw StateError('transport failed');
    await expectLater(FushellWindow.closeWindow(42), throwsStateError);
  });

  test('asynchronous transport failure reaches the surface caller', () async {
    final reply = Completer<ByteData?>();
    respond = (_) => reply.future;
    final failure = expectLater(
      FushellWindow.closeWindow(42),
      throwsStateError,
    );
    reply.completeError(StateError('transport failed'));
    await failure;
  });

  test('process exit consumes a later asynchronous send failure', () async {
    final reply = Completer<ByteData?>();
    respond = (_) => reply.future;
    await FushellProcess.exit();
    reply.completeError(StateError('transport failed'));
    // The test messenger tracks the raw transport future independently of exit.
    await expectLater(messenger.platformMessagesFinished, throwsStateError);
  });

  for (final int code in <int>[-1, 256]) {
    test('process exit rejects $code locally', () async {
      await expectLater(FushellProcess.exit(code), throwsRangeError);
      expect(requests, isEmpty);
    });
  }

  test(
    'process exit accepts boundaries without waiting for responses',
    () async {
      final reply = Completer<ByteData?>();
      respond = (_) => reply.future;
      await FushellProcess.exit(0);
      await FushellProcess.exit(255);
      expect(requests.map((request) => request['code']), <int>[0, 255]);
      expect(
        requests.every((request) => request['method'] == 'process.exit'),
        isTrue,
      );
      expect(reply.isCompleted, isFalse);
      reply.complete(null);
    },
  );
}
