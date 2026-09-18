part of '../../http.dart';

const _clientKey = #dartToolkitHttpClient;

/// The ambient HTTP client seam.
///
/// Every entry point in this module takes an optional `client:`. A session sets one
/// for all of them at once, so a script reuses connections without threading a client
/// through every call — and sets the timeout and default headers in the same place.
///
/// {@category Networking}
class Http {
  /// The client of the enclosing [session], or `null` outside one.
  static http.Client? get client => Zone.current[_clientKey] as http.Client?;

  /// Runs [body] with one shared client for every HTTP call inside it.
  ///
  /// [timeout] bounds the wait for response headers and for each body chunk; a stalled
  /// server fails with [TimeoutException] instead of hanging the program. [headers] are
  /// added to every request that does not set them itself — a `user-agent`, a referer.
  ///
  /// The client is closed when [body] completes, unless [client] was supplied — an
  /// open client delays process exit until its idle connections time out.
  static Future<T> session<T>(
    FutureOr<T> Function() body, {
    http.Client? client,
    Duration? timeout,
    Map<String, String>? headers,
  }) async {
    final owned = client == null;
    final inner = client ?? http.Client();
    final shared = timeout == null && headers == null ? inner : _SessionClient(inner, headers, timeout, owned: owned);
    try {
      return await runZoned(() async => body(), zoneValues: {_clientKey: shared});
    } finally {
      if (owned) inner.close();
    }
  }
}

/// Applies a session's default headers and timeout to every request.
class _SessionClient extends http.BaseClient {
  final http.Client _inner;
  final Map<String, String>? _headers;
  final Duration? _timeout;
  final bool _owned;

  _SessionClient(this._inner, this._headers, this._timeout, {required bool owned}) : _owned = owned;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _headers?.forEach((key, value) => request.headers.putIfAbsent(key, () => value));
    final timeout = _timeout;
    if (timeout == null) return _inner.send(request);
    final res = await _inner.send(request).timeout(timeout);
    return http.StreamedResponse(
      res.stream.timeout(timeout),
      res.statusCode,
      contentLength: res.contentLength,
      request: res.request,
      headers: res.headers,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
      reasonPhrase: res.reasonPhrase,
    );
  }

  @override
  void close() {
    if (_owned) _inner.close();
  }
}

/// A borrowed or owned client.
class _ClientLease {
  final http.Client client;

  /// The session's default headers, or `null` outside a session or when it set none.
  final Map<String, String>? headers;
  final bool _owned;

  const _ClientLease(this.client, this._owned, {this.headers});

  /// Closes the client only if this lease created it.
  void close() {
    if (_owned) client.close();
  }
}

/// Resolves the client for one call: the explicit one, else the session's, else a new one.
_ClientLease _clientFor(http.Client? explicit) {
  final shared = explicit ?? Http.client;
  if (shared == null) return _ClientLease(http.Client(), true);
  return _ClientLease(shared, false, headers: shared is _SessionClient ? shared._headers : null);
}
