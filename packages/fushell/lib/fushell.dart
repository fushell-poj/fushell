import 'dart:async';
import 'dart:convert';

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const String _surfaceChannel = 'dev.fushell/surface';
const String _applicationChannel = 'dev.fushell/application';
const String _windowEventsChannel = 'dev.fushell/window-events';

/// One process invocation delivered by Fushell's native application broker.
///
/// [arguments] and [workingDirectory] preserve the original Unix bytes. The
/// convenience text accessors use UTF-8 and replace malformed sequences.
final class FushellCommandInvocation {
  FushellCommandInvocation({
    required this.arguments,
    required this.workingDirectory,
    required this.isInitial,
  }) : _cancellation = _FushellCommandCancellation();

  FushellCommandInvocation._internal({
    required this.arguments,
    required this.workingDirectory,
    required this.isInitial,
    required _FushellCommandCancellation cancellation,
  }) : _cancellation = cancellation;

  /// 进程入口收到的原始参数字节串，不包含可执行文件名本身。
  final List<Uint8List> arguments;

  /// 调用进程中捕获的 cwd 字节。
  final Uint8List workingDirectory;

  /// Whether this invocation started the primary daemon process.
  final bool isInitial;

  final _FushellCommandCancellation _cancellation;

  /// native broker 是否已请求本次命令尽快结束。
  bool get isCancellationRequested => _cancellation.isRequested;

  /// native broker 请求取消时完成；重复取消只完成一次。
  Future<void> get cancelled => _cancellation.whenRequested;

  /// 供常规文本命令解析器使用的有损 UTF-8 视图。
  /// 文件名或参数可能包含非 UTF-8 字节时应改用 [arguments]。
  List<String> get textArguments => arguments
      .map((Uint8List value) => utf8.decode(value, allowMalformed: true))
      .toList(growable: false);

  /// [workingDirectory] 的有损 UTF-8 视图。
  String get textWorkingDirectory =>
      utf8.decode(workingDirectory, allowMalformed: true);
}

final class _FushellCommandCancellation {
  _FushellCommandCancellation();

  final Completer<void> _requested = Completer<void>();

  bool get isRequested => _requested.isCompleted;

  Future<void> get whenRequested => _requested.future;

  void _request() {
    if (!_requested.isCompleted) {
      _requested.complete();
    }
  }
}

/// 返回给应用命令调用进程的完成结果。
///
/// 输出会先缓冲，再与退出状态原子交付，因此本 API 适合命令规模的响应，不适合无界
/// 流式传输。native broker 将每个输出流限制为 16 MiB，并串行执行回调。
final class FushellCommandResult {
  FushellCommandResult({
    this.exitCode = 0,
    Uint8List? stdout,
    Uint8List? stderr,
  }) : stdout = stdout ?? Uint8List(0),
       stderr = stderr ?? Uint8List(0) {
    if (exitCode < 0 || exitCode > 255) {
      throw RangeError.range(exitCode, 0, 255, 'exitCode');
    }
  }

  factory FushellCommandResult.text({
    int exitCode = 0,
    String stdout = '',
    String stderr = '',
  }) => FushellCommandResult(
    exitCode: exitCode,
    stdout: Uint8List.fromList(utf8.encode(stdout)),
    stderr: Uint8List.fromList(utf8.encode(stderr)),
  );

  final int exitCode;
  final Uint8List stdout;
  final Uint8List stderr;
}

/// 由应用拥有的首次启动与远程调用命令分发器。
///
/// Fushell 同一时刻最多调用一个 handler。远程调用方在 30 秒后收到超时，随后
/// [FushellCommandInvocation.cancelled] 完成；handler 有两秒时间完成清理并返回。
typedef FushellCommandHandler =
    FutureOr<FushellCommandResult> Function(FushellCommandInvocation command);

/// 把单实例 Dart 应用连接到 native invocation broker。
///
/// Fushell 只运输不透明 argv/cwd 字节与命令结果，从不定义命令语法或行为。普通窗口
/// API 不依赖本类；仅 `fushell.json` 声明 `instance: "single"` 的 bundle 需要使用。
final class FushellApplication {
  FushellApplication._();

  static const MethodChannel _channel = MethodChannel(
    _applicationChannel,
    JSONMethodCodec(),
  );
  static FushellCommandHandler? _handler;
  static int? _activeCommandId;
  static _FushellCommandCancellation? _activeCancellation;

  /// 安装 [onCommand]，并释放 Dart 启动期间排队的 invocation。
  ///
  /// 必须等待返回的 Future 完成，才能假定 native broker 已可分发。再次调用只替换
  /// Dart callback，不会重新申请 D-Bus 名称，也不会创建第二个 broker。
  static Future<void> run({required FushellCommandHandler onCommand}) async {
    WidgetsFlutterBinding.ensureInitialized();
    _handler = onCommand;
    _channel.setMethodCallHandler(_handleMethodCall);
    await _channel.invokeMethod<void>('ready');
  }

  static Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'cancel') {
      if (call.arguments is! Map<Object?, Object?>) {
        throw PlatformException(
          code: 'ApplicationProtocol',
          message: 'malformed application cancellation',
        );
      }
      final Object? id = (call.arguments! as Map<Object?, Object?>)['id'];
      if (id is! int) {
        throw PlatformException(
          code: 'ApplicationProtocol',
          message: 'malformed application cancellation',
        );
      }
      if (_activeCommandId == id) {
        _activeCancellation?._request();
      }
      return;
    }
    if (call.method != 'dispatch' || call.arguments is! Map<Object?, Object?>) {
      throw PlatformException(
        code: 'ApplicationProtocol',
        message: 'unsupported application invocation',
      );
    }
    final Map<Object?, Object?> fields =
        call.arguments! as Map<Object?, Object?>;
    final Object? idValue = fields['id'];
    final Object? cwdValue = fields['cwdHex'];
    final Object? argumentsValue = fields['argumentsHex'];
    final Object? initialValue = fields['isInitial'];
    if (idValue is! int ||
        cwdValue is! String ||
        argumentsValue is! List<Object?> ||
        initialValue is! bool) {
      throw PlatformException(
        code: 'ApplicationProtocol',
        message: 'malformed application invocation',
      );
    }

    final _FushellCommandCancellation cancellation =
        _FushellCommandCancellation();
    final FushellCommandInvocation invocation =
        FushellCommandInvocation._internal(
          arguments: argumentsValue
              .map((Object? value) {
                if (value is! String) {
                  throw const FormatException('argument is not a hex string');
                }
                return _decodeHex(value);
              })
              .toList(growable: false),
          workingDirectory: _decodeHex(cwdValue),
          isInitial: initialValue,
          cancellation: cancellation,
        );

    _activeCommandId = idValue;
    _activeCancellation = cancellation;
    FushellCommandResult result;
    try {
      final FushellCommandHandler handler = _handler!;
      result = await handler(invocation);
    } catch (error, stackTrace) {
      result = FushellCommandResult.text(
        exitCode: 70,
        stderr: 'Unhandled application command error: $error\n$stackTrace\n',
      );
    } finally {
      if (_activeCommandId == idValue) {
        _activeCommandId = null;
        _activeCancellation = null;
      }
    }

    await _channel.invokeMethod<void>('complete', <String, Object?>{
      'id': idValue,
      'exitCode': result.exitCode,
      'stdoutHex': _encodeHex(result.stdout),
      'stderrHex': _encodeHex(result.stderr),
    });
  }
}

/// native 窗口完成 Flutter RemoveView 与 Wayland/EGL 销毁后的通知。
///
/// 收到事件时对应 ID 已不能再用于窗口更新或关闭；应用应按 ID 幂等移除
/// `ViewCollection` 中的 Widget 状态。
final class FushellWindowClosedEvent {
  const FushellWindowClosedEvent({required this.windowId});

  final int windowId;
}

/// 为无头 Flutter 引擎创建并控制 native surface。
///
/// 每个 native 窗口拥有一个 `FlutterView`；返回的窗口 ID 与 `FlutterView.viewId`
/// 相同。应用必须把每个 view 放入以 `runWidget` 为根的框架 `ViewCollection`：
///
/// ```dart
/// final id = await FushellWindow.openWindow(title: 'Main', appId: '...');
/// final view = await FushellWindow.viewById(id);
/// runWidget(ViewCollection(views: [View(view: view, child: const MainApp())]));
/// ```
///
/// 关闭全部窗口后 isolate 与 command broker 仍继续运行。需要主动结束进程时调用
/// [FushellProcess.exit]。
final class FushellWindow {
  FushellWindow._();

  static int _nextRequestId = 1;
  static Future<void>? _fontFallbackLoad;
  static bool _windowEventsInitialized = false;
  static final StreamController<FushellWindowClosedEvent> _closedEvents =
      StreamController<FushellWindowClosedEvent>.broadcast(sync: true);
  static const BasicMessageChannel<String> _eventsChannel =
      BasicMessageChannel<String>(_windowEventsChannel, StringCodec());

  /// 所有窗口的关闭完成事件。
  ///
  /// 该广播流不会在单个窗口关闭后结束。`closeWindow` 的 Future 与事件彼此独立；
  /// 两者都只在 native 资源销毁后完成，但调用方不得依赖二者的先后顺序。
  static Stream<FushellWindowClosedEvent> get closed {
    _ensureWindowEventsInitialized();
    return _closedEvents.stream;
  }

  /// 创建 native surface，并在 Flutter 接受新 view 后完成。
  ///
  /// [parent] 只应用 xdg transient-parent 层叠关系；关闭父窗口不会级联关闭子窗口。
  /// 提供 [layer] 时创建 layer-shell surface 而非 xdg toplevel，此时忽略 [title]
  /// 和 [appId]。省略尺寸表示让 compositor 决定 xdg 大小，或由相对锚点推导 layer
  /// 大小。
  static Future<int> openWindow({
    required String title,
    required String appId,
    int? width,
    int? height,
    int? parent,
    LayerSurfaceRole? layer,
  }) async {
    _ensureWindowEventsInitialized();
    await _ensureSystemFontFallbackLoaded();
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

  /// 移除 Flutter view，再销毁其 EGL 与 Wayland 资源。
  /// 只有引擎确认 `RemoveView` 后 Future 才会完成。
  static Future<void> closeWindow(int windowId) async {
    await _sendRequest(<String, Object?>{
      'method': 'window.close',
      'windowId': windowId,
    });
  }

  /// 更新可变 xdg-toplevel 元数据；传入 layer-surface ID 时拒绝请求。
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

  /// 应用可变 layer-shell 状态并 commit surface。
  /// 拒绝 xdg-toplevel ID 以及更新后无效的几何配置。
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

  /// 解析与 native 窗口 ID 对应的 [ui.FlutterView]。
  ///
  /// 引擎回调可能早于 `PlatformDispatcher.views` 发布，因此本方法最多等待约一秒，
  /// 之后才抛出 `ViewNotFound`。
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

  static void _ensureWindowEventsInitialized() {
    if (_windowEventsInitialized) return;
    _windowEventsInitialized = true;
    _eventsChannel.setMessageHandler((String? message) async {
      if (message == null) return '';
      final Object? decoded;
      try {
        decoded = jsonDecode(message);
      } on FormatException {
        return '';
      }
      if (decoded is! Map<String, Object?> ||
          decoded['event'] != 'window.closed') {
        return '';
      }
      final Object? windowId = decoded['windowId'];
      if (windowId is int) {
        _closedEvents.add(FushellWindowClosedEvent(windowId: windowId));
      }
      return '';
    });
  }

  static Future<void> _ensureSystemFontFallbackLoaded() {
    return _fontFallbackLoad ??= _loadSystemFontFallback();
  }

  static Future<void> _loadSystemFontFallback() async {
    const String configAsset = 'fushell_system_fonts/fallback.json';
    const String fontAsset = 'fushell_system_fonts/system.ttf';

    final String config;
    try {
      config = await rootBundle.loadString(configAsset);
    } on FlutterError {
      // The application bundle already provides every required fallback.
      return;
    }

    final Object? decoded = jsonDecode(config);
    if (decoded is! Map<String, Object?> ||
        decoded['aliases'] is! List<Object?>) {
      throw StateError('$configAsset is malformed');
    }
    final List<String> aliases = <String>[];
    for (final Object? alias in decoded['aliases']! as List<Object?>) {
      if (alias is! String || alias.isEmpty) {
        throw StateError('$configAsset contains an invalid font alias');
      }
      aliases.add(alias);
    }
    if (aliases.isEmpty) return;

    final ByteData font = await rootBundle.load(fontAsset);
    for (final String alias in aliases) {
      final FontLoader loader = FontLoader(alias)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
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

/// 无头应用进程的显式生命周期控制。
final class FushellProcess {
  FushellProcess._();

  /// 请求以 `0..255` 范围内的状态码有序关闭进程。
  ///
  /// platform loop 会在活动应用命令 reply 发出后停止，随后关闭 Flutter、销毁全部
  /// 窗口，并断开 Wayland/D-Bus。该请求不等待响应，因为 isolate 可能在
  /// platform-channel response 送达前终止。
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

/// 创建 layer-shell surface 时分配的不可变 role。
///
/// 同时设置水平方向或垂直方向的相对锚点，并省略对应尺寸，表示请求 compositor
/// 控制拉伸。[exclusiveZone] 遵循 layer-shell 协议：`-1` 要求 compositor 根据
/// surface 尺寸推导；`0` 表示不保留工作区。
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

/// 对现有 layer-shell role 的局部修改。
///
/// null 字段保持不变。应用 patch 后会验证几何与 anchor 组合，因此 patch 不会让
/// 拉伸轴留下不兼容的显式尺寸。
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

/// 对 compositor 可见 xdg-toplevel 元数据的局部更新。
/// null 字段保留当前值。
final class WindowSurfaceUpdate {
  const WindowSurfaceUpdate({this.title, this.appId});

  final String? title;
  final String? appId;

  Map<String, Object?> toJson() => <String, Object?>{
    if (title != null) 'title': title,
    if (appId != null) 'appId': appId,
  };
}

/// layer-shell 相对于普通桌面窗口的层叠平面。
enum LayerSurfaceLayer {
  background('background'),
  bottom('bottom'),
  top('top'),
  overlay('overlay');

  const LayerSurfaceLayer(this.wireName);
  final String wireName;
}

/// layer surface 所附着的 output 边缘。
enum LayerSurfaceAnchor {
  top('top'),
  bottom('bottom'),
  left('left'),
  right('right');

  const LayerSurfaceAnchor(this.wireName);
  final String wireName;
}

/// 向 layer-shell compositor 请求的键盘焦点策略。
enum LayerKeyboardInteractivity {
  none('none'),
  exclusive('exclusive'),
  onDemand('onDemand');

  const LayerKeyboardInteractivity(this.wireName);
  final String wireName;
}

/// 以 compositor 逻辑坐标表示的有符号 layer-shell 边距。
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

/// native surface 或 process channel 失败，带有稳定、机器可读的错误码。
final class FushellSurfaceException implements Exception {
  const FushellSurfaceException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'FushellSurfaceException($code): $message';
}

Uint8List _decodeHex(String value) {
  if (value.length.isOdd) throw const FormatException('odd-length hex data');
  final Uint8List bytes = Uint8List(value.length ~/ 2);
  for (var index = 0; index < bytes.length; index++) {
    final int? byte = int.tryParse(
      value.substring(index * 2, index * 2 + 2),
      radix: 16,
    );
    if (byte == null) throw const FormatException('invalid hex data');
    bytes[index] = byte;
  }
  return bytes;
}

String _encodeHex(Uint8List bytes) {
  final StringBuffer output = StringBuffer();
  for (final int byte in bytes) {
    output.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return output.toString();
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
