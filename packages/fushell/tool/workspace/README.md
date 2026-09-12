# Workspace protocol generator

From `packages/fushell`:

```sh
flutter pub get --offline
dart run tool/workspace/generate.dart
dart run tool/workspace/generate.dart --check
dart run tool/workspace/generate_test.dart
dart analyze tool/workspace lib/src/workspace/protocol.dart
```

Generation uses the XML dev dependency and only the vendored snapshots. Output order is fixed; opcodes follow XML request/event order independently, since defaults to 1, and destructor, interface and nullable metadata come from XML. `--check` compares exact output and exits 1 for missing or stale output without modifying it; invalid options exit 64. Paths are resolved relative to the generator script, not the working directory. Output intentionally uses generator-controlled formatting; do not separately format generated code.

The generated file defines `WireArg(name, type, {interfaceName, nullable = false})`, `WireMessage(name, opcode, since, args, {destructor = false})`, `WireInterface(name, version, requests, events)` and `const Map<String, WireInterface> wireInterfaces`. XML types are retained as strings. Dynamic `new_id` expands to `<name>_interface` (string), `<name>_version` (uint), then `<name>` (new_id); thus registry bind has four arguments in total. Object references, new IDs and raw signed 24.8 fixed values are Dart int; arrays are byte lists (`List<int>`), not decoded coordinate lists. The codec owns byte order, validation, object lifetimes and negotiated versions.

Request exports use `<PascalInterface>Requests`, with a `WireRequestSender` constructor parameter (`void Function(String name, List<Object?> args)`). Methods use camelCase XML names and delegate by original XML request name. `WlRegistryRequests.bind(int name, String idInterface, int idVersion, int id)` sends all four flat values. No callback request class is generated because wl_callback has no requests.

Event exports use `<PascalInterface><PascalEvent>Event`, with positional const constructors and `.fromList(List<Object?> args)` factories that validate arity and cast field types. Field names are camelCase; the registry global interface field is `interfaceValue` to avoid a Dart keyword. For example: `ExtWorkspaceManagerV1WorkspaceEvent.fromList(args).workspace` and `ExtWorkspaceHandleV1StateEvent.fromList(args).state`.

Generated prefixes: `WlDisplay`, `WlRegistry`, `WlCallback`, `WlOutput`, `ExtWorkspaceManagerV1`, `ExtWorkspaceGroupHandleV1`, `ExtWorkspaceHandleV1`. All declarations are public in protocol.dart; the package public facade controls its own exports.

Enums and bitfields use `<PascalInterface><PascalEnum>` abstract final classes with `static const int camelCaseEntry` values. Numeric entry names gain a `value` prefix. Examples: `ExtWorkspaceHandleV1State.active`, `ExtWorkspaceHandleV1WorkspaceCapabilities.activate`, `ExtWorkspaceGroupHandleV1GroupCapabilities.createWorkspace`, `WlOutputTransform.value90`.
