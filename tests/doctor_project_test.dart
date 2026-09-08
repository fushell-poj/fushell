// Run with the selected Flutter tools' package configuration; no pub resolution.
import 'dart:convert';
import 'dart:io';
import '../src/doctor/project.dart';

void check(bool condition, Object message) {
  if (!condition) throw StateError('$message');
}

void main() {
  final temporary = Directory.systemTemp.createTempSync('fushell-doctor-yaml-');
  try {
    final project = Directory('${temporary.path}/my app')..createSync();
    final flutter = Directory('${temporary.path}/flutter')..createSync();
    Directory('${flutter.path}/packages/flutter').createSync(recursive: true);
    Directory('${project.path}/vendor/fushell/lib').createSync(recursive: true);
    Directory('${project.path}/.dart_tool').createSync();
    final pubspec = File('${project.path}/pubspec.yaml');
    const source = 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n  fushell:\n    path: vendor/fushell\n';
    final sdk = Directory('${project.path}/vendor/fushell');
    File('${sdk.path}/pubspec.yaml').writeAsStringSync('name: fushell\n');
    File('${sdk.path}/lib/fushell.dart').writeAsStringSync('// SDK\n');
    final packages = <String, dynamic>{'configVersion': 2, 'packages': [
      {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
      {'name': 'fushell', 'rootUri': '../vendor/fushell', 'packageUri': 'lib/'},
      {'name': 'flutter', 'rootUri': Directory('${flutter.path}/packages/flutter').uri.toString(), 'packageUri': 'lib/'},
    ]};
    final config = File('${project.path}/.dart_tool/package_config.json');
    void reset() {
      pubspec.writeAsStringSync(source);
      config.writeAsStringSync(jsonEncode(packages));
      final overrides = File('${project.path}/pubspec_overrides.yaml');
      if (overrides.existsSync()) overrides.deleteSync();
    }
    List<Finding> run() => inspectProject(project.path, flutter.path);
    void healthy() { final results = run(); check(results.every((c) => c['status'] == 'ok'), results); }
    void invalid() { final results = run(); check(results.any((c) => c['status'] == 'error'), results); }
    reset(); healthy();
    for (final valid in [
      'name: app\r\ndependencies: {"flutter": {sdk: flutter}, "fushell": {path: vendor/fushell}}\r\n',
      'name: app\ndescription: "Unicode 文本"\ndependencies:\n  flutter: {sdk: flutter}\n  "fushell": {path: vendor/fushell}\n',
    ]) { pubspec.writeAsStringSync(valid); healthy(); }
    for (final invalidSource in [
      'name: app\n# fushell: fake\ndependencies: {flutter: {sdk: flutter}}\n',
      'name: app\ndependencies: {flutter: {sdk: flutter}}\ndev_dependencies: {fushell: any}\n',
      'name: app\ndependencies: [flutter, fushell]\n',
      'name: app\ndependencies: {flutter: any, fushell: any}\n',
      'name: app\ndependencies: {flutter: {sdk: flutter}, fushell: {path: absent}}\n',
      'name: app\ndependencies: {}\ndependencies: {}\n',
    ]) { pubspec.writeAsStringSync(invalidSource); invalid(); }
    reset();
    config.deleteSync();
    check(run().any((c) => c['status'] == 'warning'), 'missing package config must be unresolved, not success');
    reset(); config.writeAsStringSync('{invalid'); invalid();
    config.writeAsStringSync(jsonEncode({'configVersion': 1, 'packages': []})); invalid();
    reset();
    final wrong = Directory('${temporary.path}/other-sdk/lib')..createSync(recursive: true);
    File('${wrong.parent.path}/pubspec.yaml').writeAsStringSync('name: fushell\n');
    File('${wrong.path}/fushell.dart').writeAsStringSync('// other\n');
    final sdkEntry = (packages['packages'] as List)[1] as Map;
    final originalRoot = sdkEntry['rootUri'];
    sdkEntry['rootUri'] = wrong.parent.uri.toString();
    config.writeAsStringSync(jsonEncode(packages)); invalid();
    sdkEntry['rootUri'] = originalRoot;
    reset();
    File('${project.path}/pubspec_overrides.yaml').writeAsStringSync(
        'dependency_overrides:\n  fushell:\n    path: ${jsonEncode(wrong.parent.path)}\n');
    invalid(); // Config still points to the old source.
    sdkEntry['rootUri'] = wrong.parent.uri.toString();
    config.writeAsStringSync(jsonEncode(packages)); healthy();
    sdkEntry['rootUri'] = 'https://example.invalid/package';
    config.writeAsStringSync(jsonEncode(packages)); invalid();
    sdkEntry['rootUri'] = originalRoot;
    reset();
    final flutterEntry = (packages['packages'] as List)[2] as Map;
    final originalFlutter = flutterEntry['rootUri'];
    flutterEntry['rootUri'] = wrong.parent.uri.toString();
    config.writeAsStringSync(jsonEncode(packages)); invalid();
    flutterEntry['rootUri'] = originalFlutter;
    reset();
    // package root URIs are relative to package_config.json, not the project.
    sdkEntry['rootUri'] = 'vendor/fushell';
    config.writeAsStringSync(jsonEncode(packages)); invalid();
    sdkEntry['rootUri'] = originalRoot;
    reset();
    final before = {for (final f in project.listSync(recursive: true).whereType<File>()) f.path: f.readAsBytesSync()};
    healthy();
    final after = {for (final f in project.listSync(recursive: true).whereType<File>()) f.path: f.readAsBytesSync()};
    check(jsonEncode(before) == jsonEncode(after), 'diagnostics must not modify the project');
    print('Doctor YAML, override, URI, stale SDK, malformed metadata and read-only tests passed.');
  } finally { temporary.deleteSync(recursive: true); }
}
