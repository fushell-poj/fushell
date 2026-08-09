import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

const String _surfaceChannel = 'dev.fushell/surface';

/// Initializes and updates fushell's Wayland surface role.
///
/// Call [FushellSurface.init] exactly once before `runApp()`. The surface role
/// is immutable after initialization; fushell will reject repeated calls or
/// attempts to switch roles.
final class FushellSurface {
  FushellSurface._();

  static int _nextRequestId = 1;

  static Future<void> init(SurfaceRole role) async {
    await _sendRequest(<String, Object?>{
      'method': 'surface.init',
      'role': role.toJson(),
    });
  }

  /// Updates mutable properties of the initialized layer-shell role.
  ///
  /// This does not change the Wayland role. It only applies properties that are
  /// mutable on an existing layer surface, such as size, anchors, margins,
  /// exclusive zone, and keyboard interactivity. Calling this before a layer
  /// role is initialized, or when the active role is a window, throws a
  /// [FushellSurfaceException].
  static Future<void> updateLayer(LayerSurfaceUpdate update) async {
    await _sendRequest(<String, Object?>{
      'method': 'surface.updateLayer',
      'update': update.toJson(),
    });
  }

  /// Updates mutable properties of the initialized xdg toplevel role.
  ///
  /// This does not change the Wayland role. It only applies metadata that can be
  /// changed on the existing window role, currently title and app id.
  static Future<void> updateWindow(WindowSurfaceUpdate update) async {
    await _sendRequest(<String, Object?>{
      'method': 'surface.updateWindow',
      'update': update.toJson(),
    });
  }

  static Future<void> _sendRequest(Map<String, Object?> request) async {
    final int requestId = _nextRequestId++;
    final Map<String, Object?> requestWithId = <String, Object?>{
      'id': requestId,
      ...request,
    };

    final ByteData message = _encodeJson(requestWithId);
    final Completer<ByteData?> response = Completer<ByteData?>();
    ui.PlatformDispatcher.instance.sendPlatformMessage(
      _surfaceChannel,
      message,
      response.complete,
    );
    final ByteData? responseData = await response.future;
    if (responseData == null) {
      throw const FushellSurfaceException(
        code: 'NoResponse',
        message: 'fushell did not return a response for surface request',
      );
    }

    final Object? decoded = jsonDecode(
      utf8.decode(
        responseData.buffer.asUint8List(
          responseData.offsetInBytes,
          responseData.lengthInBytes,
        ),
      ),
    );
    if (decoded is! Map<String, Object?>) {
      throw const FushellSurfaceException(
        code: 'InvalidResponse',
        message: 'fushell returned a non-object response for surface request',
      );
    }

    final Object? ok = decoded['ok'];
    if (ok == true) return;

    final Object? error = decoded['error'];
    if (error is Map<String, Object?>) {
      throw FushellSurfaceException(
        code: _stringField(error, 'code') ?? 'SurfaceRequestFailed',
        message:
            _stringField(error, 'message') ?? 'fushell surface request failed',
      );
    }

    throw const FushellSurfaceException(
      code: 'SurfaceRequestFailed',
      message: 'fushell surface request failed',
    );
  }
}

/// Opens additional fushell windows.
///
/// Each window runs its own Flutter engine instance inside the same fushell
/// process (sharing the Dart VM). The window runs the Dart entrypoint named by
/// [entrypoint] from the same bundle.
final class FushellWindow {
  FushellWindow._();

  /// Opens a new window running the Dart entrypoint [entrypoint].
  ///
  /// [args] are passed to the new window's isolate and are available there via
  /// `PlatformDispatcher.instance.args`.
  ///
  /// The entrypoint must be a top-level Dart function that survives AOT tree
  /// shaking: reference it from `main` (for example `settings;`), otherwise the
  /// release snapshot will not contain it and the window fails to start.
  static Future<void> openWindow({
    required String entrypoint,
    List<String> args = const <String>[],
  }) async {
    await FushellSurface._sendRequest(<String, Object?>{
      'method': 'window.spawn',
      'entrypoint': entrypoint,
      'args': args,
    });
  }
}

sealed class SurfaceRole {
  const SurfaceRole();

  const factory SurfaceRole.window({
    required String title,
    required String appId,
    int? width,
    int? height,
  }) = WindowSurfaceRole;

  const factory SurfaceRole.layer({
    required String namespace,
    required LayerSurfaceLayer layer,
    required Set<LayerSurfaceAnchor> anchors,
    Margins margins,
    int exclusiveZone,
    LayerKeyboardInteractivity keyboardInteractivity,
    int? width,
    int? height,
  }) = LayerSurfaceRole;

  Map<String, Object?> toJson();
}

final class WindowSurfaceRole extends SurfaceRole {
  const WindowSurfaceRole({
    required this.title,
    required this.appId,
    this.width,
    this.height,
  });

  final String title;
  final String appId;
  final int? width;
  final int? height;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'window',
    'title': title,
    'appId': appId,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
  };
}

final class LayerSurfaceRole extends SurfaceRole {
  const LayerSurfaceRole({
    required this.namespace,
    required this.layer,
    required this.anchors,
    this.margins = Margins.zero,
    this.exclusiveZone = -1,
    this.keyboardInteractivity = LayerKeyboardInteractivity.none,
    this.width,
    this.height,
  });

  final String namespace;
  final LayerSurfaceLayer layer;
  final Set<LayerSurfaceAnchor> anchors;
  final Margins margins;
  final int exclusiveZone;
  final LayerKeyboardInteractivity keyboardInteractivity;
  final int? width;
  final int? height;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'layer',
    'namespace': namespace,
    'layer': layer.wireName,
    'anchors': _anchorNames(anchors),
    'margins': margins.toJson(),
    'exclusiveZone': exclusiveZone,
    'keyboardInteractivity': keyboardInteractivity.wireName,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
  };
}

/// Mutable layer-shell properties that can be changed after initialization.
///
/// All fields are optional. Passing an empty update is valid and is treated as a
/// no-op by fushell.
final class LayerSurfaceUpdate {
  const LayerSurfaceUpdate({
    this.width,
    this.height,
    this.anchors,
    this.margins,
    this.exclusiveZone,
    this.keyboardInteractivity,
  });

  /// New layer width. `0` asks the compositor to derive width from anchors.
  final int? width;

  /// New layer height. `0` asks the compositor to derive height from anchors.
  final int? height;

  /// New anchor set. When provided, it must not be empty.
  final Set<LayerSurfaceAnchor>? anchors;

  /// New layer margins.
  final Margins? margins;

  /// New exclusive zone. `-1` keeps layer-shell's compositor-defined behavior.
  final int? exclusiveZone;

  /// New keyboard interactivity policy.
  final LayerKeyboardInteractivity? keyboardInteractivity;

  Map<String, Object?> toJson() => <String, Object?>{
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (anchors != null) 'anchors': _anchorNames(anchors!),
    if (margins != null) 'margins': margins!.toJson(),
    if (exclusiveZone != null) 'exclusiveZone': exclusiveZone,
    if (keyboardInteractivity != null)
      'keyboardInteractivity': keyboardInteractivity!.wireName,
  };
}

/// Mutable xdg toplevel metadata that can be changed after initialization.
///
/// All fields are optional. Passing an empty update is valid and is treated as a
/// no-op by fushell.
final class WindowSurfaceUpdate {
  const WindowSurfaceUpdate({this.title, this.appId});

  final String? title;
  final String? appId;

  Map<String, Object?> toJson() => <String, Object?>{
    if (title != null) 'title': title,
    if (appId != null) 'appId': appId,
  };
}

enum LayerSurfaceLayer {
  background('background'),
  bottom('bottom'),
  top('top'),
  overlay('overlay');

  const LayerSurfaceLayer(this.wireName);
  final String wireName;
}

enum LayerSurfaceAnchor {
  top('top'),
  bottom('bottom'),
  left('left'),
  right('right');

  const LayerSurfaceAnchor(this.wireName);
  final String wireName;
}

enum LayerKeyboardInteractivity {
  none('none'),
  exclusive('exclusive'),
  onDemand('onDemand');

  const LayerKeyboardInteractivity(this.wireName);
  final String wireName;
}

final class Margins {
  const Margins({this.top = 0, this.right = 0, this.bottom = 0, this.left = 0});

  static const Margins zero = Margins();

  final int top;
  final int right;
  final int bottom;
  final int left;

  Map<String, Object?> toJson() => <String, Object?>{
    'top': top,
    'right': right,
    'bottom': bottom,
    'left': left,
  };
}

final class FushellSurfaceException implements Exception {
  const FushellSurfaceException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'FushellSurfaceException($code): $message';
}

ByteData _encodeJson(Map<String, Object?> value) {
  final Uint8List bytes = utf8.encode(jsonEncode(value));
  return ByteData.sublistView(bytes);
}

List<String> _anchorNames(Set<LayerSurfaceAnchor> anchors) => anchors
    .map((LayerSurfaceAnchor anchor) => anchor.wireName)
    .toList(growable: false);

String? _stringField(Map<String, Object?> object, String key) {
  final Object? value = object[key];
  return value is String ? value : null;
}
