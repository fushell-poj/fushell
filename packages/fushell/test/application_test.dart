import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';

const String _channelName = 'dev.fushell/application';
const JSONMethodCodec _codec = JSONMethodCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> nativeCalls;
  late MethodChannel channel;

  setUp(() {
    nativeCalls = <MethodCall>[];
    channel = const MethodChannel(_channelName, _codec);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          nativeCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('ready installs the handler before notifying native', () async {
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async =>
          FushellCommandResult.text(),
    );

    expect(nativeCalls, hasLength(1));
    expect(nativeCalls.single.method, 'ready');
  });

  test('dispatch preserves opaque argument and cwd bytes', () async {
    late FushellCommandInvocation received;
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        received = invocation;
        return FushellCommandResult(
          exitCode: 23,
          stdout: Uint8List.fromList(<int>[0, 10, 255]),
          stderr: Uint8List.fromList(<int>[254, 1]),
        );
      },
    );
    nativeCalls.clear();

    await _dispatch(<String, Object?>{
      'id': 41,
      'argumentsHex': <String>['0061ff', 'f09f9880'],
      'cwdHex': '2f746d702fff',
      'isInitial': true,
    });

    expect(received.arguments, <Uint8List>[
      Uint8List.fromList(<int>[0, 97, 255]),
      Uint8List.fromList(<int>[240, 159, 152, 128]),
    ]);
    expect(
      received.workingDirectory,
      Uint8List.fromList(<int>[47, 116, 109, 112, 47, 255]),
    );
    expect(received.isInitial, isTrue);

    expect(nativeCalls, hasLength(1));
    final MethodCall completion = nativeCalls.single;
    expect(completion.method, 'complete');
    expect(completion.arguments, <String, Object?>{
      'id': 41,
      'exitCode': 23,
      'stdoutHex': '000aff',
      'stderrHex': 'fe01',
    });
  });

  test('matching cancellation reaches the active invocation', () async {
    final Completer<void> started = Completer<void>();
    final Completer<void> finish = Completer<void>();
    late FushellCommandInvocation received;
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        received = invocation;
        started.complete();
        await finish.future;
        return FushellCommandResult.text();
      },
    );
    nativeCalls.clear();

    final Future<void> dispatch = _dispatch(<String, Object?>{
      'id': 51,
      'argumentsHex': <String>[],
      'cwdHex': '2f',
      'isInitial': false,
    });
    await started.future;

    await _invokeNative('cancel', <String, Object?>{'id': 50});
    expect(received.isCancellationRequested, isFalse);
    var cancellationCount = 0;
    received.cancelled.then((_) => cancellationCount += 1);
    await _invokeNative('cancel', <String, Object?>{'id': 51});
    await _invokeNative('cancel', <String, Object?>{'id': 51});
    expect(received.isCancellationRequested, isTrue);
    await received.cancelled;
    await Future<void>.delayed(Duration.zero);
    expect(cancellationCount, 1);

    finish.complete();
    await dispatch;
  });

  test('late cancellation does not affect the next invocation', () async {
    final Completer<void> nextStarted = Completer<void>();
    final Completer<void> nextFinish = Completer<void>();
    late FushellCommandInvocation next;
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        next = invocation;
        nextStarted.complete();
        await nextFinish.future;
        return FushellCommandResult.text();
      },
    );
    nativeCalls.clear();

    final Future<void> dispatch = _dispatch(<String, Object?>{
      'id': 52,
      'argumentsHex': <String>[],
      'cwdHex': '2f',
      'isInitial': false,
    });
    await nextStarted.future;
    await _invokeNative('cancel', <String, Object?>{'id': 51});
    expect(next.isCancellationRequested, isFalse);

    nextFinish.complete();
    await dispatch;
  });

  test('asynchronous handler errors become software-error replies', () async {
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) async {
        throw StateError('command failed');
      },
    );
    nativeCalls.clear();

    await _dispatch(<String, Object?>{
      'id': 7,
      'argumentsHex': <String>[],
      'cwdHex': '2f',
      'isInitial': false,
    });

    final MethodCall completion = nativeCalls.single;
    final Map<Object?, Object?> fields =
        completion.arguments! as Map<Object?, Object?>;
    expect(fields['exitCode'], 70);
    expect(
      _decodeHex(fields['stderrHex']! as String),
      contains('command failed'),
    );
  });

  test('synchronous handler errors become software-error replies', () async {
    await FushellApplication.run(
      onCommand: (FushellCommandInvocation invocation) {
        throw StateError('synchronous command failure');
      },
    );
    nativeCalls.clear();

    await _dispatch(<String, Object?>{
      'id': 8,
      'argumentsHex': <String>[],
      'cwdHex': '2f',
      'isInitial': false,
    });

    final MethodCall completion = nativeCalls.single;
    final Map<Object?, Object?> fields =
        completion.arguments! as Map<Object?, Object?>;
    expect(fields['exitCode'], 70);
    expect(
      _decodeHex(fields['stderrHex']! as String),
      contains('synchronous command failure'),
    );
  });
}

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

String _decodeHex(String value) {
  final List<int> bytes = <int>[];
  for (int index = 0; index < value.length; index += 2) {
    bytes.add(int.parse(value.substring(index, index + 2), radix: 16));
  }
  return String.fromCharCodes(bytes);
}
