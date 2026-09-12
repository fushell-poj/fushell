import 'dart:convert';
import 'dart:io';
import 'package:xml/xml.dart';

const selected = [
  'wl_display',
  'wl_registry',
  'wl_callback',
  'wl_output',
  'ext_workspace_manager_v1',
  'ext_workspace_group_handle_v1',
  'ext_workspace_handle_v1',
];
String attr(XmlElement node, String name) =>
    node.getAttribute(name) ?? (throw FormatException('Missing $name'));
String pascal(String name) =>
    name.split('_').map((p) => '${p[0].toUpperCase()}${p.substring(1)}').join();
String identifier(String name) {
  final p = pascal(name);
  final value = '${p[0].toLowerCase()}${p.substring(1)}';
  return {'interface', 'class', 'switch', 'default'}.contains(value)
      ? '${value}Value'
      : value;
}

String quote(String value) => jsonEncode(value);
List<XmlElement> arguments(XmlElement message) {
  final result = <XmlElement>[];
  for (final arg in message.findElements('arg')) {
    if (attr(arg, 'type') == 'new_id' &&
        arg.getAttribute('interface') == null) {
      final name = attr(arg, 'name');
      result.add(
        XmlDocument.parse(
          '<arg name="${name}_interface" type="string"/>',
        ).rootElement,
      );
      result.add(
        XmlDocument.parse(
          '<arg name="${name}_version" type="uint"/>',
        ).rootElement,
      );
    }
    result.add(arg);
  }
  return result;
}

String dartType(XmlElement arg) {
  final type = switch (attr(arg, 'type')) {
    'string' => 'String',
    'array' => 'List<int>',
    'int' || 'uint' || 'fixed' || 'object' || 'new_id' => 'int',
    final other => throw FormatException('Unsupported argument type $other'),
  };
  return arg.getAttribute('allow-null') == 'true' ? '$type?' : type;
}

String generate(List<XmlElement> interfaces, List<String> copyrights) {
  final out = StringBuffer(
    '// GENERATED FILE. DO NOT EDIT.\n// Run: dart run tool/workspace/generate.dart\n// Provenance: protocols/README.md\n',
  );
  for (final copyright in copyrights) {
    for (final line in copyright.split('\n')) {
      out.writeln('// $line'.trimRight());
    }
  }
  out.writeln('''

class WireArg {
  const WireArg(this.name, this.type, {this.interfaceName, this.nullable = false});
  final String name;
  final String type;
  final String? interfaceName;
  final bool nullable;
}
class WireMessage {
  const WireMessage(this.name, this.opcode, this.since, this.args, {this.destructor = false});
  final String name;
  final int opcode;
  final int since;
  final List<WireArg> args;
  final bool destructor;
}
class WireInterface {
  const WireInterface(this.name, this.version, this.requests, this.events);
  final String name;
  final int version;
  final List<WireMessage> requests;
  final List<WireMessage> events;
}
/// A sender bound to one runtime object. It resolves requests by XML name.
typedef WireRequestSender = void Function(String name, List<Object?> args);
const Map<String, WireInterface> wireInterfaces = {
''');
  for (final interface in interfaces) {
    final name = attr(interface, 'name');
    final version = int.parse(attr(interface, 'version'));
    out.writeln('  ${quote(name)}: WireInterface(${quote(name)}, $version, [');
    for (final direction in ['request', 'event']) {
      var opcode = 0;
      for (final message in interface.findElements(direction)) {
        final since = int.parse(message.getAttribute('since') ?? '1');
        if (since < 1 || since > version) {
          throw FormatException('Invalid since');
        }
        out.writeln(
          '    WireMessage(${quote(attr(message, 'name'))}, $opcode, $since, [',
        );
        opcode++;
        for (final arg in arguments(message)) {
          dartType(arg);
          final target = arg.getAttribute('interface');
          if (target != null && !selected.contains(target)) {
            throw FormatException('Unsupported interface reference $target');
          }
          final nullable = arg.getAttribute('allow-null') == 'true';
          out.writeln(
            '      WireArg(${quote(attr(arg, 'name'))}, ${quote(attr(arg, 'type'))}, '
            'interfaceName: ${target == null ? 'null' : quote(target)}, nullable: $nullable),',
          );
        }
        final destructor = message.getAttribute('type') == 'destructor';
        out.writeln('    ], destructor: $destructor),');
      }
      out.writeln(direction == 'request' ? '  ], [' : '  ]),');
    }
  }
  out.writeln('};');
  for (final interface in interfaces) {
    final prefix = pascal(attr(interface, 'name'));
    for (final enumeration in interface.findElements('enum')) {
      final className = '$prefix${pascal(attr(enumeration, 'name'))}';
      out.writeln('\nabstract final class $className {');
      for (final entry in enumeration.findElements('entry')) {
        final rawName = attr(entry, 'name');
        final name = identifier(
          RegExp(r'^[0-9]').hasMatch(rawName) ? 'value_$rawName' : rawName,
        );
        final value = int.parse(attr(entry, 'value'));
        out.writeln('  static const int $name = $value;');
      }
      out.writeln('}');
    }
    final requests = interface.findElements('request').toList();
    if (requests.isNotEmpty) {
      out.writeln('\nclass ${prefix}Requests {');
      out.writeln('  const ${prefix}Requests(this.send);');
      out.writeln('  final WireRequestSender send;');
      for (final request in requests) {
        final name = attr(request, 'name');
        final args = arguments(request);
        final parameters = args
            .map((arg) => '${dartType(arg)} ${identifier(attr(arg, 'name'))}')
            .join(', ');
        final values = args
            .map((arg) => identifier(attr(arg, 'name')))
            .join(', ');
        out.writeln(
          '  void ${identifier(name)}($parameters) => send(${quote(name)}, [$values]);',
        );
      }
      out.writeln('}');
    }
    for (final event in interface.findElements('event')) {
      final name = '$prefix${pascal(attr(event, 'name'))}Event';
      final args = arguments(event);
      final fields = args.map((arg) => identifier(attr(arg, 'name'))).toList();
      out.writeln('\nclass $name {');
      out.writeln(
        '  const $name(${fields.map((field) => 'this.$field').join(', ')});',
      );
      out.writeln('  factory $name.fromList(List<Object?> args) {');
      final count = args.length;
      final condition = count == 0
          ? 'args.isNotEmpty'
          : 'args.length != $count';
      out.writeln('    if ($condition) {');
      out.writeln(
        '      throw ArgumentError("Expected $count arguments for $name");',
      );
      out.writeln('    }');
      final values = List.generate(
        count,
        (i) => 'args[$i] as ${dartType(args[i])}',
      ).join(', ');
      out.writeln('    return $name($values);');
      out.writeln('  }');
      for (var i = 0; i < count; i++) {
        out.writeln('  final ${dartType(args[i])} ${fields[i]};');
      }
      out.writeln('}');
    }
  }
  return out.toString();
}

void main(List<String> args) {
  if (args.length > 1 || args.any((arg) => arg != '--check')) {
    stderr.writeln('Usage: dart run tool/workspace/generate.dart [--check]');
    exitCode = 64;
    return;
  }
  final package = File.fromUri(Platform.script).parent.parent.parent;
  final found = <String, XmlElement>{};
  final copyrights = <String>[];
  for (final source in ['wayland.xml', 'ext-workspace-v1.xml']) {
    final document = XmlDocument.parse(
      File('${package.path}/protocols/$source').readAsStringSync(),
    );
    copyrights.add(document.rootElement.getElement('copyright')!.innerText);
    for (final interface in document.rootElement.findElements('interface')) {
      final name = attr(interface, 'name');
      if (found.containsKey(name)) {
        throw FormatException('Duplicate interface: $name');
      }
      found[name] = interface;
    }
  }
  final interfaces = selected
      .map(
        (name) =>
            found[name] ?? (throw FormatException('Missing interface: $name')),
      )
      .toList();
  final output = generate(interfaces, copyrights);
  final target = File('${package.path}/lib/src/workspace/protocol.dart');
  if (args.contains('--check')) {
    if (!target.existsSync() || target.readAsStringSync() != output) {
      stderr.writeln(
        'Generated protocol.dart is stale. Run dart run tool/workspace/generate.dart',
      );
      exitCode = 1;
    } else {
      stdout.writeln('Generated protocol.dart is current.');
    }
  } else {
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(output);
    stdout.writeln('Generated protocol.dart (7 interfaces).');
  }
}
