import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:fushell/fushell.dart';
import 'package:fushell/icons.dart';
import 'package:fushell/tray.dart';
import 'package:fushell/windows.dart';
import 'package:icon_preview/icon_image.dart';
import 'package:icon_preview/icon_theme.dart';

import 'icon_choice.dart';
import 'menu_icon.dart';
import 'tray_pixels.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runWidget(
    FushellWindowViews(
      builder: (context, view) => const TrayPreviewApp(),
      onLastViewClosed: FushellProcess.exit,
    ),
  );
  await FushellWindow.openWindow(
    title: 'Tray preview',
    appId: 'dev.fushell.TrayPreview',
    width: 960,
    height: 680,
  );
}

class TrayPreviewApp extends StatelessWidget {
  const TrayPreviewApp({super.key});
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
  TrayHost? _host;
  StreamSubscription<void>? _subscription;
  String? _selected;
  String? _error;
  bool _connecting = false;
  final List<String> _events = [];
  final _icons = IconResolver();
  final _theme = TextEditingController();
  late final IconThemeSelection _themeSelection;
  String? _selectedTheme;
  int _iconRevision = 0;

  @override
  void initState() {
    super.initState();
    _themeSelection = IconThemeSelection(_icons)..addListener(_themeChanged);
    _theme.addListener(_themeSelection.invalidateDraft);
    unawaited(_applyTheme());
    unawaited(_connect());
  }

  @override
  void dispose() {
    _themeSelection.dispose();
    _theme.dispose();
    unawaited(_subscription?.cancel());
    unawaited(_host?.close());
    super.dispose();
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _events.insert(
        0,
        '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
      );
      if (_events.length > 40) _events.removeLast();
    });
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await _subscription?.cancel();
      await _host?.close();
      _host = null;
      final host = await TrayHost.connect();
      if (!mounted) {
        await host.close();
        return;
      }
      _host = host;
      _subscription = host.changes.listen((_) {
        if (!mounted) return;
        setState(() {
          if (!host.items.any((i) => i.key == _selected)) _selected = null;
        });
      });
      _log('Connected to session bus');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _act(String label, Future<void> Function() action) async {
    try {
      await action();
      _log(label);
    } catch (error) {
      _log('$label: $error');
    }
  }

  void _themeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _applyTheme({bool refresh = false}) async {
    final theme = await _themeSelection.apply(_theme.text, refresh: refresh);
    if (!mounted || theme == null) return;
    setState(() {
      _selectedTheme = theme;
      ++_iconRevision;
    });
  }

  void _refreshIcons() => unawaited(_applyTheme(refresh: true));

  Widget _itemIcon(TrayItem item, {double size = 24}) => TrayPixmapIcon(
    item: item,
    size: size,
    resolver: _icons,
    theme: _selectedTheme,
    revision: _iconRevision,
  );

  Future<void> _menu(TrayItem item) async {
    try {
      final menu = await item.loadMenu();
      if (menu == null) {
        _log('No DBusMenu; requesting native context menu');
        await item.contextMenu();
        return;
      }
      try {
        if (mounted)
          await showDialog<void>(
            context: context,
            builder: (_) => _MenuDialog(
              menu: menu,
              title: item.title,
              log: _log,
              resolver: _icons,
              theme: _selectedTheme,
              revision: _iconRevision,
              extraPaths: item.iconThemePath.isEmpty
                  ? const []
                  : [item.iconThemePath],
            ),
          );
      } finally {
        await menu.close();
      }
    } catch (error) {
      _log('Menu: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = _host;
    final items = host?.items ?? <TrayItem>[];
    final selected = items.where((i) => i.key == _selected).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tray preview'),
        actions: [
          TextButton.icon(
            onPressed: _connecting ? null : _connect,
            icon: const Icon(Icons.refresh),
            label: const Text('Reconnect'),
          ),
          IconButton(
            tooltip: 'Quit preview',
            onPressed: () async {
              await _host?.close();
              await FushellProcess.exit();
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _theme,
                  decoration: const InputDecoration(
                    labelText: 'Icon theme (blank = system)',
                  ),
                  onSubmitted: (_) => _refreshIcons(),
                ),
              ),
              TextButton.icon(
                onPressed: _refreshIcons,
                icon: const Icon(Icons.refresh),
                label: const Text('Apply / refresh icons'),
              ),
            ],
          ),
          Text(_themeSelection.label),
          const SizedBox(height: 16),
          Text(
            _connecting
                ? 'Connecting…'
                : '${items.length} items · ${host?.isFallbackWatcher == true ? "Local watcher" : "External watcher"}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          SelectableText('Watcher: ${host?.watcherOwner ?? "not connected"}'),
          SelectableText('Host: ${host?.hostName ?? "—"}'),
          if (_error != null || host?.lastError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                _error ?? host!.lastError.toString(),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 24),
          if (items.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No tray items registered. Start a tray application or the demo item.\n'
                  'Items appear automatically when they register with the current watcher.',
                ),
              ),
            ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final item in items)
                Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      final horizontal =
                          event.scrollDelta.dx.abs() >
                          event.scrollDelta.dy.abs();
                      final delta =
                          -(horizontal
                                  ? event.scrollDelta.dx
                                  : event.scrollDelta.dy)
                              .round();
                      unawaited(
                        _act(
                          'Scroll $delta',
                          () => item.scroll(
                            delta,
                            orientation: horizontal ? 'horizontal' : 'vertical',
                          ),
                        ),
                      );
                    }
                  },
                  child: GestureDetector(
                    onSecondaryTap: () => _menu(item),
                    onTertiaryTapUp: (_) => _act(
                      'Secondary activate',
                      () => item.secondaryActivate(),
                    ),
                    child: Tooltip(
                      message: [
                        item.toolTip?.title ?? item.title,
                        item.toolTip?.description ?? '',
                        item.iconName,
                      ].where((s) => s.isNotEmpty).join('\n'),
                      child: ActionChip(
                        avatar: _itemIcon(item),
                        label: Text(item.title.isEmpty ? item.id : item.title),
                        onPressed: () {
                          setState(() => _selected = item.key);
                        },
                        backgroundColor: _selected == item.key
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Select an item to inspect it. Right click opens its menu; middle click activates its secondary action; wheel scrolls.',
          ),
          if (selected != null) ...[
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _itemIcon(selected, size: 48),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            selected.title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      'ID: ${selected.id}\nStatus: ${selected.status}\nService: ${selected.service}\nObject: ${selected.path}\nIcon: ${selected.iconName}\nTheme path: ${selected.iconThemePath}\nPixmaps: ${selected.iconPixmaps.map((p) => "${p.width}×${p.height}").join(", ")}',
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: () => selected.itemIsMenu
                              ? _menu(selected)
                              : _act('Activate', () => selected.activate()),
                          child: const Text('Activate'),
                        ),
                        OutlinedButton(
                          onPressed: () => _menu(selected),
                          child: const Text('Menu'),
                        ),
                        OutlinedButton(
                          onPressed: () =>
                              _act('Refresh item', selected.refresh),
                          child: const Text('Refresh'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text('Activity', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(
            _events.isEmpty
                ? 'Actions and errors appear here.'
                : _events.join('\n'),
          ),
        ],
      ),
    );
  }
}

class _MenuDialog extends StatefulWidget {
  const _MenuDialog({
    required this.menu,
    required this.title,
    required this.log,
    required this.resolver,
    required this.theme,
    required this.revision,
    required this.extraPaths,
  });
  final TrayMenu menu;
  final String title;
  final void Function(String) log;
  final IconResolver resolver;
  final String? theme;
  final int revision;
  final List<String> extraPaths;
  @override
  State<_MenuDialog> createState() => _MenuDialogState();
}

class _MenuDialogState extends State<_MenuDialog> {
  StreamSubscription<void>? _subscription;
  String? _error;
  @override
  void initState() {
    super.initState();
    _subscription = widget.menu.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Widget _menuIcon(TrayMenuNode node) => TrayMenuIcon(
    resolver: widget.resolver,
    name: node.iconName,
    data: node.properties['icon-data'],
    theme: widget.theme,
    revision: widget.revision,
    extraPaths: widget.extraPaths,
  );

  Widget _node(TrayMenuNode node) {
    if (!node.visible) return const SizedBox.shrink();
    if (node.type == 'separator') return const Divider();
    final title = Text(
      node.label.replaceAllMapped(
        RegExp(r'__|_(.)'),
        (m) => m.group(0) == '__' ? '_' : m.group(1)!,
      ),
    );
    if (node.isSubmenu || node.children.isNotEmpty)
      return ExpansionTile(
        key: PageStorageKey(node.id),
        enabled: node.enabled,
        title: title,
        leading: _menuIcon(node),
        onExpansionChanged: (open) {
          if (open)
            _run(() async {
              await widget.menu.aboutToShow(id: node.id);
              await widget.menu.refresh();
            });
        },
        children: node.children.map(_node).toList(),
      );
    return ListTile(
      enabled: node.enabled,
      title: Row(
        children: [
          if (node.iconName.isNotEmpty ||
              node.properties.containsKey('icon-data')) ...[
            _menuIcon(node),
            const SizedBox(width: 8),
          ],
          Expanded(child: title),
        ],
      ),
      leading: node.toggleType.isEmpty
          ? null
          : Icon(
              node.toggleType == 'radio'
                  ? (node.toggleState == 1
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked)
                  : (node.toggleState == 1
                        ? Icons.check_box
                        : node.toggleState < 0
                        ? Icons.indeterminate_check_box
                        : Icons.check_box_outline_blank),
            ),
      onTap: node.enabled
          ? () => _run(() async {
              await widget.menu.event(node.id);
              widget.log('Menu clicked: ${node.label}');
              await widget.menu.refresh();
            })
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title.isEmpty ? 'Tray menu' : widget.title),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) Text(_error!),
            ...widget.menu.root.children.map(_node),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

/// Theme names take priority, retaining the premultiplied SNI pixmap fallback.
class TrayPixmapIcon extends StatelessWidget {
  const TrayPixmapIcon({
    super.key,
    required this.item,
    required this.resolver,
    this.theme,
    this.revision = 0,
    this.size = 24,
  });
  final TrayItem item;
  final IconResolver resolver;
  final String? theme;
  final int revision;
  final double size;
  @override
  Widget build(BuildContext context) {
    final attention = item.status == 'NeedsAttention';
    final pixmaps = attention && item.attentionIconPixmaps.isNotEmpty
        ? item.attentionIconPixmaps
        : item.iconPixmaps;
    final name = trayIconName(
      needsAttention: attention,
      normalName: item.iconName,
      attentionName: item.attentionIconName,
      hasAttentionPixmap: item.attentionIconPixmaps.isNotEmpty,
    );
    Widget fallback = Icon(
      attention ? Icons.notifications_active : Icons.apps,
      size: size,
    );
    if (pixmaps.isNotEmpty) {
      final sorted = [...pixmaps]..sort((a, b) => a.width.compareTo(b.width));
      final target = size * MediaQuery.devicePixelRatioOf(context);
      final pixmap =
          sorted.where((p) => p.width >= target).firstOrNull ?? sorted.last;
      fallback = _RawPixmap(pixmap: pixmap, size: size);
    }
    return ResolvedIcon(
      resolver: resolver,
      name: name,
      theme: theme,
      size: size,
      scale: MediaQuery.devicePixelRatioOf(context).ceil(),
      revision: revision,
      extraSearchPaths: item.iconThemePath.isEmpty
          ? const []
          : [item.iconThemePath],
      fallback: fallback,
    );
  }
}

class _RawPixmap extends StatefulWidget {
  const _RawPixmap({required this.pixmap, required this.size});
  final TrayIconPixmap pixmap;
  final double size;
  @override
  State<_RawPixmap> createState() => _RawPixmapState();
}

class _RawPixmapState extends State<_RawPixmap> {
  ui.Image? _image;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_RawPixmap oldWidget) {
    super.didUpdateWidget(oldWidget);
    _decode();
  }

  void _decode() {
    final generation = ++_generation;
    final p = widget.pixmap;
    final rgba = premultipliedRgba(p);
    ui.decodeImageFromPixels(rgba, p.width, p.height, ui.PixelFormat.rgba8888, (
      image,
    ) {
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
      });
    });
  }

  @override
  void dispose() {
    ++_generation;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RawImage(image: _image, width: widget.size, height: widget.size);
}
