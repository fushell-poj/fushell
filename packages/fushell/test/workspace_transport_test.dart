import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/src/workspace/transport.dart' show WorkspaceTransport;
import 'package:fushell/workspace.dart';

Uint8List _uint(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.host)).buffer.asUint8List();

Uint8List _frame(int id, int opcode, [List<int> body = const []]) =>
    Uint8List.fromList([
      ..._uint(id),
      ..._uint(((body.length + 8) << 16) | opcode),
      ...body,
    ]);

// Deterministically reproduces IOSink's exclusive ownership during flush.
// An actual Unix socket's tiny writes may drain before the incoming event.
class _GatedSocket implements Socket {
  final incoming = StreamController<Uint8List>(sync: true);
  final flushStarted = Completer<void>();
  final releaseFlush = Completer<void>();
  final secondFlushStarted = Completer<void>();
  final releaseSecondFlush = Completer<void>();
  bool blockSecondFlush = false;
  final writes = <int>[];
  bool _flushing = false;
  bool destroyed = false;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) {
    if (_flushing) {
      throw StateError('StreamSink is bound to a stream');
    }
    if (destroyed) {
      throw StateError('Socket destroyed');
    }
    writes.addAll(data);
  }

  @override
  Future<void> flush() async {
    if (_flushing) {
      throw StateError('StreamSink is bound to a stream');
    }
    _flushing = true;
    if (!flushStarted.isCompleted) {
      flushStarted.complete();
      await releaseFlush.future;
    } else if (blockSecondFlush && !secondFlushStarted.isCompleted) {
      secondFlushStarted.complete();
      await releaseSecondFlush.future;
    }
    _flushing = false;
  }

  @override
  void destroy() {
    destroyed = true;
  }

  Future<void> dispose() async {
    if (!releaseFlush.isCompleted) {
      releaseFlush.complete();
    }
    if (!releaseSecondFlush.isCompleted) {
      releaseSecondFlush.complete();
    }
    await incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'event-triggered output release queues behind an active socket flush',
    () async {
      final socket = _GatedSocket()..blockSecondFlush = true;
      addTearDown(socket.dispose);
      final failures = <WorkspaceException?>[];
      late WorkspaceTransport transport;
      late int registry;
      late int output;
      transport = WorkspaceTransport(socket, (object, event, args) {
        if (object.id == registry && event.name == 'global_remove') {
          expect(args, [11]);
          transport.send(output, 'release');
        }
      }, failures.add);
      addTearDown(transport.close);
      registry = transport.allocate('wl_registry', 1);
      final manager = transport.allocate('ext_workspace_manager_v1', 1);
      output = transport.allocate('wl_output', 4);
      const workspaceId = 0xff000001;
      socket.incoming.add(_frame(manager, 1, _uint(workspaceId)));
      transport.send(workspaceId, 'activate');
      transport.send(manager, 'commit');
      final action = transport.flush();
      // Observe any asynchronous failure before injecting the removal event.
      final actionResult = action.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await socket.flushStarted.future.timeout(const Duration(seconds: 2));
      socket.incoming.add(_frame(registry, 1, _uint(11)));
      expect(transport.isClosed, isFalse);
      expect(failures, isEmpty);
      expect(socket.writes, [..._frame(workspaceId, 1), ..._frame(manager, 0)]);
      var cleanupComplete = false;
      final cleanupResult = transport.flush().then<Object?>((_) {
        cleanupComplete = true;
        return null;
      }, onError: (Object e) => e);
      socket.releaseFlush.complete();
      expect(await actionResult.timeout(const Duration(seconds: 2)), isNull);
      await socket.secondFlushStarted.future.timeout(
        const Duration(seconds: 2),
      );
      expect(
        cleanupComplete,
        isFalse,
        reason:
            'The first barrier must not wait for or resolve the second barrier',
      );
      socket.releaseSecondFlush.complete();
      expect(await cleanupResult.timeout(const Duration(seconds: 2)), isNull);
      // Independent goldens also prove the event-triggered destructor was not lost.
      expect(socket.writes, [
        ..._frame(workspaceId, 1),
        ..._frame(manager, 0),
        ..._frame(output, 0),
      ]);
      expect(transport.isClosed, isFalse);
      expect(failures, isEmpty);
    },
  );
  test(
    'close settles active and queued flush barriers without releasing socket gate',
    () async {
      final socket = _GatedSocket();
      addTearDown(socket.dispose);
      final transport = WorkspaceTransport(socket, (_, _, _) {}, (_) {});
      addTearDown(transport.close);
      final manager = transport.allocate('ext_workspace_manager_v1', 1);
      transport.send(manager, 'commit');
      final first = transport.flush().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await socket.flushStarted.future.timeout(const Duration(seconds: 2));
      transport.send(manager, 'commit');
      final second = transport.flush().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await transport.close().timeout(const Duration(seconds: 1));
      await transport.close().timeout(const Duration(seconds: 1));
      final results = await Future.wait([
        first,
        second,
      ]).timeout(const Duration(seconds: 1));
      for (final result in results) {
        expect(
          result,
          isA<WorkspaceException>().having(
            (e) => e.code,
            'code',
            'Disconnected',
          ),
        );
      }
      expect(socket.releaseFlush.isCompleted, isFalse);
      expect(socket.destroyed, isTrue);
      final sentBeforeClose = List<int>.of(socket.writes);
      socket.releaseFlush.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
        socket.writes,
        sentBeforeClose,
        reason: 'Queued writes must not reach a closed socket',
      );
    },
  );

  for (final largeFrames in [false, true]) {
    test(
      'outgoing ${largeFrames ? 'byte' : 'frame'} overflow settles blocked flush',
      () async {
        final socket = _GatedSocket();
        addTearDown(socket.dispose);
        final failures = <WorkspaceException?>[];
        final transport = WorkspaceTransport(
          socket,
          (_, _, _) {},
          failures.add,
        );
        addTearDown(transport.close);
        final manager = transport.allocate('ext_workspace_manager_v1', 1);
        final group = transport.allocate('ext_workspace_group_handle_v1', 1);
        transport.send(manager, 'commit');
        final pending = transport.flush().then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        await socket.flushStarted.future.timeout(const Duration(seconds: 2));
        final largeName = List.filled(65000, 'x').join();
        Object? overflow;
        var accepted = 0;
        try {
          for (var i = 0; i < (largeFrames ? 32 : 4097); i++) {
            if (largeFrames) {
              transport.send(group, 'create_workspace', [largeName]);
            } else {
              transport.send(manager, 'commit');
            }
            accepted++;
          }
        } catch (error) {
          overflow = error;
        }
        final disconnected = isA<WorkspaceException>().having(
          (e) => e.code,
          'code',
          'Disconnected',
        );
        expect(overflow, disconnected);
        expect(accepted, largeFrames ? 16 : 4095);
        expect(await pending.timeout(const Duration(seconds: 1)), disconnected);
        expect(failures, hasLength(1));
        expect(transport.isClosed, isTrue);
        expect(socket.releaseFlush.isCompleted, isFalse);
        expect(socket.writes, _frame(manager, 0));
      },
    );
  }

  test('flush barrier overflow settles every pending caller', () async {
    final socket = _GatedSocket();
    addTearDown(socket.dispose);
    final transport = WorkspaceTransport(socket, (_, _, _) {}, (_) {});
    addTearDown(transport.close);
    final manager = transport.allocate('ext_workspace_manager_v1', 1);
    transport.send(manager, 'commit');
    final callers = <Future<Object?>>[];
    for (var i = 0; i < 4097; i++) {
      callers.add(
        transport.flush().then<Object?>((_) => null, onError: (Object e) => e),
      );
    }
    final results = await Future.wait(
      callers,
    ).timeout(const Duration(seconds: 2));
    expect(
      results,
      everyElement(
        isA<WorkspaceException>().having((e) => e.code, 'code', 'Disconnected'),
      ),
    );
    expect(transport.isClosed, isTrue);
    expect(socket.writes, isEmpty);
  });
  test(
    'active socket flush failure rejects current and queued callers',
    () async {
      final socket = _GatedSocket();
      addTearDown(socket.dispose);
      final failures = <WorkspaceException?>[];
      final transport = WorkspaceTransport(socket, (_, _, _) {}, failures.add);
      addTearDown(transport.close);
      final manager = transport.allocate('ext_workspace_manager_v1', 1);
      transport.send(manager, 'commit');
      final first = transport.flush().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await socket.flushStarted.future.timeout(const Duration(seconds: 2));
      transport.send(manager, 'commit');
      final second = transport.flush().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      socket.releaseFlush.completeError(StateError('write failed'));
      final results = await Future.wait([
        first,
        second,
      ]).timeout(const Duration(seconds: 1));
      final disconnected = isA<WorkspaceException>().having(
        (e) => e.code,
        'code',
        'Disconnected',
      );
      expect(results, everyElement(disconnected));
      expect(failures, hasLength(1));
      expect(failures.single, disconnected);
      expect(failures.single!.message, contains('write failed'));
      expect(socket.destroyed, isTrue);
      expect(transport.isClosed, isTrue);
      expect(socket.writes, _frame(manager, 0));
      await expectLater(transport.flush(), throwsA(disconnected));
    },
  );
  test(
    'late socket flush rejection after close is observed without further writes',
    () async {
      final socket = _GatedSocket();
      addTearDown(socket.dispose);
      final failures = <WorkspaceException?>[];
      final transport = WorkspaceTransport(socket, (_, _, _) {}, failures.add);
      addTearDown(transport.close);
      final manager = transport.allocate('ext_workspace_manager_v1', 1);
      transport.send(manager, 'commit');
      final pending = transport.flush().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await socket.flushStarted.future.timeout(const Duration(seconds: 2));
      transport.send(manager, 'commit');
      await transport.close();
      expect(
        await pending.timeout(const Duration(seconds: 1)),
        isA<WorkspaceException>().having((e) => e.code, 'code', 'Disconnected'),
      );
      socket.releaseFlush.completeError(StateError('late socket failure'));
      await Future<void>.delayed(Duration.zero);
      expect(failures, [null]);
      expect(socket.writes, _frame(manager, 0));
      expect(transport.isClosed, isTrue);
    },
  );
}
