import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushell/fushell.dart';
import 'settings.dart';

/// 所有窗口共用 main 入口 (main 永远在 AOT 快照中)。
/// 宿主通过 dart_entrypoint_argv 传窗口标识(见 main 的 args 参数)。
Future<void> main(List<String> args) async {
  final windowId = args.isNotEmpty ? args.first : 'main';

  if (windowId == 'settings') {
    await FushellSurface.init(
      const SurfaceRole.window(
        title: 'fushell Settings',
        appId: 'dev.fushell.settings',
        width: 480,
        height: 360,
      ),
    );
    runApp(const SettingsApp());
    return;
  }

  await FushellSurface.init(
    const SurfaceRole.window(
      title: 'fushell Flutter Smoke',
      appId: 'dev.fushell.smoke',
      width: 800,
      height: 600,
    ),
  );
  runApp(const FushellSmokeApp());
}

class FushellSmokeApp extends StatelessWidget {
  const FushellSmokeApp({super.key});

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
                    'fushell Flutter first frame',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF17122B),
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'If you can see this card, the Zig Wayland/EGL embedder is rendering Flutter.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, color: Color(0xFF34324A)),
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
                    onPressed: () {
                      FushellWindow.openWindow(entrypoint: 'settings');
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
                    value: 'OpenGL over Wayland/EGL',
                  ),
                  const _StatusRow(label: 'Scope', value: 'first-frame only'),
                ],
              ),
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
