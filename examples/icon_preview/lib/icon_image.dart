import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:fushell/icons.dart';

/// Presentation only: the SDK resolver stays independent of Flutter and SVG.
class IconFileImage extends StatelessWidget {
  const IconFileImage({
    super.key,
    required this.result,
    this.size = 24,
    this.fallback = const Icon(Icons.broken_image_outlined),
    this.revision = 0,
  });
  final IconLookupResult result;
  final double size;
  final Widget fallback;
  final int revision;

  @override
  Widget build(BuildContext context) {
    if (result.format.toLowerCase() == 'svg') {
      return SvgPicture.file(
        File(result.path),
        key: ValueKey((result.path, revision)),
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return Image.file(
      File(result.path),
      key: ValueKey((result.path, revision)),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

/// Looks up only on input changes; old futures cannot overwrite newer requests.
class ResolvedIcon extends StatefulWidget {
  const ResolvedIcon({
    super.key,
    required this.resolver,
    required this.name,
    this.theme,
    this.size = 24,
    this.scale = 1,
    this.extraSearchPaths = const [],
    this.revision = 0,
    this.fallback = const Icon(Icons.image_not_supported_outlined),
  });
  final IconResolver resolver;
  final String name;
  final String? theme;
  final double size;
  final int scale;
  final List<String> extraSearchPaths;
  final int revision;
  final Widget fallback;

  @override
  State<ResolvedIcon> createState() => _ResolvedIconState();
}

class _ResolvedIconState extends State<ResolvedIcon> {
  IconLookupResult? _result;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _lookup();
  }

  @override
  void didUpdateWidget(ResolvedIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolver != widget.resolver ||
        oldWidget.name != widget.name ||
        oldWidget.theme != widget.theme ||
        oldWidget.size != widget.size ||
        oldWidget.scale != widget.scale ||
        oldWidget.revision != widget.revision ||
        !listEquals(oldWidget.extraSearchPaths, widget.extraSearchPaths)) {
      _lookup();
    }
  }

  Future<void> _lookup() async {
    final generation = ++_generation;
    _result = null;
    try {
      final result = widget.name.isEmpty
          ? null
          : await widget.resolver.lookup(
              name: widget.name,
              theme: widget.theme,
              size: widget.size.round(),
              scale: widget.scale,
              extraSearchPaths: widget.extraSearchPaths,
            );
      if (mounted && generation == _generation)
        setState(() => _result = result);
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _result = null);
    }
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _result == null
      ? widget.fallback
      : IconFileImage(
          result: _result!,
          size: widget.size,
          fallback: widget.fallback,
          revision: widget.revision,
        );
}

/// Refresh both resolver metadata and Flutter's decoded image caches.
void refreshIconCaches(IconResolver resolver) {
  resolver.clearCache();
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  svg.cache.clear();
}
