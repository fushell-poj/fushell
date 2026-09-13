/// Hover tooltips rendered in native, input-transparent popup views.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'fushell.dart';

class _TooltipChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// Owns tooltip popups, serializing replacement separately for each parent view.
///
/// Share one controller when multiple hosts can target the same parent. Await
/// [dismissAll] before opening an application popup on that parent. Failed closes
/// retain ownership: retry dismissAll/dispose, or wait for the native close event.
class NativeTooltipController implements Listenable {
  NativeTooltipController({
    Future<ui.FlutterView> Function(int)? viewById,
    Stream<FushellWindowClosedEvent>? closed,
    this.onError,
  }) : _viewById = viewById ?? FushellWindow.viewById {
    _closed = (closed ?? FushellWindow.closed).listen(_didClose);
  }

  final Future<ui.FlutterView> Function(int) _viewById;
  final void Function(Object error, StackTrace stackTrace)? onError;
  final _TooltipChanges _changes = _TooltipChanges();
  final Map<int, _Slot> _slots = {};
  final Set<int> _closedDuringOpen = {};
  late final StreamSubscription<FushellWindowClosedEvent> _closed;
  bool _disposed = false;
  bool _notifierDisposed = false;
  Future<void>? _disposal;

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  void _report(Object error, StackTrace stack) {
    if (onError != null) {
      onError!(error, stack);
    } else {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'fushell native tooltip',
        ),
      );
    }
  }

  void _run(Future<void> future) {
    unawaited(future.catchError((Object e, StackTrace s) => _report(e, s)));
  }

  void _notify() {
    if (!_notifierDisposed) _changes.changed();
  }

  void _didClose(FushellWindowClosedEvent event) {
    if (_slots.values.any((slot) => slot.opening)) {
      _closedDuringOpen.add(event.windowId);
    }
    for (final slot in _slots.values.toList()) {
      final entry = slot.entry;
      if (slot.parent == event.windowId) {
        slot.wanted?.cancel();
        slot.wanted = null;
        entry?.cancel();
        _run(_drain(slot));
      }
      if (entry?.id == event.windowId) {
        entry!.cancel();
        slot.entry = null;
        if (identical(slot.wanted, entry)) slot.wanted = null;
        _notify();
        _run(_drain(slot));
      }
    }
  }

  void _show(_Entry entry) {
    if (_disposed) return;
    final slot = _slots.putIfAbsent(entry.parent, () => _Slot(entry.parent));
    slot.wanted?.cancel();
    slot.wanted = entry;
    _run(_drain(slot));
  }

  void _hide(_Entry entry) {
    entry.cancel();
    final slot = _slots[entry.parent];
    if (slot == null) return;
    if (identical(slot.wanted, entry)) slot.wanted = null;
    _run(_drain(slot));
  }

  Future<void> _drain(_Slot slot) {
    if (slot.running != null) return slot.running!;
    final completer = Completer<void>();
    slot.running = completer.future;
    () async {
      try {
        while (true) {
          final current = slot.entry;
          if (current != null &&
              (current.cancelled || !identical(current, slot.wanted))) {
            // Keep the handle until native acknowledges cleanup. A failed close
            // must not permit a replacement to open on the same parent.
            if (current.id != null) {
              try {
                await FushellWindow.closeWindow(current.id!);
              } on FushellSurfaceException catch (error) {
                if (error.code != 'WindowNotFound') rethrow;
              }
            }
            if (identical(slot.entry, current)) slot.entry = null;
            _notify();
            continue;
          }
          if (current != null || slot.wanted == null || _disposed) break;
          final next = slot.wanted!;
          if (next.cancelled) {
            slot.wanted = null;
            continue;
          }
          slot.entry = next;
          try {
            slot.opening = true;
            next.id = await FushellWindow.openPopup(
              parent: next.parent,
              popup: PopupSurfaceRole(
                inputPassthrough: true,
                positioner: next.positioner,
              ),
            );
            if (_closedDuringOpen.remove(next.id)) next.cancel();
            slot.opening = false;
            if (!_slots.values.any((slot) => slot.opening)) {
              _closedDuringOpen.clear();
            }
            if (next.cancelled || !identical(slot.wanted, next) || _disposed) {
              next.cancel();
              continue;
            }
            // Cancellation wins even if readiness hangs after native create.
            final view = await Future.any<ui.FlutterView?>([
              _viewById(next.id!),
              next.cancellation.future.then((_) => null),
            ]);
            if (view == null || next.cancelled || _disposed) continue;
            next.view = view;
            _notify();
          } catch (error, stack) {
            next.cancel();
            if (identical(slot.wanted, next)) slot.wanted = null;
            slot.opening = false;
            _report(error, stack);
            // Roll back any allocated native surface on the next iteration.
          }
        }
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        slot.running = null;
        if (slot.entry == null && slot.wanted == null) {
          _slots.remove(slot.parent);
        }
      }
    }();
    return completer.future;
  }

  /// Cancels pending shows and awaits cleanup. Failed handles remain retryable.
  Future<void> dismissAll() async {
    final slots = _slots.values.toList();
    for (final slot in slots) {
      slot.wanted?.cancel();
      slot.wanted = null;
      slot.entry?.cancel();
    }
    await Future.wait(slots.map(_drain));
  }

  void _detach(Object host) {
    for (final slot in _slots.values.toList()) {
      if (slot.wanted?.host == host) {
        slot.wanted!.cancel();
        slot.wanted = null;
      }
      if (slot.entry?.host == host) slot.entry!.cancel();
      _run(_drain(slot));
    }
  }

  /// Async disposal; on failure this remains retryable and keeps native handles.
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    return _disposal = () async {
      try {
        await dismissAll();
        await _closed.cancel();
        if (!_notifierDisposed) {
          _notifierDisposed = true;
          _changes.dispose();
        }
      } catch (_) {
        _disposal = null;
        rethrow;
      }
    }();
  }
}

class _Slot {
  _Slot(this.parent);
  final int parent;
  _Entry? wanted;
  _Entry? entry;
  Future<void>? running;
  bool opening = false;
}

class _Entry {
  _Entry({
    required this.host,
    required this.parent,
    required this.positioner,
    required this.content,
  });
  final Object host;
  final int parent;
  final PopupPositioner positioner;
  final Widget content;
  final Completer<void> cancellation = Completer<void>();
  int? id;
  ui.FlutterView? view;
  bool get cancelled => cancellation.isCompleted;
  void cancel() {
    if (!cancelled) cancellation.complete();
  }
}

/// Non-rendering root for [NativeTooltip], installed above explicit [View]s.
///
/// Use with runWidget, above the application's Views. [child] must render only
/// application-owned views; do not enumerate tooltip views a second time.
/// This host never looks up an ambient View. Each popup has its own View while
/// the source supplies captured inherited presentation state.
class NativeTooltipHost extends StatefulWidget {
  const NativeTooltipHost({super.key, required this.child, this.controller});
  final Widget child;
  final NativeTooltipController? controller;

  @override
  State<NativeTooltipHost> createState() => _NativeTooltipHostState();
}

class _NativeTooltipHostState extends State<NativeTooltipHost> {
  late NativeTooltipController controller;
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? NativeTooltipController();
    controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(NativeTooltipHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      controller.removeListener(_changed);
      controller._detach(this);
      if (oldWidget.controller == null) controller._run(controller.dispose());
      controller = widget.controller ?? NativeTooltipController();
      controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller._detach(this);
    if (widget.controller == null) controller._run(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _TooltipScope(
    host: this,
    controller: controller,
    child: ViewCollection(
      views: [
        widget.child,
        for (final slot in controller._slots.values)
          if (slot.entry case final entry?)
            if (entry.host == this && entry.view != null && !entry.cancelled)
              View(
                key: ValueKey(entry.id),
                view: entry.view!,
                child: entry.content,
              ),
      ],
    ),
  );
}

class _TooltipScope extends InheritedWidget {
  const _TooltipScope({
    required this.host,
    required this.controller,
    required super.child,
  });
  final _NativeTooltipHostState host;
  final NativeTooltipController controller;
  @override
  bool updateShouldNotify(_TooltipScope oldWidget) =>
      oldWidget.host != host || oldWidget.controller != controller;
}

/// A desktop hover/focus tooltip in a native popup, with Material-style defaults.
///
/// A [NativeTooltipHost] must surround the source View. Standard Material Tooltip
/// is unaffected; replace it explicitly. Hover remains visible while stationary.
/// [showDuration] limits keyboard-focus display; [exitDuration] delays hover exit.
/// Pointer-down, source movement, metrics changes and disposal cancel immediately.
/// Rich text, touch/long-press triggers, nested tooltips and interactive content
/// are not supported. [animationDuration] controls fade-in (no exit animation).
class NativeTooltip extends StatefulWidget {
  const NativeTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration,
    this.showDuration,
    this.exitDuration,
    this.preferBelow,
    this.verticalOffset,
    this.edgeGap,
    this.decoration,
    this.textStyle,
    this.padding,
    this.margin,
    this.constraints,
    this.excludeFromSemantics = false,
    this.animationDuration = const Duration(milliseconds: 150),
  });

  final String message;
  final Widget child;
  final Duration? waitDuration;
  final Duration? showDuration;
  final Duration? exitDuration;
  final bool? preferBelow;

  /// Distance from the source center, as in Flutter's Material Tooltip.
  /// Defaults to TooltipThemeData.verticalOffset, then 24 logical pixels.
  /// Cannot be supplied together with [edgeGap].
  final double? verticalOffset;

  /// Distance from the source bottom/top edge rather than its center.
  /// Overrides the theme's verticalOffset. Must be finite and non-negative.
  /// Integer rounding can shift placement by one logical pixel; this measures
  /// the popup surface, not its painted bounds. Compositor flip/slide applies.
  final double? edgeGap;

  void _validatePosition() {
    if (edgeGap != null && verticalOffset != null) {
      throw ArgumentError('verticalOffset and edgeGap are mutually exclusive');
    }
    if (edgeGap != null && (!edgeGap!.isFinite || edgeGap! < 0)) {
      throw ArgumentError.value(
        edgeGap,
        'edgeGap',
        'must be finite and non-negative',
      );
    }
  }

  final Decoration? decoration;
  final TextStyle? textStyle;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BoxConstraints? constraints;
  final bool excludeFromSemantics;
  final Duration animationDuration;

  @override
  State<NativeTooltip> createState() => _NativeTooltipState();
}

class _NativeTooltipState extends State<NativeTooltip>
    with WidgetsBindingObserver {
  Timer? _wait;
  Timer? _exit;
  Timer? _showTimer;
  _Entry? _entry;
  _TooltipScope? _scope;
  bool _hovered = false;
  bool _focused = false;
  Rect? _anchor;
  Size? _parentSize;
  double? _parentRatio;
  ui.FlutterView? _parent;

  @override
  void initState() {
    super.initState();
    widget._validatePosition();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dismiss();
    _scope = context.dependOnInheritedWidgetOfExactType<_TooltipScope>();
    assert(
      _scope != null,
      'NativeTooltip requires a NativeTooltipHost above its View.',
    );
  }

  @override
  void didUpdateWidget(NativeTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message ||
        oldWidget.animationDuration != widget.animationDuration ||
        oldWidget.textStyle != widget.textStyle ||
        oldWidget.decoration != widget.decoration ||
        oldWidget.padding != widget.padding ||
        oldWidget.margin != widget.margin ||
        oldWidget.constraints != widget.constraints ||
        oldWidget.preferBelow != widget.preferBelow ||
        oldWidget.verticalOffset != widget.verticalOffset ||
        oldWidget.edgeGap != widget.edgeGap) {
      _dismiss();
    }
  }

  Rect? _rect() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    if (!rect.isFinite || rect.isEmpty) return null;
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    // Inward rounding guarantees a positive, valid parent-local integer anchor.
    final clipped = rect.intersect(Offset.zero & size);
    final left = clipped.left.ceilToDouble();
    final top = clipped.top.ceilToDouble();
    final right = clipped.right.floorToDouble();
    final bottom = clipped.bottom.floorToDouble();
    if (right <= left || bottom <= top) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _dismiss() {
    _wait?.cancel();
    _exit?.cancel();
    _showTimer?.cancel();
    final entry = _entry;
    _entry = null;
    if (entry != null) _scope?.controller._hide(entry);
  }

  void _enter() {
    _hovered = true;
    _exit?.cancel();
    _showTimer?.cancel();
    if (_entry != null && !_entry!.cancelled) return;
    _schedule();
  }

  void _schedule() {
    _wait?.cancel();
    if (widget.message.isEmpty || _scope == null) return;
    final theme = TooltipTheme.of(context);
    _wait = Timer(
      widget.waitDuration ??
          theme.waitDuration ??
          const Duration(milliseconds: 500),
      _present,
    );
  }

  void _leave() {
    _hovered = false;
    _wait?.cancel();
    final theme = TooltipTheme.of(context);
    _exit = Timer(
      widget.exitDuration ??
          theme.exitDuration ??
          const Duration(milliseconds: 100),
      _dismiss,
    );
  }

  void _focus(bool value) {
    _focused = value;
    if (value) {
      if (!_hovered) _schedule();
    } else if (!_hovered) {
      _dismiss();
    }
  }

  void _present() {
    if (!mounted || (!_hovered && !_focused) || _scope == null) return;
    final anchor = _rect();
    if (anchor == null) return;
    final view = View.of(context);
    _parent = view;
    _parentSize = view.physicalSize;
    _parentRatio = view.devicePixelRatio;
    _anchor = anchor;
    final theme = Theme.of(context);
    final tooltipTheme = TooltipTheme.of(context);
    final direction = Directionality.of(context);
    final media = MediaQuery.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final dark = theme.brightness == Brightness.dark;
    var style = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(fontSize: 12, color: dark ? Colors.black : Colors.white)
        .merge(widget.textStyle ?? tooltipTheme.textStyle);
    if (media.boldText) style = style.copyWith(fontWeight: FontWeight.bold);
    final span = TextSpan(text: widget.message, style: style);
    final decoration =
        widget.decoration ??
        tooltipTheme.decoration ??
        BoxDecoration(
          color: (dark ? Colors.white : Colors.grey[700]!).withValues(
            alpha: 0.9,
          ),
          borderRadius: BorderRadius.circular(4),
        );
    final padding =
        (widget.padding ??
                tooltipTheme.padding ??
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4))
            .resolve(direction) +
        decoration.padding.resolve(direction);
    final margin = (widget.margin ?? tooltipTheme.margin ?? EdgeInsets.zero)
        .resolve(direction);
    final constraints =
        (widget.constraints ??
                tooltipTheme.constraints ??
                const BoxConstraints(minHeight: 24, maxWidth: 320))
            .enforce(const BoxConstraints(maxWidth: 4096, maxHeight: 4096));
    final painter =
        TextPainter(
          text: span,
          textDirection: direction,
          textScaler: media.textScaler,
          locale: locale,
        )..layout(
          minWidth: math.max(0, constraints.minWidth - padding.horizontal),
          maxWidth: math.max(0, constraints.maxWidth - padding.horizontal),
        );
    final size = constraints.constrain(
      Size(
        painter.width + padding.horizontal,
        painter.height + padding.vertical,
      ),
    );
    painter.dispose();
    final width = math.max(1, (size.width + margin.horizontal).ceil());
    final height = math.max(1, (size.height + margin.vertical).ceil());
    final below = widget.preferBelow ?? tooltipTheme.preferBelow ?? true;
    final offset =
        (widget.edgeGap ??
                widget.verticalOffset ??
                tooltipTheme.verticalOffset ??
                24)
            .round();
    Widget content = Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: decoration,
        child: Padding(
          padding: padding,
          child: RichText(
            text: span,
            textDirection: direction,
            textScaler: media.textScaler,
            locale: locale,
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
        ),
      ),
    );
    content = ExcludeSemantics(child: IgnorePointer(child: content));
    if (!media.disableAnimations && widget.animationDuration > Duration.zero) {
      content = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: widget.animationDuration,
        builder: (context, value, child) =>
            Opacity(opacity: value, child: child),
        child: content,
      );
    }
    content = Directionality(textDirection: direction, child: content);
    content = Localizations.override(context: context, child: content);
    content = InheritedTheme.capture(from: context, to: null).wrap(content);
    final captured = content;
    content = Builder(
      builder: (popupContext) {
        final popupView = View.of(popupContext);
        return MediaQuery(
          data: media.copyWith(
            size: popupView.physicalSize / popupView.devicePixelRatio,
            devicePixelRatio: popupView.devicePixelRatio,
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
            viewInsets: EdgeInsets.zero,
          ),
          child: captured,
        );
      },
    );
    final entry = _Entry(
      host: _scope!.host,
      parent: view.viewId,
      content: content,
      positioner: PopupPositioner(
        width: width,
        height: height,
        anchorRect: PopupAnchorRect(
          x: anchor.left.toInt(),
          y: anchor.top.toInt(),
          width: anchor.width.toInt(),
          height: anchor.height.toInt(),
        ),
        anchor: widget.edgeGap == null
            ? PopupAnchor.none
            : below
            ? PopupAnchor.bottom
            : PopupAnchor.top,
        gravity: below ? PopupGravity.bottom : PopupGravity.top,
        offset: PopupOffset(y: below ? offset : -offset),
        constraintAdjustment: const {
          PopupConstraintAdjustment.flipY,
          PopupConstraintAdjustment.slideX,
          PopupConstraintAdjustment.slideY,
        },
      ),
    );
    _entry = entry;
    _scope!.controller._show(entry);
    _watchAnchor(entry);
    if (!_hovered) {
      _showTimer = Timer(
        widget.showDuration ??
            tooltipTheme.showDuration ??
            const Duration(milliseconds: 1500),
        _dismiss,
      );
    }
  }

  void _watchAnchor(_Entry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_entry, entry) || entry.cancelled) return;
      if (_rect() != _anchor) {
        _dismiss();
      } else {
        // Watch existing layout/animation frames without scheduling idle frames.
        _watchAnchor(entry);
      }
    });
  }

  @override
  void didChangeMetrics() {
    if (_parent?.physicalSize != _parentSize ||
        _parent?.devicePixelRatio != _parentRatio) {
      _dismiss();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget._validatePosition();
    return Semantics(
      tooltip: widget.excludeFromSemantics || widget.message.isEmpty
          ? null
          : widget.message,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: _focus,
        child: MouseRegion(
          onEnter: (_) => _enter(),
          onExit: (_) => _leave(),
          child: Listener(
            onPointerDown: (_) => _dismiss(),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
