import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';

const placement = PopupPositioner(
  width: 120,
  height: 80,
  anchorRect: PopupAnchorRect(x: 0, y: 0, width: 20, height: 20),
);
const press = PointerDownEvent(
  viewId: 7,
  timeStamp: Duration(microseconds: 1234000),
  kind: PointerDeviceKind.mouse,
  buttons: kSecondaryMouseButton,
  device: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final requests = <Map<String, dynamic>>[];
  Object? token = 91;
  setUp(() {
    requests.clear();
    token = 91;
    messenger.setMockMessageHandler('dev.fushell/surface', (data) async {
      final request =
          jsonDecode(const StringCodec().decodeMessage(data)!)
              as Map<String, dynamic>;
      requests.add(request);
      return const StringCodec().encodeMessage(
        jsonEncode({
          'ok': true,
          if (request['method'] == 'input.capture') 'inputToken': token,
          if (request['method'] == 'window.open') 'windowId': 42,
        }),
      );
    });
  });
  tearDown(() => messenger.setMockMessageHandler('dev.fushell/surface', null));

  test(
    'captures the actual down fingerprint and forwards only its opaque token',
    () async {
      final grab = await PopupGrab.capture(press);
      expect(grab.windowId, 7);
      final capture = Map<String, dynamic>.of(requests.single)..remove('id');
      expect(capture, {
        'method': 'input.capture',
        'windowId': 7,
        'timeMicros': 1234000,
        'buttons': kSecondaryMouseButton,
        'device': 0,
      });
      expect(
        await FushellWindow.openPopup(
          parent: 7,
          popup: PopupSurfaceRole(positioner: placement, grab: grab),
        ),
        42,
      );
      expect((requests.last['role'] as Map)['grabToken'], 91);
    },
  );

  test(
    'cannot reuse a credential for another parent or pass-through popup',
    () async {
      final grab = await PopupGrab.capture(press);
      await expectLater(
        FushellWindow.openPopup(
          parent: 8,
          popup: PopupSurfaceRole(positioner: placement, grab: grab),
        ),
        throwsArgumentError,
      );
      expect(
        () => PopupSurfaceRole(
          positioner: placement,
          grab: grab,
          inputPassthrough: true,
        ).toJson(),
        throwsArgumentError,
      );
      expect(requests, hasLength(1));
    },
  );

  test('rejects non-mouse capture without sending a request', () async {
    await expectLater(
      PopupGrab.capture(const PointerDownEvent(viewId: 7)),
      throwsArgumentError,
    );
    expect(requests, isEmpty);
  });

  test('rejects malformed and imprecise native tokens', () async {
    for (final invalid in [null, 0, -1, '91', 9007199254740992]) {
      token = invalid;
      await expectLater(
        PopupGrab.capture(press),
        throwsA(isA<FushellSurfaceException>()),
      );
    }
  });

  test('tooltip default remains non-grabbing', () {
    final json = const PopupSurfaceRole(
      positioner: placement,
      inputPassthrough: true,
    ).toJson();
    expect(json.containsKey('grabToken'), false);
  });
}
