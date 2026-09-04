import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
    final FushellCommandOutput output = invocation.output;
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
      await output.writeStdoutText('$encoded\n');
      return FushellCommandResult();
    }

    final List<String> arguments = invocation.textArguments;
    if (arguments.isEmpty) return FushellCommandResult();

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
        await output.writeStdoutText('$id\n');
        return FushellCommandResult();

      case 'list':
        reconcileViews();
        final String listing = _windows.entries
            .map(
              (MapEntry<int, String> entry) => '${entry.key}\t${entry.value}',
            )
            .join('\n');
        await output.writeStdoutText(listing.isEmpty ? '' : '$listing\n');
        return FushellCommandResult();

      case 'close':
        if (arguments.length != 2) {
          await output.writeStderrText('usage: close <window-id>\n');
          return FushellCommandResult(exitCode: 64);
        }
        final int? id = int.tryParse(arguments[1]);
        if (id == null || !_windows.containsKey(id)) {
          await output.writeStderrText('unknown window: ${arguments[1]}\n');
          return FushellCommandResult(exitCode: 66);
        }
        await FushellWindow.closeWindow(id);
        _windows.remove(id);
        notifyListeners();
        return FushellCommandResult();

      case 'closed':
        final String listing = _closedWindowIds.join('\n');
        await output.writeStdoutText(listing.isEmpty ? '' : '$listing\n');
        return FushellCommandResult();

      case 'status':
        reconcileViews();
        await output.writeStdoutText(
          'daemon running; windows=${_windows.length}; cwd=${invocation.textWorkingDirectory}\n',
        );
        return FushellCommandResult();

      case 'context':
        await output.writeStdoutText(
          'cwd=${invocation.textWorkingDirectory}; initial=${invocation.isInitial}; '
          'arguments=${arguments.join('|')}\n',
        );
        return FushellCommandResult();

      case 'exit124':
        return FushellCommandResult(exitCode: 124);

      case 'stream':
        await output.writeStdoutText('first marker\n');
        final int milliseconds = arguments.length == 2
            ? int.tryParse(arguments[1]) ?? 100
            : 100;
        await Future<void>.delayed(Duration(milliseconds: milliseconds));
        await output.writeStdoutText('rest marker\n');
        return FushellCommandResult();

      case 'interleaved':
        await output.writeStdout(Uint8List.fromList(<int>[0, 255, 1]));
        await output.writeStderr(Uint8List.fromList(<int>[254, 0, 2]));
        await output.writeStdout(Uint8List.fromList(<int>[3, 0, 4]));
        return FushellCommandResult();

      case 'exact-limit':
        final Uint8List chunk = Uint8List(32 * 1024);
        for (var index = 0; index < 256; index++) {
          await output.writeStdout(chunk);
        }
        return FushellCommandResult();

      case 'overflow':
        final Uint8List chunk = Uint8List(32 * 1024);
        for (var index = 0; index < 256; index++) {
          await output.writeStdout(chunk);
        }
        await output.writeStdout(Uint8List.fromList(<int>[0]));
        return FushellCommandResult();

      case 'late-write':
        unawaited(output.writeStdoutText('late marker\n'));
        return FushellCommandResult();

      case 'throw':
        throw StateError('example handler failure');

      case 'gate':
        if (arguments.length != 2) {
          await output.writeStderrText('usage: gate <release-file>\n');
          return FushellCommandResult(exitCode: 64);
        }
        await output.writeStdoutText('waiting\n');
        final File releaseFile = File(arguments[1]);
        while (!releaseFile.existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return FushellCommandResult();

      case 'wait':
        final int milliseconds = arguments.length == 2
            ? int.tryParse(arguments[1]) ?? -1
            : -1;
        if (milliseconds < 0) {
          await output.writeStderrText('usage: wait <milliseconds>\n');
          return FushellCommandResult(exitCode: 64);
        }
        await output.writeStdoutText('waiting\n');
        final bool cancelled = await Future.any<bool>(<Future<bool>>[
          Future<void>.delayed(
            Duration(milliseconds: milliseconds),
          ).then((_) => false),
          invocation.cancelled.then((_) => true),
        ]);
        if (cancelled) return FushellCommandResult();
        await output.writeStdoutText('waited\n');
        return FushellCommandResult();

      case 'hang':
        final int milliseconds = arguments.length == 2
            ? int.tryParse(arguments[1]) ?? -1
            : -1;
        if (milliseconds < 0) {
          await output.writeStderrText('usage: hang <milliseconds>\n');
          return FushellCommandResult(exitCode: 64);
        }
        await Future<void>.delayed(Duration(milliseconds: milliseconds));
        await output.writeStdoutText('hang completed\n');
        return FushellCommandResult();

      case 'quit':
        Timer(const Duration(milliseconds: 50), FushellProcess.exit);
        await output.writeStdoutText('stopping daemon\n');
        return FushellCommandResult();

      case 'help':
        await output.writeStdoutText(_help);
        return FushellCommandResult();

      default:
        await output.writeStderrText(
          'unknown command: ${arguments.first}\n$_help',
        );
        return FushellCommandResult(exitCode: 64);
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
  exit124            return business exit code 124
  context [args...]   echo invocation context
  raw <bytes...>      echo raw argv bytes as hexadecimal
  wait <milliseconds> wait asynchronously (integration testing)
  gate <release-file> wait for a release file (integration testing)
  hang <milliseconds> ignore cancellation (integration testing)
  quit               stop the daemon
  help               show this help
''';
