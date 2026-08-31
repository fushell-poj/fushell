import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushell/fushell.dart';
import 'settings.dart';

/// 无头壳: main() 不绑定窗口 (引擎以 implicit view 无窗口启动)。
/// 全部窗口由 FushellWindow.openWindow 创建, 内容用框架 View/ViewCollection
/// 渲染到对应 view。关闭全部窗口不会退出进程 (显式退出用 FushellProcess.exit)。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final int mainWindowId = await FushellWindow.openWindow(
    title: 'fushell Flutter Smoke',
    appId: 'dev.fushell.smoke',
    width: 800,
    height: 600,
  );
  // 设置窗: 绑定到主窗 (xdg set_parent, transient 语义)。
  final int settingsWindowId = await FushellWindow.openWindow(
    title: 'fushell Settings',
    appId: 'dev.fushell.settings',
    width: 480,
    height: 360,
    parent: mainWindowId,
  );
  // 顶部 bar: layer-shell 角色 (与 xdg 窗口互斥的另一种窗口类型)。
  // 某些 compositor (如无 layer-shell 的 cage) 不支持: 跳过并继续主演示。
  int? topBarId;
  try {
    topBarId = await FushellWindow.openWindow(
      title: 'unused-for-layer',
      appId: 'unused-for-layer',
      layer: const LayerSurfaceRole(
        namespace: 'fushell-smoke',
        layer: LayerSurfaceLayer.top,
        anchors: {
          LayerSurfaceAnchor.top,
          LayerSurfaceAnchor.left,
          LayerSurfaceAnchor.right,
        },
        exclusiveZone: 32,
        height: 32,
      ),
    );
  } catch (e) {
    debugPrint('layer-shell window unavailable on this compositor: $e');
  }

  runWidget(
    _SmokeViewCollection(
      mainWindowId: mainWindowId,
      mainView: await FushellWindow.viewById(mainWindowId),
      initialSettingsView: await FushellWindow.viewById(settingsWindowId),
      topBarView: topBarId == null
          ? null
          : await FushellWindow.viewById(topBarId),
    ),
  );
}

class _SmokeViewCollection extends StatefulWidget {
  const _SmokeViewCollection({
    required this.mainWindowId,
    required this.mainView,
    required this.initialSettingsView,
    this.topBarView,
  });

  final int mainWindowId;
  final ui.FlutterView mainView;
  final ui.FlutterView initialSettingsView;
  final ui.FlutterView? topBarView;

  @override
  State<_SmokeViewCollection> createState() => _SmokeViewCollectionState();
}

class _SmokeViewCollectionState extends State<_SmokeViewCollection> {
  late final Map<int, Widget> _views;
  late final StreamSubscription<FushellWindowClosedEvent> _closedSubscription;
  int _nextSettingsNumber = 2;

  @override
  void initState() {
    super.initState();
    _views = <int, Widget>{
      widget.mainView.viewId: View(
        view: widget.mainView,
        child: FushellSmokeApp(onOpenSettingsWindow: _openSettingsWindow),
      ),
      widget.initialSettingsView.viewId: View(
        view: widget.initialSettingsView,
        child: const SettingsApp(),
      ),
      if (widget.topBarView case final topBarView?)
        topBarView.viewId: View(view: topBarView, child: const _TopBar()),
    };
    _closedSubscription = FushellWindow.closed.listen((
      FushellWindowClosedEvent event,
    ) {
      if (!mounted || !_views.containsKey(event.windowId)) return;
      setState(() => _views.remove(event.windowId));
    });
  }

  @override
  void dispose() {
    unawaited(_closedSubscription.cancel());
    super.dispose();
  }

  Future<void> _openSettingsWindow() async {
    final number = _nextSettingsNumber++;
    final windowId = await FushellWindow.openWindow(
      title: 'fushell Settings $number',
      appId: 'dev.fushell.settings',
      width: 480,
      height: 360,
      parent: widget.mainWindowId,
    );
    final view = await FushellWindow.viewById(windowId);
    if (!mounted) return;
    setState(() {
      _views[windowId] = View(view: view, child: const SettingsApp());
    });
  }

  @override
  Widget build(BuildContext context) =>
      ViewCollection(views: _views.values.toList());
}

class FushellSmokeApp extends StatelessWidget {
  const FushellSmokeApp({super.key, required this.onOpenSettingsWindow});

  final Future<void> Function() onOpenSettingsWindow;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF17122B), Color(0xFF2F6FED)],
            ),
          ),
          child: Center(
            child: Container(
              width: 560,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 36,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'fushell multi-view first frames',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF17122B),
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'This window, every settings window, and the top bar are '
                    'Flutter views of one engine rendered through the '
                    'compositor path.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Color(0xFF34324A)),
                  ),
                  SizedBox(height: 28),
                  Tooltip(
                    message:
                        'Tooltip text rendered with the injected system sans font',
                    child: Icon(
                      Icons.description,
                      size: 44,
                      color: Color(0xFF2F6FED),
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: () async {
                      await onOpenSettingsWindow();
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open Settings Window'),
                  ),
                  const SizedBox(height: 18),
                  // ── 输入法测试区 (TextField 需要 textinput 通道) ──
                  const _InputSection(),
                  const SizedBox(height: 18),
                  // ── 可复制元素 + 复制按钮 (需要 Clipboard 通道) ──
                  const _CopySection(),
                  const SizedBox(height: 18),
                  const _StatusRow(
                    label: 'Engine',
                    value: 'raw libflutter_engine.so',
                  ),
                  _StatusRow(
                    label: 'Renderer',
                    value: 'compositor (backing store + per-view blit)',
                  ),
                  const _StatusRow(
                    label: 'Scope',
                    value: 'headless shell + multi-view',
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

/// layer-shell 顶部 bar 内容 (由 main 中的 View 渲染到 layer 窗口)。
class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFF2F6FED), Color(0xFF17122B)],
          ),
        ),
        child: const Center(
          child: Text(
            'fushell layer-shell top bar (one engine, another view)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2F6FED),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 16, color: Color(0xFF17122B)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 输入法测试区: TextField 依赖宿主实现 flutter/textinput 通道。
class _InputSection extends StatefulWidget {
  const _InputSection();

  @override
  State<_InputSection> createState() => _InputSectionState();
}

class _InputSectionState extends State<_InputSection> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 诊断: 打印 Flutter 端实际应用的 editing value (经 logMessageCallback 出现在宿主日志)
    _controller.addListener(() {
      debugPrint(
        'CTRL text="${_controller.text}" sel=${_controller.selection.baseOffset},${_controller.selection.extentOffset} comp=${_controller.value.composing.isValid ? '${_controller.value.composing.start},${_controller.value.composing.end}' : 'none'}',
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Input (IME test)',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2F6FED),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          decoration: const InputDecoration(
            hintText: 'Type here…',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (value) => setState(() {}),
        ),
        const SizedBox(height: 6),
        Text(
          'echo: ${_controller.text.isEmpty ? '(empty)' : _controller.text}',
          style: const TextStyle(fontSize: 13, color: Color(0xFF34324A)),
        ),
        const SizedBox(height: 4),
        // 诊断: Flutter 侧看到的 selection/composing 状态
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, v, _) {
            final s = v.selection;
            final c = v.composing;
            return Text(
              'diag: text=${v.text.length} sel=${s.isValid ? '${s.start},${s.end}' : 'invalid'} '
              'comp=${c.isValid ? '${c.start},${c.end}' : 'none'}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
            );
          },
        ),
      ],
    );
  }
}

/// 可复制元素 + 复制按钮: Clipboard.setData 依赖宿主实现 flutter/platform 通道。
class _CopySection extends StatelessWidget {
  const _CopySection();

  static const String copyableText =
      'fushell copyable text — select me with mouse, or use the button';

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Clipboard test',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2F6FED),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF2F4FA),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const SelectableText(
            copyableText,
            style: TextStyle(fontSize: 13, color: Color(0xFF17122B)),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: () async {
              try {
                await Clipboard.setData(
                  const ClipboardData(text: copyableText),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Copy failed: $e')));
                }
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
        ),
      ],
    );
  }
}
