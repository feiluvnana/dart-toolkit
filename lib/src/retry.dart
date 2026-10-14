/// Retry policy shared by `http`'s verbs.
///
/// One home for doubling backoff, `Retry-After` parsing and the retryable
/// test, so a bad certificate is never retried with 1 s, 2 s … backoff.
library;

import 'dart:async';
import 'dart:io' as io;

/// Doubling backoff from 1 s (`attempt` 0 → 1 s, 1 → 2 s, … capped at 2^10 s),
/// or the server's `Retry-After` when it is longer (capped at 5 minutes).
Duration backoff(int attempt, Duration? server) {
  final shift = attempt > 10 ? 10 : attempt;
  var wait = Duration(seconds: 1 << shift);
  const cap = Duration(minutes: 5);
  if (server != null && server > wait) wait = server > cap ? cap : server;
  return wait;
}

/// Parse a `Retry-After` value: delay-seconds or an HTTP date in the future.
/// Null when absent, unparseable, or in the past.
Duration? parseRetryAfter(String? value) {
  if (value == null) return null;
  final digits = value.trim();
  if (RegExp(r'^\d+$').hasMatch(digits)) {
    // Clamp before building the Duration: a huge value overflows to negative.
    final seconds = digits.length > 9 ? 999999999 : int.parse(digits);
    return Duration(seconds: seconds);
  }
  try {
    final date = io.HttpDate.parse(value.trim());
    final wait = date.difference(DateTime.now().toUtc());
    if (wait > Duration.zero) return wait;
  } catch (_) {}
  return null;
}

/// True for transient failures worth resending an in-memory body for:
/// network errors, timeouts, `http.ClientException`s (as [io.HttpException]).
/// TLS failures ([io.HandshakeException], [io.TlsException],
/// [io.CertificateException]) are permanent: retrying a bad certificate with
/// backoff only waits. Anything else (programmer errors, [FormatException],
/// [ArgumentError]) is not retryable.
bool isRetryable(Object e) {
  if (e is io.HandshakeException) return false;
  if (e is io.TlsException) return false;
  if (e is io.CertificateException) return false;
  if (e is TimeoutException) return true;
  if (e is io.SocketException) return true;
  if (e is io.HttpException) {
    final msg = e.message.toLowerCase();
    // TLS failures surface as HttpException on some paths (package:http
    // maps ClientException; cert failures mention tls/cert/handshake).
    if (msg.contains('tls') || msg.contains('certificate') || msg.contains('handshake') || msg.contains('cert')) {
      return false;
    }
    return true;
  }
  return false;
}
