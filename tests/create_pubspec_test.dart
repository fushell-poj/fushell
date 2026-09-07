// Uses the initialized Flutter tools YAML dependency; no additional pub get.
import 'dart:convert';
import 'package:yaml/yaml.dart';
import '../src/project_templates/configure.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  const fixtures = [
    'name: app\nenvironment:\n  sdk: ^3.11.0\n# keep this comment\ndependencies:\n  flutter:\n    sdk: flutter\n  http: ^1.0.0\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n',
    'name: app\r\ndependencies:\r\n    flutter:\r\n        sdk: flutter\r\nflutter:\r\n  uses-material-design: true\r\n',
    'name: app\ndescription: "Unicode 文本"\n"dependencies": {flutter: {sdk: flutter}} # retained\n',
    'name: app\ndependencies: {}\n',
    'name: app\ndependencies:\n   # before dependency\n   "flutter":\n     sdk: flutter\n\nflutter:\n  assets: [assets/a.txt]\n',
  ];
  for (final before in fixtures) {
    final after = configurePubspec(before, 'app');
    final parsed = loadYaml(after) as YamlMap;
    check(parsed['dependencies']['fushell']['path'] == 'vendor/fushell', after);
    check(parsed['name'] == 'app', after);
    if (before.contains('# keep this comment')) check(after.contains('# keep this comment'), after);
    if (before.contains('# retained')) check(after.contains('# retained'), after);
  }
  for (final input in [
    'name: other\ndependencies: {}\n',
    'name: app\ndependencies: [flutter]\n',
    'name: app\ndependencies: {fushell: any}\n',
    'name: app\ndependencies: {}\ndependencies: {}\n',
  ]) {
    var rejected = false;
    try { configurePubspec(input, 'app'); } on Object { rejected = true; }
    check(rejected, 'Expected rejection: $input');
  }
  final ignore = configureGitignore('# custom\n/build/\n');
  check(ignore.contains('# custom'), ignore);
  check(ignore.split('/build/').length == 2, ignore);
  check(ignore.contains('/linux/flutter/ephemeral/'), ignore);
  check(ignore.contains('/linux/flutter/generated_plugin_registrant.*'), ignore);
  check(ignore == configureGitignore(ignore), 'Ignore update is not idempotent');
  check(!ignore.contains('vendor/') && !ignore.contains('pubspec.lock'), ignore);
  check(jsonDecode(dartString('quotes " newline\n').replaceAll(r'\$', r'$')) == 'quotes " newline\n', 'Escaping');
  check(dartString(r'a$variable').contains(r'\$'), 'Dart interpolation must be escaped');
  print('Pubspec AST, template escaping and gitignore tests passed.');
}
