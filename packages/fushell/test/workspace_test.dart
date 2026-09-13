import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/workspace.dart';

// These opcodes and encoders deliberately do not use the generated schema or
// production codec: a shared encoding bug must not make both peers agree.
const _manager = 4;
const _output = 5;
const _group = 0xff000000;
const _entry = 0xff000001;

Uint8List _uint(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.host)).buffer.asUint8List();

List<int> _string(String value) {
  final bytes = [...utf8.encode(value), 0];
  return [
    ..._uint(bytes.length),
    ...bytes,
    ...List<int>.filled((4 - bytes.length % 4) % 4, 0),
  ];
}

Uint8List _event(int id, int opcode, [List<int> body = const []]) =>
    Uint8List.fromList([
      ..._uint(id),
      ..._uint(((body.length + 8) << 16) | opcode),
      ...body,
    ]);

List<int> _global(int name, String interface, int version) =>
    _event(2, 0, [..._uint(name), ..._string(interface), ..._uint(version)]);

Matcher _failure(String code) =>
    isA<WorkspaceException>().having((error) => error.code, 'code', code);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

class _Server {
  _Server(this.directory, this.listener);
  final Directory directory;
  final ServerSocket listener;
  Socket? socket;
  StreamIterator<Uint8List>? requests;
  String get path => '${directory.path}/wayland-test';

  static Future<_Server> start() async {
    final directory = await Directory.systemTemp.createTemp('fushell-ws-');
    final address = InternetAddress(
      '${directory.path}/wayland-test',
      type: InternetAddressType.unix,
    );
    final listener = await ServerSocket.bind(address, 0);
    final server = _Server(directory, listener);
    addTearDown(server.close);
    return server;
  }

  Future<void> accept() async {
    socket = await listener.first.timeout(const Duration(seconds: 2));
    requests = StreamIterator(_frames(socket!));
  }

  static Stream<Uint8List> _frames(Socket socket) async* {
    var pending = <int>[];
    await for (final chunk in socket) {
      pending.addAll(chunk);
      while (pending.length >= 8) {
        final bytes = Uint8List.fromList(pending);
        final size =
            ByteData.sublistView(bytes).getUint32(4, Endian.host) >> 16;
        if (size < 8 || size % 4 != 0) {
          throw StateError('Client emitted invalid frame size $size');
        }
        if (pending.length < size) {
          break;
        }
        yield Uint8List.fromList(pending.sublist(0, size));
        pending = pending.sublist(size);
      }
    }
    if (pending.isNotEmpty) {
      throw StateError('Truncated client request');
    }
  }

  Future<Uint8List> next() async {
    final available = await requests!.moveNext().timeout(
      const Duration(seconds: 2),
    );
    if (!available) {
      throw StateError('Client closed before expected request');
    }
    return requests!.current;
  }

  Future<void> send(List<int> bytes, {bool fragmented = false}) async {
    if (fragmented) {
      // Split inside object ID, header, and body, then coalesce the remainder.
      var offset = 0;
      for (final length in [1, 4, 2, 6]) {
        if (offset + length >= bytes.length) {
          break;
        }
        socket!.add(bytes.sublist(offset, offset + length));
        await socket!.flush();
        await Future<void>.delayed(const Duration(milliseconds: 1));
        offset += length;
      }
      socket!.add(bytes.sublist(offset));
    } else {
      socket!.add(bytes);
    }
    await socket!.flush();
  }

  Future<void> discover({int? outputVersion, bool sync = true}) async {
    await accept();
    // Hardcoded wire goldens catch wrong object IDs, opcodes and frame lengths.
    expect(await next(), [..._uint(1), ..._uint(0x000c0001), ..._uint(2)]);
    expect(await next(), [..._uint(1), ..._uint(0x000c0000), ..._uint(3)]);
    await send([
      ..._global(10, 'ext_workspace_manager_v1', 1),
      if (outputVersion != null) ..._global(11, 'wl_output', outputVersion),
      if (sync) ..._event(3, 0, _uint(42)),
    ], fragmented: true);
    expect(await next(), [
      ..._uint(2),
      ..._uint(0x00340000),
      ..._uint(10),
      ..._uint(25),
      ...ascii.encode('ext_workspace_manager_v1'),
      0,
      0,
      0,
      0,
      ..._uint(1),
      ..._uint(_manager),
    ]);
    if (outputVersion != null) {
      expect(await next(), [
        ..._uint(2),
        ..._uint(0x00240000),
        ..._uint(11),
        ..._uint(10),
        ...ascii.encode('wl_output'),
        0,
        0,
        0,
        ..._uint(outputVersion > 4 ? 4 : outputVersion),
        ..._uint(_output),
      ]);
    }
    if (sync) {
      await bindingBarrier();
    }
  }

  Future<void> bindingBarrier({bool reply = true}) async {
    final request = await next();
    expect(request.length, 12);
    final words = ByteData.sublistView(request);
    expect(words.getUint32(0, Endian.host), 1);
    expect(words.getUint32(4, Endian.host), 0x000c0000);
    final callback = words.getUint32(8, Endian.host);
    expect(callback, greaterThan(_manager));
    if (reply) {
      await send(_event(callback, 0, _uint(43)));
    }
    bindingCallback = callback;
  }

  int? bindingCallback;

  Future<void> initial({bool done = true, bool output = false, int caps = 1}) =>
      send([
        ..._event(_manager, 0, _uint(_group)),
        ..._event(_manager, 1, _uint(_entry)),
        ..._event(_group, 0, _uint(1)),
        ..._event(_entry, 0, _string('stable-id')),
        ..._event(_entry, 1, _string('开发 🐈')),
        ..._event(_entry, 2, [..._uint(8), ..._uint(2), ..._uint(7)]),
        ..._event(_entry, 3, _uint(3)),
        ..._event(_entry, 4, _uint(caps)),
        ..._event(_group, 3, _uint(_entry)),
        if (output) ..._event(_group, 1, _uint(_output)),
        if (done) ..._event(_manager, 2),
      ]);

  Future<void> close() async {
    socket?.destroy();
    await requests?.cancel();
    await listener.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

Future<Workspace> _connected(
  _Server server, {
  int? outputVersion,
  int caps = 1,
}) async {
  final connecting = Workspace.connect(socketPath: server.path);
  await server.discover(outputVersion: outputVersion);
  await server.initial(output: outputVersion != null, caps: caps);
  final workspace = await connecting;
  addTearDown(workspace.close);
  return workspace;
}

Future<void> _publish(
  _Server server,
  Workspace workspace,
  List<int> events,
) async {
  final changed = workspace.changes.first;
  await server.send([...events, ..._event(_manager, 2)]);
  await changed.timeout(const Duration(seconds: 2));
}

void main() {
  test('new workspaces re-sort numerically without changing focus', () async {
    final server = await _Server.start();
    final workspace = await _connected(server);
    await _publish(server, workspace, [
      ..._event(_entry, 1, _string('10')),
      ..._event(_manager, 1, _uint(_entry + 1)),
      ..._event(_entry + 1, 1, _string('2')),
    ]);
    expect(workspace.workspaces.map((e) => e.name), ['2', '10']);
    final before = workspace.workspaces;
    final focused = before.singleWhere((e) => e.isActive);

    await _publish(server, workspace, [
      ..._event(_manager, 1, _uint(_entry + 2)),
      ..._event(_entry + 2, 1, _string('1')),
    ]);
    expect(workspace.workspaces.map((e) => e.name), ['1', '2', '10']);
    expect(before.map((e) => e.name), ['2', '10']);
    final active = workspace.workspaces.singleWhere((e) => e.isActive);
    expect(active.objectId, focused.objectId);
    expect(active.isUrgent, isTrue);
    expect(active.groupId, _group);
    expect(active.coordinates, [2, 7]);
    // A retained snapshot still targets the same handle after its index moves.
    await workspace.activate(focused);
    expect(await server.next(), [..._uint(_entry), ..._uint(0x00080001)]);
    expect(await server.next(), [..._uint(_manager), ..._uint(0x00080000)]);
  });

  test(
    'renames re-sort atomically and removals preserve focused handle',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      await _publish(server, workspace, [
        ..._event(_entry, 1, _string('10')),
        ..._event(_manager, 1, _uint(_entry + 1)),
        ..._event(_entry + 1, 1, _string('2')),
        ..._event(_manager, 1, _uint(_entry + 2)),
        ..._event(_entry + 2, 1, _string('Alpha')),
      ]);
      final before = workspace.workspaces;
      await server.send(_event(_entry, 1, _string('1')));
      await _settle();
      expect(identical(workspace.workspaces, before), isTrue);
      await _publish(server, workspace, []);
      expect(workspace.workspaces.map((e) => e.name), ['1', '2', 'Alpha']);
      expect(before.map((e) => e.name), ['2', '10', 'Alpha']);
      await _publish(server, workspace, [
        ..._event(_entry + 1, 1, _string('Zulu')),
      ]);
      expect(workspace.workspaces.map((e) => e.name), ['1', 'Alpha', 'Zulu']);
      await _publish(server, workspace, [..._event(_entry + 2, 5)]);
      expect(workspace.workspaces.map((e) => e.name), ['1', 'Zulu']);
      expect(
        workspace.workspaces.singleWhere((e) => e.isActive).objectId,
        _entry,
      );
      expect(await server.next(), [..._uint(_entry + 2), ..._uint(0x00080000)]);
    },
  );

  test(
    'numeric named and missing labels have stable display ordering',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      await _publish(server, workspace, [
        ..._event(_entry, 1, _string('Zulu')),
        for (final (offset, name) in [
          (8, '2'),
          (3, '02'),
          (9, '0x10'),
          (10, '20'),
          (7, 'Alpha'),
          (2, 'Alpha'),
          (6, null),
          (1, null),
        ]) ...[
          ..._event(_manager, 1, _uint(_entry + offset)),
          if (name != null) ..._event(_entry + offset, 1, _string(name)),
        ],
      ]);
      final expected = [
        8,
        3,
        10,
        9,
        7,
        2,
        0,
        6,
        1,
      ].map((i) => _entry + i).toList();
      expect(workspace.workspaces.map((e) => e.objectId), expected);
      // Neither opaque IDs nor group-local geometry are display order keys.
      await _publish(server, workspace, [
        ..._event(_entry + 8, 0, _string('opaque-z')),
        ..._event(_entry + 3, 0, _string('opaque-a')),
        ..._event(_entry + 8, 2, [..._uint(4), ..._uint(99)]),
        ..._event(_entry + 3, 2, [..._uint(4), ..._uint(1)]),
      ]);
      expect(workspace.workspaces.map((e) => e.objectId), expected);
      await _publish(server, workspace, []);
      expect(workspace.workspaces.map((e) => e.objectId), expected);
    },
  );

  test(
    'fragmented/coalesced discovery waits for initial manager done',
    () async {
      final server = await _Server.start();
      var ready = false;
      final connecting = Workspace.connect(socketPath: server.path).then((
        workspace,
      ) {
        ready = true;
        return workspace;
      });
      await server.discover();
      await server.initial(done: false);
      await _settle();
      expect(ready, isFalse);
      await server.send(_event(_manager, 2), fragmented: true);
      final workspace = await connecting;
      addTearDown(workspace.close);
      final entry = workspace.workspaces.single;
      expect(entry.id, 'stable-id');
      expect(entry.name, '开发 🐈');
      expect(entry.coordinates, [2, 7]);
      expect(entry.isActive, isTrue);
      expect(entry.isUrgent, isTrue);
      expect(entry.isHidden, isFalse);
      expect(entry.groupId, _group);
      expect(workspace.groups.single.canCreateWorkspace, isTrue);
      expect(() => workspace.workspaces.clear(), throwsUnsupportedError);
      expect(() => entry.coordinates.add(9), throwsUnsupportedError);
      expect(() => workspace.groups.clear(), throwsUnsupportedError);
    },
  );

  test('initial manager done cannot bypass registry sync barrier', () async {
    final server = await _Server.start();
    var ready = false;
    final connecting = Workspace.connect(socketPath: server.path).then((
      workspace,
    ) {
      ready = true;
      return workspace;
    });
    await server.discover(sync: false);
    await server.initial();
    await _settle();
    expect(ready, isFalse);
    await server.send(_event(3, 0, _uint(42)));
    await server.bindingBarrier(reply: false);
    await _settle();
    expect(ready, isFalse, reason: 'Initial binds need their own sync barrier');
    await server.send(_event(server.bindingCallback!, 0, _uint(43)));
    final workspace = await connecting;
    addTearDown(workspace.close);
    expect(workspace.workspaces, hasLength(1));
  });

  test(
    'workspace and group state publish together only at manager done',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      final oldEntries = workspace.workspaces;
      final oldGroups = workspace.groups;
      var notifications = 0;
      final subscription = workspace.changes.listen((_) => notifications++);
      addTearDown(subscription.cancel);
      await server.send([
        ..._event(_entry, 1, _string('次の桌面')),
        ..._event(_entry, 3, _uint(4)),
        ..._event(_group, 0, _uint(0)),
        ..._event(_group, 4, _uint(_entry)),
      ]);
      await _settle();
      expect(identical(workspace.workspaces, oldEntries), isTrue);
      expect(identical(workspace.groups, oldGroups), isTrue);
      expect(notifications, 0);
      await _publish(server, workspace, []);
      expect(notifications, 1);
      expect(workspace.workspaces.single.name, '次の桌面');
      expect(workspace.workspaces.single.isActive, isFalse);
      expect(workspace.workspaces.single.isHidden, isTrue);
      expect(workspace.workspaces.single.groupId, isNull);
      expect(workspace.groups.single.canCreateWorkspace, isFalse);
      expect(oldEntries.single.name, '开发 🐈');
      expect(oldEntries.single.groupId, _group);
      expect(oldGroups.single.canCreateWorkspace, isTrue);
    },
  );

  test(
    'activate writes golden activate then commit without optimistic state',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      final before = workspace.workspaces;
      await workspace.activate(before.single);
      expect(await server.next(), [..._uint(0xff000001), ..._uint(0x00080001)]);
      expect(await server.next(), [..._uint(4), ..._uint(0x00080000)]);
      expect(identical(workspace.workspaces, before), isTrue);
    },
  );

  test(
    'concurrent activate and deactivate preserve request commit order',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server, caps: 3);
      final entry = workspace.workspaces.single;
      await Future.wait([
        workspace.activate(entry),
        workspace.deactivate(entry),
      ]).timeout(const Duration(seconds: 2));
      expect(await server.next(), _event(_entry, 1));
      expect(await server.next(), _event(_manager, 0));
      expect(await server.next(), _event(_entry, 2));
      expect(await server.next(), _event(_manager, 0));
      expect(workspace.isClosed, isFalse);
      expect(workspace.lastError, isNull);
    },
  );

  test(
    'concurrent actions and event-triggered release preserve wire order',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server, caps: 3, outputVersion: 4);
      final entry = workspace.workspaces.single;
      final changed = workspace.changes.first;
      final actions = Future.wait([
        workspace.activate(entry),
        workspace.deactivate(entry),
      ]);
      final actionsResult = actions.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await server.send(_event(2, 1, _uint(11)));
      await changed.timeout(const Duration(seconds: 2));
      expect(await actionsResult.timeout(const Duration(seconds: 2)), isNull);
      expect(await server.next(), _event(_entry, 1));
      expect(await server.next(), _event(_manager, 0));
      expect(await server.next(), _event(_entry, 2));
      expect(await server.next(), _event(_manager, 0));
      expect(await server.next(), [..._uint(5), ..._uint(0x00080000)]);
      expect(workspace.groups.single.outputs, isEmpty);
      expect(workspace.isClosed, isFalse);
      expect(workspace.lastError, isNull);
    },
  );

  test(
    'old snapshots use latest committed capabilities in both directions',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server, caps: 0);
      final old = workspace.workspaces.single;
      await server.send(_event(_entry, 4, _uint(1)));
      await _settle();
      await expectLater(
        workspace.activate(old),
        throwsA(_failure('UnsupportedOperation')),
      );
      await _publish(server, workspace, []);
      expect(old.canActivate, isFalse);
      await workspace.activate(old);
      expect(await server.next(), _event(_entry, 1));
      expect(await server.next(), _event(_manager, 0));
      final capable = workspace.workspaces.single;
      await _publish(server, workspace, _event(_entry, 4, _uint(0)));
      expect(capable.canActivate, isTrue);
      await expectLater(
        workspace.activate(capable),
        throwsA(_failure('UnsupportedOperation')),
      );
      // No invalid activate request was queued before this valid create request.
      await workspace.createWorkspace(workspace.groups.single, '猫');
      expect(await server.next(), [
        ..._uint(_group),
        ..._uint(0x00100000),
        ..._uint(4),
        0xe7,
        0x8c,
        0xab,
        0,
      ]);
      expect(await server.next(), _event(_manager, 0));
    },
  );

  test(
    'removed server object ID may be reused but stale identity is rejected',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      final stale = workspace.workspaces.single;
      await _publish(server, workspace, _event(_entry, 5));
      expect(await server.next(), _event(_entry, 0));
      expect(workspace.workspaces, isEmpty);
      await _publish(server, workspace, [
        ..._event(_manager, 1, _uint(_entry)),
        ..._event(_entry, 1, _string('replacement')),
        ..._event(_entry, 4, _uint(1)),
      ]);
      expect(workspace.workspaces.single.objectId, stale.objectId);
      await expectLater(
        workspace.activate(stale),
        throwsA(_failure('StaleWorkspace')),
      );
      await workspace.activate(workspace.workspaces.single);
      expect(await server.next(), _event(_entry, 1));
      expect(await server.next(), _event(_manager, 0));
    },
  );

  for (final version in [1, 2, 3, 4, 9]) {
    test(
      'wl_output v$version binds supported version and exposes metadata',
      () async {
        final server = await _Server.start();
        final workspace = await _connected(server, outputVersion: version);
        final original = workspace.groups.single;
        expect(original.outputs.single.objectId, _output);
        expect(original.outputs.single.name, isNull);
        expect(original.outputs.single.description, isNull);
        expect(() => original.outputs.clear(), throwsUnsupportedError);
        if (version >= 4) {
          final changed = workspace.changes.first;
          await server.send([
            ..._event(_output, 4, _string('DP-猫')),
            ..._event(_output, 5, _string('显示器 🌈')),
            ..._event(_output, 2),
          ], fragmented: true);
          await changed;
          expect(workspace.groups.single.outputs.single.name, 'DP-猫');
          expect(workspace.groups.single.outputs.single.description, '显示器 🌈');
          expect(original.outputs.single.name, isNull);
        } else {
          // Version 1 has geometry/mode but no done, name, or description.
          await server.send(
            _event(_output, 1, [
              ..._uint(3),
              ..._uint(1920),
              ..._uint(1080),
              ..._uint(60000),
            ]),
          );
          await _settle();
          expect(workspace.isClosed, isFalse);
        }
        final changed = workspace.changes.first;
        await server.send(_event(2, 1, _uint(11)));
        await changed;
        expect(workspace.groups.single.outputs, isEmpty);
        expect(original.outputs, hasLength(1));
        if (version >= 3) {
          // release is wl_output opcode 0, eight bytes, with no arguments.
          expect(await server.next(), [..._uint(5), ..._uint(0x00080000)]);
        } else {
          // A following request proves v1/v2 removal did not enqueue release.
          await workspace.activate(workspace.workspaces.single);
          expect(await server.next(), _event(_entry, 1));
          expect(await server.next(), _event(_manager, 0));
        }
        final queuedOutputEvent = version >= 4
            ? _event(_output, 4, _string('queued-after-removal'))
            : _event(_output, 1, [
                ..._uint(3),
                ..._uint(1920),
                ..._uint(1080),
                ..._uint(60000),
              ]);
        // A manager done after the queued event proves it was decoded safely.
        await _publish(server, workspace, queuedOutputEvent);
        expect(workspace.isClosed, isFalse);
        expect(workspace.groups.single.outputs, isEmpty);
        if (version >= 3) {
          await _publish(server, workspace, _event(1, 1, _uint(_output)));
          expect(workspace.isClosed, isFalse);
          final closed = workspace.changes.drain<void>();
          await server.send(queuedOutputEvent);
          await closed.timeout(const Duration(seconds: 2));
          expect(workspace.lastError, _failure('MalformedMessage'));
        }
      },
    );
  }

  test('missing manager fails after discovery callback', () async {
    final server = await _Server.start();
    final failure = expectLater(
      Workspace.connect(socketPath: server.path),
      throwsA(_failure('UnsupportedProtocol')),
    );
    await server.accept();
    await server.next();
    await server.next();
    await server.send(_event(3, 0, _uint(1)));
    await failure;
  });

  test('initial state timeout closes a silent connection', () async {
    final server = await _Server.start();
    final failure = expectLater(
      Workspace.connect(
        socketPath: server.path,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(_failure('TimedOut')),
    );
    await server.discover();
    await failure;
    expect(
      await server.requests!.moveNext().timeout(const Duration(seconds: 2)),
      isFalse,
    );
  });

  test('nonexistent explicit socket fails without desktop fallback', () async {
    final server = await _Server.start();
    await expectLater(
      Workspace.connect(socketPath: '${server.directory.path}/absent'),
      throwsA(_failure('Disconnected')),
    );
  });

  final malformed = <String, List<int>>{
    'undersized header': [..._uint(_manager), ..._uint(0x00040002)],
    'unaligned header': [..._uint(_manager), ..._uint(0x00090002), 0],
    'unknown opcode': _event(_manager, 99),
    'unknown object': _event(123456, 0),
    'invalid server ID': _event(_manager, 1, _uint(8)),
    'duplicate server ID': _event(_manager, 1, _uint(_entry)),
    'unterminated string': _event(_entry, 1, [..._uint(4), 97, 98, 99, 100]),
    'invalid UTF-8': _event(_entry, 1, [..._uint(2), 0xff, 0, 0, 0]),
    'invalid coordinate array': _event(_entry, 2, [..._uint(1), 1, 0, 0, 0]),
    'wrong interface reference': _event(_group, 1, _uint(_entry)),
  };
  for (final entry in malformed.entries) {
    test('malformed event: ${entry.key}', () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      final closed = workspace.changes.drain<void>();
      await server.send(entry.value);
      await closed.timeout(const Duration(seconds: 2));
      expect(workspace.isClosed, isTrue);
      expect(workspace.lastError, _failure('MalformedMessage'));
    });
  }

  for (final truncated in [false, true]) {
    test(
      'server EOF ${truncated ? 'with partial frame' : 'between frames'} closes stream',
      () async {
        final server = await _Server.start();
        final workspace = await _connected(server);
        final closed = workspace.changes.drain<void>();
        if (truncated)
          await server.send(
            _event(_entry, 1, _string('partial')).sublist(0, 10),
          );
        await server.socket!.close();
        await closed.timeout(const Duration(seconds: 2));
        expect(
          workspace.lastError,
          _failure(truncated ? 'MalformedMessage' : 'Disconnected'),
        );
        expect(workspace.isClosed, isTrue);
      },
    );
  }

  test(
    'display error preserves compositor diagnostic and terminates',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      final closed = workspace.changes.drain<void>();
      await server.send(
        _event(1, 0, [..._uint(_manager), ..._uint(7), ..._string('操作失败')]),
      );
      await closed.timeout(const Duration(seconds: 2));
      expect(workspace.lastError, _failure('ProtocolError'));
      expect(
        (workspace.lastError as WorkspaceException).message,
        contains('操作失败'),
      );
    },
  );

  test(
    'close is idempotent even with paused listener and rejects requests',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      final entry = workspace.workspaces.single;
      final subscription = workspace.changes.listen((_) {});
      subscription.pause();
      await workspace.close().timeout(const Duration(seconds: 1));
      await workspace.close().timeout(const Duration(seconds: 1));
      expect(workspace.isClosed, isTrue);
      expect(workspace.lastError, isNull);
      await expectLater(
        workspace.activate(entry),
        throwsA(_failure('Disconnected')),
      );
      subscription.resume();
      await subscription.cancel();
    },
  );
  test('pending activation settles when close interrupts its flush', () async {
    final server = await _Server.start();
    final workspace = await _connected(server);
    final subscription = workspace.changes.listen((_) {});
    addTearDown(subscription.cancel);
    subscription.pause();
    // Install the error observer before close can interrupt the pending flush.
    // Either send completion or Disconnected is valid, depending on scheduling.
    final activation = workspace
        .activate(workspace.workspaces.single)
        .then<Object?>((_) => null, onError: (Object error) => error);
    await workspace.close().timeout(const Duration(seconds: 1));
    await workspace.close().timeout(const Duration(seconds: 1));
    final outcome = await activation.timeout(const Duration(seconds: 1));
    expect(outcome, anyOf(isNull, _failure('Disconnected')));
    expect(workspace.isClosed, isTrue);
    expect(workspace.lastError, isNull);
    subscription.resume();
  });

  test('stale group rejects creation after server ID reuse', () async {
    final server = await _Server.start();
    final workspace = await _connected(server);
    final old = workspace.groups.single;
    await _publish(server, workspace, _event(_group, 5));
    expect(await server.next(), _event(_group, 1));
    expect(workspace.groups, isEmpty);
    expect(workspace.workspaces.single.groupId, isNull);
    await _publish(server, workspace, [
      ..._event(_manager, 0, _uint(_group)),
      ..._event(_group, 0, _uint(1)),
    ]);
    await expectLater(
      workspace.createWorkspace(old, 'stale'),
      throwsA(_failure('StaleWorkspace')),
    );
    await workspace.createWorkspace(workspace.groups.single, 'é');
    // UTF-8 byte length includes the NUL; one alignment byte follows it.
    expect(await server.next(), [
      ..._uint(_group),
      ..._uint(0x00100000),
      ..._uint(3),
      0xc3,
      0xa9,
      0,
      0,
    ]);
    expect(await server.next(), _event(_manager, 0));
  });

  test('output event newer than bound version is rejected', () async {
    final server = await _Server.start();
    final workspace = await _connected(server, outputVersion: 1);
    final closed = workspace.changes.drain<void>();
    await server.send(_event(_output, 4, _string('too-new')));
    await closed.timeout(const Duration(seconds: 2));
    expect(workspace.lastError, _failure('MalformedMessage'));
  });

  for (final finished in [false, true]) {
    test(
      'manager ${finished ? 'finished' : 'global removed'} terminates connection',
      () async {
        final server = await _Server.start();
        final workspace = await _connected(server);
        final closed = workspace.changes.drain<void>();
        await server.send(
          finished ? _event(_manager, 3) : _event(2, 1, _uint(10)),
        );
        await closed.timeout(const Duration(seconds: 2));
        expect(
          workspace.lastError,
          _failure(finished ? 'Disconnected' : 'UnsupportedProtocol'),
        );
        expect(workspace.isClosed, isTrue);
      },
    );
  }

  for (final partial in [false, true]) {
    test(
      'EOF before discovery ${partial ? 'with truncated header' : 'without data'} rejects connect',
      () async {
        final server = await _Server.start();
        final failure = expectLater(
          Workspace.connect(socketPath: server.path),
          throwsA(_failure(partial ? 'MalformedMessage' : 'Disconnected')),
        );
        await server.accept();
        await server.next();
        await server.next();
        if (partial) {
          await server.send([1, 0, 0]);
        }
        await server.socket!.close();
        await failure;
      },
    );
  }

  test(
    'display error for an unknown offending object remains ProtocolError',
    () async {
      final server = await _Server.start();
      final workspace = await _connected(server);
      final closed = workspace.changes.drain<void>();
      await server.send(
        _event(1, 0, [
          ..._uint(98765),
          ..._uint(9),
          ..._string('unknown object'),
        ]),
      );
      await closed.timeout(const Duration(seconds: 2));
      expect(workspace.lastError, _failure('ProtocolError'));
      expect(
        (workspace.lastError as WorkspaceException).message,
        contains('98765'),
      );
    },
  );
}
