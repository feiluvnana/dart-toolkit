part of '../../http.dart';

const _clientKey = #dartToolkitHttpClient;

/// The ambient HTTP client seam: no entry point takes a `client:`; a scope names one for
/// every request, download and crawl inside it, with its timeout and default headers.
///
/// {@category Networking}
class Http {
  /// The client of the enclosing [scope], or `null` outside one.
  static Client? get client => Zone.current[_clientKey] as Client?;

  /// Runs [body] with one shared client for every HTTP call inside it.
  ///
  /// [timeout] bounds the wait for headers and for each body chunk ([TimeoutException]).
  /// [headers] fill in what a request does not set; a credential among them goes only to the
  /// origin of the scope's first request, so an API token does not ride along to the
  /// presigned URL the API answers with.
  ///
  /// [cookies] keeps what responses set — on every redirect hop, where a login sets its
  /// session — and sends them back. The jar lives as long as this call, never on disk.
  ///
  /// ```dart
  /// await Http.scope(cookies: true, () async {
  ///   await login.post(form: {'user': u, 'pass': p});
  ///   await for (final item in dashboard.scrape<Item>()...) { ... }
  /// });
  /// ```
  ///
  /// [jar] starts the jar (implying [cookies]): log in through a browser, then fetch at
  /// socket speed.
  ///
  /// ```dart
  /// final session = await chrome.page(login, (p) async {
  ///   await p.fill('#user', user);
  ///   await p.waitForNavigation(() => p.click('#go'));
  ///   return p.cookies();
  /// });
  /// await Http.scope(jar: session, () => api.get().json);
  /// ```
  ///
  /// A cookie without a domain is skipped; a leading dot matches subdomains.
  ///
  /// [retries] is the crawl's policy for every request and download in the scope: a
  /// transport error, a broken-off body or a 5xx is sent again, a 429 or 503 after its
  /// `Retry-After` (over 30 s is handed back), a TLS failure never. POST and PATCH are resent
  /// only on a 429 or 503 with `Retry-After` — the server saying it did nothing.
  ///
  /// [delay] spaces requests to one host (`www.` or not), hops and downloads included,
  /// jittered ±25 % since a metronome is a bot signal.
  ///
  /// ```dart
  /// await Http.scope(retries: 3, delay: 500.ms, () => urls.pairs.download().show());
  /// ```
  ///
  /// [cache] keeps each GET answered with an `ETag` or `Last-Modified` in that folder and
  /// asks conditionally next time, serving a `304` from disk as its `200` — for a script
  /// rerun while it is written. Conditional requests, downloads and `no-store` are left alone.
  ///
  /// Every wait and request in flight stops when the enclosing [Cancel.scope] is cancelled.
  /// The client is closed when [body] completes, unless [client] was supplied.
  static Future<T> scope<T>(
    FutureOr<T> Function() body, {
    Client? client,
    Duration? timeout,
    Map<String, String>? headers,
    bool cookies = false,
    Iterable<Cookie>? jar,
    int retries = 0,
    Duration? delay,
    Path? cache,
  }) async {
    final owned = client == null && Http.client == null;
    final inner = client ?? Http.client ?? IoClient();
    final keeps = cookies || jar != null;
    final shared = timeout == null && headers == null && !keeps && retries <= 0 && delay == null && cache == null
        ? inner
        : _ScopeClient(
            inner,
            headers,
            timeout,
            keeps ? (_Jar()..seed(jar ?? const [])) : null,
            retries: retries < 0 ? 0 : retries,
            delay: delay != null && delay > Duration.zero ? delay : null,
            cache: cache == null ? null : _Cache(cache),
            owned: owned,
          );
    try {
      return await runZoned(() async => body(), zoneValues: {_clientKey: shared});
    } finally {
      if (owned) await inner.close();
    }
  }
}

/// Applies a scope's default headers, timeout, cookie jar, retries, delay and cache to every
/// request.
final class _ScopeClient implements Client {
  final Client _inner;
  final Map<String, String>? _headers;
  final Duration? _timeout;
  final _Jar? _jar;
  final int _retries;
  final Duration? _delay;
  final _Cache? _cache;
  final bool _owned;

  /// When each site may next be sent to, for [_delay].
  final Map<String, DateTime> _slots = {};

  /// The first request's origin, which owns the credentials among [_headers].
  Uri? _home;

  _ScopeClient(
    this._inner,
    this._headers,
    this._timeout,
    this._jar, {
    required int retries,
    required Duration? delay,
    required _Cache? cache,
    required bool owned,
  }) : _retries = retries,
       _delay = delay,
       _cache = cache,
       _owned = owned;

  @override
  Future<StreamedResponse> send(Request request) {
    if (_headers case final headers?) {
      final home = _home ??= request.url;
      final mine = _sameOrigin(request.url, home);
      headers.forEach((key, value) {
        if (mine || !_credential.contains(key.toLowerCase())) request.headers.putIfAbsent(key, () => value);
      });
    }
    return _cache?.through(request, _chain) ?? _chain(request);
  }

  /// [request]'s whole redirect chain.
  Future<StreamedResponse> _chain(Request request) async {
    final jar = _jar;
    if (jar == null && _delay == null) return _bounded(await _fire(request));

    // Walked here, hop by hop: a login sets its cookie on the 302, which a client following
    // its own redirects throws away; and each hop waits its [_delay] turn.
    final follow = request.followRedirects;
    var current = request;
    for (var hop = 0; ; hop++) {
      // A request's own `cookie` beats the jar; a hop has none of its own.
      if (jar != null) {
        if (hop > 0) current.headers.remove('cookie');
        if (!current.headers.containsKey('cookie')) {
          if (jar.headerFor(current.url) case final header?) current.headers['cookie'] = header;
        }
      }
      current.followRedirects = false;
      final res = await _fire(current);
      try {
        if (res.headers['set-cookie'] case final header? when jar != null) jar.store(res.url ?? current.url, header);
        final next = follow ? await _next(current, res, hop, request.url) : null;
        if (next == null) return _bounded(res);
        current = next;
      } catch (_) {
        unawaited(_drain(res));
        rethrow;
      }
    }
  }

  /// One request, spaced by [_delay], retried by the crawl's policy, headers bounded by
  /// [_timeout].
  Future<StreamedResponse> _fire(Request request) async {
    final budget = _Retry.none(request) == true ? 0 : _retries;
    final replayable = _replayable(request.method);
    for (var attempt = 1; ; attempt++) {
      Cancel.throwIfCancelled();
      await _polite(request.url);
      // Sending consumes a request, and a retry sends it again.
      final sent = budget == 0 ? request : request.copy();
      if (_inner is _ScopeClient) sent[_Retry.none] = true;
      final stop = CancelToken();
      Cancel.token?.onCancel(() => stop.cancel(Cancel.reason));
      final StreamedResponse res;
      try {
        res = await _timed(Cancel.scope(() => _inner.send(sent), token: stop), stop);
      } catch (e) {
        if (attempt > budget || !replayable || !_transient(e) || Cancel.isCancelled) rethrow;
        await (200 * attempt).ms.delay();
        continue;
      }
      if (attempt > budget || Cancel.isCancelled) return res;
      final wait = _Retry.after(res, attempt, once: !replayable);
      if (wait == null) return res;
      await _drain(res);
      await wait.delay();
    }
  }

  /// [pending] within [_timeout]. A late response is drained, or it would hold its connection
  /// — and its `IoClient(connections:)` permit — for good.
  Future<StreamedResponse> _timed(Future<StreamedResponse> pending, CancelToken stop) {
    final timeout = _timeout;
    if (timeout == null) return pending;
    return pending.timeout(
      timeout,
      onTimeout: () {
        stop.cancel();
        unawaited(pending.then(_drain, onError: (Object _) {}));
        throw TimeoutException('No response within $timeout', timeout);
      },
    );
  }

  /// Waits for [url]'s host to be due, and books the next slot now, so ten downloads started
  /// at once leave a [_delay] apart rather than waking together.
  Future<void> _polite(Uri url) async {
    final gap = _delay;
    if (gap == null) return;
    final site = '${url.scheme}://${_site(url.host)}:${url.port}';
    final now = DateTime.now();
    final booked = _slots[site];
    final at = booked == null || booked.isBefore(now) ? now : booked;
    _slots[site] = at.add(gap.jittered());
    if (at.isAfter(now)) await at.difference(now).delay();
  }

  /// [res] with [_timeout] on each body chunk.
  StreamedResponse _bounded(StreamedResponse res) =>
      _timeout == null ? res : res._carrying(res.stream.timeout(_timeout));

  @override
  Future<void> close() async {
    if (_owned) await _inner.close();
  }
}

/// The retry policy, written once for the crawl and for [Http.scope]'s `retries:`.
abstract final class _Retry {
  /// Marks a request its sender retries itself (the crawl), so a scope does not multiply the
  /// budget.
  static const none = RequestKey<bool>('retry.none');

  /// The longest `Retry-After` a scope waits out; longer is handed back.
  static const longest = Duration(seconds: 30);

  /// The wait before resending after [res] on [attempt], or `null` when [res] is the answer: a
  /// 429 or 503 waits its `Retry-After` or backs off; another 5xx waits a little longer each
  /// time. With [once] (not replayable) only a 429/503 with `Retry-After` is retried.
  static Duration? after(StreamedResponse res, int attempt, {bool once = false}) {
    final status = res.statusCode;
    if (status == 429 || status == 503) {
      final asked = retryAfter(res.headers);
      if (asked != null) return asked > longest ? null : asked;
      return once ? null : backoff(attempt - 1);
    }
    return status >= 500 && !once ? (200 * attempt).ms : null;
  }

  /// Half a second, doubled [times] times, at most thirty.
  static Duration backoff(int times) {
    final ms = 500 * (1 << times.clamp(0, 6));
    return Duration(milliseconds: ms > 30000 ? 30000 : ms);
  }

  /// A `Retry-After` in seconds or as a date, or `null` when unreadable.
  static Duration? retryAfter(Headers headers) {
    final header = headers['retry-after']?.trim() ?? '';
    final wait = switch (int.tryParse(header)) {
      final seconds? => Duration(seconds: seconds),
      null => _httpDate(header)?.difference(DateTime.now()),
    };
    return wait != null && wait.isNegative ? Duration.zero : wait;
  }
}

/// A borrowed or owned client.
final class _ClientLease {
  final Client client;

  /// The scope's default headers, or `null` outside a scope or when it set none.
  final Map<String, String>? headers;
  final bool _owned;

  const _ClientLease(this.client, this._owned, {this.headers});

  /// Closes the client if this lease created it, without waiting: a lease ends in synchronous
  /// teardown, and a scope's client is awaited in [Http.scope] instead.
  void close() {
    if (!_owned) return;
    unawaited(client.close().catchError((Object _) {}));
  }
}

/// Runs [body] with [client] as the ambient client.
T _withClient<T>(Client client, T Function() body) => runZoned(body, zoneValues: {_clientKey: client});

/// The enclosing [Http.scope]'s client, or a fresh one this call owns and must close.
_ClientLease _clientFor() {
  final shared = Http.client;
  if (shared == null) return _ClientLease(IoClient(), true);
  return _ClientLease(shared, false, headers: shared is _ScopeClient ? shared._headers : null);
}
