/// Optional widget and ownership helpers for the primitive window API.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'fushell.dart';

/// Renders explicit engine views with stable identity across metrics and order
/// changes. The builder runs below each [View], so View.of(context) is available.
///
/// No process-exit policy is imposed. [onLastViewClosed] runs once when an
/// observed nonempty collection becomes empty, including native closes. Initial
/// emptiness never invokes it. Omit it for a deliberately headless application.
/// [views], [listenable], and [closed] allow a caller-owned collection or tests.
class FushellWindowViews extends StatefulWidget {
  const FushellWindowViews({
    super.key,
    required this.builder,
    this.views,
    this.listenable,
    this.closed,
    this.onLastViewClosed,
  });

  final Widget Function(BuildContext context, ui.FlutterView view) builder;
  final Iterable<ui.FlutterView> Function()? views;
  final Listenable? listenable;
  final Stream<FushellWindowClosedEvent>? closed;
  final VoidCallback? onLastViewClosed;

  @override
  State<FushellWindowViews> createState() => _FushellWindowViewsState();
}

class _FushellWindowViewsState extends State<FushellWindowViews>
    with WidgetsBindingObserver {
  StreamSubscription<FushellWindowClosedEvent>? _subscription;
  bool _hadViews = false;

  List<ui.FlutterView> _views() =>
      (widget.views?.call() ?? ui.PlatformDispatcher.instance.views)
          .where((view) => view.viewId != 0)
          .toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.listenable?.addListener(_changed);
    _subscribe();
    _hadViews = _views().isNotEmpty;
  }

  void _subscribe() {
    _subscription = (widget.closed ?? FushellWindow.closed).listen((event) {
      _changed();
    });
  }

  @override
  void didUpdateWidget(FushellWindowViews oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable?.removeListener(_changed);
      widget.listenable?.addListener(_changed);
    }
    if (oldWidget.closed != widget.closed) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  void _changed() {
    if (!mounted) return;
    final hasViews = _views().isNotEmpty;
    final lastClosed = _hadViews && !hasViews;
    _hadViews = hasViews;
    setState(() {});
    if (lastClosed) widget.onLastViewClosed?.call();
  }

  @override
  void didChangeMetrics() => _changed();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.listenable?.removeListener(_changed);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final views = _views();
    if (views.isNotEmpty) _hadViews = true;
    return ViewCollection(
      views: [
        for (final view in views)
          View(
            key: ValueKey(view.viewId),
            view: view,
            child: Builder(builder: (context) => widget.builder(context, view)),
          ),
      ],
    );
  }
}

/// An open was cancelled by owner disposal or native window closure.
final class FushellWindowOpenCancelled implements Exception {
  const FushellWindowOpenCancelled();

  @override
  String toString() => 'Fushell window open cancelled';
}

/// Owns native windows from creation through readiness and attachment.
///
/// [open] publishes only ready handles through [windows] and [Listenable]. The
/// default readiness policy is [FushellWindow.viewById]'s bounded wait. Failure
/// closes the newly created window before propagating the error. If rollback
/// itself fails, the close error is propagated instead.
///
/// [dispose] immediately prevents new opens and cancels readiness waits. Native
/// creation cannot be cancelled: disposal waits for its reply and closes any
/// returned ID, even if the caller widget is already unmounted. A pending create
/// that never completes consequently keeps disposal pending. Late readiness
/// results/errors are consumed and never attach a view. No process exit occurs.
/// Callers must await open/close/dispose or handle their errors.
final class FushellWindowController implements Listenable {
  FushellWindowController({
    Future<ui.FlutterView> Function(int)? viewById,
    Future<void> Function(int)? closeWindow,
    Stream<FushellWindowClosedEvent>? closed,
  }) : _viewById = viewById ?? FushellWindow.viewById,
       _closeWindow = closeWindow ?? FushellWindow.closeWindow {
    _subscription = (closed ?? FushellWindow.closed).listen(_didClose);
  }

  final Future<ui.FlutterView> Function(int) _viewById;
  final Future<void> Function(int) _closeWindow;
  final _WindowChanges _changes = _WindowChanges();
  final Map<int, FushellOwnedWindow> _owned = {};
  final Set<int> _earlyCloses = {};
  final Set<Future<void>> _pending = {};
  final Completer<void> _cancelled = Completer<void>();
  late final StreamSubscription<FushellWindowClosedEvent> _subscription;
  bool _disposed = false;
  Future<void>? _disposal;

  Iterable<FushellOwnedWindow> get windows => List.unmodifiable(
    _owned.values.where((window) => window._view != null && !window.isClosed),
  );

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  /// Wraps the existing primitive without duplicating its surface options.
  Future<FushellOwnedWindow> open({required Future<int> Function() create}) {
    if (_disposed) return Future.error(const FushellWindowOpenCancelled());
    final settled = Completer<void>();
    _pending.add(settled.future);
    final result = _open(create);
    result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          _pending.remove(settled.future);
          if (_pending.isEmpty) _earlyCloses.clear();
          settled.complete();
        });
    return result;
  }

  Future<FushellOwnedWindow> _open(Future<int> Function() create) async {
    final id = await create();
    final window = FushellOwnedWindow._(this, id);
    _owned[id] = window;
    if (_earlyCloses.remove(id)) {
      _didClose(FushellWindowClosedEvent(windowId: id));
    }
    try {
      if (_disposed || window.isClosed) {
        throw const FushellWindowOpenCancelled();
      }
      final view = await Future.any<ui.FlutterView>([
        _viewById(id),
        _cancelled.future.then((_) => throw const FushellWindowOpenCancelled()),
        window._closed.future.then(
          (_) => throw const FushellWindowOpenCancelled(),
        ),
      ]);
      if (_disposed || window.isClosed) {
        throw const FushellWindowOpenCancelled();
      }
      window._view = view;
      _changes.changed();
      if (_disposed || window.isClosed) {
        throw const FushellWindowOpenCancelled();
      }
      return window;
    } catch (_) {
      await window.close();
      rethrow;
    }
  }

  void _didClose(FushellWindowClosedEvent event) {
    final window = _owned.remove(event.windowId);
    if (window == null) {
      if (_pending.isNotEmpty) _earlyCloses.add(event.windowId);
      return;
    }
    window._markClosed();
    if (!_disposed) _changes.changed();
  }

  /// Idempotent asynchronous disposal. Reclaims ready and pending windows.
  /// On cleanup failure ownership is retained; call dispose again to retry.
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    return _disposal = _dispose();
  }

  Future<void> _dispose() async {
    try {
      await Future.wait<void>([
        for (final window in _owned.values.toList()) window.close(),
        ..._pending,
      ]);
      // A pending create may have failed its rollback after our first snapshot.
      // Retain and retry that ownership; failed cleanup must not look successful.
      await Future.wait<void>([
        for (final window in _owned.values.toList()) window.close(),
      ]);
      await _subscription.cancel();
      _changes.dispose();
    } catch (_) {
      _disposal = null;
      rethrow;
    }
  }
}

/// A ready window owned by a [FushellWindowController]. Native close events and
/// concurrent [close] calls share one future. A failed close retains ownership
/// and can be retried. Closing a window does not exit the process.
final class FushellOwnedWindow {
  FushellOwnedWindow._(this._owner, this.windowId);

  final FushellWindowController _owner;
  final int windowId;
  ui.FlutterView? _view;
  final Completer<void> _closed = Completer<void>();
  Future<void>? _closing;

  ui.FlutterView get view => _view!;
  bool get isClosed => _closed.isCompleted;

  void _markClosed() {
    if (!isClosed) _closed.complete();
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    if (isClosed) return Future.value();
    return _closing = _close();
  }

  Future<void> _close() async {
    try {
      await Future<void>.sync(() => _owner._closeWindow(windowId));
      _owner._didClose(FushellWindowClosedEvent(windowId: windowId));
    } catch (_) {
      _closing = null;
      rethrow;
    }
  }
}

class _WindowChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}
