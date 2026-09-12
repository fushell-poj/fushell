part of '../../tray.dart';

/// SNI icon bytes in network byte order: alpha, red, green, blue per pixel.
final class TrayIconPixmap {
  TrayIconPixmap(this.width, this.height, List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  TrayIconPixmap._owned(this.width, this.height, Uint8List bytes)
    : bytes = bytes.asUnmodifiableView();
  final int width;
  final int height;
  final Uint8List bytes;
}

List<TrayIconPixmap> _pixmaps(DBusValue? value) => _TrayPixmapCache(value).all;

// Retain protocol values and convert only requested sizes, once per value.
final class _TrayPixmapCache {
  _TrayPixmapCache(DBusValue? value) {
    if (value?.signature != DBusSignature('a(iiay)')) return;
    for (final entry in value!.asArray()) {
      final fields = entry.asStruct();
      final width = fields[0].asInt32(), height = fields[1].asInt32();
      final bytes = fields[2].asByteArray();
      if (width > 0 && height > 0 && width * height * 4 == bytes.length) {
        entries.add((width, height, bytes));
      }
    }
  }
  final entries = <(int, int, Iterable<int>)>[];
  final _decoded = <int, TrayIconPixmap>{};
  List<TrayIconPixmap>? _all;
  TrayIconPixmap _at(int index) => _decoded.putIfAbsent(index, () {
    final (width, height, bytes) = entries[index];
    return TrayIconPixmap._owned(
      width,
      height,
      Uint8List(width * height * 4)..setAll(0, bytes),
    );
  });
  List<TrayIconPixmap> get all => _all ??= List.unmodifiable([
    for (var i = 0; i < entries.length; i++) _at(i),
  ]);
  TrayIconPixmap? best(int size, int maxSize) {
    int? selected;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.$1 > maxSize || entry.$2 > maxSize) continue;
      if (selected == null ||
          (entry.$1 - size).abs() < (entries[selected].$1 - size).abs()) {
        selected = i;
      }
    }
    return selected == null ? null : _at(selected);
  }
}

final class TrayToolTip {
  const TrayToolTip({
    required this.iconName,
    required this.iconPixmaps,
    required this.title,
    required this.description,
  });
  final String iconName;
  final List<TrayIconPixmap> iconPixmaps;
  final String title;
  final String description;
}

/// A live item bound to a unique service owner, never a replaceable bus alias.
final class TrayItem {
  TrayItem._(DBusClient bus, this.service, this.path, this._notify, this._error)
    : _remote = DBusRemoteObject(
        bus,
        name: service,
        path: DBusObjectPath(path),
      );
  final DBusRemoteObject _remote;
  final String service;
  final String path;
  String get key => '$service$path';
  final void Function() _notify;
  final void Function(Object) _error;
  Map<String, DBusValue> _properties = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Set<TrayMenu> _menus = {};
  bool _closed = false;
  int _revision = 0;
  Future<void>? _closing;
  int _iconVersion = 0;
  final _pixmapCaches = <String, _TrayPixmapCache>{};

  /// Changes only when advertised icon inputs change, not on title/menu updates.
  /// Snapshot this value: a TrayItem is mutable and keeps its identity.
  int get iconVersion => _iconVersion;
  _TrayPixmapCache _cache(String key) =>
      _pixmapCaches.putIfAbsent(key, () => _TrayPixmapCache(_properties[key]));

  /// Whether valid attention pixmaps exist, without allocating their bytes.
  bool get hasAttentionIconPixmaps =>
      _cache('AttentionIconPixmap').entries.isNotEmpty;

  /// Selects the closest width (first wins ties), copying only that pixmap.
  /// Returned immutable pixmaps are shared until their property changes.
  TrayIconPixmap? bestIconPixmap({
    int size = 20,
    int maxSize = 512,
    bool attention = false,
  }) => _cache(
    attention && hasAttentionIconPixmaps ? 'AttentionIconPixmap' : 'IconPixmap',
  ).best(size, maxSize);

  String get id => _string(_properties, 'Id');
  String get title => _string(_properties, 'Title');
  String get status => _string(_properties, 'Status', 'Active');
  String get category => _string(_properties, 'Category');
  String get iconName => _string(_properties, 'IconName');
  String get iconThemePath => _string(_properties, 'IconThemePath');
  String get attentionIconName => _string(_properties, 'AttentionIconName');
  String get overlayIconName => _string(_properties, 'OverlayIconName');
  List<TrayIconPixmap> get iconPixmaps => _cache('IconPixmap').all;
  List<TrayIconPixmap> get attentionIconPixmaps =>
      _cache('AttentionIconPixmap').all;
  List<TrayIconPixmap> get overlayIconPixmaps =>
      _cache('OverlayIconPixmap').all;
  bool get itemIsMenu => _boolean(_properties, 'ItemIsMenu');
  Map<String, DBusValue> get properties => Map.unmodifiable(_properties);
  TrayToolTip? get toolTip {
    final value = _properties['ToolTip'];
    if (value?.signature != DBusSignature('(sa(iiay)ss)')) return null;
    final fields = value!.asStruct();
    return TrayToolTip(
      iconName: fields[0].asString(),
      iconPixmaps: _pixmaps(fields[1]),
      title: fields[2].asString(),
      description: fields[3].asString(),
    );
  }

  Future<void> _start() async {
    _subscriptions.add(
      DBusSignalStream(
        _remote.client,
        sender: service,
        interface: _itemInterface,
        path: _remote.path,
      ).listen((_) {
        _refreshInBackground();
      }, onError: _error),
    );
    _subscriptions.add(
      _remote.propertiesChanged.listen((signal) {
        if (signal.interface == _itemInterface) _refreshInBackground();
      }, onError: _error),
    );
    await refresh();
  }

  void _refreshInBackground() {
    if (_closed) return;
    unawaited(
      refresh().catchError((Object error) {
        if (!_closed) _error(error);
      }),
    );
  }

  /// Refreshes all advertised properties. Latest request wins.
  Future<void> refresh() async {
    _checkOpen();
    final revision = ++_revision;
    final properties = await _remote
        .getAllProperties(_itemInterface)
        .timeout(_callTimeout);
    if (_closed || revision != _revision) return;
    const iconKeys = [
      'IconName',
      'IconPixmap',
      'AttentionIconName',
      'AttentionIconPixmap',
      'OverlayIconName',
      'OverlayIconPixmap',
      'IconThemePath',
    ];
    if (iconKeys.any((key) => _properties[key] != properties[key]) ||
        (_string(_properties, 'Status') == 'NeedsAttention') !=
            (_string(properties, 'Status') == 'NeedsAttention')) {
      ++_iconVersion;
    }
    _pixmapCaches.removeWhere((key, _) => _properties[key] != properties[key]);
    _properties = properties;
    _notify();
  }

  void _checkOpen() {
    if (_closed) throw StateError('Tray item has been removed');
  }

  Future<void> _call(String name, List<DBusValue> values) async {
    _checkOpen();
    await _remote
        .callMethod(
          _itemInterface,
          name,
          values,
          replySignature: DBusSignature(''),
          noAutoStart: true,
        )
        .timeout(_callTimeout);
  }

  Future<void> activate({int x = 0, int y = 0}) =>
      _call('Activate', [DBusInt32(x), DBusInt32(y)]);
  Future<void> secondaryActivate({int x = 0, int y = 0}) =>
      _call('SecondaryActivate', [DBusInt32(x), DBusInt32(y)]);
  Future<void> contextMenu({int x = 0, int y = 0}) =>
      _call('ContextMenu', [DBusInt32(x), DBusInt32(y)]);
  Future<void> scroll(int delta, {String orientation = 'vertical'}) {
    if (orientation != 'vertical' && orientation != 'horizontal') {
      throw ArgumentError.value(orientation, 'orientation');
    }
    return _call('Scroll', [DBusInt32(delta), DBusString(orientation)]);
  }

  /// Opens a menu transport. The caller may close it; item removal also closes it.
  Future<TrayMenu?> loadMenu() async {
    _checkOpen();
    final path = _properties['Menu'];
    if (path is! DBusObjectPath || path.value == '/') return null;
    late final TrayMenu menu;
    menu = TrayMenu._(
      DBusRemoteObject(_remote.client, name: service, path: path),
      () => _menus.remove(menu),
      _error,
    );
    _menus.add(menu);
    try {
      await menu._start();
      if (_closed) {
        await menu.close();
        return null;
      }
      return menu;
    } catch (_) {
      await menu.close();
      rethrow;
    }
  }

  Future<void> _close() => _closing ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    ++_revision;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    for (final menu in _menus.toList()) {
      await menu.close();
    }
  }
}
