// Dart 的 async 工具库。这里用 Timer 定时刷新时钟。
import 'dart:async';

// 这里只导入 flutter/widgets.dart，而不是 material.dart，表示这个示例只使用
// Flutter 最基础的 Widget，不依赖 Material Design 组件。
import 'package:flutter/widgets.dart';

// fushell 自己提供的 Dart API。它负责通过 platform channel 告诉 Zig host：
// “请把这个 Flutter view 初始化成 Wayland layer-shell surface”。
import 'package:fushell/fushell.dart';

// 顶栏的逻辑高度，单位是 Flutter logical pixels。
//
// 注意：这个值会传给 FushellSurface.init(...)，作为启动时的 layer 高度。
// Wayland surface role 本身初始化后不可变，但 layer 的某些属性现在可以动态更新：
// - 修改颜色、字体、普通 Flutter 布局：通常 hot reload 就能看到；
// - 修改 layer 高度、exclusiveZone、margin、anchor：可以通过
//   FushellSurface.updateLayer(...) 在运行时发给 fushell；
// - 修改 role 类型本身，比如从 layer 换成 window：仍然需要重启 fushell。
const int _barHeight = 32;

// Flutter 程序入口。
//
// fushell 的约定是：必须先 await FushellSurface.init(...)，再 runApp(...)。
// 这样 Dart app 可以在第一帧之前选择 Wayland surface role。
Future<void> main() async {
  await FushellSurface.init(
    const SurfaceRole.layer(
      // namespace 是 layer-shell 给 compositor 看的名字。
      // 它通常用于调试、规则匹配或 compositor 内部识别。
      namespace: 'fushell-top-bar',

      // top layer 通常显示在普通窗口上方，适合 panel / bar。
      layer: LayerSurfaceLayer.top,

      // anchors 决定 layer surface 贴在哪些屏幕边缘。
      // top + left + right 表示：贴在屏幕顶部，并横向拉伸。
      anchors: <LayerSurfaceAnchor>{
        LayerSurfaceAnchor.top,
        LayerSurfaceAnchor.left,
        LayerSurfaceAnchor.right,
      },

      // exclusiveZone 告诉 compositor：这个 layer 想占用多少顶部空间。
      // 支持 layer-shell 的 compositor 可以据此避免普通窗口盖住 bar。
      exclusiveZone: _barHeight,

      // 顶栏不需要键盘焦点，所以设为 none。
      keyboardInteractivity: LayerKeyboardInteractivity.none,

      // width: 0 在 layer-shell 中常用于“由 compositor 根据 anchors 分配宽度”。
      // 因为我们 anchor 了 left + right，所以 compositor 会让它横跨屏幕宽度。
      width: 0,

      // height 是顶栏高度。
      height: _barHeight,
    ),
  );

  // 如果想在运行时改变 layer 高度或 reserved space，可以在 init 之后调用：
  //
  // await FushellSurface.updateLayer(
  //   const LayerSurfaceUpdate(height: 28, exclusiveZone: 28),
  // );
  //
  // 这种 update 不会改变 layer role，也不会重建 wl_surface；它只是把可变的
  // layer-shell 属性提交给 compositor。

  // runApp 会把根 Widget 挂到 Flutter 渲染树上。
  runApp(const FushellTopBar());
}

// StatelessWidget 表示这个 Widget 自身没有可变状态。
// 它只是提供顶层方向设置，并把真正会变的时钟交给 _TopBarClock。
class FushellTopBar extends StatelessWidget {
  const FushellTopBar({super.key});

  @override
  Widget build(BuildContext context) {
    // Directionality 告诉 Flutter 文本方向。
    // 只用 widgets.dart 时，Text 需要祖先提供 textDirection。
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: _TopBarClock(),
    );
  }
}

// StatefulWidget 表示这个 Widget 有随时间变化的状态。
// 时钟每隔一段时间更新当前时间，所以需要 StatefulWidget。
class _TopBarClock extends StatefulWidget {
  const _TopBarClock();

  @override
  State<_TopBarClock> createState() => _TopBarClockState();
}

// State 对象保存 _TopBarClock 的可变数据：当前时间和定时器。
class _TopBarClockState extends State<_TopBarClock> {
  // late 的意思是：这个字段会稍后初始化，但在使用前一定会有值。
  late DateTime _now;

  // Timer? 中的 ? 表示这个字段可以为 null。
  // dispose 后我们会 cancel timer，避免 Widget 销毁后还继续回调。
  Timer? _timer;

  @override
  void initState() {
    super.initState();

    // Widget 第一次创建时，记录当前时间。
    _now = DateTime.now();

    // 每秒刷新一次。虽然界面只显示 HH:mm，但每秒刷新可以让分钟变化时
    // 不需要额外计算“距离下一分钟还有多久”。实现简单直接。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      // 如果 Widget 已经不在树里，mounted 会是 false。
      // 这时不能再 setState。
      if (!mounted) return;

      // setState 告诉 Flutter：“状态变了，请重新 build 这个 Widget”。
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    // Widget 被销毁时取消 timer，避免资源泄漏。
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ColoredBox 是最简单的纯色背景。
    // Color 写法是 0xAARRGGBB：
    // - AA: alpha / 不透明度
    // - RR: red
    // - GG: green
    // - BB: blue
    //
    // 0x88 表示大约 53% 不透明，比之前更透明。
    // 111827 是偏高级的深蓝灰色。
    return ColoredBox(
      color: const Color(0x88111827),

      // SizedBox.expand 表示让内容填满当前 layer surface 的可用空间。
      child: SizedBox.expand(
        // Center 把 child 放在可用区域正中央。
        child: Center(
          // Text 显示当前时间。
          child: Text(
            _formatClock(_now),
            style: const TextStyle(
              // 白色字体。fushell 会从 fontconfig 动态注入系统 sans 字体，
              // 并把它注册成 Flutter 默认逻辑 family “Roboto”。这里指定
              // Roboto 只是使用这个逻辑别名，不绑定具体系统字体文件。
              color: Color(0xFFF8FAFC),
              fontFamily: 'Roboto',

              // 顶栏高度减小后，字体也相应减小。
              fontSize: 17,

              // 字重稍粗，保证半透明背景上仍然清晰。
              fontWeight: FontWeight.w800,

              // 字间距略微增加，让数字更像 panel clock。
              letterSpacing: 0.8,
            ),
          ),
        ),
      ),
    );
  }
}

// 把 DateTime 格式化成 HH:mm。
//
// padLeft(2, '0') 表示不足两位时左边补 0：
// - 9 -> 09
// - 5 -> 05
String _formatClock(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}
