part of '../../tray.dart';

/// An immutable dbusmenu node. Labels retain the protocol's mnemonic underscores.
final class TrayMenuNode {
  TrayMenuNode._(
    this.id,
    Map<String, DBusValue> properties,
    List<TrayMenuNode> children,
  ) : properties = Map.unmodifiable(properties),
      children = List.unmodifiable(children);
  final int id;
  final Map<String, DBusValue> properties;
  final List<TrayMenuNode> children;
  String get label => _string(properties, 'label');
  bool get enabled => _boolean(properties, 'enabled', true);
  bool get visible => _boolean(properties, 'visible', true);
  String get type => _string(properties, 'type', 'standard');
  String get toggleType => _string(properties, 'toggle-type');
  int get toggleState => _integer(properties, 'toggle-state', -1);
  String get iconName => _string(properties, 'icon-name');
  bool get isSubmenu => _string(properties, 'children-display') == 'submenu';

  static TrayMenuNode _decode(DBusValue value, [int depth = 0]) {
    if (depth > 64) {
      throw const FormatException('Menu nesting exceeds 64 levels');
    }
    final fields = value.asStruct();
    return TrayMenuNode._(
      fields[0].asInt32(),
      fields[1].asStringVariantDict(),
      fields[2]
          .asVariantArray()
          .map((child) => _decode(child, depth + 1))
          .toList(),
    );
  }
}

/// com.canonical.dbusmenu transport. Property/layout signals refresh the tree.
final class TrayMenu {
  TrayMenu._(this._remote, this._onClose, this._error);
  final DBusRemoteObject _remote;
  final void Function() _onClose;
  final void Function(Object) _error;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  TrayMenuNode _root = TrayMenuNode._(0, {}, []);
  TrayMenuNode get root => _root;
  int _revision = 0;
  int get revision => _revision;
  int _request = 0;
  bool _closed = false;
  Future<void>? _closing;
  StreamSubscription<DBusSignal>? _subscription;

  Future<void> _start() async {
    _subscription =
        DBusSignalStream(
          _remote.client,
          sender: _remote.name,
          interface: _menuInterface,
          path: _remote.path,
        ).listen((signal) {
          if (signal.name == 'LayoutUpdated' ||
              signal.name == 'ItemsPropertiesUpdated') {
            unawaited(refresh().catchError(_error));
          }
        }, onError: _error);
    await aboutToShow();
    await refresh();
  }

  void _checkOpen() {
    if (_closed) throw StateError('Tray menu is closed');
  }

  /// Refreshes the complete tree; [parentId] is retained for caller convenience.
  /// Full snapshots also preserve nodes outside a changed subtree.
  Future<void> refresh({int parentId = 0}) async {
    _checkOpen();
    final request = ++_request;
    final reply = await _remote
        .callMethod(
          _menuInterface,
          'GetLayout',
          [const DBusInt32(0), const DBusInt32(-1), DBusArray.string([])],
          replySignature: DBusSignature('u(ia{sv}av)'),
          noAutoStart: true,
        )
        .timeout(_callTimeout);
    if (_closed || request != _request) return;
    _root = TrayMenuNode._decode(reply.returnValues[1]);
    _revision = reply.returnValues[0].asUint32();
    _changes.add(null);
  }

  Future<bool> aboutToShow({int id = 0}) async {
    _checkOpen();
    final reply = await _remote
        .callMethod(
          _menuInterface,
          'AboutToShow',
          [DBusInt32(id)],
          replySignature: DBusSignature('b'),
          noAutoStart: true,
        )
        .timeout(_callTimeout);
    final update = reply.returnValues.first.asBoolean();
    if (update && !_closed) await refresh(parentId: id);
    return update;
  }

  /// Sends an event using Unix time in seconds (dbusmenu's uint32 timestamp).
  Future<void> event(
    int id, {
    String eventId = 'clicked',
    DBusValue? data,
    int? timestamp,
  }) async {
    _checkOpen();
    await _remote
        .callMethod(
          _menuInterface,
          'Event',
          [
            DBusInt32(id),
            DBusString(eventId),
            DBusVariant(data ?? const DBusInt32(0)),
            DBusUint32(
              timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ),
          ],
          replySignature: DBusSignature(''),
          noAutoStart: true,
        )
        .timeout(_callTimeout);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    ++_request;
    await _subscription?.cancel();
    _onClose();
    await _changes.close();
  }
}
