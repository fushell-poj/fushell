part of '../../tray.dart';

/// A non-exclusive SNI host. Close it before disposing an injected [DBusClient].
/// [changes] fires for membership, item properties, and connection state changes.
final class TrayHost {
  TrayHost._(this._bus, this._ownsBus)
    : hostName = 'org.kde.StatusNotifierHost.p$pid.h${_nextId++}' {
    _hostObject = DBusObject(
      DBusObjectPath('/StatusNotifierHost/${hostName.split('.').last}'),
    );
    _state = _states[_bus] ??= _TrayBusState(_bus);
    _state.users.add(this);
  }

  static int _nextId = 0;
  static final _states = Expando<_TrayBusState>();
  final DBusClient _bus;
  final bool _ownsBus;
  late final DBusObject _hostObject;
  late final _TrayBusState _state;
  final String hostName;
  final _changes = StreamController<void>.broadcast();
  final Map<String, TrayItem> _items = {};
  final Map<String, String> _aliases = {};
  final Set<String> _registered = {};
  final Map<String, int> _versions = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<(bool, String)>? _journal;
  String? _watcherOwner;
  Object? _lastError;
  int _generation = 0;
  bool _closed = false;
  bool _hostNameOwned = false;
  bool _hostExported = false;
  Timer? _retry;
  Future<void>? _closing;

  List<TrayItem> get items => List.unmodifiable(_items.values);
  Stream<void> get changes => _changes.stream;
  String? get watcherOwner => _watcherOwner;
  bool get isFallbackWatcher =>
      _state.ownsName && _watcherOwner == _bus.uniqueName;
  Object? get lastError => _lastError;
  bool get isClosed => _closed;
  String get uniqueName => _bus.uniqueName;

  /// Uses the session bus unless [bus] is supplied. An injected bus stays open.
  static Future<TrayHost> connect({DBusClient? bus}) async {
    final host = TrayHost._(bus ?? DBusClient.session(), bus == null);
    try {
      await host._start();
      return host;
    } catch (_) {
      await host.close();
      rethrow;
    }
  }

  void _notify() {
    if (!_closed) _changes.add(null);
  }

  void _error(Object error) {
    if (!_closed) {
      _lastError = error;
      _notify();
    }
  }

  Future<void> _start() async {
    // Subscribe before querying owners or requesting names. Requests on this
    // connection are ordered after the signal streams' AddMatch requests.
    _subscriptions.add(
      _bus.nameOwnerChanged.listen(_ownerChanged, onError: _error),
    );
    _subscriptions.add(
      DBusSignalStream(
        _bus,
        interface: _watcherName,
        path: DBusObjectPath(_watcherPath),
      ).listen(_watcherSignal, onError: _error),
    );
    await _bus.registerObject(_hostObject);
    _hostExported = true;
    final reply = await _bus.requestName(
      hostName,
      flags: {DBusRequestNameFlag.doNotQueue},
    );
    if (reply != DBusRequestNameReply.primaryOwner) {
      throw StateError('Cannot acquire unique tray host name $hostName');
    }
    _hostNameOwned = true;
    await _discover();
  }

  Future<void> _discover() async {
    final generation = _generation;
    try {
      var owner = await _bus.getNameOwner(_watcherName).timeout(_callTimeout);
      if (_closed || generation != _generation) return;
      if (owner == null) {
        await _state.ensureWatcher();
        owner = await _bus.getNameOwner(_watcherName).timeout(_callTimeout);
        if (_closed || generation != _generation) return;
      }
      await _attach(owner);
    } catch (error) {
      _error(error);
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_closed || _retry != null) return;
    _retry = Timer(const Duration(seconds: 1), () {
      _retry = null;
      unawaited(_discover());
    });
  }

  void _ownerChanged(DBusNameOwnerChangedEvent event) {
    if (_closed) return;
    if (event.name == _watcherName) {
      // A -> B is as significant as A -> null. Never keep an old snapshot.
      unawaited(_attach(event.newOwner));
    }
    if (event.oldOwner != null) {
      for (final entry in _aliases.entries.toList()) {
        final service = entry.key.split('/').first;
        if (service == event.name ||
            _items[entry.value]?.service == event.name) {
          _remove(entry.key);
        }
      }
    }
  }

  Future<void> _attach(String? owner) async {
    if (_closed) return;
    final generation = ++_generation;
    _retry?.cancel();
    _retry = null;
    _watcherOwner = owner;
    _journal = null;
    _registered.clear();
    _versions.clear();
    _aliases.clear();
    final oldItems = _items.values.toList();
    _items.clear();
    for (final item in oldItems) {
      unawaited(item._close());
    }
    _notify();
    if (owner == null) {
      _scheduleRetry();
      return;
    }
    final remote = DBusRemoteObject(
      _bus,
      name: owner,
      path: DBusObjectPath(_watcherPath),
    );
    final journal = <(bool, String)>[];
    _journal = journal;
    try {
      await remote
          .callMethod(
            _watcherName,
            'RegisterStatusNotifierHost',
            [DBusString(hostName)],
            replySignature: DBusSignature(''),
            noAutoStart: true,
          )
          .timeout(_callTimeout);
      if (_closed || generation != _generation) return;
      final snapshot = await remote
          .getProperty(
            _watcherName,
            'RegisteredStatusNotifierItems',
            signature: DBusSignature('as'),
          )
          .timeout(_callTimeout);
      if (_closed || generation != _generation) return;
      final names = snapshot.asStringArray().toSet();
      // Replaying ordered events makes a delayed snapshot unable to resurrect
      // an item removed while Get was outstanding.
      for (final (added, name) in journal) {
        added ? names.add(name) : names.remove(name);
      }
      _journal = null;
      _lastError = null;
      await Future.wait(names.map(_add));
      if (!_closed && generation == _generation) _notify();
    } catch (error) {
      if (!_closed && generation == _generation) {
        _journal = null;
        _error(error);
        _scheduleRetry();
      }
    }
  }

  void _watcherSignal(DBusSignal signal) {
    if (_closed ||
        signal.sender != _watcherOwner ||
        signal.values.length != 1 ||
        signal.values.first is! DBusString)
      return;
    final added = signal.name == 'StatusNotifierItemRegistered';
    if (!added && signal.name != 'StatusNotifierItemUnregistered') return;
    final name = signal.values.first.asString();
    if (_journal case final journal?) {
      journal.add((added, name));
      return;
    }
    if (added) {
      unawaited(_add(name));
    } else {
      _remove(name);
    }
  }

  Future<void> _add(String registration) async {
    if (_closed || !_registered.add(registration)) return;
    final generation = _generation;
    final version = (_versions[registration] ?? 0) + 1;
    _versions[registration] = version;
    bool current() =>
        !_closed &&
        generation == _generation &&
        _registered.contains(registration) &&
        _versions[registration] == version;
    try {
      final slash = registration.indexOf('/');
      final name = slash < 0 ? registration : registration.substring(0, slash);
      final path = slash < 0
          ? '/StatusNotifierItem'
          : registration.substring(slash);
      final owner = await _bus.getNameOwner(name).timeout(_callTimeout);
      if (!current() || owner == null) {
        if (current()) _registered.remove(registration);
        return;
      }
      final key = '$owner$path';
      _aliases[registration] = key;
      if (_items.containsKey(key)) return;
      final item = TrayItem._(_bus, owner, path, _notify, _error);
      // Reserve canonical key before awaiting properties: aliases cannot load
      // duplicate objects, even if their GetNameOwner replies race.
      _items[key] = item;
      await item._start();
      if (!current() || !identical(_items[key], item)) {
        if (identical(_items[key], item) && !_aliases.containsValue(key))
          _items.remove(key);
        if (!identical(_items[key], item)) await item._close();
        return;
      }
      _notify();
    } catch (error) {
      if (current()) {
        final key = _aliases[registration];
        // A failed reserved item must not survive through a second alias.
        final aliases = key == null
            ? [registration]
            : _aliases.entries
                  .where((entry) => entry.value == key)
                  .map((entry) => entry.key)
                  .toList();
        for (final alias in aliases) {
          _remove(alias);
        }
        _error(error);
      }
    }
  }

  void _remove(String registration) {
    _registered.remove(registration);
    _versions[registration] = (_versions[registration] ?? 0) + 1;
    final key = _aliases.remove(registration);
    if (key != null && !_aliases.containsValue(key)) {
      final item = _items.remove(key);
      if (item != null) unawaited(item._close());
    }
    _notify();
  }

  /// Idempotent. Releases only this host's resources and names it acquired.
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    ++_generation;
    _retry?.cancel();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    for (final item in _items.values) {
      await item._close();
    }
    _items.clear();
    if (_hostNameOwned) await _bus.releaseName(hostName);
    if (_hostExported) await _bus.unregisterObject(_hostObject);
    _state.users.remove(this);
    if (_state.users.isEmpty) {
      await _state.close();
      _states[_bus] = null;
    }
    if (_ownsBus) await _bus.close();
    await _changes.close();
  }
}
