import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fushell/fushell.dart';
import 'package:fushell/icons.dart';

import 'icon_image.dart';
import 'icon_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runWidget(const _WindowViews());
  await FushellWindow.openWindow(
    title: 'Icon preview',
    appId: 'dev.fushell.IconPreview',
    width: 920,
    height: 720,
  );
}

class _WindowViews extends StatefulWidget {
  const _WindowViews();
  @override
  State<_WindowViews> createState() => _WindowViewsState();
}

class _WindowViewsState extends State<_WindowViews>
    with WidgetsBindingObserver {
  bool _hadView = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final views = ui.PlatformDispatcher.instance.views.where(
      (v) => v.viewId != 0,
    );
    if (_hadView && views.isEmpty) {
      FushellProcess.exit();
      return;
    }
    if (views.isNotEmpty) _hadView = true;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ViewCollection(
    views: [
      for (final view in ui.PlatformDispatcher.instance.views)
        if (view.viewId != 0) View(view: view, child: const IconPreviewApp()),
    ],
  );
}

class IconPreviewApp extends StatelessWidget {
  const IconPreviewApp({super.key, this.resolver});
  final IconResolver? resolver;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xff54cbb0),
    ),
    home: IconPreviewPage(resolver: resolver),
  );
}

class IconPreviewPage extends StatefulWidget {
  const IconPreviewPage({super.key, this.resolver});
  final IconResolver? resolver;
  @override
  State<IconPreviewPage> createState() => _IconPreviewPageState();
}

class _IconPreviewPageState extends State<IconPreviewPage> {
  late final IconResolver _resolver;
  late final IconThemeSelection _themeSelection;
  final _name = TextEditingController(text: 'folder');
  final _theme = TextEditingController();
  final _size = TextEditingController(text: '48');
  final _scale = TextEditingController(text: '1');
  final _paths = TextEditingController();
  List<String> _themes = [];
  IconLookupResult? _result;
  String _message = 'Enter a name or absolute path, then look up an icon.';
  bool _busy = false;
  int _generation = 0;
  int _themeGeneration = 0;
  int _revision = 0;
  double _displaySize = 48;

  @override
  void initState() {
    super.initState();
    _resolver = widget.resolver ?? IconResolver();
    _themeSelection = IconThemeSelection(_resolver)..addListener(_themeChanged);
    _theme.addListener(_themeEdited);
    _themeSelection.apply('');
    _listThemes();
  }

  void _themeChanged() {
    if (mounted) setState(() {});
  }

  void _themeEdited() {
    ++_generation;
    _busy = false;
    _result = null;
    _themeSelection.invalidateDraft();
  }

  Future<void> _listThemes() async {
    final generation = ++_themeGeneration;
    try {
      final themes = await _resolver.listThemes();
      if (mounted && generation == _themeGeneration)
        setState(() => _themes = themes);
    } catch (e) {
      if (mounted && generation == _themeGeneration)
        setState(() => _message = 'Theme list error: $e');
    }
  }

  Future<void> _lookup({bool refresh = false}) async {
    final generation = ++_generation;
    final name = _name.text.trim();
    final size = int.tryParse(_size.text);
    final scale = int.tryParse(_scale.text);
    final paths = _paths.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (refresh) {
      ++_revision;
    }
    setState(() {
      _busy = true;
      _result = null;
      _message = 'Looking up…';
    });
    final theme = await _themeSelection.apply(_theme.text, refresh: refresh);
    if (refresh) _listThemes();
    if (!mounted || generation != _generation) return;
    if (theme == null) {
      setState(() {
        _busy = false;
        _message = _themeSelection.label;
      });
      return;
    }
    if (size == null ||
        scale == null ||
        size <= 0 ||
        scale <= 0 ||
        name.isEmpty) {
      setState(() {
        _busy = false;
        _message = 'Enter an icon name and positive integer size and scale.';
      });
      return;
    }
    try {
      final result = await _resolver.lookup(
        name: name,
        theme: theme,
        size: size,
        scale: scale,
        extraSearchPaths: paths,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _result = result;
        _displaySize = size.toDouble().clamp(16, 256);
        _message = result == null
            ? 'Not found. Try another theme or an extra path.'
            : 'Found';
      });
    } catch (e) {
      if (mounted && generation == _generation)
        setState(() => _message = 'Lookup error: $e');
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    ++_themeGeneration;
    _themeSelection.dispose();
    for (final c in [_name, _theme, _size, _scale, _paths]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int lines = 1,
  }) => TextField(
    controller: controller,
    maxLines: lines,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    onSubmitted: lines == 1 ? (_) => _lookup() : null,
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Icon preview'),
      actions: [
        IconButton(
          tooltip: 'Quit preview',
          onPressed: () => FushellProcess.exit(),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _field(_name, 'Icon name or absolute path'),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _field(_theme, 'Theme (blank = system)')),
            PopupMenuButton<String>(
              tooltip: 'Installed themes',
              onSelected: (value) {
                _theme.text = value;
                _lookup();
              },
              itemBuilder: (_) => _themes
                  .map((t) => PopupMenuItem(value: t, child: Text(t)))
                  .toList(),
              icon: const Icon(Icons.arrow_drop_down),
            ),
            TextButton(
              onPressed: _listThemes,
              child: const Text('List themes'),
            ),
          ],
        ),
        Text(_themeSelection.label),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _field(_size, 'Size (logical px)')),
            const SizedBox(width: 12),
            Expanded(child: _field(_scale, 'Scale (integer)')),
          ],
        ),
        const SizedBox(height: 12),
        _field(
          _paths,
          'Extra search paths (one absolute path per line)',
          lines: 2,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => _lookup(),
              child: const Text('Look up'),
            ),
            OutlinedButton(
              onPressed: () => _lookup(refresh: true),
              child: const Text('Refresh cache'),
            ),
            for (final name in [
              'folder',
              'document-open',
              'dialog-information',
              'network-wireless',
              'audio-volume-high',
            ])
              ActionChip(
                label: Text(name),
                onPressed: () {
                  _name.text = name;
                  _lookup();
                },
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (_busy) const LinearProgressIndicator(),
        SelectableText(_message),
        if (_result case final result?) ...[
          const SizedBox(height: 12),
          SelectableText(result.path),
          Text(
            'Format: ${result.format} · Theme: ${result.theme ?? "absolute / fallback"} · Scalable: ${result.isScalable}',
          ),
          const SizedBox(height: 16),
          Center(
            child: IconFileImage(
              result: result,
              size: _displaySize,
              revision: _revision,
              fallback: const Text('Image could not be decoded.'),
            ),
          ),
        ],
      ],
    ),
  );
}
