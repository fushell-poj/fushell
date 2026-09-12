import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';
import 'transport.dart';

/// An immutable workspace snapshot. IDs and names are independently optional.
class WorkspaceEntry {
  WorkspaceEntry._(_Entry state)
    : objectId = state.objectId,
      _identity = state.identity,
      id = state.id,
      name = state.name,
      coordinates = List.unmodifiable(state.coordinates),
      isActive = state.state & ExtWorkspaceHandleV1State.active != 0,
      isUrgent = state.state & ExtWorkspaceHandleV1State.urgent != 0,
      isHidden = state.state & ExtWorkspaceHandleV1State.hidden != 0,
      canActivate =
          state.capabilities &
              ExtWorkspaceHandleV1WorkspaceCapabilities.activate !=
          0,
      canDeactivate =
          state.capabilities &
              ExtWorkspaceHandleV1WorkspaceCapabilities.deactivate !=
          0,
      canRemove =
          state.capabilities &
              ExtWorkspaceHandleV1WorkspaceCapabilities.remove !=
          0,
      canAssign =
          state.capabilities &
              ExtWorkspaceHandleV1WorkspaceCapabilities.assign !=
          0,
      groupId = state.groupId;
  final Object _identity;
  final int objectId;
  final String? id;
  final String? name;
  final List<int> coordinates;
  final bool isActive, isUrgent, isHidden;
  final bool canActivate, canDeactivate, canRemove, canAssign;
  final int? groupId;
}

/// An immutable output snapshot; names require wl_output version 4.
class WorkspaceOutput {
  const WorkspaceOutput._(this.objectId, this.name, this.description);
  final int objectId;
  final String? name;
  final String? description;
}

class WorkspaceGroup {
  WorkspaceGroup._(_Group state, Map<int, _Output> outputs)
    : objectId = state.objectId,
      _identity = state.identity,
      canCreateWorkspace =
          state.capabilities &
              ExtWorkspaceGroupHandleV1GroupCapabilities.createWorkspace !=
          0,
      outputs = List.unmodifiable(
        state.outputs
            .where(outputs.containsKey)
            .map((id) => outputs[id]!.snapshot),
      );
  WorkspaceGroup._outputs(WorkspaceGroup old, Map<int, _Output> states)
    : objectId = old.objectId,
      _identity = old._identity,
      canCreateWorkspace = old.canCreateWorkspace,
      outputs = List.unmodifiable(
        old.outputs
            .where((o) => states.containsKey(o.objectId))
            .map((o) => states[o.objectId]!.snapshot),
      );
  final Object _identity;
  final int objectId;
  final List<WorkspaceOutput> outputs;
  final bool canCreateWorkspace;
}

/// Owns a private asynchronous Wayland connection without creating surfaces.
///
/// State changes are published atomically at ext_workspace_manager_v1.done.
/// Requests complete when sent, not when confirmed by the compositor. There is
/// no automatic reconnection and no fallback to desktop-specific IPC.
class Workspace {
  Workspace._();
  WorkspaceTransport? _connection;
  WorkspaceTransport get _transport => _connection!;
  final _ready = Completer<void>();
  final _changes = StreamController<void>.broadcast();
  final Map<int, _Entry> _entries = {};
  final Map<int, _Group> _groups = {};
  final Map<int, _Output> _outputs = {};
  final Map<int, int> _globalObjects = {};
  final Map<int, String> _globals = {};
  List<WorkspaceEntry> _publishedEntries = const [];
  List<WorkspaceGroup> _publishedGroups = const [];
  int? _manager;
  int? _managerGlobal;
  late int _registry;
  late int _discoveryCallback;
  int? _bindingCallback;
  bool _discovered = false;
  bool _initialDone = false;
  bool _isClosed = false;
  Object? _lastError;

  /// Connect to [socketPath], or WAYLAND_DISPLAY under XDG_RUNTIME_DIR.
  /// The timeout covers socket connection, registry discovery and initial state.
  static Future<Workspace> connect({
    String? socketPath,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final workspace = Workspace._();
    // Install an error listener before any asynchronous transport callback.
    final ready = workspace._ready.future;
    unawaited(ready.then<void>((_) {}, onError: (Object _) {}));
    final timer = Timer(timeout, () {
      workspace._terminate(
        const WorkspaceException(
          'TimedOut',
          'Timed out waiting for workspace discovery.',
        ),
      );
    });
    try {
      final path = socketPath ?? _defaultSocketPath();
      final connection = Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: timeout,
      );
      unawaited(
        connection.then<void>((socket) {
          if (workspace.isClosed) {
            socket.destroy();
          }
        }, onError: (Object _) {}),
      );
      final socket = await Future.any<Socket>([
        connection,
        ready.then<Socket>(
          (_) => throw const WorkspaceException(
            'Disconnected',
            'Connection closed.',
          ),
        ),
      ]);
      if (workspace.isClosed) {
        socket.destroy();
        throw workspace.lastError!;
      }
      workspace._connection = WorkspaceTransport(
        socket,
        workspace._event,
        workspace._terminate,
      );
      workspace._registry = workspace._transport.allocate('wl_registry', 1);
      WlDisplayRequests(workspace._sender(1)).getRegistry(workspace._registry);
      workspace._discoveryCallback = workspace._transport.allocate(
        'wl_callback',
        1,
      );
      WlDisplayRequests(
        workspace._sender(1),
      ).sync(workspace._discoveryCallback);
      await ready;
      if (workspace.isClosed) {
        throw workspace.lastError ??
            const WorkspaceException(
              'Disconnected',
              'Connection closed during discovery.',
            );
      }
      return workspace;
    } catch (error) {
      final failure = error is WorkspaceException
          ? error
          : WorkspaceException('Disconnected', '$error');
      workspace._terminate(failure);
      throw failure;
    } finally {
      timer.cancel();
    }
  }

  static String _defaultSocketPath() {
    final display = Platform.environment['WAYLAND_DISPLAY'];
    if (display == null || display.isEmpty) {
      throw const WorkspaceException(
        'UnsupportedProtocol',
        'WAYLAND_DISPLAY is not set.',
      );
    }
    if (display.startsWith('/')) {
      return display;
    }
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    if (runtime == null || runtime.isEmpty) {
      throw const WorkspaceException(
        'UnsupportedProtocol',
        'XDG_RUNTIME_DIR is not set.',
      );
    }
    return '$runtime/$display';
  }

  List<WorkspaceEntry> get workspaces => _publishedEntries;
  List<WorkspaceGroup> get groups => _publishedGroups;
  Stream<void> get changes => _changes.stream;
  bool get isClosed => _isClosed;
  Object? get lastError => _lastError;

  void _terminate(WorkspaceException? error) {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _lastError = error;
    // The timer can fire before the socket has connected.
    final connection = _connection;
    if (connection != null) {
      unawaited(connection.close());
    }
    if (!_ready.isCompleted) {
      _ready.completeError(
        error ?? const WorkspaceException('Disconnected', 'Connection closed.'),
      );
    }
    _changes.add(null);
    // Do not await broadcast close: paused subscribers must not block close().
    unawaited(_changes.close());
  }

  Future<void> close() async {
    _terminate(null);
  }

  void _checkReady() {
    if (_isClosed) {
      throw const WorkspaceException(
        'Disconnected',
        'Workspace connection is closed.',
      );
    }
  }

  WorkspaceEntry _current(WorkspaceEntry entry) {
    _checkReady();
    final current = _publishedEntries
        .where((e) => identical(e._identity, entry._identity))
        .firstOrNull;
    if (current == null ||
        !identical(_entries[entry.objectId]?.identity, entry._identity)) {
      throw const WorkspaceException(
        'StaleWorkspace',
        'Workspace no longer belongs to this connection.',
      );
    }
    return current;
  }

  WorkspaceGroup _currentGroup(WorkspaceGroup group) {
    _checkReady();
    final current = _publishedGroups
        .where((g) => identical(g._identity, group._identity))
        .firstOrNull;
    if (current == null ||
        !identical(_groups[group.objectId]?.identity, group._identity)) {
      throw const WorkspaceException(
        'StaleWorkspace',
        'Workspace group no longer belongs to this connection.',
      );
    }
    return current;
  }

  void _capability(bool available) {
    if (!available) {
      throw const WorkspaceException(
        'UnsupportedOperation',
        'The compositor did not advertise this capability.',
      );
    }
  }

  WireRequestSender _sender(int id) =>
      (name, args) => _transport.send(id, name, args);
  ExtWorkspaceHandleV1Requests _entryRequests(int id) =>
      ExtWorkspaceHandleV1Requests(_sender(id));
  ExtWorkspaceGroupHandleV1Requests _groupRequests(int id) =>
      ExtWorkspaceGroupHandleV1Requests(_sender(id));

  Future<void> _request(void Function() send) async {
    send();
    ExtWorkspaceManagerV1Requests(_sender(_manager!)).commit();
    await _transport.flush();
  }

  Future<void> activate(WorkspaceEntry entry) async {
    _capability(_current(entry).canActivate);
    await _request(_entryRequests(entry.objectId).activate);
  }

  Future<void> deactivate(WorkspaceEntry entry) async {
    _capability(_current(entry).canDeactivate);
    await _request(_entryRequests(entry.objectId).deactivate);
  }

  Future<void> remove(WorkspaceEntry entry) async {
    _capability(_current(entry).canRemove);
    await _request(_entryRequests(entry.objectId).remove);
  }

  Future<void> assign(WorkspaceEntry entry, WorkspaceGroup group) async {
    _capability(_current(entry).canAssign);
    _currentGroup(group);
    await _request(() => _entryRequests(entry.objectId).assign(group.objectId));
  }

  Future<void> createWorkspace(WorkspaceGroup group, String name) async {
    _capability(_currentGroup(group).canCreateWorkspace);
    await _request(() => _groupRequests(group.objectId).createWorkspace(name));
  }

  void _publish() {
    _publishedEntries = List.unmodifiable(
      _entries.values.map(WorkspaceEntry._),
    );
    _publishedGroups = List.unmodifiable(
      _groups.values.map((g) => WorkspaceGroup._(g, _outputs)),
    );
    _changes.add(null);
    _initialDone = true;
    _maybeReady();
  }

  void _maybeReady() {
    if (_discovered && _initialDone && !_ready.isCompleted) {
      _ready.complete();
    }
  }

  void _outputMetadataChanged() {
    if (!_initialDone) {
      return;
    }
    _publishedGroups = List.unmodifiable(
      _publishedGroups.map((g) => WorkspaceGroup._outputs(g, _outputs)),
    );
    _changes.add(null);
  }

  void _event(WireObject object, WireMessage event, List<Object?> args) {
    final id = object.id;
    final name = event.name;
    if (id == _registry) {
      if (name == 'global') {
        final globalEvent = WlRegistryGlobalEvent.fromList(args);
        final global = globalEvent.name;
        final interface = globalEvent.interfaceValue;
        final offered = globalEvent.version;
        if (_globals.containsKey(global) || offered == 0) {
          throw const FormatException('Invalid registry global');
        }
        _globals[global] = interface;
        if (interface == 'ext_workspace_manager_v1' && _manager == null ||
            interface == 'wl_output') {
          final supported = wireInterfaces[interface]!.version;
          final version = offered < supported ? offered : supported;
          final bound = _transport.allocate(interface, version);
          _globalObjects[global] = bound;
          if (interface == 'wl_output') {
            _outputs[bound] = _Output(bound);
          } else {
            _manager = bound;
            _managerGlobal = global;
          }
          WlRegistryRequests(
            _sender(_registry),
          ).bind(global, interface, version, bound);
        }
      } else if (name == 'global_remove') {
        final global = WlRegistryGlobalRemoveEvent.fromList(args).name;
        _globals.remove(global);
        final bound = _globalObjects.remove(global);
        if (global == _managerGlobal) {
          _terminate(
            const WorkspaceException(
              'UnsupportedProtocol',
              'Workspace manager global was removed.',
            ),
          );
        } else if (bound != null && _outputs.remove(bound) != null) {
          for (final group in _groups.values) {
            group.outputs.remove(bound);
          }
          final outputObject = _transport.objects[bound]!;
          if (outputObject.version >= 3) {
            WlOutputRequests(_sender(bound)).release();
          }
          // Older outputs lack release and remain inert until connection close.
          // Released objects retain a typed tombstone for already queued events.
          _outputMetadataChanged();
        }
      }
    } else if (id == _discoveryCallback && name == 'done') {
      if (_manager == null) {
        _terminate(
          const WorkspaceException(
            'UnsupportedProtocol',
            'Compositor does not advertise ext_workspace_manager_v1.',
          ),
        );
      } else {
        // Bind requests issued while reading registry globals precede this sync.
        // Its reply covers initial output metadata and group associations too.
        _bindingCallback = _transport.allocate('wl_callback', 1);
        WlDisplayRequests(_sender(1)).sync(_bindingCallback!);
      }
    } else if (id == _bindingCallback && name == 'done') {
      _discovered = true;
      _maybeReady();
    } else if (id == _manager) {
      switch (name) {
        case 'workspace':
          final child = ExtWorkspaceManagerV1WorkspaceEvent.fromList(
            args,
          ).workspace;
          _entries[child] = _Entry(child);
        case 'workspace_group':
          final child = ExtWorkspaceManagerV1WorkspaceGroupEvent.fromList(
            args,
          ).workspaceGroup;
          _groups[child] = _Group(child);
        case 'done':
          _publish();
        case 'finished':
          _terminate(
            const WorkspaceException(
              'Disconnected',
              'Workspace manager finished.',
            ),
          );
      }
    } else if (_entries.containsKey(id)) {
      final entry = _entries[id]!;
      switch (name) {
        case 'id':
          entry.id = ExtWorkspaceHandleV1IdEvent.fromList(args).id;
        case 'name':
          entry.name = ExtWorkspaceHandleV1NameEvent.fromList(args).name;
        case 'coordinates':
          final bytes = ExtWorkspaceHandleV1CoordinatesEvent.fromList(
            args,
          ).coordinates;
          if (bytes.length % 4 != 0) {
            throw const FormatException('Invalid uint array');
          }
          final data = ByteData.sublistView(Uint8List.fromList(bytes));
          entry.coordinates = [
            for (var i = 0; i < bytes.length; i += 4)
              data.getUint32(i, Endian.host),
          ];
        case 'state':
          entry.state = ExtWorkspaceHandleV1StateEvent.fromList(args).state;
        case 'capabilities':
          entry.capabilities = ExtWorkspaceHandleV1CapabilitiesEvent.fromList(
            args,
          ).capabilities;
        case 'removed':
          _entries.remove(id);
          _entryRequests(id).destroy();
      }
    } else if (_groups.containsKey(id)) {
      final group = _groups[id]!;
      switch (name) {
        case 'capabilities':
          group.capabilities =
              ExtWorkspaceGroupHandleV1CapabilitiesEvent.fromList(
                args,
              ).capabilities;
        case 'output_enter':
          group.outputs.add(
            ExtWorkspaceGroupHandleV1OutputEnterEvent.fromList(args).output,
          );
        case 'output_leave':
          group.outputs.remove(
            ExtWorkspaceGroupHandleV1OutputLeaveEvent.fromList(args).output,
          );
        case 'workspace_enter':
          _entries[ExtWorkspaceGroupHandleV1WorkspaceEnterEvent.fromList(
                    args,
                  ).workspace]
                  ?.groupId =
              id;
        case 'workspace_leave':
          final entry =
              _entries[ExtWorkspaceGroupHandleV1WorkspaceLeaveEvent.fromList(
                args,
              ).workspace];
          if (entry?.groupId == id) {
            entry?.groupId = null;
          }
        case 'removed':
          _groups.remove(id);
          for (final entry in _entries.values) {
            if (entry.groupId == id) {
              entry.groupId = null;
            }
          }
          _groupRequests(id).destroy();
      }
    } else if (_outputs.containsKey(id)) {
      final output = _outputs[id]!;
      switch (name) {
        case 'name':
          output.name = WlOutputNameEvent.fromList(args).name;
        case 'description':
          output.description = WlOutputDescriptionEvent.fromList(
            args,
          ).description;
        case 'done':
          _outputMetadataChanged();
      }
    }
  }
}

class _Entry {
  _Entry(this.objectId);
  final int objectId;
  final Object identity = Object();
  String? id, name;
  List<int> coordinates = [];
  int state = 0, capabilities = 0;
  int? groupId;
}

class _Group {
  _Group(this.objectId);
  final int objectId;
  final Object identity = Object();
  final Set<int> outputs = {};
  int capabilities = 0;
}

class _Output {
  _Output(this.objectId);
  final int objectId;
  String? name, description;
  WorkspaceOutput get snapshot =>
      WorkspaceOutput._(objectId, name, description);
}
