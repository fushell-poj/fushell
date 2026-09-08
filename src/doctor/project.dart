// Executed with the selected Flutter tools' package_config.json. This program
// reads project metadata only: it never runs project Dart, pub, hooks or builds.
import 'dart:convert';
import 'dart:io';
import 'package:yaml/yaml.dart';

typedef Finding = Map<String, Object?>;

Finding finding(String id, String status, String summary,
        {List<String> details = const [], String? remedy}) =>
    {'id': id, 'title': 'Project dependencies', 'status': status,
     'summary': summary, 'details': details, 'remedy': remedy};

class InvalidMetadata implements Exception {
  const InvalidMetadata(this.message);
  final String message;
}

String readText(File file, {int limit = 1024 * 1024}) {
  final stat = file.statSync();
  if (stat.type != FileSystemEntityType.file || stat.size > limit) {
    throw const InvalidMetadata('Expected a regular metadata file within the size limit');
  }
  return file.readAsStringSync();
}

Map<Object?, Object?> yamlMap(File file) {
  try {
    final value = loadYaml(readText(file));
    if (value is! Map) throw const InvalidMetadata('Expected a YAML mapping');
    return Map<Object?, Object?>.from(value);
  } on YamlException {
    // A parser exception can embed secret file contents. Do not echo it.
    throw const InvalidMetadata('YAML syntax is invalid (including duplicate keys)');
  }
}

Map<Object?, Object?> optionalMap(Object? value) {
  if (value == null) return {};
  if (value is! Map) throw const InvalidMetadata('Expected a dependency mapping');
  return Map<Object?, Object?>.from(value);
}

Directory resolvedDirectory(Directory base, String path) {
  final directory = Directory.fromUri(base.uri.resolveUri(Uri.directory(path)));
  return Directory(directory.resolveSymbolicLinksSync());
}

Uri localUri(Uri base, String value) {
  final result = base.resolve(value);
  if (result.scheme != 'file' || result.hasQuery || result.hasFragment ||
      (result.host.isNotEmpty && result.host != 'localhost')) {
    throw const InvalidMetadata('Package configuration must use local file URIs');
  }
  return result;
}

Directory packageRoot(File config, Map<String, Object?> package) {
  final value = package['rootUri'];
  if (value is! String || value.isEmpty) {
    throw const InvalidMetadata('A package rootUri is missing or invalid');
  }
  final uri = localUri(config.uri, value);
  return Directory(Directory.fromUri(uri).resolveSymbolicLinksSync());
}

void validateFushellPackage(Directory root, {String packageUri = 'lib/'}) {
  if (yamlMap(File('${root.path}/pubspec.yaml'))['name'] != 'fushell') {
    throw const InvalidMetadata('The resolved SDK is not a package named fushell');
  }
  final lib = localUri(root.uri, packageUri);
  if (!lib.path.endsWith('/')) {
    throw const InvalidMetadata('The packageUri must identify a directory');
  }
  readText(File.fromUri(lib.resolve('fushell.dart')), limit: 4 * 1024 * 1024);
}

/// Purely read-only inspection, also used directly by the fixture tests.
List<Finding> inspectProject(String input, String flutterRoot) {
  final results = <Finding>[];
  const retry = 'Run flutter pub get with the selected Flutter SDK in this project.';
  try {
    final project = Directory(Directory(input).resolveSymbolicLinksSync());
    final pubspec = yamlMap(File('${project.path}/pubspec.yaml'));
    final name = pubspec['name'];
    if (name is! String || name.isEmpty) {
      throw const InvalidMetadata('pubspec.yaml has no valid package name');
    }
    final dependencies = optionalMap(pubspec['dependencies']);
    final flutter = dependencies['flutter'];
    if (flutter is! Map || flutter['sdk'] != 'flutter') {
      throw const InvalidMetadata('dependencies.flutter must select sdk: flutter');
    }
    if (!dependencies.containsKey('fushell')) {
      throw const InvalidMetadata('dependencies does not declare fushell (comments and dev_dependencies do not count)');
    }
    var dependency = dependencies['fushell'];
    final overrides = optionalMap(pubspec['dependency_overrides']);
    if (overrides.containsKey('fushell')) dependency = overrides['fushell'];
    final overrideFile = File('${project.path}/pubspec_overrides.yaml');
    if (overrideFile.existsSync()) {
      final overrides = optionalMap(yamlMap(overrideFile)['dependency_overrides']);
      if (overrides.containsKey('fushell')) dependency = overrides['fushell'];
    }
    Directory? expected;
    if (dependency is Map && dependency.containsKey('path')) {
      final path = dependency['path'];
      if (path is! String || path.isEmpty || dependency.containsKey('git') ||
          dependency.containsKey('hosted') || dependency.containsKey('sdk')) {
        throw const InvalidMetadata('The effective fushell path dependency is invalid');
      }
      expected = resolvedDirectory(project, path);
      validateFushellPackage(expected);
    } else if (dependency != null && dependency is! String && dependency is! Map) {
      throw const InvalidMetadata('The fushell dependency has an invalid type');
    }
    results.add(finding('project.pubspec', 'ok', 'Flutter and Fushell dependencies are declared',
        details: ['package: $name', if (expected != null) 'effective SDK path: ${expected.path}']));

    // Dart workspaces may share package_config.json in a parent directory.
    var search = project;
    File? config;
    while (true) {
      final candidate = File('${search.path}/.dart_tool/package_config.json');
      if (candidate.existsSync()) { config = candidate; break; }
      final parent = search.parent;
      if (parent.path == search.path) break;
      search = parent;
    }
    if (config == null) {
      results.add(finding('project.packages', 'warning', 'Dart dependencies have not been resolved', remedy: retry));
      return results;
    }
    final Object? document;
    try { document = jsonDecode(readText(config, limit: 4 * 1024 * 1024)); }
    on FormatException { throw const InvalidMetadata('package_config.json is not valid JSON'); }
    if (document is! Map || document['configVersion'] != 2 || document['packages'] is! List) {
      throw const InvalidMetadata('Expected package_config.json schema version 2');
    }
    final packages = <String, Map<String, Object?>>{};
    for (final item in document['packages'] as List) {
      if (item is! Map || item['name'] is! String || packages.containsKey(item['name'])) {
        throw const InvalidMetadata('Invalid or duplicate package name in package_config.json');
      }
      packages[item['name'] as String] = Map<String, Object?>.from(item);
    }
    final self = packages[name];
    if (self == null || packageRoot(config, self).path != project.path) {
      results.add(finding('project.packages', 'warning', 'The discovered package configuration does not describe this project', remedy: retry));
      return results;
    }
    final sdk = packages['fushell'];
    final resolvedFlutter = packages['flutter'];
    if (sdk == null || resolvedFlutter == null) {
      throw const InvalidMetadata('Resolved packages do not include both flutter and fushell');
    }
    final root = packageRoot(config, sdk);
    final packageUri = sdk['packageUri'] ?? 'lib/';
    if (packageUri is! String) throw const InvalidMetadata('Invalid fushell packageUri');
    validateFushellPackage(root, packageUri: packageUri);
    if (expected != null && root.path != expected.path) {
      throw const InvalidMetadata('Resolved fushell root differs from the effective path dependency; package configuration is stale');
    }
    final selectedFlutter = Directory('$flutterRoot/packages/flutter').resolveSymbolicLinksSync();
    if (packageRoot(config, resolvedFlutter).path != selectedFlutter) {
      throw const InvalidMetadata('Resolved flutter package belongs to another Flutter SDK');
    }
    results.add(finding('project.packages', 'ok', 'Resolved Fushell package and Flutter SDK paths are consistent',
        details: ['SDK package: ${root.path}', 'package configuration: ${config.path}']));
  } on InvalidMetadata catch (error) {
    results.add(finding('project.dependencies', 'error', error.message, remedy: retry));
  } on FileSystemException {
    results.add(finding('project.dependencies', 'error', 'A required metadata file or SDK directory is missing or unreadable',
        remedy: 'Check the effective SDK dependency path and metadata permissions, then run flutter pub get.'));
  } on FormatException {
    results.add(finding('project.dependencies', 'error', 'Metadata contains invalid UTF-8 or a malformed file URI', remedy: retry));
  }
  return results;
}

void main(List<String> args) {
  if (args.length != 2) { stderr.writeln('Expected project and selected Flutter SDK directories.'); exitCode = 2; return; }
  stdout.writeln(jsonEncode({'schemaVersion': 1, 'checks': inspectProject(args[0], args[1])}));
}
