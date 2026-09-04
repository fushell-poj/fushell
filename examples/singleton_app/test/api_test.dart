import 'package:flutter_test/flutter_test.dart';
import 'package:fushell/fushell.dart';

void main() {
  test('command results carry only a bounded exit code', () {
    expect(FushellCommandResult().exitCode, 0);
    expect(FushellCommandResult(exitCode: 255).exitCode, 255);
    expect(
      () => FushellCommandResult(exitCode: 256),
      throwsA(isA<RangeError>()),
    );
  });
}
