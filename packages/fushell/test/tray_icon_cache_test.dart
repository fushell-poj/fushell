import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/tray.dart';

import 'tray_host_test.dart' show MockItem, eventually, watcherName;

// Protocol types used by consumers of this private-bus test fixture.
export 'package:dbus/dbus.dart';

DBusValue iconPixels(int size, [int red = 1]) =>
    DBusArray(DBusSignature('(iiay)'), [
      DBusStruct([
        DBusInt32(size),
        DBusInt32(size),
        DBusArray.byte(
          List.generate(size * size * 4, (i) => [255, red, 2, 3][i % 4]),
        ),
      ]),
    ]);

class IconTestItem extends MockItem {
  final overrides = <String, DBusValue>{};
  final removed = <String>{};
  @override
  Map<String, DBusValue> get properties =>
      {...super.properties, ...overrides}
        ..removeWhere((k, _) => removed.contains(k));
}

// Shared focused icon fixture. It never connects to the desktop session bus.
class IconTestFixture {
  late Process daemon;
  late DBusClient bus;
  late DBusClient source;
  late TrayHost host;
  final mock = IconTestItem();
  TrayItem get item => host.items.single;
  Future<void> start() async {
    daemon = await Process.start('dbus-daemon', [
      '--session',
      '--nofork',
      '--print-address=1',
    ]);
    final address = DBusAddress(
      await daemon.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first,
    );
    bus = DBusClient(address);
    source = DBusClient(address);
    host = await TrayHost.connect(bus: bus);
    await source.registerObject(mock);
    await DBusRemoteObject(
      source,
      name: watcherName,
      path: DBusObjectPath('/StatusNotifierWatcher'),
    ).callMethod(watcherName, 'RegisterStatusNotifierItem', [
      const DBusString('/StatusNotifierItem'),
    ]);
    await eventually(() => host.items.length == 1);
  }

  Future<void> close() async {
    await host.close();
    await source.close();
    await bus.close();
    daemon.kill();
    await daemon.exitCode;
  }
}

void main() {
  test(
    'pixmaps are immutable, size-selected and cached across equal refreshes',
    () async {
      final f = IconTestFixture();
      await f.start();
      addTearDown(f.close);
      f.mock.overrides['IconPixmap'] = DBusArray(DBusSignature('(iiay)'), [
        ...iconPixels(16).asArray(),
        ...iconPixels(24).asArray(),
        DBusStruct([
          const DBusInt32(513),
          const DBusInt32(1),
          DBusArray.byte(List.filled(513 * 4, 255)),
        ]),
        DBusStruct([
          const DBusInt32(0),
          const DBusInt32(1),
          DBusArray.byte([]),
        ]),
      ]);
      await f.item.refresh();
      final selected = f.item.bestIconPixmap();
      expect(selected!.width, 16); // First size wins an equal-distance tie.
      expect(f.item.bestIconPixmap(), same(selected));
      expect(f.item.bestIconPixmap(size: 24)!.width, 24);
      expect(f.item.bestIconPixmap(size: 513)!.width, 24);
      expect(f.item.bestIconPixmap(maxSize: 1), isNull);
      final all = f.item.iconPixmaps;
      expect(all, hasLength(3));
      expect(all.first, same(selected));
      expect(() => all.clear(), throwsUnsupportedError);
      expect(() => selected.bytes[0] = 0, throwsUnsupportedError);
      final version = f.item.iconVersion;
      await f.item.refresh(); // New DBus objects with equal values.
      expect(f.item.iconVersion, version);
      expect(f.item.iconPixmaps, same(all));
      f.mock.title = 'new title';
      await f.item.refresh();
      expect(f.item.iconVersion, version);
      expect(f.item.iconPixmaps, same(all));
      f.mock.overrides['IconPixmap'] = iconPixels(24, 9);
      await f.item.refresh();
      expect(f.item.iconVersion, version + 1);
      expect(f.item.bestIconPixmap()!.bytes[1], 9);
      expect(f.item.iconPixmaps, isNot(same(all)));
    },
  );

  test(
    'each icon input invalidates version without evicting unrelated pixels',
    () async {
      final f = IconTestFixture();
      await f.start();
      addTearDown(f.close);
      final pixels = f.item.iconPixmaps;
      for (final entry in <String, DBusValue>{
        'IconName': const DBusString('changed'),
        'AttentionIconName': const DBusString('attention'),
        'AttentionIconPixmap': iconPixels(2),
        'OverlayIconName': const DBusString('overlay'),
        'OverlayIconPixmap': iconPixels(3),
        'IconThemePath': const DBusString('/new/path'),
        'Status': const DBusString('NeedsAttention'),
      }.entries) {
        final version = f.item.iconVersion;
        f.mock.overrides[entry.key] = entry.value;
        await f.item.refresh();
        expect(f.item.iconVersion, version + 1, reason: entry.key);
        expect(f.item.iconPixmaps, same(pixels));
      }
      expect(f.item.hasAttentionIconPixmaps, isTrue);
      expect(f.item.bestIconPixmap(attention: true)!.width, 2);
      f.mock.removed.add('AttentionIconPixmap');
      final version = f.item.iconVersion;
      await f.item.refresh();
      expect(f.item.iconVersion, version + 1);
      expect(f.item.hasAttentionIconPixmaps, isFalse);
      expect(f.item.bestIconPixmap(attention: true), same(pixels.single));
      f.mock.overrides['Status'] = const DBusString('Passive');
      await f.item.refresh();
      final passiveVersion = f.item.iconVersion;
      f.mock.overrides['Status'] = const DBusString('Active');
      await f.item.refresh();
      expect(f.item.iconVersion, passiveVersion);
    },
  );
}
