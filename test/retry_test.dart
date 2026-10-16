import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/src/rate.dart' as rate;
import 'package:dart_toolkit/src/retry.dart';
import 'package:test/test.dart';

void main() {
  test('backoff doubles with ±25% jitter and honours Retry-After', () {
    for (var i = 0; i < 50; i++) {
      expect(backoff(0, null).inMilliseconds, inInclusiveRange(750, 1250));
      expect(backoff(2, null).inMilliseconds, inInclusiveRange(3000, 5000));
    }
    expect({for (var i = 0; i < 20; i++) backoff(1, null)}.length, greaterThan(1));
    expect(backoff(0, const Duration(seconds: 30)), const Duration(seconds: 30));
  });

  test('an uncapped Retry-After is capped at 5 minutes', () {
    expect(backoff(0, const Duration(days: 1)), const Duration(minutes: 5));
    expect(backoff(0, parseRetryAfter('86400')), const Duration(minutes: 5));
  });

  test('Retry-After reads seconds and future HTTP dates only', () {
    expect(parseRetryAfter(null), isNull);
    expect(parseRetryAfter(' 7 '), const Duration(seconds: 7));
    expect(parseRetryAfter('-3'), isNull);
    expect(parseRetryAfter('+5'), isNull);
    expect(parseRetryAfter('9223372036854775807')! > const Duration(days: 1), isTrue);
    expect(backoff(0, parseRetryAfter('18446744073709')), const Duration(minutes: 5));
    expect(parseRetryAfter('soon'), isNull);
    final later = HttpDate.format(DateTime.now().toUtc().add(const Duration(minutes: 2)));
    expect(parseRetryAfter(later)!.inSeconds, inInclusiveRange(100, 120));
    expect(parseRetryAfter(HttpDate.format(DateTime.utc(2000))), isNull);
  });

  test('network errors and timeouts retry; TLS and programmer errors do not', () {
    expect(isRetryable(TimeoutException('t')), isTrue);
    expect(isRetryable(const SocketException('reset')), isTrue);
    expect(isRetryable(const HttpException('Connection closed')), isTrue);
    expect(isRetryable(const HandshakeException('bad')), isFalse);
    expect(isRetryable(const TlsException('bad')), isFalse);
    expect(isRetryable(const CertificateException('bad')), isFalse);
    expect(isRetryable(const HttpException('CERTIFICATE_VERIFY_FAILED')), isFalse);
    expect(isRetryable(const FormatException('x')), isFalse);
    expect(isRetryable(ArgumentError('x')), isFalse);
  });

  test('firing a halt ends the waits in flight', () async {
    final halt = rate.Halt();
    await Future.wait([for (var i = 0; i < 100; i++) rate.sleep(const Duration(milliseconds: 1), halt)]);
    final sw = Stopwatch()..start();
    final long = rate.sleep(const Duration(seconds: 30), halt);
    halt.fire();
    await long;
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('a server Retry-After is capped at 5 minutes; the own window is not', () {
    expect(rate.ban(rate.Rate(1, const Duration(seconds: 1)), const Duration(days: 365)), const Duration(minutes: 5));
    expect(rate.ban(rate.Rate(1, const Duration(hours: 1)), const Duration(seconds: 1)), const Duration(hours: 1));
  });
}
