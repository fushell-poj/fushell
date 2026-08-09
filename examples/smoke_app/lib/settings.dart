import 'package:flutter/material.dart';

/// 设置窗口 UI。由主窗口通过 FushellWindow.openWindow(entrypoint: 'settings')
/// 打开; 宿主以 main 入口启动新 engine, 通过 dart_entrypoint_argv 传 'settings',
/// main.dart 按窗口标识分支到本窗口。
class SettingsApp extends StatelessWidget {
  const SettingsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1B1F2A),
        body: Center(
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.settings, size: 40, color: Color(0xFF2F6FED)),
                SizedBox(height: 12),
                Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF17122B),
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'This window runs in its own engine instance '
                  '(custom Dart entrypoint) inside the same fushell process.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Color(0xFF34324A)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
