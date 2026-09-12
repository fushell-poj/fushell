import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';
import 'package:fushell/windows.dart';

const positioner = PopupPositioner(
  width: 180,
  height: 90,
  anchorRect: PopupAnchorRect(x: 12, y: -4, width: 32, height: 24),
);
const expectedPositioner = <String, Object?>{
  'width': 180,
  'height': 90,
  'anchorRect': {'x': 12, 'y': -4, 'width': 32, 'height': 24},
  'anchor': 'none',
  'gravity': 'none',
  'constraintAdjustment': <String>[],
  'offset': {'x': 0, 'y': 0},
  'reactive': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final requests = <Map<String, dynamic>>[];
  late Future<ByteData?> Function() respond;
  setUp(() {
    requests.clear();
    respond = () async =>
        const StringCodec().encodeMessage('{"ok":true,"windowId":42}');
    messenger.setMockMessageHandler('dev.fushell/surface', (data) {
      requests.add(
        jsonDecode(
              utf8.decode(
                data!.buffer.asUint8List(
                  data.offsetInBytes,
                  data.lengthInBytes,
                ),
              ),
            )
            as Map<String, dynamic>,
      );
      return respond();
    });
  });
  tearDown(() => messenger.setMockMessageHandler('dev.fushell/surface', null));

  test(
    'popup open includes required parent, defaults, and no grab field',
    () async {
      expect(
        await FushellWindow.openPopup(
          parent: 7,
          popup: const PopupSurfaceRole(positioner: positioner),
        ),
        42,
      );
      final request = Map<String, dynamic>.of(requests.single)..remove('id');
      expect(request, {
        'method': 'window.open',
        'parent': 7,
        'role': {
          'kind': 'popup',
          'inputPassthrough': false,
          'positioner': expectedPositioner,
        },
      });
    },
  );

  test('positioner serializes all options with stable constraint ordering', () {
    final result = PopupSurfaceRole(
      inputPassthrough: true,
      positioner: PopupPositioner(
        width: 180,
        height: 90,
        anchorRect: positioner.anchorRect,
        anchor: PopupAnchor.bottomRight,
        gravity: PopupGravity.topLeft,
        constraintAdjustment: {
          PopupConstraintAdjustment.resizeY,
          PopupConstraintAdjustment.flipX,
          PopupConstraintAdjustment.slideX,
        },
        offset: const PopupOffset(x: -2147483648, y: 2147483647),
        reactive: true,
      ),
    ).toJson();
    expect(result, {
      'kind': 'popup',
      'inputPassthrough': true,
      'positioner': {
        ...expectedPositioner,
        'anchor': 'bottomRight',
        'gravity': 'topLeft',
        'constraintAdjustment': ['slideX', 'flipX', 'resizeY'],
        'offset': {'x': -2147483648, 'y': 2147483647},
        'reactive': true,
      },
    });
  });

  test(
    'reposition sends full replacement and awaits native acknowledgement',
    () async {
      final reply = Completer<ByteData?>();
      respond = () => reply.future;
      var completed = false;
      final future = FushellWindow.repositionPopup(
        42,
        positioner,
      ).then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      final request = Map<String, dynamic>.of(requests.single)..remove('id');
      expect(request, {
        'method': 'popup.reposition',
        'windowId': 42,
        'positioner': expectedPositioner,
      });
      reply.complete(const StringCodec().encodeMessage('{"ok":true}'));
      await future;
      expect(completed, isTrue);
    },
  );

  for (final code in [
    'PopupParentNotMapped',
    'PopupParentHasPopup',
    'PopupRepositionUnsupported',
    'PopupReactiveUnsupported',
    'WindowNotFound',
  ]) {
    test('native $code reaches popup callers unchanged', () async {
      respond = () async => const StringCodec().encodeMessage(
        jsonEncode({
          'ok': false,
          'error': {'code': code, 'message': 'native detail'},
        }),
      );
      final matcher = throwsA(
        isA<FushellSurfaceException>()
            .having((e) => e.code, 'code', code)
            .having((e) => e.message, 'message', 'native detail'),
      );
      await expectLater(
        FushellWindow.openPopup(
          parent: 7,
          popup: const PopupSurfaceRole(positioner: positioner),
        ),
        matcher,
      );
      await expectLater(FushellWindow.repositionPopup(42, positioner), matcher);
    });
  }

  for (final response in ['{"ok":true}', '{"ok":true,"windowId":"42"}', '{']) {
    test('popup rejects invalid open response $response', () async {
      respond = () async => const StringCodec().encodeMessage(response);
      await expectLater(
        FushellWindow.openPopup(
          parent: 7,
          popup: const PopupSurfaceRole(positioner: positioner),
        ),
        throwsA(
          isA<FushellSurfaceException>().having(
            (e) => e.code,
            'code',
            'InvalidResponse',
          ),
        ),
      );
    });
  }

  test('invalid parent does not send a request', () async {
    for (final parent in [0, -1]) {
      await expectLater(
        FushellWindow.openPopup(
          parent: parent,
          popup: const PopupSurfaceRole(positioner: positioner),
        ),
        throwsRangeError,
      );
    }
    expect(requests, isEmpty);
  });

  final invalid = <PopupPositioner>[
    PopupPositioner(width: 0, height: 1, anchorRect: positioner.anchorRect),
    PopupPositioner(width: 1, height: -1, anchorRect: positioner.anchorRect),
    PopupPositioner(
      width: 2147483648,
      height: 1,
      anchorRect: positioner.anchorRect,
    ),
    const PopupPositioner(
      width: 1,
      height: 1,
      anchorRect: PopupAnchorRect(x: 0, y: 0, width: 0, height: 1),
    ),
    const PopupPositioner(
      width: 1,
      height: 1,
      anchorRect: PopupAnchorRect(x: 0, y: 0, width: 1, height: -1),
    ),
    const PopupPositioner(
      width: 1,
      height: 1,
      anchorRect: PopupAnchorRect(x: -2147483649, y: 0, width: 1, height: 1),
    ),
    const PopupPositioner(
      width: 1,
      height: 1,
      anchorRect: PopupAnchorRect(x: 0, y: 2147483648, width: 1, height: 1),
    ),
    PopupPositioner(
      width: 1,
      height: 1,
      anchorRect: positioner.anchorRect,
      offset: const PopupOffset(x: 2147483648),
    ),
    PopupPositioner(
      width: 1,
      height: 1,
      anchorRect: positioner.anchorRect,
      offset: const PopupOffset(y: -2147483649),
    ),
  ];
  for (var index = 0; index < invalid.length; index++) {
    test('invalid geometry $index is rejected before transport', () async {
      final bad = invalid[index];
      expect(bad.toJson, throwsRangeError);
      await expectLater(
        FushellWindow.openPopup(
          parent: 7,
          popup: PopupSurfaceRole(positioner: bad),
        ),
        throwsRangeError,
      );
      await expectLater(
        FushellWindow.repositionPopup(42, bad),
        throwsRangeError,
      );
      expect(requests, isEmpty);
    });
  }

  test(
    'owned popup helper forwards its ID and rejects after closure',
    () async {
      final testOwner = FushellWindowController(
        viewById: (_) async =>
            TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!,
      );
      final window = await testOwner.open(create: () async => 42);
      await window.repositionPopup(positioner);
      expect(requests.single['windowId'], 42);
      await window.close();
      requests.clear();
      await expectLater(window.repositionPopup(positioner), throwsStateError);
      expect(requests, isEmpty);
      await testOwner.dispose();
    },
  );
}
