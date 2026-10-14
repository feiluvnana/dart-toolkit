import 'package:dart_toolkit/src/retry.dart';
import 'package:test/test.dart';

void main() {
  test('backoff doubles and honours Retry-After', () {
    expect(backoff(0, null), const Duration(seconds: 1));
    expect(backoff(2, null), const Duration(seconds: 4));
    expect(backoff(0, const Duration(seconds: 30)), const Duration(seconds: 30));
  });

  test('an uncapped Retry-After is capped at 5 minutes', () {
    expect(backoff(0, const Duration(days: 1)), const Duration(minutes: 5));
    expect(backoff(0, parseRetryAfter('86400')), const Duration(minutes: 5));
  });
}
