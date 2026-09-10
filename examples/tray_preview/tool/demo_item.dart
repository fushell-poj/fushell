// Run inside the same isolated session bus as the tray preview:
//   dart run tool/demo_item.dart
// This is a debugging fixture, not a public publisher API.
import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

const _sni = 'org.kde.StatusNotifierItem';
const _watcher = 'org.kde.StatusNotifierWatcher';
const _menu = 'com.canonical.dbusmenu';

DBusIntrospectMethod _method(
  String name,
  List<String> inputs, [
  List<String> outputs = const [],
]) => DBusIntrospectMethod(
  name,
  args: [
    for (final type in inputs)
      DBusIntrospectArgument(DBusSignature(type), DBusArgumentDirection.in_),
    for (final type in outputs)
      DBusIntrospectArgument(DBusSignature(type), DBusArgumentDirection.out),
  ],
);

DBusIntrospectSignal _signal(String name, [List<String> types = const []]) =>
    DBusIntrospectSignal(
      name,
      args: [
        for (final type in types)
          DBusIntrospectArgument(
            DBusSignature(type),
            DBusArgumentDirection.out,
          ),
      ],
    );

/// Common read-only properties; DBusClient supplies Properties and Introspectable.
abstract class _DemoObject extends DBusObject {
  _DemoObject(String path, this.interface) : super(DBusObjectPath(path));

  final String interface;
  Map<String, DBusValue> get properties;

  List<DBusIntrospectProperty> get propertyDescriptions => [
    for (final entry in properties.entries)
      DBusIntrospectProperty(
        entry.key,
        entry.value.signature,
        access: DBusPropertyAccess.read,
      ),
  ];

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != this.interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      interface == this.interface
      ? DBusGetAllPropertiesResponse(properties)
      : DBusMethodErrorResponse.unknownInterface();

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (interface != this.interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    return properties.containsKey(name)
        ? DBusMethodErrorResponse.propertyReadOnly()
        : DBusMethodErrorResponse.unknownProperty();
  }
}

class _DemoItem extends _DemoObject {
  _DemoItem() : super('/StatusNotifierItem', _sni);

  int activations = 0;
  int scroll = 0;
  bool attention = false;
  late final _DemoMenu menu = _DemoMenu(this);

  String get title => 'Tray demo · $activations clicks · scroll $scroll';
  String get status => attention ? 'NeedsAttention' : 'Active';

  // SNI specifies network-order ARGB bytes, not the host's pixel byte order.
  final DBusArray pixmap = DBusArray(DBusSignature('(iiay)'), [
    DBusStruct([
      const DBusInt32(32),
      const DBusInt32(32),
      DBusArray.byte([
        for (var y = 0; y < 32; y++)
          for (var x = 0; x < 32; x++)
            ...((x - y).abs() < 5 || (x >= 20 && y < 12)
                ? [255, 255, 151, 61]
                : [255, 20, 184, 166]),
      ]),
    ]),
  ]);

  @override
  Map<String, DBusValue> get properties => {
    'Category': const DBusString('ApplicationStatus'),
    'Id': DBusString('tray-preview-demo-$pid'),
    'Title': DBusString(title),
    'Status': DBusString(status),
    'WindowId': const DBusUint32(0),
    'IconName': const DBusString(''),
    'IconPixmap': pixmap,
    'OverlayIconName': const DBusString(''),
    'OverlayIconPixmap': DBusArray(DBusSignature('(iiay)'), []),
    'AttentionIconName': const DBusString(''),
    'AttentionIconPixmap': pixmap,
    'AttentionMovieName': const DBusString(''),
    'ToolTip': DBusStruct([
      const DBusString(''),
      pixmap,
      DBusString(title),
      DBusString(
        'Status: $status. Left click counts; scroll changes the title. '
        'Right click opens the demo menu.',
      ),
    ]),
    'ItemIsMenu': const DBusBoolean(false),
    'Menu': DBusObjectPath('/Menu'),
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      _sni,
      properties: propertyDescriptions,
      methods: [
        _method('Activate', ['i', 'i']),
        _method('SecondaryActivate', ['i', 'i']),
        _method('ContextMenu', ['i', 'i']),
        _method('Scroll', ['i', 's']),
      ],
      signals: [
        _signal('NewTitle'),
        _signal('NewIcon'),
        _signal('NewAttentionIcon'),
        _signal('NewOverlayIcon'),
        _signal('NewToolTip'),
        _signal('NewStatus', ['s']),
      ],
    ),
  ];

  Future<void> changed({bool statusChanged = false}) async {
    stdout.writeln('$title; status=$status');
    final values = properties;
    await emitPropertiesChanged(
      _sni,
      changedProperties: {
        'Title': values['Title']!,
        'ToolTip': values['ToolTip']!,
        if (statusChanged) 'Status': values['Status']!,
      },
    );
    await emitSignal(_sni, 'NewTitle');
    await emitSignal(_sni, 'NewToolTip');
    if (statusChanged) {
      await emitSignal(_sni, 'NewStatus', [DBusString(status)]);
    }
    await menu.changed();
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _sni) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final signature = switch (call.name) {
      'Activate' || 'SecondaryActivate' || 'ContextMenu' => 'ii',
      'Scroll' => 'is',
      _ => null,
    };
    if (signature == null) return DBusMethodErrorResponse.unknownMethod();
    if (call.signature != DBusSignature(signature)) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    stdout.writeln(
      '${call.name}: ${call.values.map((v) => v.toNative()).join(', ')}',
    );
    switch (call.name) {
      case 'Activate':
        activations++;
        await changed();
      case 'SecondaryActivate':
        attention = !attention;
        await changed(statusChanged: true);
      case 'Scroll':
        final orientation = call.values[1].asString();
        if (orientation != 'vertical' && orientation != 'horizontal') {
          return DBusMethodErrorResponse.invalidArgs('Unknown orientation');
        }
        scroll += call.values[0].asInt32();
        await changed();
      case 'ContextMenu':
        // The preview reads Menu and renders DBusMenu itself.
        break;
    }
    return DBusMethodSuccessResponse();
  }
}

class _DemoMenu extends _DemoObject {
  _DemoMenu(this.item) : super('/Menu', _menu);

  final _DemoItem item;
  int revision = 1;
  bool checked = true;

  @override
  Map<String, DBusValue> get properties => {
    'Version': const DBusUint32(3),
    'TextDirection': const DBusString('ltr'),
    'Status': const DBusString('normal'),
    'IconThemePath': DBusArray.string([]),
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      _menu,
      properties: propertyDescriptions,
      methods: [
        _method('GetLayout', ['i', 'i', 'as'], ['u', '(ia{sv}av)']),
        _method('AboutToShow', ['i'], ['b']),
        _method('Event', ['i', 's', 'v', 'u']),
      ],
      signals: [
        _signal('LayoutUpdated', ['u', 'i']),
      ],
    ),
  ];

  Map<String, DBusValue> nodeProperties(int id) => switch (id) {
    0 => {'children-display': const DBusString('submenu')},
    1 => {'label': DBusString('Activate (${item.activations})')},
    2 => {
      'label': const DBusString('Disabled entry'),
      'enabled': const DBusBoolean(false),
    },
    3 => {'type': const DBusString('separator')},
    4 => {
      'label': const DBusString('Demo checkbox'),
      'toggle-type': const DBusString('checkmark'),
      'toggle-state': DBusInt32(checked ? 1 : 0),
    },
    5 => {
      'label': const DBusString('More actions'),
      'children-display': const DBusString('submenu'),
    },
    6 => {'label': const DBusString('Count a submenu click')},
    7 => {'label': DBusString('Toggle attention (${item.status})')},
    _ => {},
  };

  DBusStruct layout(int id, int depth, Set<String> names) {
    final props = nodeProperties(id);
    final children = switch (id) {
      0 => [1, 2, 3, 4, 5, 7],
      5 => [6],
      _ => <int>[],
    };
    return DBusStruct([
      DBusInt32(id),
      DBusDict.stringVariant({
        for (final entry in props.entries)
          if (names.isEmpty || names.contains(entry.key))
            entry.key: entry.value,
      }),
      DBusArray(DBusSignature('v'), [
        if (depth != 0)
          for (final child in children)
            DBusVariant(layout(child, depth < 0 ? -1 : depth - 1, names)),
      ]),
    ]);
  }

  Future<void> changed() async {
    revision++;
    await emitSignal(_menu, 'LayoutUpdated', [
      DBusUint32(revision),
      const DBusInt32(0),
    ]);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _menu) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final signature = switch (call.name) {
      'GetLayout' => 'iias',
      'AboutToShow' => 'i',
      'Event' => 'isvu',
      _ => null,
    };
    if (signature == null) return DBusMethodErrorResponse.unknownMethod();
    if (call.signature != DBusSignature(signature)) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    final id = call.values[0].asInt32();
    if (id < 0 || id > 7) {
      return DBusMethodErrorResponse.invalidArgs('Unknown menu id $id');
    }
    switch (call.name) {
      case 'GetLayout':
        final depth = call.values[1].asInt32();
        if (depth < -1) return DBusMethodErrorResponse.invalidArgs();
        return DBusMethodSuccessResponse([
          DBusUint32(revision),
          layout(id, depth, call.values[2].asStringArray().toSet()),
        ]);
      case 'AboutToShow':
        stdout.writeln('AboutToShow: $id');
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'Event':
        final event = call.values[1].asString();
        stdout.writeln('Menu Event: id=$id event=$event');
        if (event == 'clicked') {
          switch (id) {
            case 1 || 6:
              item.activations++;
              await item.changed();
            case 4:
              checked = !checked;
              stdout.writeln('Checkbox: $checked');
              await changed();
            case 7:
              item.attention = !item.attention;
              await item.changed(statusChanged: true);
            default:
              // Disabled entries, separators, and submenu parents are inert.
              break;
          }
        }
    }
    return DBusMethodSuccessResponse();
  }
}

Future<void> main() async {
  final bus = DBusClient.session();
  final service = 'org.example.TrayPreviewDemo-$pid';
  final stopped = Completer<void>();
  final signals = <StreamSubscription<ProcessSignal>>[];
  StreamSubscription<DBusNameOwnerChangedEvent>? owners;
  var closing = false;

  void stop(ProcessSignal signal) {
    stdout.writeln('Stopping on $signal');
    closing = true;
    if (!stopped.isCompleted) stopped.complete();
  }

  Future<void> register() async {
    if (closing) return;
    try {
      await bus.callMethod(
        destination: _watcher,
        path: DBusObjectPath('/StatusNotifierWatcher'),
        interface: _watcher,
        name: 'RegisterStatusNotifierItem',
        values: [DBusString(service)],
        replySignature: DBusSignature(''),
        noAutoStart: true,
      );
      stdout.writeln('Registered $service with $_watcher');
    } catch (error) {
      if (!closing) {
        stdout.writeln('Watcher unavailable: $error. Waiting for its owner.');
      }
    }
  }

  try {
    signals.add(ProcessSignal.sigint.watch().listen(stop));
    signals.add(ProcessSignal.sigterm.watch().listen(stop));
    final item = _DemoItem();
    await bus.registerObject(item);
    await bus.registerObject(item.menu);
    final reply = await bus.requestName(
      service,
      flags: {DBusRequestNameFlag.doNotQueue},
    );
    if (reply != DBusRequestNameReply.primaryOwner) {
      throw StateError('Cannot own $service: $reply');
    }
    owners = bus.nameOwnerChanged.listen((event) {
      if (event.name == _watcher && event.newOwner != null) {
        unawaited(register());
      }
    });
    stdout.writeln('Demo ready: $service /StatusNotifierItem; menu /Menu');
    await register();
    await stopped.future;
  } finally {
    closing = true;
    await owners?.cancel();
    for (final signal in signals) {
      await signal.cancel();
    }
    await bus.close();
  }
}
