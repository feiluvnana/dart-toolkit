/// Retry policy shared by `http`'s sends and `pool`'s `retries:`.
///
/// One home for jittered backoff, `Retry-After` parsing and the retryable
/// test, so a bad certificate is never retried with 1 s, 2 s … backoff.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math';

final _random = Random();

/// Doubling backoff from 1 s (`attempt` 0 → 1 s, 1 → 2 s, … capped at 2^10 s)
/// with ±25% jitter, or the server's `Retry-After` when it is longer (capped
/// at 5 minutes).
Duration backoff(int attempt, Duration? server) {
  final shift = attempt > 10 ? 10 : attempt;
  final base = 1000 * (1 << shift);
  var wait = Duration(milliseconds: (base * (0.75 + _random.nextDouble() * 0.5)).round());
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

/// Failures marked final where they are made, whatever their type (an
/// HTTP 4xx, a logged-out session, a refused proxy login): no retry layer
/// tries them again.
final _final = Expando<bool>('final');

/// Mark [e] final (see [isPermanent]) and return it.
T permanent<T extends Object>(T e) {
  _final[e] = true;
  return e;
}

/// [to], marked final when [from] was: for a failure re-made with more
/// context.
T carry<T extends Object>(Object from, T to) => _final[from] == true ? permanent(to) : to;

/// True for transient failures worth resending an in-memory body for:
/// network errors, timeouts, `http.ClientException`s (as [io.HttpException]).
/// TLS failures ([io.HandshakeException], [io.TlsException],
/// [io.CertificateException]) are permanent: retrying a bad certificate with
/// backoff only waits. Anything else (programmer errors, [FormatException],
/// [ArgumentError], a failure marked [permanent]) is not retryable.
bool isRetryable(Object e) {
  if (_final[e] == true) return false;
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

/// True for failures another attempt of a `pool` job cannot fix: an
/// [Error] (a bug, an [ArgumentError]), bad data ([FormatException], so
/// `ContentException`), TLS, and failures marked [permanent] (an HTTP 4xx
/// after the client's own retries, a logged-out session, a refused proxy
/// login). Any other exception is retried: a shell's exit, a 5xx, a
/// browser or network failure.
bool isPermanent(Object e) =>
    e is Error ||
    e is FormatException ||
    _final[e] == true ||
    e is io.HandshakeException ||
    e is io.TlsException ||
    e is io.CertificateException;
