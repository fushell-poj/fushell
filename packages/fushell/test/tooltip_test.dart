import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';
import 'package:fushell/tooltip.dart';

class _View extends TestFlutterView {
  _View(WidgetTester tester, this.viewId)
    : super(
        view: tester.view,
        platformDispatcher: tester.platformDispatcher,
        display: tester.view.display,
      );
  @override
  final int viewId;
}

class _Harness {
  _Harness(this.tester) {
    root = _View(tester, 7)
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 48);
    controller = NativeTooltipController(
      viewById: (id) => readiness?.call(id) ?? Future.value(views[id]!),
      closed: closed.stream,
      onError: (error, stack) => errors.add(error),
    );
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.fushell/surface',
      (data) async {
        final request =
            jsonDecode(const StringCodec().decodeMessage(data)!)
                as Map<String, dynamic>;
        requests.add(request);
        if (request['method'] == 'window.open') {
          final positioner = request['role']['positioner'];
          final id = ++nextId;
          views[id] = _View(tester, id)
            ..devicePixelRatio = 1
            ..physicalSize = Size(
              (positioner['width'] as int).toDouble(),
              (positioner['height'] as int).toDouble(),
            );
          if (openReply != null) return openReply!.future;
          return reply({'ok': true, 'windowId': id});
        }
        if (closeReply != null) return closeReply!.future;
        if (failClose)
          return reply({
            'ok': false,
            'error': {
              'code': 'RemoveFailed',
              'message': 'test cleanup failure',
            },
          });
        return reply({'ok': true});
      },
    );
  }
  final WidgetTester tester;
  late final _View root;
  late final NativeTooltipController controller;
  final closed = StreamController<FushellWindowClosedEvent>.broadcast();
  final requests = <Map<String, dynamic>>[];
  final errors = <Object>[];
  final views = <int, _View>{};
  int nextId = 40;
  Completer<ByteData?>? openReply;
  Completer<ByteData?>? closeReply;
  Future<ui.FlutterView> Function(int)? readiness;
  bool failClose = false;
  bool added = false;
  double left = 10.25;
  String message = 'Native tooltip';
  TextScaler scaler = TextScaler.noScaling;
  TextDirection direction = TextDirection.ltr;
  bool disabledAnimations = false;
  bool source = true;
  bool second = false;
  double? verticalOffset;
  double? edgeGap;
  bool? preferBelow;
  double? themeOffset;
  bool? themeBelow;
  final focus = FocusNode();

  static ByteData? reply(Map<String, Object?> data) =>
      const StringCodec().encodeMessage(jsonEncode(data));
  List<Map<String, dynamic>> get opens =>
      requests.where((r) => r['method'] == 'window.open').toList();
  List<Map<String, dynamic>> get closes =>
      requests.where((r) => r['method'] == 'window.close').toList();

  Widget tooltip(String text) => NativeTooltip(
    message: text,
    waitDuration: const Duration(milliseconds: 100),
    exitDuration: const Duration(milliseconds: 50),
    showDuration: const Duration(milliseconds: 200),
    verticalOffset: verticalOffset,
    edgeGap: edgeGap,
    preferBelow: preferBelow,
    child: SizedBox(
      width: 60,
      height: 48,
      child: ColoredBox(
        color: Colors.blue,
        child: text == message
            ? Focus(focusNode: focus, child: const SizedBox())
            : const SizedBox(),
      ),
    ),
  );

  Future<void> mount() => tester.pumpWidget(
    NativeTooltipHost(
      controller: controller,
      child: View(
        view: root,
        child: MaterialApp(
          theme: ThemeData(
            tooltipTheme: TooltipThemeData(
              verticalOffset: themeOffset,
              preferBelow: themeBelow,
              textStyle: const TextStyle(fontSize: 13, color: Colors.orange),
              decoration: const BoxDecoration(color: Colors.purple),
            ),
          ),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 48),
              textScaler: scaler,
              disableAnimations: disabledAnimations,
              boldText: true,
            ),
            child: DefaultTextStyle(
              style: const TextStyle(),
              maxLines: 1,
              child: Directionality(
                textDirection: direction,
                child: Stack(
                  children: [
                    if (source)
                      Positioned(left: left, top: 0, child: tooltip(message)),
                    if (second)
                      Positioned(left: 100, top: 0, child: tooltip('Second')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    wrapWithView: false,
  );

  Future<void> hover([Offset position = const Offset(20, 20)]) async {
    if (!added) {
      tester.binding.handlePointerEvent(
        const PointerAddedEvent(
          viewId: 7,
          device: 1,
          kind: PointerDeviceKind.mouse,
        ),
      );
      added = true;
    }
    tester.binding.handlePointerEvent(
      PointerHoverEvent(
        viewId: 7,
        device: 1,
        kind: PointerDeviceKind.mouse,
        position: position,
      ),
    );
    await tester.pump();
  }

  Future<void> settle() async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  Future<void> show() async {
    await hover();
    await tester.pump(const Duration(milliseconds: 100));
    await settle();
  }

  Future<void> finish() async {
    if (added) {
      tester.binding.handlePointerEvent(
        const PointerRemovedEvent(
          viewId: 7,
          device: 1,
          kind: PointerDeviceKind.mouse,
        ),
      );
      added = false;
    }
    await tester.pumpWidget(
      const ViewCollection(views: []),
      wrapWithView: false,
    );
    await tester.pump();
    // Stream cancellation can complete in the real zone; do not await its
    // continuation while the widget-test fake clock is stopped.
    await tester.runAsync(() async {
      await controller.dispose();
      await closed.close();
    });
    focus.dispose();
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.fushell/surface',
      null,
    );
    root.reset();
    for (final view in views.values) view.reset();
    expect(tester.takeException(), isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final config in [
    (
      name: 'default below',
      vertical: null,
      gap: null,
      theme: null,
      below: null,
      themeBelow: null,
      anchor: 'none',
      gravity: 'bottom',
      y: 24,
    ),
    (
      name: 'default above',
      vertical: null,
      gap: null,
      theme: null,
      below: false,
      themeBelow: null,
      anchor: 'none',
      gravity: 'top',
      y: -24,
    ),
    (
      name: 'fractional edge gap',
      vertical: null,
      gap: 8.6,
      theme: null,
      below: true,
      themeBelow: null,
      anchor: 'bottom',
      gravity: 'bottom',
      y: 9,
    ),
    (
      name: 'legacy explicit below',
      vertical: 12.0,
      gap: null,
      theme: 40.0,
      below: true,
      themeBelow: null,
      anchor: 'none',
      gravity: 'bottom',
      y: 12,
    ),
    (
      name: 'legacy explicit above',
      vertical: 12.0,
      gap: null,
      theme: null,
      below: false,
      themeBelow: null,
      anchor: 'none',
      gravity: 'top',
      y: -12,
    ),
    (
      name: 'theme above',
      vertical: null,
      gap: null,
      theme: 30.0,
      below: null,
      themeBelow: false,
      anchor: 'none',
      gravity: 'top',
      y: -30,
    ),
    (
      name: 'theme below',
      vertical: null,
      gap: null,
      theme: 30.0,
      below: null,
      themeBelow: true,
      anchor: 'none',
      gravity: 'bottom',
      y: 30,
    ),
    (
      name: 'edge below overrides theme',
      vertical: null,
      gap: 8.0,
      theme: 40.0,
      below: true,
      themeBelow: false,
      anchor: 'bottom',
      gravity: 'bottom',
      y: 8,
    ),
    (
      name: 'edge above',
      vertical: null,
      gap: 8.0,
      theme: 40.0,
      below: false,
      themeBelow: true,
      anchor: 'top',
      gravity: 'top',
      y: -8,
    ),
    (
      name: 'zero edge follows theme above',
      vertical: null,
      gap: 0.0,
      theme: 40.0,
      below: null,
      themeBelow: false,
      anchor: 'top',
      gravity: 'top',
      y: 0,
    ),
  ]) {
    testWidgets('encoded tooltip positioner: ${config.name}', (tester) async {
      final h = _Harness(tester)
        ..verticalOffset = config.vertical
        ..edgeGap = config.gap
        ..themeOffset = config.theme
        ..preferBelow = config.below
        ..themeBelow = config.themeBelow;
      await h.mount();
      await h.show();
      final role = h.opens.single['role'];
      final positioner = role['positioner'] as Map<String, dynamic>;
      expect(positioner['anchorRect'], {
        'x': 11,
        'y': 0,
        'width': 59,
        'height': 48,
      });
      expect(positioner['anchor'], config.anchor);
      expect(positioner['gravity'], config.gravity);
      expect(positioner['offset'], {'x': 0, 'y': config.y});
      expect(positioner['constraintAdjustment'], ['slideX', 'slideY', 'flipY']);
      expect(role['inputPassthrough'], true);
      expect(role.containsKey('grab'), false);
      await h.controller.dismissAll();
      await h.settle();
      expect(h.closes, hasLength(1));
      expect(h.errors, isEmpty);
      await h.finish();
    });
  }

  for (final invalid in [
    -1.0,
    double.infinity,
    double.negativeInfinity,
    double.nan,
  ]) {
    testWidgets('edgeGap rejects $invalid at mount', (tester) async {
      final h = _Harness(tester)..edgeGap = invalid;
      await h.mount();
      expect(tester.takeException(), isArgumentError);
      expect(h.opens, isEmpty);
      await h.finish();
    });
  }

  testWidgets('explicit edgeGap and verticalOffset conflict at runtime', (
    tester,
  ) async {
    final h = _Harness(tester)
      ..edgeGap = 8
      ..verticalOffset = 24;
    await h.mount();
    expect(tester.takeException(), isArgumentError);
    expect(h.opens, isEmpty);
    await h.finish();
  });

  testWidgets('edgeGap validates updates as well as initial mount', (
    tester,
  ) async {
    final h = _Harness(tester)..edgeGap = 8;
    await h.mount();
    h.edgeGap = -1;
    await h.mount();
    expect(tester.takeException(), isArgumentError);
    expect(h.opens, isEmpty);
    await h.finish();
  });

  testWidgets('invalid edgeGap update dismisses an active popup', (
    tester,
  ) async {
    final h = _Harness(tester)..edgeGap = 8;
    await h.mount();
    await h.show();
    expect(h.opens, hasLength(1));
    expect(find.byType(View), findsNWidgets(2));
    h.edgeGap = double.infinity;
    await h.mount();
    expect(tester.takeException(), isArgumentError);
    await h.settle();
    expect(h.closes.single['windowId'], 41);
    expect(find.byType(View), findsOneWidget);
    expect(h.errors, isEmpty);
    await h.finish();
  });

  testWidgets('invalid edgeGap update cancels a pending hover timer', (
    tester,
  ) async {
    final h = _Harness(tester)..edgeGap = 8;
    await h.mount();
    await h.hover();
    expect(h.opens, isEmpty);
    h.edgeGap = -1;
    await h.mount();
    expect(tester.takeException(), isArgumentError);
    await tester.pump(const Duration(milliseconds: 200));
    await h.settle();
    expect(h.opens, isEmpty);
    expect(h.closes, isEmpty);
    expect(h.errors, isEmpty);
    await h.finish();
  });

  testWidgets('invalid edgeGap update closes a late native create', (
    tester,
  ) async {
    final h = _Harness(tester)
      ..edgeGap = 8
      ..openReply = Completer<ByteData?>();
    await h.mount();
    await h.show();
    expect(h.opens, hasLength(1));
    expect(h.closes, isEmpty);
    h.edgeGap = double.nan;
    await h.mount();
    expect(tester.takeException(), isArgumentError);
    await h.settle();
    expect(h.closes, isEmpty);
    h.openReply!.complete(_Harness.reply({'ok': true, 'windowId': 41}));
    await h.settle();
    expect(h.closes.single['windowId'], 41);
    expect(find.byType(View), findsOneWidget);
    expect(h.errors, isEmpty);
    await h.finish();
  });

  testWidgets('changing edgeGap dismisses the old popup', (tester) async {
    final h = _Harness(tester)..edgeGap = 8;
    await h.mount();
    await h.show();
    h.edgeGap = 12;
    await h.mount();
    await h.settle();
    expect(h.closes, hasLength(1));
    await h.finish();
  });

  testWidgets(
    'real parent coordinates, popup View, theme, scale and semantics',
    (tester) async {
      final h = _Harness(tester)
        ..message =
            'A multiline tooltip that must extend beyond the tiny panel height'
        ..scaler = TextScaler.linear(2)
        ..direction = TextDirection.rtl
        ..disabledAnimations = true;
      await h.mount();
      await h.show();
      expect(h.errors, isEmpty);
      expect(h.opens, hasLength(1));
      final request = h.opens.single;
      expect(request['parent'], 7);
      final role = request['role'];
      expect(role['inputPassthrough'], true);
      expect(role.containsKey('grab'), false);
      expect(role['positioner']['anchorRect'], {
        'x': 11,
        'y': 0,
        'width': 59,
        'height': 48,
      });
      expect(role['positioner']['height'], greaterThan(48));
      expect(role['positioner']['constraintAdjustment'], [
        'slideX',
        'slideY',
        'flipY',
      ]);
      expect(find.byType(View), findsNWidgets(2));
      final textFinder = find.text(h.message, findRichText: true);
      expect(textFinder, findsOneWidget);
      final text = tester.widget<RichText>(textFinder);
      expect(text.text.style!.color, Colors.orange);
      expect(text.text.style!.fontSize, 13);
      expect(text.text.style!.fontWeight, FontWeight.bold);
      expect(text.maxLines, isNull);
      final context = tester.element(textFinder);
      expect(View.of(context).viewId, 41);
      expect(Directionality.of(context), TextDirection.rtl);
      expect(MediaQuery.textScalerOf(context).scale(10), 20);
      expect(Localizations.localeOf(context), const Locale('en', 'US'));
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      expect(
        tester
            .widgetList<Semantics>(find.byType(Semantics))
            .any((widget) => widget.properties.tooltip == h.message),
        isTrue,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(
        h.closes,
        isEmpty,
        reason: 'stationary hover ignores focus showDuration',
      );
      await h.finish();
    },
  );

  testWidgets('exit before delay never creates a popup', (tester) async {
    final h = _Harness(tester);
    await h.mount();
    await h.hover();
    await tester.pump(const Duration(milliseconds: 40));
    await h.hover(const Offset(400, 20));
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.opens, isEmpty);
    await h.finish();
  });

  testWidgets('late create after cancellation is closed without rendering', (
    tester,
  ) async {
    final h = _Harness(tester)..openReply = Completer<ByteData?>();
    await h.mount();
    await h.show();
    await h.hover(const Offset(400, 20));
    await tester.pump(const Duration(milliseconds: 50));
    h.openReply!.complete(_Harness.reply({'ok': true, 'windowId': 41}));
    await h.settle();
    expect(h.closes.single['windowId'], 41);
    expect(find.byType(View), findsOneWidget);
    await h.finish();
  });

  testWidgets(
    'cancel hanging readiness closes immediately and ignores late view',
    (tester) async {
      final ready = Completer<ui.FlutterView>();
      final h = _Harness(tester)..readiness = (_) => ready.future;
      await h.mount();
      await h.show();
      final dismissal = h.controller.dismissAll();
      await h.settle();
      await dismissal;
      expect(h.closes.single['windowId'], 41);
      ready.complete(h.views[41]);
      await h.settle();
      expect(find.byType(View), findsOneWidget);
      await h.finish();
    },
  );

  testWidgets('replacement waits for native close acknowledgement', (
    tester,
  ) async {
    final h = _Harness(tester)..second = true;
    await h.mount();
    await h.show();
    h.closeReply = Completer<ByteData?>();
    await h.hover(const Offset(120, 20));
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.opens, hasLength(1));
    expect(h.closes, hasLength(1));
    final closeReply = h.closeReply!;
    h.closeReply = null;
    closeReply.complete(_Harness.reply({'ok': true}));
    await h.settle();
    expect(h.opens, hasLength(2));
    expect(find.text('Second', findRichText: true), findsOneWidget);
    await h.finish();
  });

  testWidgets('native close resumes replacement after failed cleanup', (
    tester,
  ) async {
    final h = _Harness(tester)..second = true;
    await h.mount();
    await h.show();
    h.failClose = true;
    await h.hover(const Offset(120, 20));
    await tester.pump(const Duration(milliseconds: 100));
    await h.settle();
    expect(h.errors, isNotEmpty);
    expect(h.opens, hasLength(1));
    h.failClose = false;
    h.closed.add(const FushellWindowClosedEvent(windowId: 41));
    await h.settle();
    expect(h.opens, hasLength(2));
    expect(find.text('Second', findRichText: true), findsOneWidget);
    await h.finish();
  });

  testWidgets('close failure retains ID and dispose retries cleanup', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.mount();
    await h.show();
    h.failClose = true;
    final failure = expectLater(
      h.controller.dispose(),
      throwsA(isA<FushellSurfaceException>()),
    );
    await tester.pump();
    await failure;
    expect(h.closes.single['windowId'], 41);
    h.failClose = false;
    await tester.runAsync(h.controller.dispose);
    expect(h.closes.map((r) => r['windowId']), [41, 41]);
    await h.finish();
  });

  testWidgets('readiness failure rolls back native handle', (tester) async {
    final h = _Harness(tester)
      ..readiness = (_) => Future.error(StateError('no view'));
    await h.mount();
    await h.show();
    expect(h.errors.single, isA<StateError>());
    expect(h.closes.single['windowId'], 41);
    expect(find.byType(View), findsOneWidget);
    await h.finish();
  });

  testWidgets('source layout movement dismisses without idle frame loop', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.mount();
    await h.show();
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    h.left = 20;
    await h.mount();
    await tester.pump();
    expect(h.closes.single['windowId'], 41);
    await h.finish();
  });

  testWidgets('pointer down dismisses before opening an application menu', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.mount();
    await h.show();
    tester.binding.handlePointerEvent(
      const PointerDownEvent(
        viewId: 7,
        device: 1,
        pointer: 1,
        kind: PointerDeviceKind.mouse,
        position: Offset(20, 20),
      ),
    );
    await tester.pump();
    expect(h.closes.single['windowId'], 41);
    tester.binding.handlePointerEvent(
      const PointerUpEvent(
        viewId: 7,
        device: 1,
        pointer: 1,
        kind: PointerDeviceKind.mouse,
        position: Offset(20, 20),
      ),
    );
    await h.finish();
  });

  testWidgets('native popup close removes content; parent resize dismisses', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.mount();
    await h.show();
    h.closed.add(const FushellWindowClosedEvent(windowId: 41));
    await tester.pump();
    expect(find.byType(View), findsOneWidget);
    await h.hover(const Offset(400, 20));
    await tester.pump(const Duration(milliseconds: 50));
    await h.show();
    expect(h.opens, hasLength(2));
    h.root.physicalSize = const Size(810, 48);
    await tester.pump();
    expect(h.closes.last['windowId'], 42);
    await h.finish();
  });

  testWidgets('focus duration and pending-show unmount cleanup', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.mount();
    h.focus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await h.settle();
    expect(h.opens, hasLength(1));
    await tester.pump(const Duration(milliseconds: 200));
    await h.settle();
    expect(h.closes, hasLength(1));
    await h.hover();
    h.source = false;
    await h.mount();
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.opens, hasLength(1));
    await h.finish();
  });
  testWidgets('independent root views own independent popup slots', (
    tester,
  ) async {
    final h = _Harness(tester);
    final secondRoot = _View(tester, 8)
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 48);
    h.views[8] = secondRoot;
    Widget app(String message) => MaterialApp(
      home: Center(
        child: NativeTooltip(
          message: message,
          waitDuration: const Duration(milliseconds: 100),
          animationDuration: Duration.zero,
          child: const SizedBox(
            width: 80,
            height: 48,
            child: ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      NativeTooltipHost(
        controller: h.controller,
        child: ViewCollection(
          views: [
            View(view: h.root, child: app('Root seven')),
            View(view: secondRoot, child: app('Root eight')),
          ],
        ),
      ),
      wrapWithView: false,
    );
    await h.hover(const Offset(400, 20));
    await tester.pump(const Duration(milliseconds: 100));
    await h.settle();
    tester.binding.handlePointerEvent(
      const PointerAddedEvent(
        viewId: 8,
        device: 2,
        kind: PointerDeviceKind.mouse,
      ),
    );
    tester.binding.handlePointerEvent(
      const PointerHoverEvent(
        viewId: 8,
        device: 2,
        kind: PointerDeviceKind.mouse,
        position: Offset(400, 20),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await h.settle();
    expect(h.opens.map((r) => r['parent']), [7, 8]);
    expect(h.closes, isEmpty);
    expect(find.byType(View), findsNWidgets(4));
    expect(find.text('Root seven', findRichText: true), findsOneWidget);
    expect(find.text('Root eight', findRichText: true), findsOneWidget);
    tester.binding.handlePointerEvent(
      const PointerRemovedEvent(
        viewId: 8,
        device: 2,
        kind: PointerDeviceKind.mouse,
      ),
    );
    await h.finish();
  });
}
