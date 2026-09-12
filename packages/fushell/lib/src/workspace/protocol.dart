// GENERATED FILE. DO NOT EDIT.
// Run: dart run tool/workspace/generate.dart
// Provenance: protocols/README.md
//
//     Copyright © 2008-2011 Kristian Høgsberg
//     Copyright © 2010-2011 Intel Corporation
//     Copyright © 2012-2013 Collabora, Ltd.
//
//     Permission is hereby granted, free of charge, to any person
//     obtaining a copy of this software and associated documentation files
//     (the "Software"), to deal in the Software without restriction,
//     including without limitation the rights to use, copy, modify, merge,
//     publish, distribute, sublicense, and/or sell copies of the Software,
//     and to permit persons to whom the Software is furnished to do so,
//     subject to the following conditions:
//
//     The above copyright notice and this permission notice (including the
//     next paragraph) shall be included in all copies or substantial
//     portions of the Software.
//
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//     EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//     MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//     NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
//     BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
//     ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
//     CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//     SOFTWARE.
//
//
//     Copyright © 2019 Christopher Billington
//     Copyright © 2020 Ilia Bozhinov
//     Copyright © 2022 Victoria Brekenfeld
//
//     Permission to use, copy, modify, distribute, and sell this
//     software and its documentation for any purpose is hereby granted
//     without fee, provided that the above copyright notice appear in
//     all copies and that both that copyright notice and this permission
//     notice appear in supporting documentation, and that the name of
//     the copyright holders not be used in advertising or publicity
//     pertaining to distribution of the software without specific,
//     written prior permission.  The copyright holders make no
//     representations about the suitability of this software for any
//     purpose.  It is provided "as is" without express or implied
//     warranty.
//
//     THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
//     SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
//     FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
//     SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//     WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
//     AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
//     ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
//     THIS SOFTWARE.
//

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

  "wl_display": WireInterface("wl_display", 1, [
    WireMessage("sync", 0, 1, [
      WireArg("callback", "new_id", interfaceName: "wl_callback", nullable: false),
    ], destructor: false),
    WireMessage("get_registry", 1, 1, [
      WireArg("registry", "new_id", interfaceName: "wl_registry", nullable: false),
    ], destructor: false),
  ], [
    WireMessage("error", 0, 1, [
      WireArg("object_id", "object", interfaceName: null, nullable: false),
      WireArg("code", "uint", interfaceName: null, nullable: false),
      WireArg("message", "string", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("delete_id", 1, 1, [
      WireArg("id", "uint", interfaceName: null, nullable: false),
    ], destructor: false),
  ]),
  "wl_registry": WireInterface("wl_registry", 1, [
    WireMessage("bind", 0, 1, [
      WireArg("name", "uint", interfaceName: null, nullable: false),
      WireArg("id_interface", "string", interfaceName: null, nullable: false),
      WireArg("id_version", "uint", interfaceName: null, nullable: false),
      WireArg("id", "new_id", interfaceName: null, nullable: false),
    ], destructor: false),
  ], [
    WireMessage("global", 0, 1, [
      WireArg("name", "uint", interfaceName: null, nullable: false),
      WireArg("interface", "string", interfaceName: null, nullable: false),
      WireArg("version", "uint", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("global_remove", 1, 1, [
      WireArg("name", "uint", interfaceName: null, nullable: false),
    ], destructor: false),
  ]),
  "wl_callback": WireInterface("wl_callback", 1, [
  ], [
    WireMessage("done", 0, 1, [
      WireArg("callback_data", "uint", interfaceName: null, nullable: false),
    ], destructor: true),
  ]),
  "wl_output": WireInterface("wl_output", 4, [
    WireMessage("release", 0, 3, [
    ], destructor: true),
  ], [
    WireMessage("geometry", 0, 1, [
      WireArg("x", "int", interfaceName: null, nullable: false),
      WireArg("y", "int", interfaceName: null, nullable: false),
      WireArg("physical_width", "int", interfaceName: null, nullable: false),
      WireArg("physical_height", "int", interfaceName: null, nullable: false),
      WireArg("subpixel", "int", interfaceName: null, nullable: false),
      WireArg("make", "string", interfaceName: null, nullable: false),
      WireArg("model", "string", interfaceName: null, nullable: false),
      WireArg("transform", "int", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("mode", 1, 1, [
      WireArg("flags", "uint", interfaceName: null, nullable: false),
      WireArg("width", "int", interfaceName: null, nullable: false),
      WireArg("height", "int", interfaceName: null, nullable: false),
      WireArg("refresh", "int", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("done", 2, 2, [
    ], destructor: false),
    WireMessage("scale", 3, 2, [
      WireArg("factor", "int", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("name", 4, 4, [
      WireArg("name", "string", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("description", 5, 4, [
      WireArg("description", "string", interfaceName: null, nullable: false),
    ], destructor: false),
  ]),
  "ext_workspace_manager_v1": WireInterface("ext_workspace_manager_v1", 1, [
    WireMessage("commit", 0, 1, [
    ], destructor: false),
    WireMessage("stop", 1, 1, [
    ], destructor: false),
  ], [
    WireMessage("workspace_group", 0, 1, [
      WireArg("workspace_group", "new_id", interfaceName: "ext_workspace_group_handle_v1", nullable: false),
    ], destructor: false),
    WireMessage("workspace", 1, 1, [
      WireArg("workspace", "new_id", interfaceName: "ext_workspace_handle_v1", nullable: false),
    ], destructor: false),
    WireMessage("done", 2, 1, [
    ], destructor: false),
    WireMessage("finished", 3, 1, [
    ], destructor: true),
  ]),
  "ext_workspace_group_handle_v1": WireInterface("ext_workspace_group_handle_v1", 1, [
    WireMessage("create_workspace", 0, 1, [
      WireArg("workspace", "string", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("destroy", 1, 1, [
    ], destructor: true),
  ], [
    WireMessage("capabilities", 0, 1, [
      WireArg("capabilities", "uint", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("output_enter", 1, 1, [
      WireArg("output", "object", interfaceName: "wl_output", nullable: false),
    ], destructor: false),
    WireMessage("output_leave", 2, 1, [
      WireArg("output", "object", interfaceName: "wl_output", nullable: false),
    ], destructor: false),
    WireMessage("workspace_enter", 3, 1, [
      WireArg("workspace", "object", interfaceName: "ext_workspace_handle_v1", nullable: false),
    ], destructor: false),
    WireMessage("workspace_leave", 4, 1, [
      WireArg("workspace", "object", interfaceName: "ext_workspace_handle_v1", nullable: false),
    ], destructor: false),
    WireMessage("removed", 5, 1, [
    ], destructor: false),
  ]),
  "ext_workspace_handle_v1": WireInterface("ext_workspace_handle_v1", 1, [
    WireMessage("destroy", 0, 1, [
    ], destructor: true),
    WireMessage("activate", 1, 1, [
    ], destructor: false),
    WireMessage("deactivate", 2, 1, [
    ], destructor: false),
    WireMessage("assign", 3, 1, [
      WireArg("workspace_group", "object", interfaceName: "ext_workspace_group_handle_v1", nullable: false),
    ], destructor: false),
    WireMessage("remove", 4, 1, [
    ], destructor: false),
  ], [
    WireMessage("id", 0, 1, [
      WireArg("id", "string", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("name", 1, 1, [
      WireArg("name", "string", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("coordinates", 2, 1, [
      WireArg("coordinates", "array", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("state", 3, 1, [
      WireArg("state", "uint", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("capabilities", 4, 1, [
      WireArg("capabilities", "uint", interfaceName: null, nullable: false),
    ], destructor: false),
    WireMessage("removed", 5, 1, [
    ], destructor: false),
  ]),
};

abstract final class WlDisplayError {
  static const int invalidObject = 0;
  static const int invalidMethod = 1;
  static const int noMemory = 2;
  static const int implementation = 3;
}

class WlDisplayRequests {
  const WlDisplayRequests(this.send);
  final WireRequestSender send;
  void sync(int callback) => send("sync", [callback]);
  void getRegistry(int registry) => send("get_registry", [registry]);
}

class WlDisplayErrorEvent {
  const WlDisplayErrorEvent(this.objectId, this.code, this.message);
  factory WlDisplayErrorEvent.fromList(List<Object?> args) {
    if (args.length != 3) {
      throw ArgumentError("Expected 3 arguments for WlDisplayErrorEvent");
    }
    return WlDisplayErrorEvent(args[0] as int, args[1] as int, args[2] as String);
  }
  final int objectId;
  final int code;
  final String message;
}

class WlDisplayDeleteIdEvent {
  const WlDisplayDeleteIdEvent(this.id);
  factory WlDisplayDeleteIdEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for WlDisplayDeleteIdEvent");
    }
    return WlDisplayDeleteIdEvent(args[0] as int);
  }
  final int id;
}

class WlRegistryRequests {
  const WlRegistryRequests(this.send);
  final WireRequestSender send;
  void bind(int name, String idInterface, int idVersion, int id) => send("bind", [name, idInterface, idVersion, id]);
}

class WlRegistryGlobalEvent {
  const WlRegistryGlobalEvent(this.name, this.interfaceValue, this.version);
  factory WlRegistryGlobalEvent.fromList(List<Object?> args) {
    if (args.length != 3) {
      throw ArgumentError("Expected 3 arguments for WlRegistryGlobalEvent");
    }
    return WlRegistryGlobalEvent(args[0] as int, args[1] as String, args[2] as int);
  }
  final int name;
  final String interfaceValue;
  final int version;
}

class WlRegistryGlobalRemoveEvent {
  const WlRegistryGlobalRemoveEvent(this.name);
  factory WlRegistryGlobalRemoveEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for WlRegistryGlobalRemoveEvent");
    }
    return WlRegistryGlobalRemoveEvent(args[0] as int);
  }
  final int name;
}

class WlCallbackDoneEvent {
  const WlCallbackDoneEvent(this.callbackData);
  factory WlCallbackDoneEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for WlCallbackDoneEvent");
    }
    return WlCallbackDoneEvent(args[0] as int);
  }
  final int callbackData;
}

abstract final class WlOutputSubpixel {
  static const int unknown = 0;
  static const int none = 1;
  static const int horizontalRgb = 2;
  static const int horizontalBgr = 3;
  static const int verticalRgb = 4;
  static const int verticalBgr = 5;
}

abstract final class WlOutputTransform {
  static const int normal = 0;
  static const int value90 = 1;
  static const int value180 = 2;
  static const int value270 = 3;
  static const int flipped = 4;
  static const int flipped90 = 5;
  static const int flipped180 = 6;
  static const int flipped270 = 7;
}

abstract final class WlOutputMode {
  static const int current = 1;
  static const int preferred = 2;
}

class WlOutputRequests {
  const WlOutputRequests(this.send);
  final WireRequestSender send;
  void release() => send("release", []);
}

class WlOutputGeometryEvent {
  const WlOutputGeometryEvent(this.x, this.y, this.physicalWidth, this.physicalHeight, this.subpixel, this.make, this.model, this.transform);
  factory WlOutputGeometryEvent.fromList(List<Object?> args) {
    if (args.length != 8) {
      throw ArgumentError("Expected 8 arguments for WlOutputGeometryEvent");
    }
    return WlOutputGeometryEvent(args[0] as int, args[1] as int, args[2] as int, args[3] as int, args[4] as int, args[5] as String, args[6] as String, args[7] as int);
  }
  final int x;
  final int y;
  final int physicalWidth;
  final int physicalHeight;
  final int subpixel;
  final String make;
  final String model;
  final int transform;
}

class WlOutputModeEvent {
  const WlOutputModeEvent(this.flags, this.width, this.height, this.refresh);
  factory WlOutputModeEvent.fromList(List<Object?> args) {
    if (args.length != 4) {
      throw ArgumentError("Expected 4 arguments for WlOutputModeEvent");
    }
    return WlOutputModeEvent(args[0] as int, args[1] as int, args[2] as int, args[3] as int);
  }
  final int flags;
  final int width;
  final int height;
  final int refresh;
}

class WlOutputDoneEvent {
  const WlOutputDoneEvent();
  factory WlOutputDoneEvent.fromList(List<Object?> args) {
    if (args.isNotEmpty) {
      throw ArgumentError("Expected 0 arguments for WlOutputDoneEvent");
    }
    return WlOutputDoneEvent();
  }
}

class WlOutputScaleEvent {
  const WlOutputScaleEvent(this.factor);
  factory WlOutputScaleEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for WlOutputScaleEvent");
    }
    return WlOutputScaleEvent(args[0] as int);
  }
  final int factor;
}

class WlOutputNameEvent {
  const WlOutputNameEvent(this.name);
  factory WlOutputNameEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for WlOutputNameEvent");
    }
    return WlOutputNameEvent(args[0] as String);
  }
  final String name;
}

class WlOutputDescriptionEvent {
  const WlOutputDescriptionEvent(this.description);
  factory WlOutputDescriptionEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for WlOutputDescriptionEvent");
    }
    return WlOutputDescriptionEvent(args[0] as String);
  }
  final String description;
}

class ExtWorkspaceManagerV1Requests {
  const ExtWorkspaceManagerV1Requests(this.send);
  final WireRequestSender send;
  void commit() => send("commit", []);
  void stop() => send("stop", []);
}

class ExtWorkspaceManagerV1WorkspaceGroupEvent {
  const ExtWorkspaceManagerV1WorkspaceGroupEvent(this.workspaceGroup);
  factory ExtWorkspaceManagerV1WorkspaceGroupEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceManagerV1WorkspaceGroupEvent");
    }
    return ExtWorkspaceManagerV1WorkspaceGroupEvent(args[0] as int);
  }
  final int workspaceGroup;
}

class ExtWorkspaceManagerV1WorkspaceEvent {
  const ExtWorkspaceManagerV1WorkspaceEvent(this.workspace);
  factory ExtWorkspaceManagerV1WorkspaceEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceManagerV1WorkspaceEvent");
    }
    return ExtWorkspaceManagerV1WorkspaceEvent(args[0] as int);
  }
  final int workspace;
}

class ExtWorkspaceManagerV1DoneEvent {
  const ExtWorkspaceManagerV1DoneEvent();
  factory ExtWorkspaceManagerV1DoneEvent.fromList(List<Object?> args) {
    if (args.isNotEmpty) {
      throw ArgumentError("Expected 0 arguments for ExtWorkspaceManagerV1DoneEvent");
    }
    return ExtWorkspaceManagerV1DoneEvent();
  }
}

class ExtWorkspaceManagerV1FinishedEvent {
  const ExtWorkspaceManagerV1FinishedEvent();
  factory ExtWorkspaceManagerV1FinishedEvent.fromList(List<Object?> args) {
    if (args.isNotEmpty) {
      throw ArgumentError("Expected 0 arguments for ExtWorkspaceManagerV1FinishedEvent");
    }
    return ExtWorkspaceManagerV1FinishedEvent();
  }
}

abstract final class ExtWorkspaceGroupHandleV1GroupCapabilities {
  static const int createWorkspace = 1;
}

class ExtWorkspaceGroupHandleV1Requests {
  const ExtWorkspaceGroupHandleV1Requests(this.send);
  final WireRequestSender send;
  void createWorkspace(String workspace) => send("create_workspace", [workspace]);
  void destroy() => send("destroy", []);
}

class ExtWorkspaceGroupHandleV1CapabilitiesEvent {
  const ExtWorkspaceGroupHandleV1CapabilitiesEvent(this.capabilities);
  factory ExtWorkspaceGroupHandleV1CapabilitiesEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceGroupHandleV1CapabilitiesEvent");
    }
    return ExtWorkspaceGroupHandleV1CapabilitiesEvent(args[0] as int);
  }
  final int capabilities;
}

class ExtWorkspaceGroupHandleV1OutputEnterEvent {
  const ExtWorkspaceGroupHandleV1OutputEnterEvent(this.output);
  factory ExtWorkspaceGroupHandleV1OutputEnterEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceGroupHandleV1OutputEnterEvent");
    }
    return ExtWorkspaceGroupHandleV1OutputEnterEvent(args[0] as int);
  }
  final int output;
}

class ExtWorkspaceGroupHandleV1OutputLeaveEvent {
  const ExtWorkspaceGroupHandleV1OutputLeaveEvent(this.output);
  factory ExtWorkspaceGroupHandleV1OutputLeaveEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceGroupHandleV1OutputLeaveEvent");
    }
    return ExtWorkspaceGroupHandleV1OutputLeaveEvent(args[0] as int);
  }
  final int output;
}

class ExtWorkspaceGroupHandleV1WorkspaceEnterEvent {
  const ExtWorkspaceGroupHandleV1WorkspaceEnterEvent(this.workspace);
  factory ExtWorkspaceGroupHandleV1WorkspaceEnterEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceGroupHandleV1WorkspaceEnterEvent");
    }
    return ExtWorkspaceGroupHandleV1WorkspaceEnterEvent(args[0] as int);
  }
  final int workspace;
}

class ExtWorkspaceGroupHandleV1WorkspaceLeaveEvent {
  const ExtWorkspaceGroupHandleV1WorkspaceLeaveEvent(this.workspace);
  factory ExtWorkspaceGroupHandleV1WorkspaceLeaveEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceGroupHandleV1WorkspaceLeaveEvent");
    }
    return ExtWorkspaceGroupHandleV1WorkspaceLeaveEvent(args[0] as int);
  }
  final int workspace;
}

class ExtWorkspaceGroupHandleV1RemovedEvent {
  const ExtWorkspaceGroupHandleV1RemovedEvent();
  factory ExtWorkspaceGroupHandleV1RemovedEvent.fromList(List<Object?> args) {
    if (args.isNotEmpty) {
      throw ArgumentError("Expected 0 arguments for ExtWorkspaceGroupHandleV1RemovedEvent");
    }
    return ExtWorkspaceGroupHandleV1RemovedEvent();
  }
}

abstract final class ExtWorkspaceHandleV1State {
  static const int active = 1;
  static const int urgent = 2;
  static const int hidden = 4;
}

abstract final class ExtWorkspaceHandleV1WorkspaceCapabilities {
  static const int activate = 1;
  static const int deactivate = 2;
  static const int remove = 4;
  static const int assign = 8;
}

class ExtWorkspaceHandleV1Requests {
  const ExtWorkspaceHandleV1Requests(this.send);
  final WireRequestSender send;
  void destroy() => send("destroy", []);
  void activate() => send("activate", []);
  void deactivate() => send("deactivate", []);
  void assign(int workspaceGroup) => send("assign", [workspaceGroup]);
  void remove() => send("remove", []);
}

class ExtWorkspaceHandleV1IdEvent {
  const ExtWorkspaceHandleV1IdEvent(this.id);
  factory ExtWorkspaceHandleV1IdEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceHandleV1IdEvent");
    }
    return ExtWorkspaceHandleV1IdEvent(args[0] as String);
  }
  final String id;
}

class ExtWorkspaceHandleV1NameEvent {
  const ExtWorkspaceHandleV1NameEvent(this.name);
  factory ExtWorkspaceHandleV1NameEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceHandleV1NameEvent");
    }
    return ExtWorkspaceHandleV1NameEvent(args[0] as String);
  }
  final String name;
}

class ExtWorkspaceHandleV1CoordinatesEvent {
  const ExtWorkspaceHandleV1CoordinatesEvent(this.coordinates);
  factory ExtWorkspaceHandleV1CoordinatesEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceHandleV1CoordinatesEvent");
    }
    return ExtWorkspaceHandleV1CoordinatesEvent(args[0] as List<int>);
  }
  final List<int> coordinates;
}

class ExtWorkspaceHandleV1StateEvent {
  const ExtWorkspaceHandleV1StateEvent(this.state);
  factory ExtWorkspaceHandleV1StateEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceHandleV1StateEvent");
    }
    return ExtWorkspaceHandleV1StateEvent(args[0] as int);
  }
  final int state;
}

class ExtWorkspaceHandleV1CapabilitiesEvent {
  const ExtWorkspaceHandleV1CapabilitiesEvent(this.capabilities);
  factory ExtWorkspaceHandleV1CapabilitiesEvent.fromList(List<Object?> args) {
    if (args.length != 1) {
      throw ArgumentError("Expected 1 arguments for ExtWorkspaceHandleV1CapabilitiesEvent");
    }
    return ExtWorkspaceHandleV1CapabilitiesEvent(args[0] as int);
  }
  final int capabilities;
}

class ExtWorkspaceHandleV1RemovedEvent {
  const ExtWorkspaceHandleV1RemovedEvent();
  factory ExtWorkspaceHandleV1RemovedEvent.fromList(List<Object?> args) {
    if (args.isNotEmpty) {
      throw ArgumentError("Expected 0 arguments for ExtWorkspaceHandleV1RemovedEvent");
    }
    return ExtWorkspaceHandleV1RemovedEvent();
  }
}
