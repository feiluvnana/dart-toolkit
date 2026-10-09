// The one way a request goes out, for the verbs, downloads, crawls and renders alike: the
// scope's headers, credentials and cookies on each hop, its per-host limits, its timeout, and
// one retry loop.

part of '../http.dart';

/// [request]'s whole redirect chain (or its one hop, when it does not follow redirects), through
/// [s]'s cache when it has one. [idle] bounds each body chunk by the timeout as well as the
/// headers; [step] hears a wait (`'waiting'`).
Future<StreamedResponse> _exchange(_Settings s, Request request, {bool idle = true, void Function(String step)? step}) {
  final cache = s.cache;
  if (cache == null || !_Cache.wants(request)) return _chain(s, request, idle: idle, step: step);
  return _Cache.of(s).through(
    request,
    who:
        '${request.headers['authorization'] ?? s.credentialFor(request.url)?.reveal ?? ''}\n'
        '${request.headers['cookie'] ?? s.jar._headerFor(request.url) ?? ''}',
    fresh: cache,
    send: (r) => _chain(s, r, idle: idle, step: step),
  );
}

Future<StreamedResponse> _chain(
  _Settings s,
  Request request, {
  required bool idle,
  void Function(String step)? step,
}) async {
  final follow = request.followRedirects;
  var current = request;
  for (var hop = 0; ; hop++) {
    final res = await _hop(s, current, idle: idle, step: step);
    if (!follow) return res;
    final Request? next;
    try {
      next = await _next(current, res, hop, request.url);
    } catch (_) {
      unawaited(_drain(res));
      rethrow;
    }
    if (next == null) return res;
    current = next;
  }
}

/// One request, as the scope says: its headers where the request has none, the credential bound
/// to its origin, the jar's cookies unless it carries its own, the per-host limits, and its
/// timeout; what the answer sets is kept in the jar. The permits are held until the body ends.
Future<StreamedResponse> _hop(
  _Settings s,
  Request request, {
  required bool idle,
  void Function(String step)? step,
}) async {
  // Sending consumes a request, and a retry sends it again.
  final sent = request.copy()..followRedirects = false;
  s.headers.forEach((name, value) => sent.headers.putIfAbsent(name, () => value));
  if (!sent.headers.containsKey('authorization')) {
    if (s.credentialFor(sent.url) case final secret?) sent.headers['authorization'] = secret.reveal;
  }
  if (!sent.headers.containsKey('cookie')) {
    if (s.jar._headerFor(sent.url) case final cookie?) sent.headers['cookie'] = cookie;
  }
  final releases = <void Function()>[];
  void release() {
    for (final r in releases) {
      r();
    }
    releases.clear();
  }

  try {
    for (final limit in s.limits) {
      releases.add(await limit.enter(sent.url, waiting: () => step?.call('waiting')));
    }
    final (client, lease) = _transport(s);
    releases.add(lease);
    final res = await _timedSend(client, sent, s.timeout, idle: idle, end: release);
    s.jar._keep(res, sent);
    return res;
  } catch (_) {
    release();
    rethrow;
  }
}

/// [body], calling [end] once however it ends: read, failed, or left by its listener.
Stream<List<int>> _ending(Stream<List<int>> body, void Function() end) {
  StreamSubscription<List<int>>? source;
  late final StreamController<List<int>> out;
  out = StreamController<List<int>>(
    sync: true,
    onListen: () {
      source = body.listen(
        out.add,
        onError: out.addError,
        onDone: () {
          end();
          out.close();
        },
      );
    },
    onPause: () => source?.pause(),
    onResume: () => source?.resume(),
    onCancel: () {
      end();
      return source?.cancel();
    },
  );
  return out.stream;
}

/// [once] tried as [s]'s retry policy says for [request]: one loop covering the headers and
/// whatever [once] reads of the body. Each retry is a `Warned` on the work around the caller
/// and a `retry n/m` [step]; a `Retry-After` is waited out (a `waiting` [step], and [onWait]
/// told) before the next try.
Future<R> _retrying<R>(
  _Settings s,
  Request request,
  Future<R> Function() once, {
  void Function(String step)? step,
  void Function(Duration wait)? onWait,
}) {
  final policy = s.retry;
  final replayable = _replayable(request.method);
  final cap = policy.max ?? _longestRetryAfter;
  Duration? asked;
  bool worth(Object e) {
    asked = null;
    final again = switch (e) {
      StatusException(:final response) => _statusWorth(response, replayable, cap, (wait) => asked = wait),
      CancelledException() => false,
      TimeoutException() => replayable,
      ClientException() => replayable && !_certain(e),
      SocketException() || HttpException() => replayable,
      _ => false,
    };
    return again && (policy.when?.call(e) ?? true);
  }

  return Retry(policy.times, backoff: policy.backoff, max: policy.max, when: worth).attempt(
    () async {
      if (asked case final wait?) {
        asked = null;
        step?.call('waiting');
        onWait?.call(wait);
        await wait.delay();
      }
      return once();
    },
    onRetry: (warning) {
      final wait = asked;
      TaskInternals.warn(
        wait == null ? warning : RetryWarning(warning.attempt, warning.of, warning.wait + wait, warning.cause),
      );
      step?.call('retry ${warning.attempt}/${warning.of}');
    },
  );
}

/// Whether [res] is worth another try: a `429` or `503` (after a `Retry-After` within [cap],
/// told to [wait]; without one only when [replayable]), and a `408` or a `5xx` other than
/// `501`/`505` when [replayable].
bool _statusWorth(Response res, bool replayable, Duration cap, void Function(Duration wait) wait) {
  final status = res.statusCode;
  if (status == 429 || status == 503) {
    if (_retryAfter(res.headers) case final asked?) {
      if (asked > cap) return false;
      wait(asked);
      return true;
    }
    return replayable;
  }
  return replayable && (status == 408 || (status >= 500 && status != 501 && status != 505));
}

/// A `Retry-After` in seconds or as a date, or `null` when there is none or it is unreadable.
Duration? _retryAfter(Headers headers) {
  final header = headers['retry-after']?.trim() ?? '';
  if (header.isEmpty) return null;
  final wait = switch (int.tryParse(header)) {
    final seconds? => Duration(seconds: seconds),
    null => MessageInternals.httpDate(header)?.difference(Clock.current.now()),
  };
  return wait != null && wait.isNegative ? Duration.zero : wait;
}

/// Whether a second attempt might not meet [error]: the connection or the clock, not TLS or a
/// cancel.
bool _transient(Object error) =>
    (error is SocketException || (error is HttpException && error is! StatusException) || error is TimeoutException) &&
    error is! CancelledException &&
    !_certain(error);

/// Whether [method] may be sent twice: a retried POST is a second order.
bool _replayable(String method) => method != 'POST' && method != 'PATCH';

// ---- the shared client ----------------------------------------------------------------------

/// The client of requests in no scope's `client:`: made on first use and shared, so back-to-back
/// requests reuse one keep-alive connection (and one TLS handshake); closed a turn after the
/// last request ends, since an idle socket would hold the process open.
IoClient? _shared;
var _leases = 0;

/// What [s] sends through, and the release of the lease on it.
(Client, void Function()) _transport(_Settings s) {
  if (s.client case final client?) return (client, () {});
  final client = _shared ??= IoClient();
  _leases++;
  var released = false;
  return (
    client,
    () {
      if (released) return;
      released = true;
      if (--_leases > 0) return;
      Timer.run(() {
        if (_leases > 0 || !identical(_shared, client)) return;
        _shared = null;
        unawaited(client.close().catchError((Object _) {})); // best-effort: nothing is in flight
      });
    },
  );
}

// ---- time limits ----------------------------------------------------------------------------

const _watchKey = #dartToolkitHttpWatch;

/// [request] through [client], its headers within [timeout] and then, with [idle], each body
/// chunk within it too, on a token of its own so a late one is aborted (and drained, or it would
/// hold its connection). The enclosing [Cancel.scope] still cuts it until its body ends.
///
/// One timer serves the whole exchange: it is re-armed for what is left of [timeout] when it
/// fires after activity, never per chunk. What the client waits for inside
/// [HttpBridge.untimed] (a browser's tab, a challenge) does not count.
/// [end] runs once the body is read, failed or left, as the permits it holds end.
Future<StreamedResponse> _timedSend(
  Client client,
  Request request,
  Duration timeout, {
  bool idle = true,
  void Function()? end,
}) async {
  final stop = CancelToken();
  final outer = Cancel.token;
  final unlink = outer?.onCancel(() => stop.cancel(outer.reason));
  void unhear() {
    unlink?.call();
    end?.call();
  }

  final late = Completer<StreamedResponse>();
  final watch = _Watch(timeout, () {
    if (late.isCompleted) return;
    stop.cancel();
    late.completeError(TimeoutBridge('${request.url}', timeout));
  });
  final pending = CancelInternals.run(() => client.send(request), stop, {_watchKey: watch});
  unawaited(
    pending.then(
      (res) => late.isCompleted ? _drain(res) : late.complete(res),
      onError: (Object e, StackTrace st) => late.isCompleted ? null : late.completeError(e, st),
    ),
  );
  final StreamedResponse res;
  try {
    res = await late.future;
  } catch (_) {
    watch.cancel();
    unlink?.call();
    rethrow;
  }
  if (!idle) {
    watch.cancel();
    return MessageInternals.carrying(res, _ending(res.stream, unhear));
  }
  watch.touch();
  return MessageInternals.carrying(res, watch.guard(res.stream, request.url, unhear));
}

/// An idle deadline: [onExpire] runs once [limit] passes with no [touch], counted only while
/// the stream it [guard]s is not paused by its reader, nor [hold]ing.
final class _Watch {
  final Duration limit;
  void Function() onExpire;
  Duration _last = Clock.current.elapsed;
  Deadline? _timer;
  var _holds = 0;
  var _over = false;

  /// Whether anything happened since the timer was armed; if not, its firing is the deadline.
  var _stirred = false;

  _Watch(this.limit, this.onExpire) {
    _arm(limit);
  }

  void _arm(Duration after) {
    _stirred = false;
    _timer = ClockInternals.after(after, _check);
  }

  void _check() {
    _timer = null;
    if (_holds > 0) return;
    if (!_stirred) return onExpire();
    final idle = Clock.current.elapsed - _last;
    idle >= limit ? onExpire() : _arm(limit - idle);
  }

  void touch() {
    _last = Clock.current.elapsed;
    _stirred = true;
  }

  /// Stops counting until [release]: a wait the deadline does not cover.
  void hold() {
    _holds++;
    _timer?.cancel();
    _timer = null;
  }

  void release() {
    if (--_holds > 0 || _over) return;
    touch();
    _timer ??= ClockInternals.after(limit, _check);
  }

  void cancel() {
    _over = true;
    _timer?.cancel();
    _timer = null;
  }

  /// [body], failing with a [TimeoutException] when a chunk is [limit] late; [end] runs once
  /// however it ends.
  Stream<List<int>> guard(Stream<List<int>> body, Uri url, void Function()? end) {
    StreamSubscription<List<int>>? source;
    var ended = false;
    void finish() {
      if (ended) return;
      ended = true;
      cancel();
      end?.call();
    }

    late final StreamController<List<int>> out;
    out = StreamController<List<int>>(
      sync: true,
      onListen: () {
        onExpire = () {
          final cut = source;
          source = null;
          finish();
          unawaited(cut?.cancel().catchError((Object _) {})); // best-effort: the body is abandoned
          out
            ..addError(TimeoutBridge('$url body', limit))
            ..close();
        };
        source = body.listen(
          (chunk) {
            touch();
            out.add(chunk);
          },
          onError: out.addError,
          onDone: () {
            finish();
            out.close();
          },
        );
      },
      onPause: () {
        _timer?.cancel();
        _timer = null;
        source?.pause();
      },
      onResume: () {
        touch();
        if (!ended && _timer == null) _arm(limit);
        source?.resume();
      },
      onCancel: () {
        finish();
        return source?.cancel();
      },
    );
    return out.stream;
  }
}
