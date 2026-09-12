import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushell/fushell.dart';
import 'package:fushell/windows.dart';
import 'package:fushell/workspace.dart';

import 'inspector.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runWidget(
    FushellWindowViews(
      builder: (context, view) => const WorkspacePreviewApp(),
      onLastViewClosed: FushellProcess.exit,
    ),
  );
  await FushellWindow.openWindow(
    title: 'Workspace preview',
    appId: 'dev.fushell.WorkspacePreview',
    width: 960,
    height: 680,
  );
}

class WorkspacePreviewApp extends StatelessWidget {
  const WorkspacePreviewApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xff54cbb0),
    ),
    home: const _Preview(),
  );
}

class _Preview extends StatefulWidget {
  const _Preview();

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  Workspace? _workspace;
  StreamSubscription<void>? _subscription;
  int _generation = 0;
  bool _connecting = false;
  List<EntryView> _entries = const [];
  List<GroupView> _groups = const [];
  final Set<int> _pending = {};
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  // Cleanup also runs after disposal or a superseded connect. Consume failures
  // here so an unawaited disposal cannot leak an asynchronous error.
  Future<void> _release(
    Workspace? workspace,
    StreamSubscription<void>? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } catch (error) {
      debugPrint('Workspace subscription cleanup: $error');
    }
    try {
      await workspace?.close();
    } catch (error) {
      debugPrint('Workspace connection cleanup: $error');
    }
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    final previous = _workspace;
    final subscription = _subscription;
    _workspace = null;
    _subscription = null;
    setState(() {
      _connecting = true;
      _entries = const [];
      _groups = const [];
      _pending.clear();
      _error = null;
      _notice = null;
    });
    await _release(previous, subscription);
    if (!mounted || generation != _generation) return;
    try {
      final socketPath = Platform.environment['WORKSPACE_PREVIEW_SOCKET'];
      if (socketPath != null && !socketPath.startsWith('/')) {
        throw ArgumentError(
          'WORKSPACE_PREVIEW_SOCKET must be an absolute path',
        );
      }
      final workspace = await Workspace.connect(socketPath: socketPath);
      if (!mounted || generation != _generation) {
        await _release(workspace, null);
        return;
      }
      _workspace = workspace;
      _subscription = workspace.changes.listen(
        (_) => _snapshot(workspace, generation),
        onError: (Object error) {
          if (mounted && generation == _generation) {
            setState(() => _error = error.toString());
          }
        },
        onDone: () => _snapshot(workspace, generation),
      );
      _snapshot(workspace, generation);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Connection failed: $error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _connecting = false);
      }
    }
  }

  void _snapshot(Workspace workspace, int generation) {
    if (!mounted || generation != _generation) return;
    // Both lists are captured together after a manager snapshot notification.
    setState(() {
      _entries = [
        for (final entry in workspace.workspaces)
          EntryView(
            objectId: entry.objectId,
            activationToken: (workspace, entry, generation),
            id: entry.id,
            name: entry.name,
            coordinates: entry.coordinates,
            isActive: entry.isActive,
            isUrgent: entry.isUrgent,
            isHidden: entry.isHidden,
            canActivate: entry.canActivate,
            canDeactivate: entry.canDeactivate,
            canRemove: entry.canRemove,
            canAssign: entry.canAssign,
            groupId: entry.groupId,
          ),
      ];
      _groups = [
        for (final group in workspace.groups)
          GroupView(
            objectId: group.objectId,
            canCreateWorkspace: group.canCreateWorkspace,
            outputs: [
              for (final output in group.outputs)
                [
                  output.name ?? 'Unnamed output',
                  if (output.description != null) output.description!,
                  '(session object ${output.objectId})',
                ].join(' · '),
            ],
          ),
      ];
      if (workspace.lastError != null) {
        _error = workspace.lastError.toString();
      }
    });
  }

  Future<void> _activate(EntryView view) async {
    final token = view.activationToken;
    if (token is! (Workspace, WorkspaceEntry, int)) return;
    final (workspace, current, generation) = token;
    final objectId = current.objectId;
    if (!mounted ||
        generation != _generation ||
        !identical(workspace, _workspace) ||
        workspace.isClosed ||
        _pending.contains(objectId)) {
      return;
    }
    // Preserve the exact originating entry. The SDK validates its lifetime and
    // current capabilities; resolving by objectId could target a reused ID.
    setState(() {
      _pending.add(objectId);
      _error = null;
      _notice = null;
    });
    try {
      await workspace.activate(current);
      if (mounted && generation == _generation) {
        setState(() {
          _notice =
              'Activation request sent for object $objectId. '
              'State changes are reported by the compositor.';
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Activation failed: $error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _pending.remove(objectId));
      }
    }
  }

  Future<void> _quit() async {
    ++_generation;
    final workspace = _workspace;
    final subscription = _subscription;
    _workspace = null;
    _subscription = null;
    await _release(workspace, subscription);
    await FushellProcess.exit();
  }

  @override
  void dispose() {
    ++_generation;
    unawaited(_release(_workspace, _subscription));
    _workspace = null;
    _subscription = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _workspace != null && !_workspace!.isClosed;
    return WorkspaceInspector(
      entries: _entries,
      groups: _groups,
      status: _connecting
          ? 'Connecting…'
          : (connected ? 'Connected' : 'Disconnected'),
      connected: connected,
      error: _error,
      notice: _notice,
      pending: _pending,
      onActivate: (id) => unawaited(_activate(id)),
      onReconnect: () => unawaited(_connect()),
      onQuit: () => unawaited(_quit()),
    );
  }
}
