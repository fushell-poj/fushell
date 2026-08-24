import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

const String _surfaceChannel = 'dev.fushell/surface';

/// 窗口管理: fushell 以无头引擎启动 (无隐式窗口), 窗口全部由 Dart 通过
/// [FushellWindow.openWindow] 创建。每个窗口对应一个 Flutter view
/// (`PlatformDispatcher.views` 中的 `FlutterView`, viewId = 窗口 id),
/// 窗口内容用框架的 `View` widget 渲染到对应 view:
///
/// ```dart
/// final id = await FushellWindow.openWindow(title: 'Main', appId: '...');
/// final view = await FushellWindow.viewById(id);
/// runApp(ViewCollection(views: [View(view: view, child: const MainApp())]));
/// ```
///
/// 关闭全部窗口不会退出进程; 退出用 [FushellProcess.exit]。
final class FushellWindow {
  FushellWindow._();

  static int _nextRequestId = 1;

  /// 创建新窗口, 返回窗口 id (= Flutter view_id)。
  ///
  /// [parent] 指定父窗口 id: 子窗口经 xdg `set_parent` 绑定到父窗口
  /// (transient 语义: 子窗口堆叠于父窗口之上; 父窗口关闭时 compositor 自动
  /// 解除绑定, 不级联关闭子窗口)。
  ///
  /// [layer] 提供时创建 layer-shell 角色窗口 (参数同旧 LayerSurfaceRole,
  /// 与 xdg 窗口互斥; title/appId 被忽略)。
  static Future<int> openWindow({
    required String title,
    required String appId,
    int? width,
    int? height,
    int? parent,
    LayerSurfaceRole? layer,
  }) async {
    final Map<String, Object?> role = layer == null
        ? <String, Object?>{
            'kind': 'window',
            'title': title,
            'appId': appId,
            if (width != null) 'width': width,
            if (height != null) 'height': height,
          }
        : layer.toJson();
    final Map<String, Object?> response = await _sendRequest(<String, Object?>{
      'method': 'window.open',
      'role': role,
      if (parent != null) 'parent': parent,
    });
    final Object? windowId = response['windowId'];
    if (windowId is! int) {
      throw const FushellSurfaceException(
        code: 'InvalidResponse',
        message: 'window.open response is missing windowId',
      );
    }
    return windowId;
  }

  /// 关闭窗口 (引擎移除对应 view 后销毁其 Wayland surface)。
  static Future<void> closeWindow(int windowId) async {
    await _sendRequest(<String, Object?>{
      'method': 'window.close',
      'windowId': windowId,
    });
  }

  /// 更新窗口的 mutable 属性 (title / appId)。
  static Future<void> updateWindow(
    int windowId,
    WindowSurfaceUpdate update,
  ) async {
    await _sendRequest(<String, Object?>{
      'method': 'window.update',
      'windowId': windowId,
      'update': update.toJson(),
    });
  }

  /// 更新 layer 角色窗口的 mutable 属性。
  static Future<void> updateLayer(
    int windowId,
    LayerSurfaceUpdate update,
  ) async {
    await _sendRequest(<String, Object?>{
      'method': 'layer.update',
      'windowId': windowId,
      'update': update.toJson(),
    });
  }

  /// 在 `PlatformDispatcher.views` 中查找窗口 id 对应的 FlutterView。
  ///
  /// openWindow 回复时 view 已在引擎注册, 但通知 Dart 侧 `PlatformDispatcher`
  /// 的通道消息可能还在队列中; 此方法会等待 view 出现 (最多 ~1s)。
  static Future<ui.FlutterView> viewById(int windowId) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      for (final ui.FlutterView view in ui.PlatformDispatcher.instance.views) {
        if (view.viewId == windowId) return view;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw FushellSurfaceException(
      code: 'ViewNotFound',
      message: 'view $windowId did not appear in PlatformDispatcher.views',
    );
  }

  static Future<Map<String, Object?>> _sendRequest(
    Map<String, Object?> request,
  ) async {
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
    if (ok == true) return decoded;

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

/// 进程控制: 无头 shell 的退出方式。
final class FushellProcess {
  FushellProcess._();

  /// 显式退出进程: 宿主按序关闭引擎、销毁全部剩余窗口、断开 Wayland 连接,
  /// 以 [code] 退出。
  static Future<void> exit([int code = 0]) async {
    final int requestId = FushellWindow._nextRequestId++;
    final ByteData message = _encodeJson(<String, Object?>{
      'id': requestId,
      'method': 'process.exit',
      'code': code,
    });
    // 进程即将退出, 响应可能收不到 — 不等待。
    ui.PlatformDispatcher.instance.sendPlatformMessage(
      _surfaceChannel,
      message,
      (_) {},
    );
  }
}

/// layer-shell 角色参数 (window.open 的 layer 参数)。
final class LayerSurfaceRole {
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

/// layer 窗口的 mutable 属性更新。
final class LayerSurfaceUpdate {
  const LayerSurfaceUpdate({
    this.width,
    this.height,
    this.anchors,
    this.margins,
    this.exclusiveZone,
    this.keyboardInteractivity,
  });

  final int? width;
  final int? height;
  final Set<LayerSurfaceAnchor>? anchors;
  final Margins? margins;
  final int? exclusiveZone;
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

/// xdg 窗口的 mutable 属性更新。
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
