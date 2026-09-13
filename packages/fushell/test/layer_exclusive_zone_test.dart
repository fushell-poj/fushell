import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';

void main() {
  test('zone modes serialize identically in roles and updates', () {
    final modes = <LayerExclusiveZone, Object>{
      LayerExclusiveZone.auto: 'auto',
      LayerExclusiveZone.none: 0,
      LayerExclusiveZone.ignoreOtherZones: -1,
      const LayerExclusiveZone.fixed(32): 32,
      const LayerExclusiveZone.fixed(2147483647): 2147483647,
    };
    for (final mode in modes.entries) {
      final role = LayerSurfaceRole(
        namespace: 'test',
        layer: LayerSurfaceLayer.top,
        anchors: const {LayerSurfaceAnchor.top},
        exclusiveZone: mode.key,
      );
      expect(role.toJson()['exclusiveZone'], mode.value);
      expect(LayerSurfaceUpdate(exclusiveZone: mode.key).toJson(), {
        'exclusiveZone': mode.value,
      });
    }
  });

  test('role defaults to none and null update preserves policy', () {
    const role = LayerSurfaceRole(
      namespace: 'test',
      layer: LayerSurfaceLayer.top,
      anchors: {},
    );
    expect(role.exclusiveZone, LayerExclusiveZone.none);
    expect(role.toJson()['exclusiveZone'], 0);
    expect(const LayerSurfaceUpdate().toJson(), isEmpty);
  });

  test('fixed values have mode-aware equality and hash codes', () {
    final value = LayerExclusiveZone.fixed(32);
    expect(value, const LayerExclusiveZone.fixed(32));
    expect(value.hashCode, const LayerExclusiveZone.fixed(32).hashCode);
    expect(value, isNot(const LayerExclusiveZone.fixed(33)));
    expect(const LayerExclusiveZone.fixed(0), isNot(LayerExclusiveZone.none));
    expect(
      const LayerExclusiveZone.fixed(-1),
      isNot(LayerExclusiveZone.ignoreOtherZones),
    );
    expect(LayerExclusiveZone.auto, isNot(LayerExclusiveZone.none));
  });

  for (final invalid in [-2147483649, -1, 0, 2147483648]) {
    test('fixed($invalid) rejects invalid wire values at runtime', () {
      final zone = LayerExclusiveZone.fixed(invalid);
      expect(zone.toJson, throwsRangeError);
      expect(LayerSurfaceUpdate(exclusiveZone: zone).toJson, throwsRangeError);
      expect(
        LayerSurfaceRole(
          namespace: 'test',
          layer: LayerSurfaceLayer.top,
          anchors: const {},
          exclusiveZone: zone,
        ).toJson,
        throwsRangeError,
      );
    });
  }
}
