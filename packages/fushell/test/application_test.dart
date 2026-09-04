import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';

const String _channelName = 'dev.fushell/application';
const JSONMethodCodec _codec = JSONMethodCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> nativeCalls;
  late Future<Object?> Function(MethodCall) nativeResponse;
  late MethodChannel channel;

  setUp(() {
    nativeCalls = <MethodCall>[];
    nativeResponse = (_) async => null;
    channel = const MethodChannel(_channelName, _codec);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) {
          nativeCalls.add(call);
          return nativeResponse(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Completer<void> deferNativeWrites() {
    final Completer<void> response = Completer<void>();
    nativeResponse = (MethodCall call) {
      if (call.method == 'write') return response.future;
      return Future<Object?>.value(null);
    };
    return response;
  }

  Future<void> waitForComplete(int id) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (nativeCalls.any(
        (MethodCall call) =>
            call.method == 'complete' &&
            (call.arguments! as Map<Object?, Object?>)['id'] == id,
      )) {
        return;
      }
      await Future<void>.delayed(Duration.zero);
    }
    fail('completion for invocation $id was not sent');
  }

  Future<void> dispatchAndWait(Map<String, Object?> arguments) async {
    await _dispatch(arguments);
    await waitForComplete(arguments['id']! as int);
  }

  test(
    'dispatch exposes a native-only invocation and exit-code-only result',
    () async {
      late FushellCommandInvocation received;
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          received = invocation;
          return FushellCommandResult(exitCode: 23);
        },
      );
      nativeCalls.clear();

      await dispatchAndWait(<String, Object?>{
        'id': 41,
        'argumentsHex': <String>['0061ff', 'f09f9880'],
        'cwdHex': '2f746d702fff',
        'isInitial': true,
      });

      expect(received.arguments, <Uint8List>[
        Uint8List.fromList(<int>[0, 97, 255]),
        Uint8List.fromList(<int>[240, 159, 152, 128]),
      ]);
      expect(received.workingDirectory, <int>[47, 116, 109, 112, 47, 255]);
      expect(received.isInitial, isTrue);
      expect(received.output, isA<FushellCommandOutput>());
      expect(nativeCalls.single.method, 'complete');
      expect(nativeCalls.single.arguments, <String, Object?>{
        'id': 41,
        'exitCode': 23,
      });
    },
  );

  test(
    'raw bytes preserve NUL, non-UTF8 bytes, and one frame per write',
    () async {
      final Uint8List bytes = Uint8List.fromList(<int>[0, 10, 255, 1]);
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          await invocation.output.writeStdout(bytes);
          return FushellCommandResult();
        },
      );
      nativeCalls.clear();

      await dispatchAndWait(<String, Object?>{
        'id': 1,
        'argumentsHex': <String>[],
        'cwdHex': '2f',
        'isInitial': false,
      });

      expect(nativeCalls[0].method, 'write');
      expect(nativeCalls[0].arguments, <String, Object?>{
        'id': 1,
        'stream': 1,
        'dataHex': '000aff01',
      });
    },
  );

  test('empty writes complete without a native write call', () async {
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        await invocation.output.writeStdout(Uint8List(0));
        await invocation.output.writeStderrText('');
        return FushellCommandResult();
      },
    );
    nativeCalls.clear();

    await dispatchAndWait(<String, Object?>{
      'id': 2,
      'argumentsHex': <String>[],
      'cwdHex': '2f',
      'isInitial': false,
    });

    expect(nativeCalls.map((MethodCall call) => call.method), <String>[
      'complete',
    ]);
  });

  test('text helper encodes before splitting and keeps all bytes', () async {
    final String text = '${'é' * 20_000}\u0000終';
    final List<String> frames = <String>[];
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        await invocation.output.writeStdoutText(text);
        return FushellCommandResult();
      },
    );
    nativeResponse = (MethodCall call) async {
      if (call.method == 'write') {
        frames.add(
          (call.arguments! as Map<Object?, Object?>)['dataHex']! as String,
        );
      }
      return null;
    };
    nativeCalls.clear();

    await dispatchAndWait(<String, Object?>{
      'id': 3,
      'argumentsHex': <String>[],
      'cwdHex': '2f',
      'isInitial': false,
    });

    final List<int> rebuilt = <int>[];
    for (final String frame in frames) {
      rebuilt.addAll(_decodeHex(frame));
      expect(frame.length, inInclusiveRange(2, 64 * 1024));
    }
    expect(rebuilt, utf8Bytes(text));
    expect(frames.length, greaterThan(1));
  });

  test('overlap is a synchronous typed StateError', () async {
    final Completer<void> writeReply = Completer<void>();
    nativeResponse = (MethodCall call) {
      if (call.method == 'write') return writeReply.future;
      return Future<Object?>.value(null);
    };
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        final Future<void> first = invocation.output.writeStdoutText('first');
        expect(
          () => invocation.output.writeStderrText('overlap'),
          throwsA(isA<FushellCommandOutputStateError>()),
        );
        writeReply.complete();
        await first;
        return FushellCommandResult();
      },
    );

    await dispatchAndWait(<String, Object?>{
      'id': 4,
      'argumentsHex': <String>[],
      'cwdHex': '2f',
      'isInitial': false,
    });
  });

  test(
    'raw frame and combined output limits are checked before sending',
    () async {
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          expect(
            () => invocation.output.writeStdout(Uint8List(32 * 1024 + 1)),
            throwsA(isA<FushellCommandOutputLimitException>()),
          );
          for (var index = 0; index < 256; index++) {
            await invocation.output.writeStdout(Uint8List(32 * 1024));
          }
          expect(
            () => invocation.output.writeStderr(Uint8List(1)),
            throwsA(isA<FushellCommandOutputLimitException>()),
          );
          return FushellCommandResult();
        },
      );

      await dispatchAndWait(<String, Object?>{
        'id': 5,
        'argumentsHex': <String>[],
        'cwdHex': '2f',
        'isInitial': false,
      });
      expect(
        nativeCalls.where((MethodCall call) => call.method == 'write'),
        hasLength(256),
      );
    },
  );

  test('delayed native write response applies backpressure', () async {
    final Completer<void> response = deferNativeWrites();
    final Completer<void> started = Completer<void>();
    final Completer<void> finished = Completer<void>();
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        started.complete();
        await invocation.output.writeStdoutText('backpressure');
        finished.complete();
        return FushellCommandResult();
      },
    );

    final Future<void> dispatch = _dispatchId(6);
    await started.future;
    await Future<void>.delayed(Duration.zero);
    expect(finished.isCompleted, isFalse);
    response.complete();
    await finished.future;
    await dispatch;
  });

  test('unawaited write is settled before complete', () async {
    final Completer<void> response = deferNativeWrites();
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) {
        unawaited(invocation.output.writeStdoutText('before complete'));
        return FushellCommandResult();
      },
    );

    final Future<void> dispatch = _dispatchId(7);
    await Future<void>.delayed(Duration.zero);
    expect(
      nativeCalls.map((MethodCall call) => call.method),
      contains('write'),
    );
    expect(
      nativeCalls.map((MethodCall call) => call.method),
      isNot(contains('complete')),
    );
    response.complete();
    await dispatch;
    await waitForComplete(7);
    expect(nativeCalls.last.method, 'complete');
  });

  test(
    'matching cancellation closes writer and pending write gets typed cancellation',
    () async {
      final Completer<void> response = deferNativeWrites();
      final Completer<void> started = Completer<void>();
      late FushellCommandInvocation received;
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          received = invocation;
          started.complete();
          try {
            await invocation.output.writeStdoutText('pending');
          } on FushellCommandOutputCancelledException {
            return FushellCommandResult();
          }
          return FushellCommandResult();
        },
      );

      final Future<void> dispatch = _dispatch(<String, Object?>{
        'id': 8,
        'argumentsHex': <String>[],
        'cwdHex': '2f',
        'isInitial': false,
      });
      await started.future;
      await dispatch;
      expect(response.isCompleted, isFalse);
      await _invokeNative('cancel', <String, Object?>{'id': 8});
      await received.cancelled;
      expect(received.isCancellationRequested, isTrue);
      await dispatch;
      expect(
        nativeCalls.where((MethodCall call) => call.method == 'complete'),
        isEmpty,
      );
      response.complete();
      await waitForComplete(8);
      expect(
        nativeCalls.where(
          (MethodCall call) =>
              call.method == 'complete' &&
              (call.arguments! as Map<Object?, Object?>)['id'] == 8,
        ),
        hasLength(1),
      );
      expect(
        () => received.output.writeStdoutText('late'),
        throwsA(isA<FushellCommandOutputClosedException>()),
      );
    },
  );

  test(
    'late response after cancellation cannot affect the next invocation',
    () async {
      final Completer<void> firstResponse = Completer<void>();
      nativeResponse = (MethodCall call) {
        if (call.method == 'write' &&
            (call.arguments! as Map<Object?, Object?>)['id'] == 9) {
          return firstResponse.future;
        }
        return Future<Object?>.value(null);
      };
      final Completer<void> firstStarted = Completer<void>();
      final Completer<void> secondStarted = Completer<void>();
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          if (invocation.arguments.first.first == 1) {
            firstStarted.complete();
            try {
              await invocation.output.writeStdoutText('old');
            } on FushellCommandOutputCancelledException {
              return FushellCommandResult();
            }
          } else {
            secondStarted.complete();
          }
          return FushellCommandResult();
        },
      );

      final Future<void> first = _dispatch(<String, Object?>{
        'id': 9,
        'argumentsHex': <String>['01'],
        'cwdHex': '2f',
        'isInitial': false,
      });
      await firstStarted.future;
      await _invokeNative('cancel', <String, Object?>{'id': 9});
      await first;
      expect(
        nativeCalls.where((MethodCall call) => call.method == 'complete'),
        isEmpty,
      );
      firstResponse.complete();
      await waitForComplete(9);
      final Future<void> second = _dispatch(<String, Object?>{
        'id': 10,
        'argumentsHex': <String>['02'],
        'cwdHex': '2f',
        'isInitial': false,
      });
      await secondStarted.future;
      await second;
      await waitForComplete(10);
      expect(
        nativeCalls.where((MethodCall call) => call.method == 'complete'),
        hasLength(2),
      );
    },
  );

  test(
    'text helper stops before the next fragment after cancellation',
    () async {
      final Completer<void> nativeWriteResponse = Completer<void>();
      nativeResponse = (MethodCall call) {
        if (call.method == 'write') return nativeWriteResponse.future;
        return Future<Object?>.value(null);
      };
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          try {
            await invocation.output.writeStdoutText('a' * (32 * 1024 + 1));
          } on FushellCommandOutputCancelledException {
            return FushellCommandResult();
          }
          return FushellCommandResult();
        },
      );

      final Future<void> dispatch = _dispatchId(15);
      await Future<void>.delayed(Duration.zero);
      await _invokeNative('cancel', <String, Object?>{'id': 15});
      await dispatch;
      expect(
        nativeCalls.where((MethodCall call) => call.method == 'write'),
        hasLength(1),
      );
      nativeWriteResponse.complete();
      await waitForComplete(15);
    },
  );

  test('detached native response is still a successful write', () async {
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        await invocation.output.writeStdoutText('detached');
        return FushellCommandResult();
      },
    );
    await dispatchAndWait(<String, Object?>{
      'id': 11,
      'argumentsHex': <String>[],
      'cwdHex': '2f',
      'isInitial': false,
    });
    expect(nativeCalls.last.method, 'complete');
  });

  test(
    'handler exception writes diagnostic through stderr and exits 70',
    () async {
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          throw StateError('command failed');
        },
      );
      nativeCalls.clear();
      await dispatchAndWait(<String, Object?>{
        'id': 12,
        'argumentsHex': <String>[],
        'cwdHex': '2f',
        'isInitial': false,
      });
      final MethodCall diagnostic = nativeCalls.singleWhere(
        (MethodCall call) => call.method == 'write',
      );
      expect((diagnostic.arguments! as Map<Object?, Object?>)['stream'], 2);
      expect(
        utf8.decode(
          utf8BytesFromHex(
            (diagnostic.arguments! as Map<Object?, Object?>)['dataHex']!
                as String,
          ),
          allowMalformed: true,
        ),
        contains('command failed'),
      );
      expect(nativeCalls.last.arguments, <String, Object?>{
        'id': 12,
        'exitCode': 70,
      });
    },
  );

  test(
    'writer failure closes output and does not create buffered stderr fallback',
    () async {
      nativeResponse = (MethodCall call) async {
        if (call.method == 'write') {
          throw PlatformException(code: 'ApplicationOutputClosed');
        }
        return null;
      };
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          await invocation.output.writeStdoutText('fails');
          return FushellCommandResult();
        },
      );
      await dispatchAndWait(<String, Object?>{
        'id': 13,
        'argumentsHex': <String>[],
        'cwdHex': '2f',
        'isInitial': false,
      });
      final MethodCall completion = nativeCalls.last;
      expect(completion.method, 'complete');
      expect(completion.arguments, <String, Object?>{'id': 13, 'exitCode': 70});
    },
  );

  test('cancelled unawaited write has no uncaught zone error', () async {
    final Completer<void> response = deferNativeWrites();
    final Completer<void> started = Completer<void>();
    late FushellCommandInvocation received;
    final List<Object> uncaught = <Object>[];

    await runZonedGuarded(
      () async {
        await FushellApplication.run(
          onCommand: (FushellCommandInvocation invocation) async {
            received = invocation;
            started.complete();
            unawaited(invocation.output.writeStdoutText('pending'));
            await invocation.cancelled;
            return FushellCommandResult();
          },
        );
        final Future<void> dispatch = _dispatchId(16);
        await started.future;
        await dispatch;
        await _invokeNative('cancel', <String, Object?>{'id': 16});
        await received.cancelled;
        expect(
          nativeCalls.where((MethodCall call) => call.method == 'complete'),
          isEmpty,
        );
        response.complete();
        await waitForComplete(16);
      },
      (Object error, StackTrace stackTrace) {
        uncaught.add(error);
      },
    );

    expect(uncaught, isEmpty);
  });

  test(
    'matching cancellation is idempotent and stale cancellation is isolated',
    () async {
      final Completer<void> finish = Completer<void>();
      late FushellCommandInvocation received;
      await FushellApplication.run(
        onCommand: (FushellCommandInvocation invocation) async {
          received = invocation;
          await finish.future;
          return FushellCommandResult();
        },
      );
      final Future<void> dispatch = _dispatch(<String, Object?>{
        'id': 14,
        'argumentsHex': <String>[],
        'cwdHex': '2f',
        'isInitial': false,
      });
      await Future<void>.delayed(Duration.zero);
      await _invokeNative('cancel', <String, Object?>{'id': 13});
      expect(received.isCancellationRequested, isFalse);
      await _invokeNative('cancel', <String, Object?>{'id': 14});
      await _invokeNative('cancel', <String, Object?>{'id': 14});
      expect(received.isCancellationRequested, isTrue);
      finish.complete();
      await dispatch;
      await waitForComplete(14);
    },
  );
}

Future<void> _dispatchId(int id) => _dispatch(<String, Object?>{
  'id': id,
  'argumentsHex': <String>[],
  'cwdHex': '2f',
  'isInitial': false,
});

Future<void> _dispatch(Map<String, Object?> arguments) =>
    _invokeNative('dispatch', arguments);

Future<void> _invokeNative(
  String method,
  Map<String, Object?> arguments,
) async {
  final Completer<ByteData?> response = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channelName,
        _codec.encodeMethodCall(MethodCall(method, arguments)),
        response.complete,
      );
  final ByteData? reply = await response.future;
  _codec.decodeEnvelope(reply!);
}

List<int> _decodeHex(String value) {
  final List<int> bytes = <int>[];
  for (var index = 0; index < value.length; index += 2) {
    bytes.add(int.parse(value.substring(index, index + 2), radix: 16));
  }
  return bytes;
}

List<int> utf8Bytes(String value) => utf8.encode(value);

List<int> utf8BytesFromHex(String value) => _decodeHex(value);
