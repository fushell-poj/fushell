import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A located image. This API locates files; it does not decode or rasterize them.
class IconLookupResult {
  const IconLookupResult({
    required this.path,
    required this.format,
    required this.theme,
    required this.isScalable,
  });

  final String path;

  /// Lowercase filename extension without the dot: png, svg, or xpm.
  final String format;

  /// Internal theme directory name, or null for an unthemed/absolute file.
  final String? theme;

  /// Whether the image is SVG (independent of the directory's sizing policy).
  final bool isScalable;
}

/// Asynchronous Linux Freedesktop icon lookup, without Flutter dependencies.
///
/// [searchPaths] contains icon base directories (for example /usr/share/icons),
/// with named theme directories beneath them. Explicit paths replace defaults.
/// Filesystem changes become visible after [clearCache]. No filesystem watcher
/// or recursive directory scan is used. Symlinks are followed like normal icons.
class IconResolver {
  IconResolver({
    this.theme,
    List<String>? searchPaths,
    Future<String?> Function()? systemThemeLoader,
  }) : searchPaths = List.unmodifiable(searchPaths ?? _defaultPaths()),
       _systemThemeLoader =
           systemThemeLoader ?? SystemIconThemeDetector().detect;

  /// Explicit constructor theme; null selects the current desktop theme.
  final String? theme;
  final Future<String?> Function() _systemThemeLoader;
  Future<String>? _resolvedTheme;

  /// Resolve the explicit or detected theme, falling back to hicolor.
  /// Automatic detection is cached until [clearCache].
  Future<String> resolveTheme() {
    if (theme != null) return Future.value(theme!);
    return _resolvedTheme ??= Future<String?>.sync(_systemThemeLoader).then(
      (value) => SystemIconThemeDetector._themeName(value) ?? 'hicolor',
      onError: (Object error, StackTrace stack) => 'hicolor',
    );
  }

  final List<String> searchPaths;
  final _cache = <String, Future<IconLookupResult?>>{};
  var _indexes = <String, Future<Map<String, Map<String, String>>?>>{};
  Future<List<String>>? _themes;
  static const _formats = ['png', 'svg', 'xpm'];

  static List<String> _defaultPaths() {
    final env = Platform.environment;
    final home = env['HOME'];
    final dataHome = env['XDG_DATA_HOME'];
    final dataDirs = env['XDG_DATA_DIRS'];
    return [
      if (home != null && home.startsWith('/')) '$home/.icons',
      if (dataHome != null && dataHome.startsWith('/'))
        '$dataHome/icons'
      else if (home != null && home.startsWith('/'))
        '$home/.local/share/icons',
      for (final root
          in (dataDirs == null || dataDirs.isEmpty
                  ? '/usr/local/share:/usr/share'
                  : dataDirs)
              .split(':'))
        if (root.startsWith('/')) '$root/icons',
      '/usr/share/pixmaps',
    ];
  }

  /// Find [name], optionally including a supported extension or an absolute path.
  ///
  /// Relative names containing path separators, '.' or '..' are rejected with
  /// null. Non-positive size/scale also returns null. Extra paths take precedence
  /// and may contain loose files, an index.theme, or named theme directories.
  Future<IconLookupResult?> lookup({
    required String name,
    int size = 24,
    int scale = 1,
    String? theme,
    List<String> extraSearchPaths = const [],
  }) {
    final extra = extraSearchPaths
        .where((path) => path.isNotEmpty && !path.contains('\u0000'))
        .toList();
    final selected = theme ?? this.theme;
    final key = jsonEncode([name, size, scale, selected, searchPaths, extra]);
    return _cache.putIfAbsent(
      key,
      () => _lookup(name, size, scale, selected, extra),
    );
  }

  /// Discard positive/negative lookups and theme listings, including in-flight
  /// cache entries. Already returned futures may still finish with their result.
  void clearCache() {
    _cache.clear();
    // Detach old readers so in-flight work cannot refill the new generation.
    _indexes = {};
    _themes = null;
    _resolvedTheme = null;
  }

  /// Sorted internal names of themes with a readable [Icon Theme] index.
  /// Hidden themes are included. Only immediate children of base paths are read.
  Future<List<String>> listThemes() => _themes ??= _listThemes();

  Future<List<String>> _listThemes() async {
    final indexes = _indexes;
    final names = <String>{};
    for (final root in searchPaths) {
      try {
        await for (final entry in Directory(root).list(followLinks: true)) {
          final name = entry.path.split('/').last;
          if (_safeName(name) &&
              await indexes.putIfAbsent(
                    entry.path,
                    () => _readIndex(entry.path),
                  ) !=
                  null) {
            names.add(name);
          }
        }
      } on FileSystemException {
        // A missing or unreadable root does not invalidate the other roots.
      }
    }
    return List.unmodifiable(names.toList()..sort());
  }

  Future<IconLookupResult?> _lookup(
    String name,
    int size,
    int scale,
    String? selected,
    List<String> extra,
  ) async {
    final indexes = _indexes;
    if (size <= 0 || scale <= 0 || name.contains('\u0000')) return null;
    if (name.startsWith('/')) return _file(name, null);
    if (!_safeName(name)) return null;
    final selectedTheme = selected ?? await resolveTheme();
    if (!_safeName(selectedTheme)) return null;
    final roots = [...extra, ...searchPaths];
    // SNI IconThemePath is often a flat private directory rather than a root.
    for (final root in extra) {
      final direct = await _inDirectory(root, name, null);
      if (direct != null) return direct;
    }
    final visited = <String>{};
    Future<IconLookupResult?> visit(
      String themeName, {
      String? directPath,
    }) async {
      if (!_safeName(themeName) || !visited.add(directPath ?? themeName)) {
        return null;
      }
      final paths = [?directPath, for (final root in roots) '$root/$themeName'];
      Map<String, Map<String, String>>? index;
      for (final path in paths) {
        index = await indexes.putIfAbsent(path, () => _readIndex(path));
        if (index != null) break;
      }
      if (index == null) return null;
      final header = index['Icon Theme']!;
      final directories = <_IconDirectory>[];
      for (final name in {
        ..._list(header['Directories']),
        ..._list(header['ScaledDirectories']),
      }) {
        if (!_safeSubdirectory(name)) continue;
        final directory = _IconDirectory.parse(name, index[name]);
        if (directory != null) directories.add(directory);
      }
      // Specification order: directory, base path, then png/svg/xpm.
      for (final directory in directories) {
        if (!directory.matches(size, scale)) continue;
        for (final path in paths) {
          final result = await _inDirectory(
            '$path/${directory.name}',
            name,
            themeName,
          );
          if (result != null) return result;
        }
      }
      IconLookupResult? closest;
      int? distance;
      for (final directory in directories) {
        final candidateDistance = directory.distance(size, scale);
        if (distance != null && candidateDistance >= distance) continue;
        for (final path in paths) {
          final result = await _inDirectory(
            '$path/${directory.name}',
            name,
            themeName,
          );
          if (result != null) {
            closest = result;
            distance = candidateDistance;
            break;
          }
        }
      }
      if (closest != null) return closest;
      for (final parent in _list(header['Inherits'])) {
        final result = await visit(parent);
        if (result != null) return result;
      }
      return null;
    }

    for (final root in extra) {
      final themeName = root.replaceAll(RegExp(r'/+$'), '').split('/').last;
      final result = await visit(themeName, directPath: root);
      if (result != null) return result;
    }
    final themed = await visit(selectedTheme) ?? await visit('hicolor');
    if (themed != null) return themed;
    for (final root in roots) {
      final result = await _inDirectory(root, name, null);
      if (result != null) return result;
    }
    return null;
  }

  static bool _safeName(String value) =>
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.contains('\u0000');

  static bool _safeSubdirectory(String value) =>
      value.split('/').every(_safeName);

  static List<String> _list(String? value) => value == null
      ? []
      : value
            .split(',')
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList();

  static Future<IconLookupResult?> _file(String path, String? theme) async {
    final format = path.split('.').last;
    if (!_formats.contains(format)) return null;
    try {
      if (await File(path).exists()) {
        return IconLookupResult(
          path: File(path).absolute.path,
          format: format,
          theme: theme,
          isScalable: format == 'svg',
        );
      }
    } on FileSystemException {
      // Missing, inaccessible and malformed paths are lookup misses.
    }
    return null;
  }

  static Future<IconLookupResult?> _inDirectory(
    String directory,
    String name,
    String? theme,
  ) async {
    final extension = name.split('.').last;
    if (_formats.contains(extension)) return _file('$directory/$name', theme);
    for (final format in _formats) {
      final result = await _file('$directory/$name.$format', theme);
      if (result != null) return result;
    }
    return null;
  }

  static Future<Map<String, Map<String, String>>?> _readIndex(
    String directory,
  ) async {
    try {
      final text = await File('$directory/index.theme').readAsString();
      final sections = <String, Map<String, String>>{};
      Map<String, String>? section;
      for (final raw in const LineSplitter().convert(text)) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        if (line.startsWith('[') && line.endsWith(']')) {
          section = sections.putIfAbsent(
            line.substring(1, line.length - 1),
            () => {},
          );
        } else {
          final equals = line.indexOf('=');
          if (equals > 0 && section != null) {
            section[line.substring(0, equals).trim()] = line
                .substring(equals + 1)
                .trim();
          }
        }
      }
      return sections.containsKey('Icon Theme') ? sections : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// Best-effort desktop icon theme detection without GTK or D-Bus dependencies.
///
/// KDE prefers kdeglobals, GNOME/Unity/Cinnamon prefer GSettings, and other
/// desktops prefer GTK4/GTK3 settings.ini. User config directories precede
/// XDG_CONFIG_DIRS. This reads configuration only; it does not watch for changes.
/// Injection points make configuration and optional command handling testable.
class SystemIconThemeDetector {
  SystemIconThemeDetector({
    Map<String, String>? environment,
    Future<String?> Function(String path)? readFile,
    Future<Process> Function(String executable, List<String> arguments)?
    startProcess,
    this.commandTimeout = const Duration(seconds: 1),
  }) : environment = Map.unmodifiable(environment ?? Platform.environment),
       _readFile = readFile ?? _readText,
       _startProcess = startProcess ?? _start {
    if (commandTimeout <= Duration.zero) {
      throw ArgumentError.value(
        commandTimeout,
        'commandTimeout',
        'must be positive',
      );
    }
  }

  final Map<String, String> environment;
  final Duration commandTimeout;
  final Future<String?> Function(String path) _readFile;
  final Future<Process> Function(String executable, List<String> arguments)
  _startProcess;

  Future<String?> detect() async {
    final current = environment['XDG_CURRENT_DESKTOP']?.trim();
    final desktop =
        (current != null && current.isNotEmpty
                ? current
                : environment['XDG_SESSION_DESKTOP'] ?? '')
            .toUpperCase();
    final kde = desktop.contains('KDE') || desktop.contains('PLASMA');
    final cinnamon = desktop.contains('CINNAMON');
    final gnome =
        desktop.contains('GNOME') || desktop.contains('UNITY') || cinnamon;
    final readers = <Future<String?> Function()>[
      if (kde) _kde,
      if (gnome) () => _gsettings(cinnamon: cinnamon),
      _gtk,
      if (!kde) _kde,
      if (!gnome) _gsettings,
    ];
    for (final reader in readers) {
      try {
        final name = _themeName(await reader());
        if (name != null) return name;
      } catch (_) {
        // Unavailable optional sources never prevent trying another source.
      }
    }
    return null;
  }

  List<String> get _configDirectories {
    final home = environment['HOME'];
    final configHome = environment['XDG_CONFIG_HOME'];
    final configDirs = environment['XDG_CONFIG_DIRS'];
    return [
      if (configHome != null && configHome.startsWith('/'))
        configHome
      else if (home != null && home.startsWith('/'))
        '$home/.config',
      for (final path
          in (configDirs == null || configDirs.isEmpty
                  ? '/etc/xdg'
                  : configDirs)
              .split(':'))
        if (path.startsWith('/')) path,
    ];
  }

  Future<String?> _gtk() async {
    for (final root in _configDirectories) {
      for (final version in ['4.0', '3.0']) {
        final value = await _value(
          '$root/gtk-$version/settings.ini',
          'Settings',
          'gtk-icon-theme-name',
        );
        if (value != null) return value;
      }
    }
    return null;
  }

  Future<String?> _kde() async {
    for (final root in _configDirectories) {
      final value = await _value('$root/kdeglobals', 'Icons', 'Theme');
      if (value != null) return value;
    }
    return null;
  }

  Future<String?> _value(String path, String group, String key) async {
    try {
      final text = await _readFile(path);
      if (text == null) return null;
      String? section;
      String? value;
      for (final raw in const LineSplitter().convert(text)) {
        final line = raw.trim();
        if (line.startsWith('#') || line.startsWith(';')) continue;
        if (line.startsWith('[') && line.endsWith(']')) {
          section = line.substring(1, line.length - 1);
        } else if (section == group) {
          final equals = line.indexOf('=');
          if (equals > 0 && line.substring(0, equals).trim() == key) {
            value = _themeName(line.substring(equals + 1));
          }
        }
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  static String? _variantTheme(String value) {
    if (value.length < 2) return null;
    final quote = value[0];
    if ((quote != "'" && quote != '"') || value[value.length - 1] != quote) {
      return null;
    }
    final result = StringBuffer();
    for (var index = 1; index < value.length - 1; index++) {
      var character = value[index];
      if (character == '\\') {
        if (++index >= value.length - 1) return null;
        character = value[index];
        // Only quote/backslash escapes can occur in a valid icon theme name.
        if (character != "'" && character != '"' && character != '\\') {
          return null;
        }
      } else if (character == quote) {
        return null;
      }
      result.write(character);
    }
    return _themeName(result.toString());
  }

  static String? _themeName(String? value) {
    final name = value?.trim();
    if (name == null ||
        !IconResolver._safeName(name) ||
        RegExp(r'[\x00-\x20,\x7f-\uffff]').hasMatch(name)) {
      return null;
    }
    return name;
  }

  static Future<String?> _readText(String path) => File(path).readAsString();
  static Future<Process> _start(String executable, List<String> arguments) =>
      Process.start(executable, arguments, runInShell: false);

  Future<String?> _gsettings({bool cinnamon = false}) async {
    for (final schema in [
      if (cinnamon) 'org.cinnamon.desktop.interface',
      'org.gnome.desktop.interface',
    ]) {
      final result = await _command(schema);
      if (result != null) return result;
    }
    return null;
  }

  Future<void> _stop(Process process) async {
    process.kill(ProcessSignal.sigkill);
    try {
      await process.exitCode.timeout(commandTimeout);
    } catch (_) {
      // A broken injected process implementation must not block the caller.
    }
  }

  Future<String?> _command(String schema) async {
    Process? process;
    StreamSubscription<List<int>>? stdout;
    StreamSubscription<List<int>>? stderr;
    var startExpired = false;
    try {
      final starting = _startProcess('gsettings', [
        'get',
        schema,
        'icon-theme',
      ]);
      // If startup itself times out, reap a process that arrives after timeout.
      unawaited(
        starting.then<void>((lateProcess) async {
          if (startExpired) await _stop(lateProcess);
        }, onError: (Object error, StackTrace stack) {}),
      );
      try {
        process = await starting.timeout(commandTimeout);
      } on TimeoutException {
        startExpired = true;
        return null;
      }
      final bytes = <int>[];
      var failed = false;
      final outputDone = Completer<void>();
      final errorDone = Completer<void>();
      stdout = process.stdout.listen(
        (chunk) {
          if (bytes.length + chunk.length > 4096) {
            failed = true;
          } else {
            bytes.addAll(chunk);
          }
        },
        onError: (Object error) {
          failed = true;
        },
        onDone: outputDone.complete,
      );
      stderr = process.stderr.listen(
        (_) {},
        onError: (Object error) {},
        onDone: errorDone.complete,
      );
      final exit = await (() async {
        final code = await process!.exitCode;
        await outputDone.future;
        await errorDone.future;
        return code;
      })().timeout(commandTimeout);
      if (exit != 0 || failed) return null;
      final value = utf8.decode(bytes).trim();
      // GSettings returns a quoted GVariant string, not a raw theme name.
      return _variantTheme(value);
    } catch (_) {
      if (process != null) await _stop(process);
      return null;
    } finally {
      await stdout?.cancel();
      await stderr?.cancel();
    }
  }
}

class _IconDirectory {
  _IconDirectory(this.name, this.size, this.scale, this.min, this.max);
  final String name;
  final int size;
  final int scale;
  final int min;
  final int max;

  static _IconDirectory? parse(String name, Map<String, String>? values) {
    if (values == null) return null;
    int? number(String key, [int? fallback]) =>
        values.containsKey(key) ? int.tryParse(values[key]!) : fallback;
    final size = number('Size');
    final scale = number('Scale', 1);
    if (size == null || size <= 0 || scale == null || scale <= 0) return null;
    int? min;
    int? max;
    switch (values['Type'] ?? 'Threshold') {
      case 'Fixed':
        min = max = size;
      case 'Scalable':
        min = number('MinSize', size);
        max = number('MaxSize', size);
      case 'Threshold':
        final threshold = number('Threshold', 2);
        if (threshold == null || threshold < 0) return null;
        min = size - threshold;
        max = size + threshold;
      default:
        return null;
    }
    if (min == null || max == null || max < min || max <= 0) return null;
    return _IconDirectory(name, size, scale, min, max);
  }

  bool matches(int requestedSize, int requestedScale) =>
      scale == requestedScale && requestedSize >= min && requestedSize <= max;

  int distance(int requestedSize, int requestedScale) {
    final pixels = requestedSize * requestedScale;
    if (pixels < min * scale) return min * scale - pixels;
    if (pixels > max * scale) return pixels - max * scale;
    return 0;
  }
}
