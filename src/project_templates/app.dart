import 'package:flutter/material.dart';

/// Keep UI independent from native window creation so it can be widget-tested.
class App extends StatelessWidget {
  const App({super.key, required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Hello, Fushell!'),
            const SizedBox(height: 16),
            const Text('Closing a window does not stop the process.'),
            const SizedBox(height: 16),
            FilledButton(onPressed: onExit, child: const Text('Exit')),
          ],
        ),
      ),
    ),
  );
}
