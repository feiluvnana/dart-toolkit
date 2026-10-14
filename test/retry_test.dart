import 'dart:async';
import 'dart:io';

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
}
