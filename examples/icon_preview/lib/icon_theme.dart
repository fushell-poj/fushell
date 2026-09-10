import 'package:flutter/foundation.dart';
import 'package:fushell/icons.dart';

import 'icon_image.dart';

/// One applied theme shared by an example's icons and menus.
/// A blank input follows the resolver's system-theme detection.
class IconThemeSelection extends ChangeNotifier {
  IconThemeSelection(this.resolver);
  final IconResolver resolver;
  String? resolvedTheme;
  String? overrideTheme;
  Object? error;
  bool busy = false;
  bool pendingDraft = false;
  int _generation = 0;
  bool _disposed = false;

  String get label {
    if (pendingDraft) return 'Theme changes not applied';
    if (error != null) return 'Theme error: $error';
    if (busy || resolvedTheme == null) return 'System: detecting…';
    return overrideTheme == null
        ? 'System: $resolvedTheme'
        : 'Override: $resolvedTheme';
  }

  void invalidateDraft() {
    ++_generation;
    busy = false;
    pendingDraft = true;
    notifyListeners();
  }

  Future<String?> apply(String input, {bool refresh = false}) async {
    final generation = ++_generation;
    final trimmed = input.trim();
    final requested = trimmed.isEmpty ? null : trimmed;
    if (refresh) refreshIconCaches(resolver);
    pendingDraft = false;
    busy = true;
    error = null;
    overrideTheme = requested;
    notifyListeners();
    try {
      final result = requested ?? await resolver.resolveTheme();
      if (_disposed || generation != _generation) return null;
      resolvedTheme = result;
      busy = false;
      notifyListeners();
      return result;
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = failure;
        busy = false;
        notifyListeners();
      }
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
