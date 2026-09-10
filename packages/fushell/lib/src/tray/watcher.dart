part of '../../tray.dart';

// Shared only by hosts explicitly using the same client. A caller's connection
// and pre-existing names are never released by this fallback.
final class _TrayBusState {
  _TrayBusState(this.bus);
  final DBusClient bus;
  final Set<TrayHost> users = {};
  _FallbackWatcher? watcher;
  Future<void>? _creating;
  bool ownsName = false;
  bool closed = false;

  Future<void> ensureWatcher() => _creating ??= _ensure().whenComplete(() {
    _creating = null;
  });
  Future<void> _ensure() async {
    if (closed || ownsName) return;
    if (await bus.getNameOwner(_watcherName) != null || closed) return;
    var object = watcher;
    if (object == null) {
      object = _FallbackWatcher(bus, () => ownsName && !closed);
      watcher = object;
      await bus.registerObject(object);
      await object.start();
    }
    if (closed) return;
    // Never allow replacement, replace an owner, or queue behind another one.
    final reply = await bus.requestName(
      _watcherName,
      flags: {DBusRequestNameFlag.doNotQueue},
    );
    ownsName = reply == DBusRequestNameReply.primaryOwner;
  }

  Future<void> close() async {
    closed = true;
    await _creating;
    if (ownsName) {
      await bus.releaseName(_watcherName);
      ownsName = false;
    }
    final object = watcher;
    if (object != null) {
      await object.close();
      await bus.unregisterObject(object);
    }
  }
}

final class _FallbackWatcher extends DBusObject {
  _FallbackWatcher(this.bus, this.active) : super(DBusObjectPath(_watcherPath));
  final DBusClient bus;
  final bool Function() active;
  final Map<String, String> _items = {};
  final Map<String, Set<String>> _itemServices = {};
  final Map<String, String> _hosts = {};
  final Map<String, int> _ownerVersions = {};
  StreamSubscription<DBusNameOwnerChangedEvent>? _owners;
  bool _closed = false;

  Future<void> start() async {
    _owners = bus.nameOwnerChanged.listen((event) {
      if (event.oldOwner == null) return;
      // A newly acquired alias may be announced while GetNameOwner is pending.
      // Only loss/replacement invalidates that registration, not acquisition.
      _ownerVersions[event.name] = (_ownerVersions[event.name] ?? 0) + 1;
      for (final entry in _items.entries.toList()) {
        final services = _itemServices[entry.key]!;
        services.remove(event.name);
        if ((event.name.startsWith(':') && entry.value == event.oldOwner) ||
            services.isEmpty) {
          _items.remove(entry.key);
          _itemServices.remove(entry.key);
          _emit('StatusNotifierItemUnregistered', [DBusString(entry.key)]);
        }
      }
      final hadHosts = _hosts.isNotEmpty;
      _hosts.removeWhere(
        (name, owner) =>
            name == event.name ||
            (event.name.startsWith(':') && owner == event.oldOwner),
      );
      if (hadHosts && _hosts.isEmpty) _emit('StatusNotifierHostUnregistered');
    });
  }

  void _emit(String name, [List<DBusValue> values = const []]) {
    if (_closed || !active()) return;
    // A disconnected bus must not create uncaught errors in a signal handler.
    unawaited(emitSignal(_watcherName, name, values).catchError((Object _) {}));
    unawaited(
      emitPropertiesChanged(
        _watcherName,
        changedProperties: _properties,
      ).catchError((Object _) {}),
    );
  }

  Map<String, DBusValue> get _properties => {
    'RegisteredStatusNotifierItems': DBusArray.string(_items.keys),
    'IsStatusNotifierHostRegistered': DBusBoolean(_hosts.isNotEmpty),
    'ProtocolVersion': const DBusInt32(0),
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      _watcherName,
      methods: [
        for (final name in [
          'RegisterStatusNotifierItem',
          'RegisterStatusNotifierHost',
        ])
          DBusIntrospectMethod(
            name,
            args: [
              DBusIntrospectArgument(
                DBusSignature('s'),
                DBusArgumentDirection.in_,
                name: 'service',
              ),
            ],
          ),
      ],
      signals: [
        for (final name in [
          'StatusNotifierItemRegistered',
          'StatusNotifierItemUnregistered',
        ])
          DBusIntrospectSignal(
            name,
            args: [
              DBusIntrospectArgument(
                DBusSignature('s'),
                DBusArgumentDirection.out,
                name: 'service',
              ),
            ],
          ),
        DBusIntrospectSignal('StatusNotifierHostRegistered'),
        DBusIntrospectSignal('StatusNotifierHostUnregistered'),
      ],
      properties: [
        for (final entry in _properties.entries)
          DBusIntrospectProperty(
            entry.key,
            entry.value.signature,
            access: DBusPropertyAccess.read,
          ),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      interface == _watcherName
      ? DBusGetAllPropertiesResponse(_properties)
      : DBusMethodErrorResponse.unknownInterface();
  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != _watcherName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = _properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _watcherName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (call.name != 'RegisterStatusNotifierItem' &&
        call.name != 'RegisterStatusNotifierHost') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (call.signature != DBusSignature('s') || call.sender == null) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    if (_closed) return DBusMethodErrorResponse.failed('Watcher is closing');
    final argument = call.values.first.asString();
    final isItem = call.name == 'RegisterStatusNotifierItem';
    final name = argument.startsWith('/') ? call.sender! : argument;
    final path = argument.startsWith('/') ? argument : '/StatusNotifierItem';
    try {
      if (isItem) DBusObjectPath(path);
      final version = _ownerVersions[name] ?? 0;
      final owner = await bus.getNameOwner(name).timeout(_callTimeout);
      if (_closed || owner == null || version != (_ownerVersions[name] ?? 0)) {
        return DBusMethodErrorResponse.failed(
          'Service disappeared during registration',
        );
      }
      if (isItem) {
        // Canonical unique owner/path deduplicates service aliases.
        final key = '$owner$path';
        (_itemServices[key] ??= {}).add(name);
        if (!_items.containsKey(key)) {
          _items[key] = owner;
          _emit('StatusNotifierItemRegistered', [DBusString(key)]);
        }
      } else if (!_hosts.containsKey(name)) {
        _hosts[name] = owner;
        _emit('StatusNotifierHostRegistered');
      }
      return DBusMethodSuccessResponse();
    } catch (error) {
      return DBusMethodErrorResponse.invalidArgs(error.toString());
    }
  }

  Future<void> close() async {
    _closed = true;
    await _owners?.cancel();
  }
}
