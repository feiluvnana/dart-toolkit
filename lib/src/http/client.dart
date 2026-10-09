part of '../http.dart';

extension on Request {
  /// The request that follows a [status] redirect to [to], for the scope and the crawl alike.
  ///
  /// 303, and 301/302 on anything but GET and HEAD, become a bodiless GET, as in a browser;
  /// 307 and 308 keep both. Credentials do not follow to another origin (host, scheme or port),
  /// so an https→http hop cannot leak a bearer token.
  Request _hopTo(Uri to, int status) {
    final downgrade = method != 'HEAD' && (status == 303 || ((status == 301 || status == 302) && method != 'GET'));
    final cross = _origin(to) != _origin(url);
    final next = MessageInternals.options(this, Request(downgrade ? 'GET' : method, to), body: !downgrade);
    for (final MapEntry(:key, :value) in headers.entries) {
      if (downgrade && (key == 'content-type' || key == 'content-length')) continue;
      if (cross && HttpBridge.credentials.contains(key)) continue;
      next.headers[key] = value;
    }
    return next;
  }
}

/// Failures that will not change on a second attempt.
bool _certain(Object e) => switch (e) {
  _BodyTooLarge() => true,
  ClientException(cause: final cause?) => _certain(cause),
  _ => e is HandshakeException || e is CertificateException || e is TlsException,
};

/// A body over the cap; never retried.
final class _BodyTooLarge extends ClientException {
  const _BodyTooLarge(int cap, Uri url) : super('Response body over $cap bytes', url);
}

/// [res]'s body read to at most [cap] bytes; past [cap] it is cut when [cut], else throws
/// [_BodyTooLarge].
Future<Uint8List> _readCapped(StreamedResponse res, {required int cap, required Uri url, bool cut = false}) =>
    MessageInternals.collect(res.stream, res.contentLength, cap: cap, cut: cut, over: () => _BodyTooLarge(cap, url));

/// [e] as the [ClientException] it means when the transport threw it ([SocketException], TLS,
/// a SOCKS refusal); anything else as it is.
Object _client(Object e, Uri url) => switch (e) {
  ClientException() => e,
  SocketException(:final message) || TlsException(:final message) => ClientException(message, url, e),
  HttpException(:final message) => ClientException(message, url, e),
  _ => e,
};

/// The request after [res] in [current]'s chain, with [res] drained so the hop can reuse its
/// connection, or `null` where the chain ends. [first] names the chain in the error.
Future<Request?> _next(Request current, StreamedResponse res, int hop, Uri first) async {
  final Uri? to;
  try {
    to = _redirect(res.statusCode, res.headers, current.url);
  } on FormatException {
    return null;
  }
  if (to == null) return null;
  await _drain(res);
  if (hop >= current.redirects) throw ClientException('More than ${current.redirects} redirects', first);
  return current._hopTo(to, res.statusCode);
}

/// Where a [status] answer with [headers] to [from] redirects, for the clients and the crawl
/// alike: `null` when it is no redirect or names no `location`, a [FormatException] when the
/// `location` cannot be read.
Uri? _redirect(int status, Headers headers, Uri from) {
  if (status != 301 && status != 302 && status != 303 && status != 307 && status != 308) return null;
  final location = headers['location']?.trim();
  if (location == null || location.isEmpty) return null;
  return from.resolveUri(Uri.parse(location)).removeFragment();
}

/// Something a request can be sent through: the real client, a browser, a fake.
///
/// {@category Networking}
abstract interface class Client {
  /// A client that answers every request with what [answer] makes of it, sending nothing: the
  /// network's test seam. The request's body is held, so [answer] reads `request.text`.
  ///
  /// ```dart
  /// final fake = Client.fake((request) => Response('{"ok":true}', 200));
  /// await Http.scope(client: fake, () async => expect((await api.get().json)['ok'], isTrue));
  /// ```
  factory Client.fake(FutureOr<Response> Function(Request request) answer) = _FakeClient;

  /// Sends [request]; the body is still arriving.
  ///
  /// The contract: a non-2xx is a [StreamedResponse], not a throw; a transport failure is a
  /// [ClientException] or a `dart:io` exception; [StreamedResponse.url] is the URL that
  /// *answered*; an unknown [RequestKey] is ignored. Send [Request.open], of length
  /// [Request.contentLength]: a `files:` upload is not in [Request.bytes].
  ///
  /// **Sending consumes a request**: a client may write on it, so a caller reusing one sends a
  /// [Request.copy].
  Future<StreamedResponse> send(Request request);

  /// Releases connections; the client cannot be used afterwards.
  Future<void> close();
}

final class _FakeClient implements Client {
  final FutureOr<Response> Function(Request request) _answer;

  _FakeClient(this._answer);

  @override
  Future<StreamedResponse> send(Request request) async {
    Cancel.check();
    final bytes = request.isStreamed ? await MessageInternals.collect(request.open(), null) : request.bytes;
    final held = MessageInternals.options(
      request,
      Request(request.method, request.url, headers: request.headers, bytes: bytes),
    );
    final res = await _answer(held);
    return StreamedResponse(
      Stream.value(res.bytes),
      res.statusCode,
      contentLength: res.bytes.length,
      headers: res.headers,
      request: request,
      url: res.url ?? request.url,
      reasonPhrase: res.reasonPhrase,
    );
  }

  @override
  Future<void> close() async {}
}

/// The start of an error page: what [response] sends within a second, up to [cap] bytes; the
/// rest is cut off, as [_drain] cuts it, so a body that never ends holds nothing.
Future<Uint8List> _errorBody(StreamedResponse response, {int cap = 64 * 1024}) {
  final out = BytesBuilder(copy: false);
  final done = Completer<Uint8List>();
  late final StreamSubscription<List<int>> sub;
  void finish([Object? _]) {
    if (!done.isCompleted) done.complete(out.takeBytes());
  }

  void cut() {
    finish();
    unawaited(sub.cancel().catchError((_) {})); // best-effort: the body is abandoned either way
  }

  final patience = Timer(const Duration(seconds: 1), cut);
  sub = response.stream.listen(
    (chunk) {
      final room = cap - out.length;
      out.add(chunk.length > room ? chunk.sublist(0, room) : chunk);
      if (out.length >= cap) cut();
    },
    onDone: finish,
    onError: finish,
    cancelOnError: true,
  );
  return done.future.whenComplete(patience.cancel);
}

/// A non-2xx answer to [request] as the [StatusException] it is, with the start of its body.
Future<StatusException> _refused(StreamedResponse res, Request request) async => StatusException(
  Response.bytes(
    await _errorBody(res),
    res.statusCode,
    headers: res.headers,
    request: request,
    url: res.url ?? request.url,
    reasonPhrase: res.reasonPhrase,
  ),
);

/// Discards a response body and frees its connection; completes when it is free.
///
/// Up to [_reusable] is read to the end, since a connection cut mid-body cannot be reused; a
/// larger body, or one slower than a second, is cancelled.
Future<void> _drain(StreamedResponse response) {
  final StreamSubscription<List<int>> sub;
  try {
    sub = response.stream.listen(null, cancelOnError: true);
  } on StateError {
    return Future.value(); // already read, or already being drained
  }
  final done = Completer<void>();
  void settle([Object? _]) {
    if (!done.isCompleted) done.complete();
  }

  void cut() {
    settle();
    unawaited(sub.cancel().catchError((_) {})); // best-effort: the body is abandoned either way
  }

  var seen = 0;
  final patience = Timer(const Duration(seconds: 1), cut);
  sub
    ..onData((chunk) {
      if ((seen += chunk.length) > _reusable) cut();
    })
    ..onDone(settle)
    ..onError(settle);
  if ((response.contentLength ?? 0) > _reusable) cut();
  return done.future.whenComplete(patience.cancel);
}

/// The most of an unwanted body [_drain] reads to keep its connection.
const _reusable = 64 * 1024;

/// Whether [request] wants the stored bytes ([Request.raw], or a `range`, which counts them),
/// so it asks for `identity` and is never decoded.
bool _literal(Request request) => Request.raw(request) == true || request.headers.containsKey('range');

/// The client over `dart:io`'s [HttpClient]: keep-alive, gzip, brotli and zstd, proxies.
///
/// {@category Networking}
final class IoClient implements Client {
  /// One `HttpClient` per proxy (one without), each with its own connections, taken in turn.
  final List<HttpClient> _clients;

  /// The next of [_clients] to send through.
  var _turn = 0;

  /// [proxies] are taken in turn, a request each: `http://user:pass@host:8080`, or
  /// `socks5://user:pass@host:1080` (`socks5h://` alike), whose names the proxy resolves; any
  /// other scheme is an [ArgumentError]. A request a proxy cannot connect, or answers with a
  /// `407`, moves on to the next, until each was tried. Without any, `http_proxy`/`no_proxy`
  /// apply. [unsafe] accepts any certificate: for a self-signed intranet host only. [client] is
  /// an `HttpClient` configured elsewhere (a `SecurityContext`), with these settings on top.
  ///
  /// ```dart
  /// await Http.scope(client: IoClient(proxies: [Uri.parse('socks5://10.0.0.1:1080')]), () => …);
  /// ```
  IoClient({List<Uri> proxies = const [], bool unsafe = false, HttpClient? client})
    : _clients = [
        for (final (i, proxy) in <Uri?>[if (proxies.isEmpty) null, ...proxies].indexed)
          _configured(i == 0 ? client ?? HttpClient() : HttpClient(), proxy, unsafe: unsafe),
      ] {
    _charsets();
  }

  static HttpClient _configured(HttpClient client, Uri? proxy, {required bool unsafe}) {
    if (unsafe) client.badCertificateCallback = (_, _, _) => true;
    if (proxy != null && HttpBridge.isSocks(proxy)) {
      client
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = (url, _, _) => _socksConnect(url, proxy, unsafe: unsafe);
    } else if (proxy != null) {
      client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
      if (HttpBridge.login(proxy) case (final user, final password)) {
        final credentials = HttpClientBasicCredentials(user, password.reveal);
        client.addProxyCredentials(proxy.host, proxy.port, '', credentials);
        // `dart:io` matches proxy credentials by realm; supply them for whichever realm is
        // asked, once, so a wrong password fails (a 407) instead of looping.
        final asked = <String>{};
        client.authenticateProxy = (host, port, scheme, realm) async {
          if (!asked.add('$host:$port/$realm')) return false;
          client.addProxyCredentials(host, port, realm ?? '', credentials);
          return true;
        };
      }
    }
    // Decoded here instead: `dart:io` knows only gzip; see [_Encoding].
    return client..autoUncompress = false;
  }

  /// Honours the enclosing [Cancel.scope]: a cancel aborts the request, waiting for headers or
  /// mid-body, with [CancelledException]. Walks the redirect chain itself: `dart:io` copies
  /// every header, credentials included, onto a hop to another site.
  @override
  Future<StreamedResponse> send(Request request) async {
    Cancel.check();
    var current = request;
    for (var hop = 0; ; hop++) {
      final res = await _once(current);
      final next = current.followRedirects ? await _next(current, res, hop, request.url) : null;
      if (next == null) return MessageInternals.carrying(res, _guarded(res.stream, Cancel.token));
      current = next;
    }
  }

  /// [request] through the next proxy, or the one after it when that one cannot connect or
  /// answers `407`, until each was tried.
  Future<StreamedResponse> _once(Request request) async {
    final count = _clients.length;
    if (count == 1) return _through(_clients.first, request);
    final first = _turn++ % count;
    for (var i = 1; ; i++) {
      final StreamedResponse res;
      try {
        res = await _through(_clients[(first + i - 1) % count], request);
      } catch (e) {
        if (i == count || !_unreachable(e)) rethrow;
        continue;
      }
      if (res.statusCode != 407 || i == count) return res;
      unawaited(_drain(res));
    }
  }

  /// A proxy that refused the connection, or a tunnel through one: the next may not.
  static bool _unreachable(Object e) =>
      e is SocketException ||
      (e is ClientException && (e.cause is SocketException || e.message.startsWith('Proxy failed')));

  Future<StreamedResponse> _through(HttpClient client, Request request) async {
    final HttpClientResponse response;
    final token = Cancel.token;
    void Function()? heard;
    final contentLength = request.contentLength;
    final HttpClientRequest io;
    try {
      io = await client.openUrl(request.method, request.url);
    } catch (e, st) {
      Error.throwWithStackTrace(_client(e, request.url), st);
    }
    try {
      if (token != null) {
        if (token.isCancelled) {
          io.abort(CancelledException.of(token));
          throw CancelledException.of(token);
        }
        // Until the headers; after, [_guarded] stops the body (`dart:io` ignores the abort).
        heard = token.onCancel(() => io.abort(CancelledException.of(token)));
      }
      io
        ..followRedirects = false
        ..contentLength = contentLength;
      io.headers.set('accept-encoding', _literal(request) ? 'identity' : _acceptEncoding);
      request.headers.forEach((k, v) => io.headers.set(k, v));
      // A held body is one write; a `files:` or `file:` one is pumped, never in memory.
      if (request.isStreamed) {
        await io.addStream(request.open());
      } else if (request.bytes.isNotEmpty) {
        io.add(request.bytes);
      }
      response = await io.close();
    } catch (e, st) {
      io.abort(e);
      Error.throwWithStackTrace(_client(e, request.url), st);
    } finally {
      heard?.call();
    }
    final headers = Headers();
    // One value per name. `set-cookie` joins with a newline, not a comma (its `Expires` holds
    // one), as Chrome's DevTools protocol does, so `Chrome` agrees.
    response.headers.forEach((name, values) => headers[name] = values.join(name == 'set-cookie' ? '\n' : ', '));
    Stream<List<int>> body = response.handleError(
      (Object e, StackTrace st) => Error.throwWithStackTrace(_client(e, request.url), st),
      test: (e) => e is HttpException || e is SocketException || e is TlsException,
    );
    var length = response.contentLength == -1 ? null : response.contentLength;
    final encoding = _hasBody(response.statusCode, request.method) && !_literal(request)
        ? _Encoding.of(headers['content-encoding'])
        : null;
    if (encoding != null) {
      // Both described the bytes on the wire, not what the caller reads.
      body = _inflated(body, encoding, request.url);
      length = null;
      headers
        ..remove('content-length')
        ..remove('content-encoding');
    }
    return StreamedResponse(
      body,
      response.statusCode,
      contentLength: length,
      headers: headers,
      request: request,
      url: request.url,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  Future<void> close() async {
    for (final client in _clients) {
      client.close(force: true);
    }
  }

  /// [body], failing with [CancelledException] when [token] is cancelled mid-body, so a stalled
  /// server cannot hold the program open.
  static Stream<List<int>> _guarded(Stream<List<int>> body, CancelToken? token) {
    if (token == null) return body;
    StreamSubscription<List<int>>? source;
    void Function()? unheard;
    late final StreamController<List<int>> out;
    out = StreamController<List<int>>(
      sync: true,
      onListen: () {
        source = body.listen(
          out.add,
          onError: out.addError,
          onDone: () {
            unheard?.call();
            out.close();
          },
        );
        unheard = token.onCancel(() {
          final cut = source;
          source = null;
          unawaited(cut?.cancel().catchError((Object _) {})); // best-effort: the body is abandoned
          out
            ..addError(CancelledException.of(token))
            ..close();
        });
      },
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
      onCancel: () {
        unheard?.call();
        return source?.cancel();
      },
    );
    return out.stream;
  }
}
