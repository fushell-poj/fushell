import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:fushell/icons.dart';
import 'package:icon_preview/icon_image.dart';

/// DBusMenu icon-data is encoded PNG, unlike the SNI raw ARGB pixmaps.
class TrayMenuIcon extends StatelessWidget {
  const TrayMenuIcon({
    super.key,
    required this.resolver,
    required this.name,
    this.data,
    this.theme,
    this.extraPaths = const [],
    this.revision = 0,
  });
  final IconResolver resolver;
  final String name;
  final DBusValue? data;
  final String? theme;
  final List<String> extraPaths;
  final int revision;

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      if (data != null)
        bytes = Uint8List.fromList(data!.asByteArray().toList());
    } catch (_) {
      /* Malformed optional icon data must not break the menu. */
    }
    final fallback = bytes == null || bytes.isEmpty
        ? const SizedBox(width: 20, height: 20)
        : Image.memory(
            bytes,
            width: 20,
            height: 20,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.broken_image_outlined, size: 20),
          );
    return ResolvedIcon(
      resolver: resolver,
      name: name,
      theme: theme,
      revision: revision,
      extraSearchPaths: extraPaths,
      scale: MediaQuery.devicePixelRatioOf(context).ceil(),
      size: 20,
      fallback: fallback,
    );
  }
}
