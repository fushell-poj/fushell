import 'package:flutter/material.dart';
import 'package:fushell/fushell.dart';
import 'settings.dart';

/// 所有窗口共用 main 入口 (main 永远在 AOT 快照中)。
/// 宿主通过 dart_entrypoint_argv 传窗口标识: main(List<String> args) 接收。
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
