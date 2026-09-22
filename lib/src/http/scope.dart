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
  ///
  /// [cookies] keeps what the responses set and sends them back, so a login and the pages
  /// behind it are one scope and nothing parses `set-cookie` by hand. The jar lives as
  /// long as this call and is never written to disk.
  ///
  /// ```dart
  /// await Http.scope(cookies: true, () async {
  ///   await login.post(form: {'user': u, 'pass': p});
  ///   await for (final item in dashboard.scrape<Item>()...) { ... }
  /// });
  /// ```
  ///
  /// The client is closed when [body] completes, unless [client] was supplied — an
  /// open client delays process exit until its idle connections time out.
  static Future<T> scope<T>(
    FutureOr<T> Function() body, {
    Client? client,
    Duration? timeout,
    Map<String, String>? headers,
    bool cookies = false,
  }) async {
    final owned = client == null;
    final inner = client ?? IoClient();
    final shared = timeout == null && headers == null && !cookies
        ? inner
        : _ScopeClient(inner, headers, timeout, cookies ? _Jar() : null, owned: owned);
    try {
      return await runZoned(() async => body(), zoneValues: {_clientKey: shared});
    } finally {
      if (owned) await inner.close();
    }
  }
}

/// Applies a scope's default headers, timeout and cookie jar to every request.
final class _ScopeClient implements Client {
  final Client _inner;
  final Map<String, String>? _headers;
  final Duration? _timeout;
  final _Jar? _jar;
  final bool _owned;

  _ScopeClient(this._inner, this._headers, this._timeout, this._jar, {required bool owned}) : _owned = owned;

  @override
  Future<StreamedResponse> send(Request request) async {
    _headers?.forEach((key, value) => request.headers.putIfAbsent(key, () => value));
    // A request that names its own `cookie` keeps it: a per-call argument beats the scope.
    if (_jar case final jar? when !request.headers.containsKey('cookie')) {
      if (jar.headerFor(request.url) case final header?) request.headers['cookie'] = header;
    }
    final timeout = _timeout;
    final res = timeout == null ? await _inner.send(request) : await _inner.send(request).timeout(timeout);
    // Taken from the URL that answered, so a cookie set on the last hop of a redirect
    // belongs to the host that set it.
    if (_jar case final jar?) {
      if (res.headers['set-cookie'] case final header?) jar.store(res.url ?? request.url, header);
    }
    if (timeout == null) return res;
    return StreamedResponse(
      res.stream.timeout(timeout),
      res.statusCode,
      contentLength: res.contentLength,
      request: res.request,
      url: res.url,
      headers: res.headers,
      isRedirect: res.isRedirect,
      reasonPhrase: res.reasonPhrase,
    );
  }

  @override
  Future<void> close() async {
    if (_owned) await _inner.close();
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

/// Resolves the client for one call: the explicit one, else the scope's, else a new one.
/// Runs [body] with [client] as the ambient client, so the calls nested inside it reuse
/// the connection rather than each opening one of their own.
T _withClient<T>(Client client, T Function() body) => runZoned(body, zoneValues: {_clientKey: client});

/// The enclosing [Http.scope]'s client, or a fresh one this call owns and must close.
_ClientLease _clientFor() {
  final shared = Http.client;
  if (shared == null) return _ClientLease(IoClient(), true);
  return _ClientLease(shared, false, headers: shared is _ScopeClient ? shared._headers : null);
}
