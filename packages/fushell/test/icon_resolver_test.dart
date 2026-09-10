import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/icons.dart';

void main() {
  late Directory sandbox;
  late String root;
  late IconResolver resolver;

  Future<String> file(String path, [String contents = 'image']) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    await target.writeAsString(contents);
    return target.path;
  }

  Future<void> theme(
    String base,
    String name, {
    String inherits = '',
    Map<String, String> directories = const {'24': 'Size=24\nType=Fixed'},
    Map<String, String> scaled = const {},
  }) async {
    final body = StringBuffer('[Icon Theme]\nName=$name\nInherits=$inherits\n');
    body.writeln('Directories=${directories.keys.join(',')}');
    body.writeln('ScaledDirectories=${scaled.keys.join(',')}');
    for (final entry in {...directories, ...scaled}.entries) {
      body.writeln('[${entry.key}]\n${entry.value}');
    }
    await file('$base/$name/index.theme', body.toString());
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('fushell-icons-');
    root = '${sandbox.path}/icons';
    resolver = IconResolver(theme: 'main', searchPaths: [root]);
  });
  tearDown(() async => sandbox.delete(recursive: true));

  test(
    'inherits recursively, breaks cycles and falls back to hicolor',
    () async {
      await theme(root, 'main', inherits: 'parent');
      await theme(root, 'parent', inherits: 'main,other');
      await theme(root, 'other');
      await theme(root, 'hicolor');
      final inherited = await file('$root/other/24/app.png');
      final fallback = await file('$root/hicolor/24/fallback.png');
      expect((await resolver.lookup(name: 'app'))?.path, inherited);
      expect((await resolver.lookup(name: 'fallback'))?.path, fallback);
      expect(await resolver.lookup(name: 'absent'), isNull);
    },
  );

  test('current theme nearest size wins over inherited exact size', () async {
    await theme(
      root,
      'main',
      inherits: 'parent',
      directories: {'64': 'Size=64\nType=Fixed'},
    );
    await theme(root, 'parent');
    final current = await file('$root/main/64/app.svg');
    await file('$root/parent/24/app.png');
    final result = await resolver.lookup(name: 'app');
    expect(result?.path, current);
    expect(result?.theme, 'main');
    expect(result?.format, 'svg');
    expect(result?.isScalable, isTrue);
  });

  test(
    'exact scale beats equal physical size and nearest uses pixels',
    () async {
      await theme(
        root,
        'main',
        directories: {'48': 'Size=48\nType=Fixed', '24': 'Size=24\nType=Fixed'},
        scaled: {'24@2': 'Size=24\nScale=2\nType=Fixed'},
      );
      await file('$root/main/48/app.png');
      await file('$root/main/24/app.png');
      final doubled = await file('$root/main/24@2/app.png');
      expect((await resolver.lookup(name: 'app', scale: 2))?.path, doubled);
      expect(
        (await resolver.lookup(name: 'app', size: 22))?.path,
        '$root/main/24/app.png',
      );
      expect(
        (await resolver.lookup(name: 'app', size: 23, scale: 2))?.path,
        '$root/main/48/app.png',
      );
    },
  );

  test(
    'Scalable ranges and Threshold default and explicit boundaries',
    () async {
      await theme(
        root,
        'main',
        directories: {
          'fixed': 'Size=40\nType=Fixed',
          'vector': 'Size=24\nType=Scalable\nMinSize=16\nMaxSize=32',
          'threshold': 'Size=48\nThreshold=4',
          'default': 'Size=64',
        },
      );
      for (final dir in ['fixed', 'vector', 'threshold', 'default']) {
        await file('$root/main/$dir/app.png');
      }
      expect(
        (await resolver.lookup(name: 'app', size: 32))?.path,
        '$root/main/vector/app.png',
      );
      expect(
        (await resolver.lookup(name: 'app', size: 44))?.path,
        '$root/main/threshold/app.png',
      );
      expect(
        (await resolver.lookup(name: 'app', size: 62))?.path,
        '$root/main/default/app.png',
      );
      expect(
        (await resolver.lookup(name: 'app', size: 40))?.path,
        '$root/main/fixed/app.png',
      );
    },
  );

  test('first root overrides files using index from later root', () async {
    final second = '${sandbox.path}/second';
    resolver = IconResolver(theme: 'main', searchPaths: [root, second]);
    await theme(second, 'main');
    final preferred = await file('$root/main/24/app.svg');
    await file('$second/main/24/app.png');
    expect((await resolver.lookup(name: 'app'))?.path, preferred);
    await theme(root, 'main', directories: {'32': 'Size=32\nType=Fixed'});
    final indexed = await file('$second/main/32/app.png');
    resolver.clearCache();
    expect((await resolver.lookup(name: 'app'))?.path, indexed);
  });

  test('format precedence and explicit extensions', () async {
    await theme(root, 'main');
    for (final format in ['xpm', 'svg', 'png']) {
      await file('$root/main/24/app.$format');
    }
    expect((await resolver.lookup(name: 'app'))?.format, 'png');
    expect((await resolver.lookup(name: 'app.svg'))?.format, 'svg');
    await File('$root/main/24/app.png').delete();
    resolver.clearCache();
    expect((await resolver.lookup(name: 'app'))?.format, 'svg');
    await File('$root/main/24/app.svg').delete();
    resolver.clearCache();
    expect((await resolver.lookup(name: 'app'))?.format, 'xpm');
  });

  test('absolute files, missing files and unthemed fallback', () async {
    final absolute = await file('${sandbox.path}/absolute.svg');
    final loose = await file('$root/loose.png');
    expect((await resolver.lookup(name: absolute))?.path, absolute);
    expect((await resolver.lookup(name: absolute))?.theme, isNull);
    expect((await resolver.lookup(name: 'loose'))?.path, loose);
    expect(await resolver.lookup(name: '${sandbox.path}/missing.png'), isNull);
    expect(await resolver.lookup(name: await file('$root/no.jpg')), isNull);
  });

  test('SNI extra paths support flat files, direct themes and roots', () async {
    await theme(root, 'main');
    await file('$root/main/24/app.png');
    final flat = '${sandbox.path}/flat';
    final flatIcon = await file('$flat/app.svg');
    expect(
      (await resolver.lookup(name: 'app', extraSearchPaths: [flat]))?.path,
      flatIcon,
    );
    final extra = '${sandbox.path}/extra';
    await theme(extra, 'private');
    final private = await file('$extra/private/24/app.png');
    expect(
      (await resolver.lookup(
        name: 'app',
        extraSearchPaths: ['$extra/private'],
      ))?.path,
      private,
    );
    await theme(extra, 'main');
    final rooted = await file('$extra/main/24/app.png');
    expect(
      (await resolver.lookup(name: 'app', extraSearchPaths: [extra]))?.path,
      rooted,
    );
  });

  test('rejects traversal and invalid dimensions without throwing', () async {
    await file('${sandbox.path}/escape.png');
    for (final name in [
      '',
      '.',
      '..',
      '../escape',
      'a/b',
      r'a\b',
      'bad\u0000',
    ]) {
      expect(await resolver.lookup(name: name), isNull);
    }
    expect(await resolver.lookup(name: 'app', theme: '../main'), isNull);
    expect(await resolver.lookup(name: 'app', size: 0), isNull);
    expect(await resolver.lookup(name: 'app', scale: -1), isNull);
  });

  test('malformed indexes and unsafe directory entries are ignored', () async {
    await theme(
      root,
      'main',
      directories: {
        '../../escape': 'Size=24',
        'invalid': 'Size=no',
        'zero': 'Size=24\nScale=0',
        'backwards': 'Size=24\nType=Scalable\nMinSize=30\nMaxSize=10',
      },
    );
    await file('$root/escape/app.png');
    await theme(root, 'hicolor');
    final fallback = await file('$root/hicolor/24/app.png');
    expect((await resolver.lookup(name: 'app'))?.path, fallback);
    await File('$root/main/index.theme').writeAsBytes([255, 254]);
    resolver.clearCache();
    expect((await resolver.lookup(name: 'app'))?.path, fallback);
  });

  test(
    'clearCache invalidates positive and negative results and listings',
    () async {
      await theme(root, 'main');
      expect(await resolver.lookup(name: 'app'), isNull);
      final icon = await file('$root/main/24/app.png');
      expect(await resolver.lookup(name: 'app'), isNull);
      resolver.clearCache();
      expect((await resolver.lookup(name: 'app'))?.path, icon);
      await File(icon).delete();
      expect((await resolver.lookup(name: 'app'))?.path, icon);
      expect(await resolver.listThemes(), ['main']);
      await theme(root, 'another');
      expect(await resolver.listThemes(), ['main']);
      resolver.clearCache();
      expect(await resolver.lookup(name: 'app'), isNull);
      expect(await resolver.listThemes(), ['another', 'main']);
    },
  );

  test('cache differentiates theme and ordered extra paths', () async {
    await theme(root, 'main');
    await theme(root, 'other');
    await file('$root/main/24/app.png');
    final other = await file('$root/other/24/app.png');
    expect((await resolver.lookup(name: 'app', theme: 'other'))?.path, other);
    expect((await resolver.lookup(name: 'app'))?.theme, 'main');
    final a = '${sandbox.path}/a';
    final b = '${sandbox.path}/b';
    await file('$a/app.png');
    await file('$b/app.png');
    expect(
      (await resolver.lookup(name: 'app', extraSearchPaths: [a, b]))?.path,
      '$a/app.png',
    );
    expect(
      (await resolver.lookup(name: 'app', extraSearchPaths: [b, a]))?.path,
      '$b/app.png',
    );
  });

  test('index metadata stays cached across names until clearCache', () async {
    await theme(root, 'main');
    await file('$root/main/24/first.png');
    await file('$root/main/24/second.png');
    expect(
      (await resolver.lookup(name: 'first'))?.path,
      '$root/main/24/first.png',
    );
    await theme(root, 'main', directories: {'48': 'Size=48\nType=Fixed'});
    final updated = await file('$root/main/48/second.png');
    expect(
      (await resolver.lookup(name: 'second'))?.path,
      '$root/main/24/second.png',
    );
    resolver.clearCache();
    expect((await resolver.lookup(name: 'second'))?.path, updated);
  });

  test('old in-flight results do not replace new cache entries', () async {
    await theme(root, 'main');
    await file('$root/main/24/app.png');
    final oldLookup = resolver.lookup(name: 'app');
    final oldListing = resolver.listThemes();
    resolver.clearCache();
    final newLookup = resolver.lookup(name: 'app');
    final newListing = resolver.listThemes();
    expect(identical(oldLookup, newLookup), isFalse);
    expect(identical(oldListing, newListing), isFalse);
    await oldLookup;
    await oldListing;
    await newLookup;
    await newListing;
    expect(identical(resolver.lookup(name: 'app'), newLookup), isTrue);
    expect(identical(resolver.listThemes(), newListing), isTrue);
  });

  test('listThemes deduplicates roots and tolerates broken indexes', () async {
    final second = '$root/second';
    await theme(root, 'main');
    await theme(second, 'main');
    await theme(second, 'hidden');
    await file('$root/broken/index.theme', 'not an index');
    await file('$root/loose.png');
    resolver = IconResolver(searchPaths: ['$root/missing', root, second]);
    expect(await resolver.listThemes(), ['hidden', 'main']);
  });

  test(
    'automatic theme resolves from system loader and selects its icons',
    () async {
      await theme(root, 'main');
      final icon = await file('$root/main/24/app.png');
      resolver = IconResolver(
        searchPaths: [root],
        systemThemeLoader: () async => 'main',
      );
      expect(resolver.theme, isNull);
      expect(await resolver.resolveTheme(), 'main');
      expect((await resolver.lookup(name: 'app'))?.path, icon);
    },
  );

  test(
    'per-query and constructor themes override detection without calling loader',
    () async {
      var calls = 0;
      Future<String?> loader() async {
        calls++;
        return 'detected';
      }

      await theme(root, 'main');
      await theme(root, 'other');
      await file('$root/main/24/app.png');
      final other = await file('$root/other/24/app.png');
      resolver = IconResolver(
        theme: 'main',
        searchPaths: [root],
        systemThemeLoader: loader,
      );
      expect(await resolver.resolveTheme(), 'main');
      expect((await resolver.lookup(name: 'app', theme: 'other'))?.path, other);
      expect((await resolver.lookup(name: 'app'))?.theme, 'main');
      resolver = IconResolver(searchPaths: [root], systemThemeLoader: loader);
      expect((await resolver.lookup(name: 'app', theme: 'other'))?.path, other);
      expect(calls, 0);
    },
  );

  test(
    'missing invalid and failing system detection fall back to hicolor',
    () async {
      for (final value in <String?>[null, '', '../escape', 'bad theme']) {
        resolver = IconResolver(
          searchPaths: [],
          systemThemeLoader: () async => value,
        );
        expect(await resolver.resolveTheme(), 'hicolor');
      }
      resolver = IconResolver(
        searchPaths: [],
        systemThemeLoader: () async => throw StateError('offline'),
      );
      expect(await resolver.resolveTheme(), 'hicolor');
    },
  );

  test(
    'clearCache refreshes system detection and isolates late results',
    () async {
      final pending = <Completer<String?>>[];
      resolver = IconResolver(
        searchPaths: [],
        systemThemeLoader: () {
          final completer = Completer<String?>();
          pending.add(completer);
          return completer.future;
        },
      );
      final old = resolver.resolveTheme();
      expect(identical(old, resolver.resolveTheme()), isTrue);
      resolver.clearCache();
      final current = resolver.resolveTheme();
      expect(pending, hasLength(2));
      pending[1].complete('new');
      expect(await current, 'new');
      pending[0].complete('old');
      expect(await old, 'old');
      expect(await resolver.resolveTheme(), 'new');
      expect(pending, hasLength(2));
    },
  );

  test(
    'Hyprland prefers user GTK4 then GTK3 before system config and commands',
    () async {
      final home = sandbox.path;
      final user = '$home/.config';
      final system = '$home/system';
      await file(
        '$user/gtk-3.0/settings.ini',
        '[Settings]\ngtk-icon-theme-name=User3',
      );
      await file(
        '$system/gtk-4.0/settings.ini',
        '[Settings]\ngtk-icon-theme-name=System4',
      );
      final detector = SystemIconThemeDetector(
        environment: {
          'HOME': home,
          'XDG_CONFIG_DIRS': system,
          'XDG_CURRENT_DESKTOP': 'Hyprland',
        },
        startProcess: (exe, args) async =>
            throw StateError('command must not run'),
      );
      expect(await detector.detect(), 'User3');
      await file(
        '$user/gtk-4.0/settings.ini',
        '[Other]\ngtk-icon-theme-name=Wrong\n[Settings]\ngtk-icon-theme-name=User4',
      );
      expect(await detector.detect(), 'User4');
    },
  );

  test('XDG_CONFIG_HOME and ordered config dirs are honored', () async {
    final custom = sandbox.path;
    await file(
      '$custom/gtk-4.0/settings.ini',
      '[Settings]\ngtk-icon-theme-name=Custom',
    );
    final paths = <String>[];
    final detector = SystemIconThemeDetector(
      environment: {
        'HOME': '/unused',
        'XDG_CONFIG_HOME': custom,
        'XDG_CONFIG_DIRS': '$custom/first:$custom/second',
      },
      readFile: (path) async {
        paths.add(path);
        return File(path).readAsString();
      },
      startProcess: (exe, args) async =>
          throw const ProcessException('gsettings', [], 'missing'),
    );
    expect(await detector.detect(), 'Custom');
    expect(paths.first, '$custom/gtk-4.0/settings.ini');
    await File('$custom/gtk-4.0/settings.ini').delete();
    await file(
      '$custom/second/gtk-4.0/settings.ini',
      '[Settings]\ngtk-icon-theme-name=Second',
    );
    await file(
      '$custom/first/gtk-3.0/settings.ini',
      '[Settings]\ngtk-icon-theme-name=First',
    );
    expect(await detector.detect(), 'First');
  });

  test('KDE prioritizes kdeglobals Icons Theme', () async {
    await file(
      '$root/kdeglobals',
      '[General]\nTheme=Wrong\n[Icons]\nTheme=Breeze',
    );
    await file(
      '$root/gtk-4.0/settings.ini',
      '[Settings]\ngtk-icon-theme-name=GTK',
    );
    final detector = SystemIconThemeDetector(
      environment: {'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_CONFIG_HOME': root},
      startProcess: (exe, args) async =>
          throw StateError('command must not run'),
    );
    expect(await detector.detect(), 'Breeze');
  });

  test(
    'GNOME and Unity prioritize GSettings; Cinnamon selects its schema',
    () async {
      for (final desktop in ['ubuntu:GNOME', 'Unity', 'X-Cinnamon']) {
        final calls = <List<String>>[];
        final detector = SystemIconThemeDetector(
          environment: {'XDG_CURRENT_DESKTOP': desktop},
          readFile: (_) async => '[Settings]\ngtk-icon-theme-name=GTK',
          startProcess: (exe, args) async {
            expect(exe, 'gsettings');
            calls.add(args);
            return _ThemeProcess("'FromCommand'\n");
          },
        );
        expect(await detector.detect(), 'FromCommand');
        expect(calls.single, [
          'get',
          desktop == 'X-Cinnamon'
              ? 'org.cinnamon.desktop.interface'
              : 'org.gnome.desktop.interface',
          'icon-theme',
        ]);
      }
    },
  );

  test(
    'unavailable or failed gsettings falls back to GTK and then null',
    () async {
      for (final unavailable in [true, false]) {
        final detector = SystemIconThemeDetector(
          environment: {
            'XDG_CURRENT_DESKTOP': 'GNOME',
            'XDG_CONFIG_HOME': root,
          },
          readFile: (path) async => path.endsWith('gtk-3.0/settings.ini')
              ? '[Settings]\ngtk-icon-theme-name=Fallback'
              : null,
          startProcess: (exe, args) async {
            if (unavailable)
              throw const ProcessException('gsettings', [], 'missing');
            return _ThemeProcess('', code: 1);
          },
        );
        expect(await detector.detect(), 'Fallback');
      }
      expect(
        await SystemIconThemeDetector(
          environment: {},
          readFile: (_) async => null,
          startProcess: (exe, args) async =>
              throw const ProcessException('gsettings', [], 'missing'),
        ).detect(),
        isNull,
      );
    },
  );

  test('gsettings timeout kills and reaps the process', () async {
    final process = _ThemeProcess('', hanging: true);
    final detector = SystemIconThemeDetector(
      environment: {'XDG_CURRENT_DESKTOP': 'GNOME'},
      readFile: (_) async => null,
      commandTimeout: const Duration(milliseconds: 10),
      startProcess: (exe, args) async => process,
    );
    expect(await detector.detect(), isNull);
    expect(process.killed, isTrue);
    expect(await process.exitCode, -9);
  });

  test('gsettings late startup is killed after timeout', () async {
    final started = Completer<Process>();
    final detector = SystemIconThemeDetector(
      environment: {'XDG_CURRENT_DESKTOP': 'GNOME'},
      readFile: (_) async => null,
      commandTimeout: const Duration(milliseconds: 10),
      startProcess: (exe, args) => started.future,
    );
    expect(await detector.detect(), isNull);
    final process = _ThemeProcess('', hanging: true);
    started.complete(process);
    expect(await process.exitCode, -9);
    expect(process.killed, isTrue);
  });

  test(
    'timeout also covers stdout and stderr remaining open after exit',
    () async {
      for (final stdoutOpen in [true, false]) {
        final stream = StreamController<List<int>>();
        final process = _ThemeProcess(
          "'Theme'",
          outputStream: stdoutOpen ? stream.stream : null,
          errorStream: stdoutOpen ? null : stream.stream,
        );
        final detector = SystemIconThemeDetector(
          environment: {'XDG_CURRENT_DESKTOP': 'GNOME'},
          readFile: (_) async => null,
          commandTimeout: const Duration(milliseconds: 10),
          startProcess: (exe, args) async => process,
        );
        expect(await detector.detect(), isNull);
        expect(process.killed, isTrue);
        await stream.close();
      }
    },
  );

  test(
    'empty current desktop uses session desktop and GVariant quotes are parsed',
    () async {
      for (final output in ["'Theme'", '"Theme"', "'Theme\\'s'"]) {
        final detector = SystemIconThemeDetector(
          environment: {
            'XDG_CURRENT_DESKTOP': '',
            'XDG_SESSION_DESKTOP': 'GNOME',
          },
          readFile: (_) async => '[Settings]\ngtk-icon-theme-name=Wrong',
          startProcess: (exe, args) async => _ThemeProcess(output),
        );
        expect(
          await detector.detect(),
          output.contains('s') ? "Theme's" : 'Theme',
        );
      }
    },
  );
}

class _ThemeProcess implements Process {
  _ThemeProcess(
    String output, {
    int code = 0,
    bool hanging = false,
    Stream<List<int>>? outputStream,
    Stream<List<int>>? errorStream,
  }) : stdout = outputStream ?? Stream.value(utf8.encode(output)),
       stderr = errorStream ?? const Stream.empty() {
    if (!hanging) _exit.complete(code);
  }
  final _exit = Completer<int>();
  bool killed = false;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr;
  @override
  IOSink get stdin => throw UnsupportedError('unused');
  @override
  int get pid => 123;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-9);
    return true;
  }
}
