// Run with the selected Flutter SDK's flutter_tools package configuration.
// yaml is already installed by Flutter; this helper never runs pub or fetches
// a package. AST spans preserve the SDK's pubspec outside the dependency edit.
import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Add one relative SDK dependency without replacing Flutter's SDK constraints,
/// metadata, comments outside the edited node, or unrelated dependencies.
String configurePubspec(String source, String name) {
  final root = loadYamlNode(source);
  if (root is! YamlMap || root['name'] != name) {
    throw const FormatException('Unexpected Flutter pubspec project name');
  }
  final dependencies = root.nodes['dependencies'];
  if (dependencies is! YamlMap || dependencies.containsKey('fushell')) {
    throw const FormatException('Expected dependencies map without fushell');
  }
  const addition = {'path': 'vendor/fushell'};
  final String changed;
  final newline = source.contains('\r\n') ? '\r\n' : '\n';
  if (dependencies.span.text.trimLeft().startsWith('{')) {
    // JSON is a valid YAML flow mapping. Only this node is rewritten.
    changed = source.replaceRange(
      dependencies.span.start.offset,
      dependencies.span.end.offset,
      jsonEncode({...dependencies, 'fushell': addition}),
    );
  } else if (dependencies.nodes.isNotEmpty) {
    final firstKey = dependencies.nodes.keys.first;
    final column = firstKey.span.start.column;
    final start = firstKey.span.start.offset - column;
    if (column < 1 || source.substring(start, start + column).trim().isNotEmpty) {
      throw const FormatException('Unsupported dependencies layout');
    }
    final indent = ' ' * column;
    changed = source.replaceRange(
      start,
      start,
      '${indent}fushell:$newline$indent  path: vendor/fushell$newline',
    );
  } else {
    throw const FormatException('Unsupported empty dependencies layout');
  }
  final verified = loadYaml(changed);
  if (verified is! YamlMap ||
      verified['dependencies'] is! YamlMap ||
      verified['dependencies']['fushell']['path'] != 'vendor/fushell') {
    throw const FormatException('Fushell dependency edit did not validate');
  }
  // Verify semantic preservation too, not just syntactic validity.
  final expected = Map<Object?, Object?>.from(root);
  expected['dependencies'] = {...dependencies, 'fushell': addition};
  if (!_equalYaml(expected, verified)) {
    throw const FormatException('Dependency edit changed unrelated YAML values');
  }
  return changed;
}

bool _equalYaml(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _equalYaml(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _equalYaml(a[i], b[i]));
  }
  return a == b;
}

/// Keep Flutter's ignore file. Add narrowly scoped generated-file patterns,
/// never ignore vendor/fushell, pubspec.lock, metadata or application config.
String configureGitignore(String source) {
  const rules = [
    '.dart_tool/',
    '.flutter-plugins-dependencies',
    '/build/',
    '/coverage/',
    '/linux/flutter/ephemeral/',
    '/linux/flutter/generated_plugin_registrant.*',
    '/linux/flutter/generated_plugins.cmake',
  ];
  final present = const LineSplitter().convert(source).map((l) => l.trim()).toSet();
  final missing = rules.where((rule) => !present.contains(rule)).toList();
  if (missing.isEmpty) return source;
  final newline = source.contains('\r\n') ? '\r\n' : '\n';
  final prefix = source.isEmpty || source.endsWith('\n') ? source : '$source$newline';
  return '$prefix$newline# Fushell / Flutter generated files$newline'
      '${missing.join(newline)}$newline';
}

String dartString(String text) => jsonEncode(text).replaceAll(r'$', r'\$');

void main(List<String> arguments) {
  try {
    if (arguments.length != 1) throw const FormatException('Expected project directory');
    final project = Directory(arguments.single);
    final templates = File.fromUri(Platform.script).parent;
    final request = jsonDecode(File('${templates.path}/request.json').readAsStringSync()) as Map<String, dynamic>;
    final name = request['name'] as String;
    final id = request['applicationId'] as String;
    final single = request['single'] as bool;
    final pubspec = File('${project.path}/pubspec.yaml');
    final modified = configurePubspec(pubspec.readAsStringSync(), name);
    final mainTemplate = File('${templates.path}/main.dart.tmpl').readAsStringSync();
    const ordinaryStartup = '  await openMainWindow();';
    const singleStartup = '''  await FushellApplication.run(
    onCommand: (invocation) async {
      final arguments = invocation.textArguments;
      if (arguments.isEmpty) {
        await openMainWindow();
        return FushellCommandResult();
      }
      if (arguments.length == 1 && arguments.single == 'quit') {
        await FushellProcess.exit();
        return FushellCommandResult();
      }
      await invocation.output.writeStderrText('Usage: application [quit]\\n');
      return FushellCommandResult(exitCode: 64);
    },
  );''';
    final mainSource = mainTemplate
        .replaceAll('@@STARTUP@@', single ? singleStartup : ordinaryStartup)
        .replaceAll('@@APPLICATION_ID@@', dartString(id))
        .replaceAll('@@TITLE@@', dartString(name));
    // Delete only the official host generated in this private fresh scaffold.
    final linux = Directory('${project.path}/linux');
    final kind = FileSystemEntity.typeSync(linux.path, followLinks: false);
    if (kind == FileSystemEntityType.directory) {
      linux.deleteSync(recursive: true);
    } else if (kind != FileSystemEntityType.notFound) {
      throw const FormatException('Expected generated linux directory, not a link or file');
    }
    pubspec.writeAsStringSync(modified);
    File('${project.path}/lib/main.dart').writeAsStringSync(mainSource);
    File('${templates.path}/app.dart').copySync('${project.path}/lib/app.dart');
    Directory('${project.path}/test').createSync(recursive: true);
    File('${project.path}/test/widget_test.dart').writeAsStringSync(
      File('${templates.path}/widget_test.dart.tmpl').readAsStringSync().replaceAll('@@PROJECT_NAME@@', name),
    );
    File('${project.path}/fushell.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'schemaVersion': 1, 'applicationId': id, 'instance': single ? 'single' : 'multiple'})}\n',
    );
    final ignore = File('${project.path}/.gitignore');
    ignore.writeAsStringSync(configureGitignore(ignore.existsSync() ? ignore.readAsStringSync() : ''));
    File('${project.path}/README.md').writeAsStringSync(
      File('${templates.path}/README.md.tmpl').readAsStringSync()
          .replaceAll('@@PROJECT_NAME@@', name)
          .replaceAll('@@INSTANCE@@', single ? 'single' : 'multiple'),
    );
  } on Object catch (error) {
    stderr.writeln('Failed to configure the staged Fushell project: $error');
    exitCode = 1;
  }
}
