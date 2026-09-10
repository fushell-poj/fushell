import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/tray.dart';

const watcherName = 'org.kde.StatusNotifierWatcher';
const itemInterface = 'org.kde.StatusNotifierItem';

Future<void> eventually(bool Function() predicate) async {
  final limit = DateTime.now().add(const Duration(seconds: 8));
  while (!predicate()) {
    if (DateTime.now().isAfter(limit)) fail('Condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class MockItem extends DBusObject {
  MockItem([String path = '/StatusNotifierItem']) : super(DBusObjectPath(path));
  String title = 'Example';
  final calls = <DBusMethodCall>[];
  Completer<void>? propertyGate;
  bool propertiesRequested = false;
  Map<String, DBusValue> get properties => {
    'Id': const DBusString('example'),
    'Title': DBusString(title),
    'Status': const DBusString('Active'),
    'IconName': const DBusString('example-icon'),
    'IconThemePath': const DBusString('/tmp/icons'),
    'ItemIsMenu': const DBusBoolean(false),
    'Menu': DBusObjectPath('/Menu'),
    'IconPixmap': DBusArray(DBusSignature('(iiay)'), [
      DBusStruct([
        const DBusInt32(1),
        const DBusInt32(1),
        DBusArray.byte([255, 1, 2, 3]),
      ]),
    ]),
    'ToolTip': DBusStruct([
      const DBusString('tip'),
      DBusArray(DBusSignature('(iiay)'), []),
      const DBusString('Tooltip'),
      const DBusString('Description'),
    ]),
  };
  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    propertiesRequested = true;
    final snapshot = properties;
    await propertyGate?.future;
    return DBusGetAllPropertiesResponse(snapshot);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    calls.add(call);
    return DBusMethodSuccessResponse();
  }
}

class MockMenu extends DBusObject {
  MockMenu() : super(DBusObjectPath('/Menu'));
  final calls = <DBusMethodCall>[];
  String label = '_Open';
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    calls.add(call);
    switch (call.name) {
      case 'AboutToShow':
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'GetLayout':
        return DBusMethodSuccessResponse([
          const DBusUint32(1),
          DBusStruct([
            const DBusInt32(0),
            DBusDict.stringVariant({}),
            DBusArray.variant([
              DBusStruct([
                const DBusInt32(1),
                DBusDict.stringVariant({
                  'label': DBusString(label),
                  'enabled': const DBusBoolean(false),
                  'visible': const DBusBoolean(true),
                  'toggle-type': const DBusString('checkmark'),
                  'toggle-state': const DBusInt32(1),
                }),
                DBusArray.variant([]),
              ]),
            ]),
          ]),
        ]);
      case 'Event':
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}

class MockWatcher extends DBusObject {
  MockWatcher() : super(DBusObjectPath('/StatusNotifierWatcher'));
  final items = <String>[];
  final hosts = <String>[];
  Completer<void>? snapshotGate;
  bool snapshotRequested = false;
  int failures = 0;
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.name == 'RegisterStatusNotifierHost') {
      if (failures-- > 0) return DBusMethodErrorResponse.failed('Try again');
      hosts.add(call.values.first.asString());
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final snapshot = items.toList();
    snapshotRequested = true;
    await snapshotGate?.future;
    return DBusGetPropertyResponse(DBusArray.string(snapshot));
  }

  Future<void> add(String item) async {
    items.add(item);
    await emitSignal(watcherName, 'StatusNotifierItemRegistered', [
      DBusString(item),
    ]);
  }

  Future<void> remove(String item) async {
    items.remove(item);
    await emitSignal(watcherName, 'StatusNotifierItemUnregistered', [
      DBusString(item),
    ]);
  }
}

void main() {
  // Every test gets a private real daemon, including when flutter test is invoked
  // outside dbus-run-session. Never register a watcher on the user's desktop.
  late Process daemon;
  late DBusAddress address;
  final clients = <DBusClient>[];
  final hosts = <TrayHost>[];
  DBusClient client() {
    final bus = DBusClient(address);
    clients.add(bus);
    return bus;
  }

  Future<TrayHost> host([DBusClient? bus]) async {
    final value = await TrayHost.connect(bus: bus ?? client());
    hosts.add(value);
    return value;
  }

  Future<DBusRemoteObject> watcher(DBusClient bus) async => DBusRemoteObject(
    bus,
    name: watcherName,
    path: DBusObjectPath('/StatusNotifierWatcher'),
  );
  Future<void> register(
    DBusClient bus, [
    String path = '/StatusNotifierItem',
  ]) async {
    await (await watcher(bus)).callMethod(
      watcherName,
      'RegisterStatusNotifierItem',
      [DBusString(path)],
    );
  }

  setUp(() async {
    daemon = await Process.start('dbus-daemon', [
      '--session',
      '--nofork',
      '--print-address=1',
    ]);
    final line = await daemon.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    address = DBusAddress(line);
  });
  tearDown(() async {
    for (final value in hosts.reversed) {
      await value.close();
    }
    hosts.clear();
    for (final bus in clients.reversed) {
      await bus.close();
    }
    clients.clear();
    daemon.kill();
    await daemon.exitCode;
  });

  test(
    'fallback allows multiple hosts, deduplicates items and preserves borrowed bus',
    () async {
      final bus = client();
      final first = await host(bus);
      final second = await host();
      await eventually(
        () => first.isFallbackWatcher && second.watcherOwner == bus.uniqueName,
      );
      expect(first.hostName, isNot(second.hostName));
      final source = client();
      final mock = MockItem();
      await source.registerObject(mock);
      await register(source);
      await register(source);
      await eventually(
        () =>
            first.items.length == 1 &&
            second.items.length == 1 &&
            first.items.single.title == 'Example',
      );
      expect(first.items.single.iconPixmaps.single.bytes, [255, 1, 2, 3]);
      expect(first.items.single.toolTip?.title, 'Tooltip');
      final inspector = await watcher(source);
      final info = await inspector.introspect();
      expect(info.interfaces.any((i) => i.name == watcherName), isTrue);
      final registeredHosts = await inspector.getProperty(
        watcherName,
        'IsStatusNotifierHostRegistered',
      );
      expect(registeredHosts.asBoolean(), isTrue);
      await second.close();
      await second.close();
      expect(await bus.getNameOwner(watcherName), bus.uniqueName);
      await first.close();
      expect(await bus.getNameOwner(watcherName), isNull);
      expect(await bus.getNameOwner(bus.uniqueName), bus.uniqueName);
    },
  );

  test('simultaneous fallback contenders elect exactly one watcher', () async {
    final values = await Future.wait([host(), host(), host()]);
    await eventually(
      () =>
          values.where((value) => value.isFallbackWatcher).length == 1 &&
          values.every((value) => value.watcherOwner != null),
    );
    expect(values.map((value) => value.watcherOwner).toSet(), hasLength(1));
    final winner = values.singleWhere((value) => value.isFallbackWatcher);
    await winner.close();
    final survivors = values.where((value) => value != winner).toList();
    await eventually(
      () => survivors.where((value) => value.isFallbackWatcher).length == 1,
    );
  });

  test(
    'fallback tracks aliases until the last registered alias disappears',
    () async {
      final value = await host();
      await eventually(() => value.isFallbackWatcher);
      final source = client();
      await source.registerObject(MockItem());
      await source.requestName('org.example.First');
      await source.requestName('org.example.Second');
      await register(source, 'org.example.First');
      await register(source, 'org.example.Second');
      await eventually(() => value.items.length == 1);
      await source.releaseName('org.example.First');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(value.items, hasLength(1));
      await source.releaseName('org.example.Second');
      await eventually(() => value.items.isEmpty);
    },
  );

  test('closing host while item load is pending rejects late state', () async {
    final value = await host();
    await eventually(() => value.isFallbackWatcher);
    final source = client();
    final item = MockItem()..propertyGate = Completer<void>();
    await source.registerObject(item);
    await register(source);
    await eventually(() => item.propertiesRequested);
    await value.close();
    item.propertyGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(value.items, isEmpty);
    expect(value.isClosed, isTrue);
  });

  test(
    'shares one fallback for two hosts using the same injected connection',
    () async {
      final bus = client();
      final first = await host(bus);
      final second = await host(bus);
      await eventually(
        () => first.isFallbackWatcher && second.isFallbackWatcher,
      );
      await first.close();
      expect(await bus.getNameOwner(watcherName), bus.uniqueName);
      await second.close();
      expect(await bus.getNameOwner(watcherName), isNull);
    },
  );

  test(
    'existing watcher is not replaced; initial aliases are deduplicated',
    () async {
      final external = client();
      final mock = MockWatcher();
      await external.registerObject(mock);
      await external.requestName(
        watcherName,
        flags: {DBusRequestNameFlag.allowReplacement},
      );
      final source = client();
      await source.registerObject(MockItem());
      await source.requestName('org.example.Item');
      mock.items.addAll([
        'org.example.Item',
        '${source.uniqueName}/StatusNotifierItem',
      ]);
      final value = await host();
      await eventually(
        () => value.items.length == 1 && mock.hosts.contains(value.hostName),
      );
      expect(value.watcherOwner, external.uniqueName);
      expect(value.isFallbackWatcher, isFalse);
      expect(await external.getNameOwner(watcherName), external.uniqueName);
      await value.close();
      expect(await external.getNameOwner(watcherName), external.uniqueName);
    },
  );

  test(
    'watcher departure triggers fallback and item re-registration',
    () async {
      final external = client();
      final mock = MockWatcher();
      await external.registerObject(mock);
      await external.requestName(watcherName);
      final value = await host();
      await eventually(() => mock.hosts.isNotEmpty);
      await external.releaseName(watcherName);
      await eventually(() => value.isFallbackWatcher);
      final source = client();
      await source.registerObject(MockItem());
      await register(source);
      await eventually(() => value.items.length == 1);
      await source.close();
      clients.remove(source);
      await eventually(() => value.items.isEmpty);
    },
  );

  test(
    'A-to-B watcher replacement ignores delayed A snapshot and old signals',
    () async {
      final a = client();
      final old = MockWatcher()..snapshotGate = Completer<void>();
      await a.registerObject(old);
      await a.requestName(
        watcherName,
        flags: {DBusRequestNameFlag.allowReplacement},
      );
      final source = client();
      await source.registerObject(MockItem());
      old.items.add('${source.uniqueName}/StatusNotifierItem');
      final connecting = host();
      await eventually(() => old.snapshotRequested);
      final b = client();
      final replacement = MockWatcher();
      await b.registerObject(replacement);
      await b.requestName(
        watcherName,
        flags: {
          DBusRequestNameFlag.replaceExisting,
          DBusRequestNameFlag.doNotQueue,
        },
      );
      await eventually(() => replacement.hosts.isNotEmpty);
      old.snapshotGate!.complete();
      final value = await connecting;
      await eventually(() => value.watcherOwner == b.uniqueName);
      await old.add('${source.uniqueName}/StatusNotifierItem');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(value.items, isEmpty);
    },
  );

  test(
    'snapshot journal applies removal and addition while snapshot is delayed',
    () async {
      final external = client();
      final mock = MockWatcher()..snapshotGate = Completer<void>();
      await external.registerObject(mock);
      await external.requestName(watcherName);
      final source = client();
      await source.registerObject(MockItem());
      await source.registerObject(MockItem('/Other'));
      final removed = '${source.uniqueName}/StatusNotifierItem',
          added = '${source.uniqueName}/Other';
      mock.items.add(removed);
      final connecting = host();
      await eventually(() => mock.snapshotRequested);
      await mock.remove(removed);
      await mock.add(added);
      await mock.add(added);
      mock.snapshotGate!.complete();
      final value = await connecting;
      await eventually(
        () => value.items.length == 1 && value.items.single.path == '/Other',
      );
    },
  );

  test('late item properties cannot resurrect an unregistered item', () async {
    final external = client();
    final mock = MockWatcher();
    await external.registerObject(mock);
    await external.requestName(watcherName);
    final value = await host();
    final source = client();
    final item = MockItem()..propertyGate = Completer<void>();
    await source.registerObject(item);
    final name = '${source.uniqueName}/StatusNotifierItem';
    await mock.add(name);
    await eventually(() => item.propertiesRequested);
    await mock.remove(name);
    await eventually(() => value.items.isEmpty);
    item.propertyGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(value.items, isEmpty);
  });

  test('failed host registration retries on the same watcher', () async {
    final external = client();
    final mock = MockWatcher()..failures = 1;
    await external.registerObject(mock);
    await external.requestName(watcherName);
    final value = await host();
    await eventually(() => mock.hosts.contains(value.hostName));
    await eventually(() => value.lastError == null);
  });

  test('item actions and menu layout, events, updates and close', () async {
    final value = await host();
    await eventually(() => value.isFallbackWatcher);
    final source = client();
    final item = MockItem(), menu = MockMenu();
    await source.registerObject(item);
    await source.registerObject(menu);
    await register(source);
    await eventually(
      () => value.items.length == 1 && value.items.single.id == 'example',
    );
    final trayItem = value.items.single;
    await trayItem.activate(x: 12, y: 34);
    await trayItem.secondaryActivate();
    await trayItem.contextMenu();
    await trayItem.scroll(-120, orientation: 'horizontal');
    expect(item.calls.map((c) => c.name), [
      'Activate',
      'SecondaryActivate',
      'ContextMenu',
      'Scroll',
    ]);
    expect(item.calls.first.values.map((v) => v.toNative()), [12, 34]);
    final transport = (await trayItem.loadMenu())!;
    expect(transport.root.children.single.label, '_Open');
    expect(transport.root.children.single.enabled, isFalse);
    expect(transport.root.children.single.visible, isTrue);
    expect(transport.root.children.single.toggleState, 1);
    await transport.event(1, timestamp: 123);
    final event = menu.calls.last;
    expect(event.signature.value, 'isvu');
    expect(event.values[3].asUint32(), 123);
    menu.label = '_Changed';
    await menu.emitSignal('com.canonical.dbusmenu', 'ItemsPropertiesUpdated');
    await eventually(() => transport.root.children.single.label == '_Changed');
    item.title = 'Updated';
    await item.emitSignal(itemInterface, 'NewTitle');
    await eventually(() => trayItem.title == 'Updated');
    await value.close();
    await transport.close();
    await expectLater(transport.event(1), throwsStateError);
    await expectLater(trayItem.activate(), throwsStateError);
  });
}
