import 'dart:io';

import 'package:dart_toolkit/tui.dart';
import 'package:test/test.dart';

void main() {
  group('Tui.run', () {
    test('throws StdoutException when stdout is not a terminal', () async {
      if (stdout.hasTerminal) {
        markTestSkipped('needs a piped stdout');
      }
      expect(
        Tui.run((screen) async {}),
        throwsA(isA<StdoutException>()),
      );
    });
  });
}
