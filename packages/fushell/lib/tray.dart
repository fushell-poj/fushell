/// StatusNotifierItem host and D-Bus menu transport, independent of Flutter.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

part 'src/tray/host.dart';
part 'src/tray/item.dart';
part 'src/tray/menu.dart';
part 'src/tray/watcher.dart';

const _watcherName = 'org.kde.StatusNotifierWatcher';
const _watcherPath = '/StatusNotifierWatcher';
const _itemInterface = 'org.kde.StatusNotifierItem';
const _menuInterface = 'com.canonical.dbusmenu';
const _callTimeout = Duration(seconds: 5);

String _string(
  Map<String, DBusValue> values,
  String key, [
  String fallback = '',
]) => values[key] is DBusString ? values[key]!.asString() : fallback;
bool _boolean(
  Map<String, DBusValue> values,
  String key, [
  bool fallback = false,
]) => values[key] is DBusBoolean ? values[key]!.asBoolean() : fallback;
int _integer(Map<String, DBusValue> values, String key, [int fallback = 0]) =>
    values[key] is DBusInt32 ? values[key]!.asInt32() : fallback;
