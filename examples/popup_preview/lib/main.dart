import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:fushell/fushell.dart';
import 'package:fushell/windows.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preview = PopupPreview();
  runWidget(
    ListenableBuilder(
      listenable: preview,
      builder: (context, _) => FushellWindowViews(
        builder: (context, view) =>
            PreviewSurface(preview: preview, view: view),
      ),
    ),
  );
  await FushellApplication.run(onCommand: preview.command);
}

/// A command-driven example; all native windows share this one engine.
final class PopupPreview extends ChangeNotifier {
  PopupPreview() {
    FushellWindow.closed.listen((event) {
      surfaces.remove(event.windowId);
      metrics.remove(event.windowId);
      record({'event': 'closed', 'windowId': event.windowId});
      notifyListeners();
    });
  }

  final owner = FushellWindowController();
  final surfaces = <int, Map<String, Object?>>{};
  final events = <Map<String, Object?>>[];
  final metrics = <int, String>{};

  void record(Map<String, Object?> event) {
    events.add(event);
    if (events.length > 512) events.removeAt(0);
  }

  int number(Map<String, dynamic> options, String key, int fallback) =>
      options[key] as int? ?? fallback;

  PopupPositioner positioner(Map<String, dynamic> o) => PopupPositioner(
    width: number(o, 'width', 180),
    height: number(o, 'height', 100),
    anchorRect: PopupAnchorRect(
      x: number(o, 'x', 80),
      y: number(o, 'y', 60),
      width: number(o, 'anchorWidth', 40),
      height: number(o, 'anchorHeight', 24),
    ),
    anchor: PopupAnchor.values.byName(o['anchor'] as String? ?? 'bottom'),
    gravity: PopupGravity.values.byName(
      o['gravity'] as String? ?? 'bottomRight',
    ),
    constraintAdjustment: {
      for (final name in (o['constraints'] as List<dynamic>? ?? []))
        PopupConstraintAdjustment.values.byName(name as String),
    },
    offset: PopupOffset(x: number(o, 'offsetX', 0), y: number(o, 'offsetY', 0)),
    reactive: o['reactive'] as bool? ?? false,
  );

  Future<int> parent(String kind, Map<String, dynamic> o) async {
    if (kind != 'window' && kind != 'layer') {
      throw ArgumentError('parent window|layer');
    }
    final window = await owner.open(
      create: () => FushellWindow.openWindow(
        title: 'Popup preview',
        appId: 'dev.fushell.PopupPreview',
        width: number(o, 'width', 640),
        height: number(o, 'height', 420),
        layer: kind == 'layer'
            ? LayerSurfaceRole(
                namespace: 'popup-preview',
                layer: LayerSurfaceLayer.top,
                anchors: {
                  for (final name
                      in (o['anchors'] as List<dynamic>? ??
                          ['top', 'left', 'right']))
                    LayerSurfaceAnchor.values.byName(name as String),
                },
                width: o['width'] as int?,
                height: number(o, 'height', 48),
                exclusiveZone: 0,
              )
            : null,
      ),
    );
    surfaces[window.windowId] = {'kind': kind, 'color': 0xff126c8a};
    notifyListeners();
    return window.windowId;
  }

  Future<int> popup(int parentId, Map<String, dynamic> o) async {
    final role = PopupSurfaceRole(
      positioner: positioner(o),
      inputPassthrough: o['passthrough'] as bool? ?? false,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    final window = await owner.open(
      create: () async {
        while (true) {
          try {
            return await FushellWindow.openPopup(parent: parentId, popup: role);
          } on FushellSurfaceException catch (error) {
            if (error.code != 'PopupParentNotMapped' ||
                DateTime.now().isAfter(deadline)) {
              rethrow;
            }
            // An engine view can be ready before its first buffer is mapped.
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
      },
    );
    final nested = surfaces[parentId]?['kind'] == 'popup';
    surfaces[window.windowId] = {
      'kind': 'popup',
      'parent': parentId,
      'passthrough': role.inputPassthrough,
      'color': nested ? 0xffc23bb8 : 0xffff9d2e,
    };
    notifyListeners();
    return window.windowId;
  }

  Future<FushellCommandResult> command(
    FushellCommandInvocation invocation,
  ) async {
    final args = invocation.textArguments;
    final action = args.isEmpty ? 'help' : args.first;
    try {
      Map<String, dynamic> options(int index) => args.length > index
          ? jsonDecode(args[index]) as Map<String, dynamic>
          : {};
      Object? result;
      switch (action) {
        case 'parent':
          result = {
            'windowId': await parent(
              args.length > 1 ? args[1] : 'window',
              options(2),
            ),
          };
        case 'popup':
          result = {'windowId': await popup(int.parse(args[1]), options(2))};
        case 'reposition':
          final id = int.parse(args[1]);
          await FushellWindow.repositionPopup(id, positioner(options(2)));
          result = {'windowId': id, 'repositioned': true};
        case 'close':
          final id = int.parse(args[1]);
          await FushellWindow.closeWindow(id);
          result = {'windowId': id, 'closed': true};
        case 'cycle':
          final id = int.parse(args[1]);
          final count = int.parse(args[2]);
          RangeError.checkValueInInterval(count, 1, 1000, 'count');
          for (var i = 0; i < count; i++) {
            final child = await popup(id, options(3));
            await FushellWindow.closeWindow(child);
          }
          result = {'cycles': count};
        case 'list':
          result = [
            for (final e in surfaces.entries)
              {
                'windowId': e.key,
                ...e.value,
                if (metrics[e.key] != null)
                  'metrics': jsonDecode(metrics[e.key]!),
              },
          ];
        case 'events':
          result = List<Map<String, Object?>>.of(events);
          events.clear();
        case 'quit':
          await owner.dispose();
          Timer(const Duration(milliseconds: 50), FushellProcess.exit);
          return FushellCommandResult();
        case 'help':
          result = {
            'commands': [
              'parent [window|layer] [JSON options]',
              'popup PARENT_ID [JSON options]',
              'reposition POPUP_ID [JSON options]',
              'close WINDOW_ID',
              'cycle PARENT_ID COUNT [JSON options]',
              'list',
              'events',
              'quit',
            ],
          };
        default:
          throw ArgumentError('unknown command: $action');
      }
      await invocation.output.writeStdoutText('${jsonEncode(result)}\n');
      return FushellCommandResult();
    } catch (error) {
      final failure = {
        'error': error is FushellSurfaceException
            ? error.code
            : 'InvalidCommand',
        'message': error.toString(),
      };
      await invocation.output.writeStderrText('${jsonEncode(failure)}\n');
      return FushellCommandResult(exitCode: 1);
    }
  }
}

class PreviewSurface extends StatelessWidget {
  const PreviewSurface({super.key, required this.preview, required this.view});
  final PopupPreview preview;
  final ui.FlutterView view;

  @override
  Widget build(BuildContext context) {
    final info = preview.surfaces[view.viewId];
    if (info == null) return const SizedBox.expand();
    final popup = info['kind'] == 'popup';
    final size = view.physicalSize / view.devicePixelRatio;
    final value = jsonEncode({
      'width': size.width,
      'height': size.height,
      'scale': view.devicePixelRatio,
    });
    if (preview.metrics[view.viewId] != value) {
      preview.metrics[view.viewId] = value;
      preview.record({
        'event': 'metrics',
        'windowId': view.viewId,
        ...jsonDecode(value) as Map<String, dynamic>,
      });
    }
    void pointer(String event, ui.Offset position) => preview.record({
      'event': event,
      'windowId': view.viewId,
      'x': position.dx,
      'y': position.dy,
    });
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MouseRegion(
        onEnter: (event) => pointer('pointerenter', event.localPosition),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) => pointer('button', event.localPosition),
          child: Padding(
            padding: EdgeInsets.all(popup ? 8 : 0),
            child: ColoredBox(
              color: Color(info['color']! as int),
              child: Stack(
                children: [
                  if (!popup)
                    const Positioned(
                      left: 80,
                      top: 60,
                      width: 40,
                      height: 24,
                      child: ColoredBox(color: Color(0xff7ce4dd)),
                    ),
                  Positioned(
                    left: 12,
                    top: 10,
                    right: 12,
                    child: Text(
                      '${info['kind']} #${view.viewId}\n${size.width.toInt()} × ${size.height.toInt()}',
                      maxLines: 3,
                      overflow: TextOverflow.clip,
                      style: const TextStyle(
                        color: Color(0xff101820),
                        fontSize: 15,
                        fontFamily: 'sans-serif',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
