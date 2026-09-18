import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Duration Utilities', () {
    test('Duration short getters', () {
      expect(500.ms, equals(const Duration(milliseconds: 500)));
      expect(5.s, equals(const Duration(seconds: 5)));
      expect(2.m, equals(const Duration(minutes: 2)));
      expect(3.h, equals(const Duration(hours: 3)));
      expect(1.d, equals(const Duration(days: 1)));
    });

    test('Duration.humanize formats nicely', () {
      expect(350.ms.humanized, equals('350ms'));
      expect(45.s.humanized, equals('45s'));
      expect((2.m + 15.s).humanized, equals('2m 15s'));
      expect((1.h + 5.m + 2.s).humanized, equals('1h 5m 2s'));
    });

    test('Duration.jitter adds variance within bounds', () {
      final base = 1000.ms;
      for (var i = 0; i < 20; i++) {
        final jittered = base.jittered(0.2);
        expect(jittered.inMilliseconds, greaterThanOrEqualTo(800));
        expect(jittered.inMilliseconds, lessThanOrEqualTo(1200));
      }
    });
  });

  group('String Extensions', () {
    test('String.match extracts regex groups using RegExp pattern and matches literal strings', () {
      expect('Release version 9.4.2-alpha'.match(RegExp(r'version ([\d\.]+)'), 1), equals('9.4.2'));
      expect('DISC.05 (Original Soundtrack)'.match(RegExp(r'DISC\.(\d+)'), 1), equals('05'));
      expect('DISC.05'.match(RegExp(r'DISC\.(\d+)'), 1), equals('05'));
      expect('No match here'.match(RegExp(r'DISC\.(\d+)'), 1), isNull);
      expect('exact-match'.match('exact'), equals('exact'));
    });
  });
}
