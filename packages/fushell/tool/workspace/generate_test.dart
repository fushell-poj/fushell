import 'dart:io';
import 'package:xml/xml.dart';
import 'package:fushell/src/workspace/protocol.dart';
import 'generate.dart' as generator;

void check(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

void main() {
  check(
    wireInterfaces.keys.join(',') == generator.selected.join(','),
    'Exactly seven interfaces in fixed order',
  );
  final bind = wireInterfaces['wl_registry']!.requests.single;
  check(
    bind.args.map((arg) => arg.type).join(',') == 'uint,string,uint,new_id',
    'Dynamic bind expansion',
  );
  final output = wireInterfaces['wl_output']!;
  check(
    output.version == 4 &&
        output.requests.single.since == 3 &&
        output.requests.single.destructor,
    'Output release metadata',
  );
  check(
    output.events.map((event) => event.since).join(',') == '1,1,2,2,4,4',
    'Output event versions',
  );
  check(
    wireInterfaces['wl_callback']!.events.single.destructor,
    'Callback destructor event',
  );
  check(
    wireInterfaces['ext_workspace_handle_v1']!.events
            .singleWhere((event) => event.name == 'state')
            .args
            .single
            .type ==
        'uint',
    'Workspace state is uint bitfield',
  );
  String? sentName;
  List<Object?>? sentArgs;
  WlRegistryRequests((name, args) {
    sentName = name;
    sentArgs = args;
  }).bind(4, 'wl_output', 4, 12);
  check(
    sentName == 'bind' && sentArgs!.join(',') == '4,wl_output,4,12',
    'Typed request delegates original name and ordered args',
  );
  final event = WlRegistryGlobalEvent.fromList([4, 'wl_output', 4]);
  check(
    event.name == 4 &&
        event.interfaceValue == 'wl_output' &&
        event.version == 4,
    'Typed event fields',
  );
  var rejected = false;
  try {
    WlCallbackDoneEvent.fromList([]);
  } on ArgumentError {
    rejected = true;
  }
  check(rejected, 'Typed event rejects wrong arity');
  for (final direction in ['request', 'event']) {
    for (final declaration in [
      '<arg name="handle" type="fd"/>',
      '<arg name="surface" type="object" interface="wl_surface"/>',
      '<arg name="surface" type="new_id" interface="wl_surface"/>',
    ]) {
      final unsupported = XmlDocument.parse(
        '<interface name="sample" version="1"><$direction name="unsupported">$declaration</$direction></interface>',
      ).rootElement;
      var failed = false;
      try {
        generator.generate([unsupported], []);
      } on FormatException catch (error) {
        failed = error.message.contains('Unsupported');
      }
      check(failed, 'Reject unsupported $direction argument $declaration');
    }
  }
  final fixture = XmlDocument.parse(
    '<interface name="sample" version="3"><request name="destroy" since="2" type="destructor"><arg name="target" type="object" interface="wl_output" allow-null="true"/></request><event name="done"/><event name="next" since="3"/></interface>',
  ).rootElement;
  final generated = generator.generate([fixture], ['Copyright test']);
  check(
    generated.contains('if (args.isNotEmpty) {') &&
        !generated.contains('args.length != 0'),
    'Zero-argument event guards use isNotEmpty',
  );
  check(
    generated.contains('nullable: true') &&
        generated.contains('interfaceName: "wl_output"'),
    'Nullable object metadata',
  );
  check(
    generated.contains('WireMessage("destroy", 0, 2') &&
        generated.contains('destructor: true'),
    'Request metadata',
  );
  check(
    generated.contains('WireMessage("done", 0, 1') &&
        generated.contains('WireMessage("next", 1, 3'),
    'Independent event opcodes and since default',
  );
  check(generated.contains('// Copyright test'), 'Copyright preservation');
  check(
    generated == generator.generate([fixture], ['Copyright test']),
    'Deterministic output',
  );
  final script = File.fromUri(
    Platform.script,
  ).parent.uri.resolve('generate.dart').toFilePath();
  final result = Process.runSync(Platform.resolvedExecutable, [
    script,
    '--check',
  ]);
  check(result.exitCode == 0, 'Committed output is current: ${result.stderr}');
  check(
    ExtWorkspaceHandleV1State.active == 1 &&
        ExtWorkspaceHandleV1State.urgent == 2 &&
        ExtWorkspaceHandleV1State.hidden == 4,
    'Generated state bitfields',
  );
  check(
    ExtWorkspaceHandleV1WorkspaceCapabilities.assign == 8 &&
        ExtWorkspaceGroupHandleV1GroupCapabilities.createWorkspace == 1 &&
        WlOutputTransform.value90 == 1,
    'Generated enum names and values',
  );
  final package = File(script).parent.parent.parent;
  final scratch = File(script).parent.createTempSync('.generator-test-');
  try {
    final copied = File('${scratch.path}/tool/workspace/generate.dart');
    copied.parent.createSync(recursive: true);
    File(script).copySync(copied.path);
    Directory('${scratch.path}/protocols').createSync();
    for (final source in ['wayland.xml', 'ext-workspace-v1.xml']) {
      File(
        '${package.path}/protocols/$source',
      ).copySync('${scratch.path}/protocols/$source');
    }
    ProcessResult run(List<String> args) =>
        Process.runSync(Platform.resolvedExecutable, [
          '--packages=${package.path}/.dart_tool/package_config.json',
          copied.path,
          ...args,
        ]);
    check(run(['--check']).exitCode == 1, 'Check rejects missing output');
    check(run([]).exitCode == 0, 'Generate missing output');
    check(run(['--check']).exitCode == 0, 'Check accepts generated output');
    final target = File('${scratch.path}/lib/src/workspace/protocol.dart');
    target.writeAsStringSync('// stale');
    check(run(['--check']).exitCode == 1, 'Check rejects stale output');
    check(
      target.readAsStringSync() == '// stale',
      'Check never rewrites output',
    );
    check(run(['--invalid']).exitCode == 64, 'Reject unknown options');
  } finally {
    scratch.deleteSync(recursive: true);
  }
  stdout.writeln('Generator and typed binding checks passed.');
}
