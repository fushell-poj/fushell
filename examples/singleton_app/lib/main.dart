import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fushell/fushell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final _DaemonModel model = _DaemonModel();
  runWidget(_DaemonRoot(model: model));
  await FushellApplication.run(onCommand: model.handleCommand);
}

final class _DaemonModel extends ChangeNotifier {
  final Map<int, String> _windows = <int, String>{};
  final Set<int> _closedWindowIds = <int>{};

  Map<int, String> get windows => Map<int, String>.unmodifiable(_windows);

  Future<FushellCommandResult> handleCommand(
    FushellCommandInvocation invocation,
  ) async {
    if (invocation.arguments.isNotEmpty &&
        utf8.decode(invocation.arguments.first) == 'raw') {
      final String encoded = invocation.arguments
          .skip(1)
          .map(
            (List<int> argument) => argument
                .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
                .join(),
          )
          .join('|');
      return FushellCommandResult.text(stdout: '$encoded\n');
    }

    final List<String> arguments = invocation.textArguments;
    if (arguments.isEmpty) {
      return FushellCommandResult.text();
    }

    switch (arguments.first) {
      case 'open':
        final String title = arguments.length > 1
            ? arguments.skip(1).join(' ')
            : 'Singleton window';
        final int id = await FushellWindow.openWindow(
          title: title,
          appId: 'dev.fushell.SingletonExample',
          width: 720,
          height: 480,
        );
        await FushellWindow.viewById(id);
        _windows[id] = title;
        notifyListeners();
        return FushellCommandResult.text(stdout: '$id\n');

      case 'list':
        reconcileViews();
        final String output = _windows.entries
            .map(
              (MapEntry<int, String> entry) => '${entry.key}\t${entry.value}',
            )
            .join('\n');
        return FushellCommandResult.text(
          stdout: output.isEmpty ? '' : '$output\n',
        );

      case 'close':
        if (arguments.length != 2) {
          return FushellCommandResult.text(
            exitCode: 64,
            stderr: 'usage: close <window-id>\n',
          );
        }
        final int? id = int.tryParse(arguments[1]);
        if (id == null || !_windows.containsKey(id)) {
          return FushellCommandResult.text(
            exitCode: 66,
            stderr: 'unknown window: ${arguments[1]}\n',
          );
        }
        await FushellWindow.closeWindow(id);
        _windows.remove(id);
        notifyListeners();
        return FushellCommandResult.text();

      case 'closed':
        final String output = _closedWindowIds.join('\n');
        return FushellCommandResult.text(
          stdout: output.isEmpty ? '' : '$output\n',
        );

      case 'status':
        reconcileViews();
        return FushellCommandResult.text(
          stdout:
              'daemon running; windows=${_windows.length}; cwd=${invocation.textWorkingDirectory}\n',
        );

      case 'context':
        return FushellCommandResult.text(
          stdout:
              'cwd=${invocation.textWorkingDirectory}; initial=${invocation.isInitial}; '
              'arguments=${arguments.join('|')}\n',
        );

      case 'wait':
        final int milliseconds = arguments.length == 2
            ? int.tryParse(arguments[1]) ?? -1
            : -1;
        if (milliseconds < 0) {
          return FushellCommandResult.text(
            exitCode: 64,
            stderr: 'usage: wait <milliseconds>\n',
          );
        }
        final bool cancelled = await Future.any<bool>(<Future<bool>>[
          Future<void>.delayed(
            Duration(milliseconds: milliseconds),
          ).then((_) => false),
          invocation.cancelled.then((_) => true),
        ]);
        return FushellCommandResult.text(
          stdout: cancelled ? 'wait cancelled\n' : 'waited\n',
        );

      case 'hang':
        final int milliseconds = arguments.length == 2
            ? int.tryParse(arguments[1]) ?? -1
            : -1;
        if (milliseconds < 0) {
          return FushellCommandResult.text(
            exitCode: 64,
            stderr: 'usage: hang <milliseconds>\n',
          );
        }
        await Future<void>.delayed(Duration(milliseconds: milliseconds));
        return FushellCommandResult.text(stdout: 'hang completed\n');

      case 'quit':
        Timer(const Duration(milliseconds: 50), FushellProcess.exit);
        return FushellCommandResult.text(stdout: 'stopping daemon\n');

      case 'help':
        return FushellCommandResult.text(stdout: _help);

      default:
        return FushellCommandResult.text(
          exitCode: 64,
          stderr: 'unknown command: ${arguments.first}\n$_help',
        );
    }
  }

  void removeWindow(int windowId) {
    _closedWindowIds.add(windowId);
    if (_windows.remove(windowId) != null) notifyListeners();
  }

  void reconcileViews() {
    final Set<int> liveViews = ui.PlatformDispatcher.instance.views
        .map((ui.FlutterView view) => view.viewId)
        .toSet();
    final int previousLength = _windows.length;
    _windows.removeWhere((int id, String _) => !liveViews.contains(id));
    if (_windows.length != previousLength) notifyListeners();
  }
}

final class _DaemonRoot extends StatefulWidget {
  const _DaemonRoot({required this.model});

  final _DaemonModel model;

  @override
  State<_DaemonRoot> createState() => _DaemonRootState();
}

final class _DaemonRootState extends State<_DaemonRoot>
    with WidgetsBindingObserver {
  late final StreamSubscription<FushellWindowClosedEvent> _closedSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _closedSubscription = FushellWindow.closed.listen(
      (FushellWindowClosedEvent event) =>
          widget.model.removeWindow(event.windowId),
    );
  }

  @override
  void dispose() {
    unawaited(_closedSubscription.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    widget.model.reconcileViews();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (BuildContext context, Widget? child) {
        final Map<int, ui.FlutterView> views = <int, ui.FlutterView>{
          for (final ui.FlutterView view
              in ui.PlatformDispatcher.instance.views)
            view.viewId: view,
        };
        return ViewCollection(
          views: <Widget>[
            for (final MapEntry<int, String> entry
                in widget.model.windows.entries)
              if (views[entry.key] case final ui.FlutterView view)
                View(
                  view: view,
                  child: _WindowApp(windowId: entry.key, title: entry.value),
                ),
          ],
        );
      },
    );
  }
}

final class _WindowApp extends StatelessWidget {
  const _WindowApp({required this.windowId, required this.title});

  final int windowId;
  final String title;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.hub_outlined, size: 72),
              const SizedBox(height: 20),
              Text('Window $windowId', style: const TextStyle(fontSize: 24)),
              const SizedBox(height: 8),
              const Text('Created by the single-instance daemon'),
            ],
          ),
        ),
      ),
    );
  }
}

const String _help = '''fushell singleton example commands:
  open [title]       open a new window
  list               list live windows
  close <window-id>  close one window
  closed             list completed window closes
  status             show daemon status
  context [args...]   echo invocation context
  raw <bytes...>      echo raw argv bytes as hexadecimal
  wait <milliseconds> wait asynchronously (integration testing)
  hang <milliseconds> ignore cancellation (integration testing)
  quit               stop the daemon
  help               show this help
''';
