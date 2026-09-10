import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';
import 'package:fushell/windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ready window attaches, closes once, and leaves owner empty', () async {
    final closed = <int>[];
    final owner = FushellWindowController(
      viewById: (_) async => ui.PlatformDispatcher.instance.implicitView!,
      closeWindow: (id) async {
        closed.add(id);
      },
      closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
    );
    final window = await owner.open(create: () async => 1);
    expect(window.view, ui.PlatformDispatcher.instance.implicitView!);
    expect(owner.windows.single, window);
    final first = window.close();
    expect(window.close(), same(first));
    await first;
    await window.close();
    expect(closed, [1]);
    expect(owner.windows, isEmpty);
    await owner.dispose();
  });

  test(
    'reentrant create disposal waits for late creation and close acknowledgement',
    () async {
      final create = Completer<int>();
      final close = Completer<void>();
      final closed = <int>[];
      final owner = FushellWindowController(
        viewById: (_) => throw StateError('must not attach'),
        closeWindow: (id) {
          closed.add(id);
          return close.future;
        },
        closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
      );
      late Future<void> disposal;
      var disposed = false;
      final opening = owner.open(
        create: () {
          disposal = owner.dispose().then((_) {
            disposed = true;
          });
          return create.future;
        },
      );
      final rejected = expectLater(
        opening,
        throwsA(isA<FushellWindowOpenCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      create.complete(42);
      await Future<void>.delayed(Duration.zero);
      expect(closed, [42]);
      expect(disposed, isFalse);
      close.complete();
      await rejected;
      await disposal;
      expect(disposed, isTrue);
      expect(owner.windows, isEmpty);
    },
  );

  test('dispose during pending create reclaims its late ID', () async {
    final create = Completer<int>();
    final closed = <int>[];
    var readinessCalls = 0;
    final owner = FushellWindowController(
      viewById: (_) {
        readinessCalls++;
        throw StateError('unexpected');
      },
      closeWindow: (id) async {
        closed.add(id);
      },
      closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
    );
    final opened = owner.open(create: () => create.future);
    final rejected = expectLater(
      opened,
      throwsA(isA<FushellWindowOpenCancelled>()),
    );
    var disposed = false;
    final disposal = owner.dispose().then((_) {
      disposed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    create.complete(7);
    await rejected;
    await disposal;
    expect(closed, [7]);
    expect(readinessCalls, 0);
    await expectLater(
      owner.open(create: () async => 8),
      throwsA(isA<FushellWindowOpenCancelled>()),
    );
  });

  test(
    'dispose during readiness closes promptly and consumes late errors',
    () async {
      final ready = Completer<ui.FlutterView>();
      final started = Completer<void>();
      final closed = <int>[];
      final owner = FushellWindowController(
        viewById: (_) {
          started.complete();
          return ready.future;
        },
        closeWindow: (id) async {
          closed.add(id);
        },
        closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
      );
      final opened = owner.open(create: () async => 9);
      final rejected = expectLater(
        opened,
        throwsA(isA<FushellWindowOpenCancelled>()),
      );
      await started.future;
      await owner.dispose();
      await rejected;
      ready.completeError(StateError('late readiness failure'));
      await Future<void>.delayed(Duration.zero);
      expect(closed, [9]);
      expect(owner.windows, isEmpty);
    },
  );

  test('readiness failure rolls back before returning the error', () async {
    final failure = StateError('view missing');
    final close = Completer<void>();
    final owner = FushellWindowController(
      viewById: (_) => Future.error(failure),
      closeWindow: (_) => close.future,
      closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
    );
    var settled = false;
    final opened = owner.open(create: () async => 2);
    final rejected = expectLater(opened, throwsA(same(failure))).then((_) {
      settled = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    expect(owner.windows, isEmpty);
    close.complete();
    await rejected;
    await owner.dispose();
  });

  test('failed close retains ownership and can be retried', () async {
    var attempts = 0;
    final owner = FushellWindowController(
      viewById: (_) async => ui.PlatformDispatcher.instance.implicitView!,
      closeWindow: (_) {
        if (++attempts == 1) throw StateError('close failed');
        return Future.value();
      },
      closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
    );
    final window = await owner.open(create: () async => 3);
    await expectLater(window.close(), throwsStateError);
    expect(owner.windows.single, window);
    expect(window.isClosed, isFalse);
    await window.close();
    expect(attempts, 2);
    await owner.dispose();
  });

  test(
    'late create rollback failure rejects disposal and cleanup can retry',
    () async {
      final create = Completer<int>();
      var fail = true;
      final closed = <int>[];
      final owner = FushellWindowController(
        closeWindow: (id) async {
          if (fail) throw StateError('close failed');
          closed.add(id);
        },
        closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
      );
      final opened = expectLater(
        owner.open(create: () => create.future),
        throwsStateError,
      );
      final disposal = expectLater(owner.dispose(), throwsStateError);
      create.complete(4);
      await opened;
      await disposal;
      fail = false;
      await owner.dispose();
      expect(closed, [4]);
    },
  );

  test(
    'native close during readiness cancels without duplicate native close',
    () async {
      final events = StreamController<FushellWindowClosedEvent>.broadcast(
        sync: true,
      );
      final started = Completer<void>();
      final ready = Completer<ui.FlutterView>();
      var closes = 0;
      final owner = FushellWindowController(
        viewById: (_) {
          started.complete();
          return ready.future;
        },
        closeWindow: (_) async {
          closes++;
        },
        closed: events.stream,
      );
      final opened = expectLater(
        owner.open(create: () async => 5),
        throwsA(isA<FushellWindowOpenCancelled>()),
      );
      await started.future;
      events.add(const FushellWindowClosedEvent(windowId: 5));
      await opened;
      expect(closes, 0);
      expect(owner.windows, isEmpty);
      await owner.dispose();
      await events.close();
    },
  );

  test('native close before create reply never attaches stale ID', () async {
    final events = StreamController<FushellWindowClosedEvent>.broadcast(
      sync: true,
    );
    final create = Completer<int>();
    var closes = 0;
    final owner = FushellWindowController(
      viewById: (_) => throw StateError('must not request readiness'),
      closeWindow: (_) async {
        closes++;
      },
      closed: events.stream,
    );
    final opened = expectLater(
      owner.open(create: () => create.future),
      throwsA(isA<FushellWindowOpenCancelled>()),
    );
    events.add(const FushellWindowClosedEvent(windowId: 6));
    create.complete(6);
    await opened;
    expect(closes, 0);
    await owner.dispose();
    await events.close();
  });

  testWidgets(
    'unmount while creating reclaims window instead of attaching it',
    (tester) async {
      await tester.runAsync(() async {
        final create = Completer<int>();
        final closed = <int>[];
        final owner = FushellWindowController(
          viewById: (_) async => tester.view,
          closeWindow: (id) async {
            closed.add(id);
          },
          closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
        );
        Future<void>? disposal;
        Object? openError;
        final opened = owner
            .open(create: () => create.future)
            .then<void>(
              (_) => fail('disposed widget must not attach a view'),
              onError: (Object error) {
                openError = error;
              },
            );
        await tester.pumpWidget(
          _OwnerHost(
            onDispose: () {
              disposal = owner.dispose();
            },
          ),
        );
        await tester.pumpWidget(const SizedBox());
        create.complete(31);
        await tester.pump();
        await opened;
        await disposal;
        expect(openError, isA<FushellWindowOpenCancelled>());
        expect(closed, [31]);
        expect(owner.windows, isEmpty);
      });
    },
  );

  testWidgets(
    'stable view identity survives reorder, metrics and sibling close',
    (tester) async {
      final first = _TestView(tester, 11);
      final second = _TestView(tester, 12);
      final changes = ChangeNotifier();
      var views = <ui.FlutterView>[first, second];
      final states = <int, State>{};
      await tester.pumpWidget(
        FushellWindowViews(
          views: () => views,
          listenable: changes,
          closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
          builder: (context, view) {
            expect(View.of(context), same(view));
            return _Probe(id: view.viewId, states: states);
          },
        ),
        wrapWithView: false,
      );
      final original = states[12];
      views = [second, first];
      changes.notifyListeners();
      await tester.pump();
      tester.binding.handleMetricsChanged();
      await tester.pump();
      views = [second];
      changes.notifyListeners();
      await tester.pump();
      expect(states[12], same(original));
      expect(original!.mounted, isTrue);
      await tester.pumpWidget(
        const ViewCollection(views: []),
        wrapWithView: false,
      );
      expect(original.mounted, isFalse);
      changes.dispose();
    },
  );

  testWidgets(
    'initial view first closure invokes policy once; startup stays headless',
    (tester) async {
      final changes = ChangeNotifier();
      var views = <ui.FlutterView>[];
      var exits = 0;
      Widget root() => FushellWindowViews(
        views: () => views,
        listenable: changes,
        closed: StreamController<FushellWindowClosedEvent>.broadcast().stream,
        onLastViewClosed: () {
          exits++;
        },
        builder: (_, _) => const SizedBox(),
      );
      await tester.pumpWidget(root(), wrapWithView: false);
      changes.notifyListeners();
      await tester.pump();
      expect(exits, 0);
      views = [_TestView(tester, 21)];
      // The initial build must observe this view even without an addition metric.
      await tester.pumpWidget(root(), wrapWithView: false);
      views = [];
      changes.notifyListeners();
      await tester.pump();
      changes.notifyListeners();
      await tester.pump();
      expect(exits, 1);
      await tester.pumpWidget(
        const ViewCollection(views: []),
        wrapWithView: false,
      );
      changes.dispose();
    },
  );
}

class _TestView extends TestFlutterView {
  _TestView(WidgetTester tester, this.viewId)
    : super(
        view: tester.view,
        platformDispatcher: tester.platformDispatcher,
        display: tester.view.display,
      );
  @override
  final int viewId;
}

class _Probe extends StatefulWidget {
  const _Probe({required this.id, required this.states});
  final int id;
  final Map<int, State> states;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.states[widget.id] = this;
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _OwnerHost extends StatefulWidget {
  const _OwnerHost({required this.onDispose});
  final VoidCallback onDispose;
  @override
  State<_OwnerHost> createState() => _OwnerHostState();
}

class _OwnerHostState extends State<_OwnerHost> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
