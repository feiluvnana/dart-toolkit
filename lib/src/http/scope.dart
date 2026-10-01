part of '../../http.dart';

const _clientKey = #dartToolkitHttpClient;

/// The ambient HTTP client seam.
///
/// No entry point in this module takes a `client:`. A scope names one once, for every
/// request, download and crawl inside it, so a script reuses connections without threading
/// a client through every call — and sets the timeout and default headers in the same place.
///
/// {@category Networking}
class Http {
  /// The client of the enclosing [scope], or `null` outside one.
  static Client? get client => Zone.current[_clientKey] as Client?;

  /// Runs [body] with one shared client for every HTTP call inside it.
  ///
  /// [timeout] bounds the wait for response headers and for each body chunk; a stalled
  /// server fails with [TimeoutException] instead of hanging the program. [headers] are
  /// added to every request that does not set them itself — a `user-agent`, a referer.
  /// A credential among them — `authorization`, `cookie` — goes only to the origin of the
  /// scope's first request: an API token must not ride along to the presigned storage URL
  /// the API answers with. Another origin that needs one is given it per call.
  ///
  /// [cookies] keeps what the responses set and sends them back, so a login and the pages
  /// behind it are one scope and nothing parses `set-cookie` by hand. The jar lives as
  /// long as this call and is never written to disk.
  ///
  /// It walks the redirect chain itself, hop by hop, because a login is a POST that answers a
  /// 302 and sets the session *on that hop*: the response at the end of the chain carries no
  /// `set-cookie` at all, so a client left to follow its own redirects would arrive with the
  /// session already thrown away.
  ///
  /// ```dart
  /// await Http.scope(cookies: true, () async {
  ///   await login.post(form: {'user': u, 'pass': p});
  ///   await for (final item in dashboard.scrape<Item>()...) { ... }
  /// });
  /// ```
  ///
  /// [jar] starts the jar with cookies from elsewhere and implies [cookies]: log in through
  /// a browser, where the JavaScript and the captcha are, then fetch at socket speed.
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
  /// A cookie without a domain has no origin to belong to and is skipped; a domain with a
  /// leading dot (Chrome's way of writing `Domain=`) matches its subdomains too.
  ///
  /// [retries] is the crawl's retry policy for everything else in the scope — every
  /// `url.get()` and every download, none of them wrapped in a `retry`: a transport error or a
  /// 5xx is sent again, a 429 or 503 after the `Retry-After` it asked for (one asking for more
  /// than 30 s is handed back), a TLS failure never. A body that breaks off half-way is a
  /// transport error too, and a download picks up where it stopped. A crawl keeps its own
  /// `ctx.retries`.
  ///
  /// POST and PATCH are not sent twice, because the server may have acted on the first: a
  /// retried order is two orders. The one exception is a 429 or 503 carrying `Retry-After`,
  /// which is the server saying it did not process the request and when to ask again.
  ///
  /// [delay] is the crawl's `ctx.delay` for the same: the time between two requests, hops
  /// and downloads included, to one host — `www.` or not. Each gap is jittered by ±25 %,
  /// since a metronome is a bot signal; `500.ms` waits 375 to 625 ms.
  ///
  /// ```dart
  /// await Http.scope(retries: 3, delay: 500.ms, () => urls.pairs.download().show());
  /// ```
  ///
  /// [cache] keeps every GET answered with an `ETag` or a `Last-Modified` under that folder,
  /// and asks with `if-none-match` / `if-modified-since` the next time: a `304` is served
  /// from disk as the `200` it stands for. It is for the script run again and again while it
  /// is being written — the second run reads what did not change instead of fetching it.
  /// A request that asks conditionally itself, a download, and a `cache-control: no-store`
  /// answer are left alone.
  ///
  /// Every wait here — a backoff, a `Retry-After`, a [delay] gap — and every request in
  /// flight stops when the enclosing [Cancel.scope] is cancelled.
  ///
  /// The client is closed when [body] completes, unless [client] was supplied — an
  /// open client delays process exit until its idle connections time out.
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

  /// The origin of the first request, which the credentials among [_headers] belong to.
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

    // With a jar or a delay the chain is walked here, hop by hop. A login is a POST that
    // answers 302 and sets the session cookie *on that hop*; the response at the end of the
    // chain carries no `set-cookie` at all, so a client left to follow its own redirects — any
    // client, since this wraps whichever one the scope holds — arrives with the cookie already
    // thrown away. And a hop is a request to a host like any other, so it waits its turn.
    final follow = request.followRedirects;
    var current = request;
    for (var hop = 0; ; hop++) {
      // A request that names its own `cookie` keeps it: a per-call argument beats the scope.
      // A hop names none of its own, the jar being what sent it there.
      if (jar != null) {
        if (hop > 0) current.headers.remove('cookie');
        if (!current.headers.containsKey('cookie')) {
          if (jar.headerFor(current.url) case final header?) current.headers['cookie'] = header;
        }
      }
      current.followRedirects = false;
      final res = await _fire(current);
      try {
        // Stored against the URL that answered, so a cookie belongs to the host that set it.
        if (jar != null) {
          if (res.headers['set-cookie'] case final header?) jar.store(res.url ?? current.url, header);
        }
        final next = follow ? await _next(current, res, hop, request.url) : null;
        if (next == null) return _bounded(res);
        current = next;
      } catch (_) {
        // A response nobody will read still holds its connection until it is read.
        unawaited(_drain(res));
        rethrow;
      }
    }
  }

  /// One request, spaced by [_delay] and retried by the crawl's policy, and its headers
  /// bounded by [_timeout].
  ///
  /// A POST or a PATCH is sent again only when the server said it did not act on it — a 429
  /// or 503 with a `Retry-After`; see [Http.scope].
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

  /// [pending], failing with [TimeoutException] when its headers take longer than [_timeout].
  ///
  /// A response that lands after the wait was given up on still holds its connection — and
  /// under `IoClient(connections:)` its permit — until its body is read, so it is drained
  /// rather than abandoned: left alone, N timeouts would take all N permits for good.
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

  /// Waits for [url]'s host to be due, and books the slot after it.
  ///
  /// Slots are booked when asked for rather than when sent, so ten downloads started at once
  /// leave about one [_delay] apart instead of all waking together after the first.
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

  /// [res] with the scope's timeout on each chunk of its body as well as on its headers.
  StreamedResponse _bounded(StreamedResponse res) =>
      _timeout == null ? res : res._carrying(res.stream.timeout(_timeout));

  @override
  Future<void> close() async {
    if (_owned) await _inner.close();
  }
}

/// The retry policy, written once for the crawl and for [Http.scope]'s `retries:`.
abstract final class _Retry {
  /// Marks a request its sender retries itself — the crawl, whose budget is `ctx.retries` —
  /// so a scope around it does not multiply that budget by its own.
  static const none = RequestKey<bool>('retry.none');

  /// The longest a `Retry-After` may hold a scope's request; one asking for longer is handed
  /// back rather than waited out. The crawl's `ctx.maxRetryAfter` defaults to the same.
  static const longest = Duration(seconds: 30);

  /// How long to wait before sending again after [res] on [attempt], or `null` when [res] is
  /// the answer: a 429 or 503 waits what `Retry-After` asks — or backs off, doubling from half
  /// a second — and any other 5xx waits a little longer each time.
  ///
  /// [once] is a request that must not be sent twice: only a 429 or 503 whose `Retry-After`
  /// says when to ask again is retried, which is the server saying it did nothing.
  static Duration? after(StreamedResponse res, int attempt, {bool once = false}) {
    final status = res.statusCode;
    if (status == 429 || status == 503) {
      final asked = retryAfter(res.headers);
      if (asked != null) return asked > longest ? null : asked;
      return once ? null : backoff(attempt - 1);
    }
    return status >= 500 && !once ? (200 * attempt).ms : null;
  }

  /// Half a second, doubled [times] times, and never more than thirty.
  static Duration backoff(int times) {
    final ms = 500 * (1 << times.clamp(0, 6));
    return Duration(milliseconds: ms > 30000 ? 30000 : ms);
  }

  /// What a server's `Retry-After` asks for — seconds or a date — or `null` when it says
  /// nothing that can be read.
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

  /// Closes the client only if this lease created it.
  ///
  /// A lease is closed from synchronous teardown — a crawl finishing, a download's `finally`
  /// — so a client that closes asynchronously is left to finish on its own; a scope's
  /// client, the one that may be a browser, is awaited in [Http.scope] instead.
  void close() {
    if (!_owned) return;
    unawaited(client.close().catchError((Object _) {}));
  }
}

/// Runs [body] with [client] as the ambient client, so the calls nested inside it reuse
/// the connection rather than each opening one of their own.
T _withClient<T>(Client client, T Function() body) => runZoned(body, zoneValues: {_clientKey: client});

/// The enclosing [Http.scope]'s client, or a fresh one this call owns and must close.
_ClientLease _clientFor() {
  final shared = Http.client;
  if (shared == null) return _ClientLease(IoClient(), true);
  return _ClientLease(shared, false, headers: shared is _ScopeClient ? shared._headers : null);
}
