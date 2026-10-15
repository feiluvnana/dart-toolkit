/// Minimal HTTP client. Thin facade over SDK `dart:io` `HttpClient`.
///
/// ```dart
/// final api = Http.client(base: 'https://api.example.com/', headers: {'authorization': token}, check: true);
/// final me = await api.get('me').json();
/// final cdn = Http.client(resume: true);
/// await (cdn.get(isoUrl) | Console.bar(null) > Fs.file('d.iso'));   // skips, resumes, renames atomically
/// await api.put('upload', body: .stream(Fs.file('d.iso')));
/// ```
///
/// Public surface is exactly: [Http], [Client], [Response], [Body],
/// [HttpStatusException], [HttpRequestException], [RequestFailure],
/// [Server], [Request], [Reply].
/// - `Http.client(...)` holds the settings a script states once (base,
///   headers, cookies, retries, pacing); `client.copy(...)` is a variant
///   that stays one session. `Http.pool([...])` spreads requests over
///   several clients.
/// - [Client] verbs `get` `head` `delete` `post` `put` `patch` return a
///   [Response]; `cookies` is the jar. With `resume: true`, a GET piped
///   into a file skips a complete file and resumes a partial one.
/// - [Response] supports `status` `ok` `check` `header` `url` `size` `name`
///   (plus [Reader]/[Closeable]).
/// - [Body] is a sealed request body: `.text` `.bytes` `.form` `.json`
///   `.stream`. A [Body.stream] is sent once and never retried.
/// - [HttpStatusException] is what `check` and piping a non-2xx body throw;
///   [HttpRequestException] is a request that was aborted or could not
///   follow a redirect.
/// - `Http.serve(handler)` answers requests ([Request] `method` `path`
///   `query` `header`, a [Reader] of the body) with a [Reply] (`.text`
///   `.json` `.stream` `.redirect` `.status`) until [Server.close].
/// A non-2xx status is still a [Response] unless the client says `check:`;
/// only network failures and timeouts throw. Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core.dart';
export 'core.dart';

import 'src/charset.dart' as charset;
import 'src/cookies.dart' as jar;
import 'src/origin.dart' as names;
import 'src/posix.dart' as posix;
import 'src/rate.dart' as rate;
import 'src/resume.dart';
import 'src/retry.dart' as retry;
import 'src/timeout.dart';

/// A request body. The compiler rejects a wrong shape; there is no
/// `body:`/`json:` pair to pass together and no runtime `ArgumentError`.
///
/// ```dart
/// await api.post('items', body: .json(item));
/// await api.post('ajax', body: .form({'action': 'decode', 'page': 2}));
/// await api.put(uploadUrl, body: .stream(Archive.archive(['.'], dir: 'site', format: .zip)));
/// ```
sealed class Body {
  const Body._();

  /// `text/plain; charset=utf-8` (unless `content-type` is given).
  const factory Body.text(String text) = _TextBody;

  /// Raw bytes; no default `content-type`.
  const factory Body.bytes(List<int> bytes) = _BytesBody;

  /// URL-encoded form (`application/x-www-form-urlencoded`); values as in
  /// `query:` (`num`, `bool`, null drops the key, an `Iterable` repeats it).
  const factory Body.form(Map<String, Object?> fields) = _FormBody;

  /// `jsonEncode(value)` as `application/json`.
  const factory Body.json(Object? value) = _JsonBody;

  /// Streamed from [reader]: sent once, never retried.
  const factory Body.stream(Reader reader) = _StreamBody;
}

final class _TextBody extends Body {
  const _TextBody(this._text) : super._();

  final String _text;
}

final class _BytesBody extends Body {
  const _BytesBody(this._bytes) : super._();

  final List<int> _bytes;
}

final class _FormBody extends Body {
  const _FormBody(this._fields) : super._();

  final Map<String, Object?> _fields;
}

final class _JsonBody extends Body {
  const _JsonBody(this._value) : super._();

  final Object? _value;
}

/// A streamed body. Sent once, never retried: a redirect that would need
/// the bytes back throws [HttpRequestException] ([RequestFailure.unsendable]).
final class _StreamBody extends Body {
  const _StreamBody(this._reader) : super._();

  final Reader _reader;
}

/// What `check` and piping a non-2xx body throw: the status, the
/// method, the final URL and the body's first line as fields, so callers
/// switch on `status` instead of parsing the message. Extends [HttpException],
/// so an existing `on HttpException` keeps catching it.
final class HttpStatusException extends HttpException implements ToolkitException {
  HttpStatusException(super.message, {required this.status, required this.method, required this.url, this.snippet = ''})
    : super(uri: Uri.tryParse(url));

  /// HTTP status.
  final int status;

  /// The method (`GET`, `POST` …).
  final String method;

  /// The final URL, redirects followed (credentials and tokens masked).
  final String url;

  /// The body's first 200 characters, whitespace collapsed.
  final String snippet;

  @override
  Object? get cause => null;

  @override
  String toString() => 'HttpStatusException: $message';
}

/// Why a request never produced a [Response].
enum RequestFailure {
  /// The client was closed while the request ran.
  aborted,

  /// More than 10 redirect hops.
  redirects,

  /// A redirect that cannot be followed: an unsupported location, or a
  /// streamed body that would have to be sent again.
  unsendable,
}

/// A request that was aborted or could not follow a redirect. Extends
/// [HttpException], so an existing `on HttpException` keeps catching it.
final class HttpRequestException extends HttpException implements ToolkitException {
  HttpRequestException(this.method, this.url, this.reason, [String? detail])
    : super('${detail ?? reason.name}: $method $url', uri: Uri.tryParse(url));

  /// The method (`GET`, `POST` …).
  final String method;

  /// The URL of the hop that failed (credentials and tokens masked).
  final String url;

  /// What went wrong.
  final RequestFailure reason;

  @override
  Object? get cause => null;

  @override
  String toString() => 'HttpRequestException: $message';
}

/// Entry point: a [client] with named settings, or a [pool] of them.
abstract final class Http {
  /// A new, isolated client: its own cookie jar and connections. Settings
  /// are stated once here; a request passes only `query`, `headers`, `body`.
  ///
  /// - [base]: relative URLs resolve against it (`Uri.resolve`).
  /// - [headers]: sent on every request; a per-call header of the same name
  ///   wins for that call.
  /// - [timeout]: the connect, the wait for the headers, then any stall
  ///   streaming.
  /// - [retries]: re-sends only when the request provably was not
  ///   processed. Any in-memory body retries on connect/DNS failures before
  ///   sending, 429 and 503; GET, HEAD, PUT and DELETE also on timeouts,
  ///   network errors and 502/504. Backoff doubles from 1 s with ±25%
  ///   jitter; `Retry-After` is honoured (capped at 5 min unless [rate] is
  ///   set, then a 429 waits the window out). TLS failures never retry.
  /// - [rate] paces every send; [check] throws [HttpStatusException] on a
  ///   non-2xx status.
  /// - [cookies]: the jar (a fresh one when null): `set-cookie` (redirect
  ///   hops too) updates it, and a per-call `cookie` header merges by name.
  /// - [csrf] copies a cookie into a header on every send.
  /// - [proxy]: `http://host:port` (credentials allowed); null reads
  ///   `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` like curl.
  /// - [cache]: a folder; a GET within [ttl] of a stored 2xx answer uses no
  ///   network and no [rate] slot (for development).
  /// - [insecure] lists hosts whose bad certificate is accepted (each with
  ///   its subdomains), on every redirect hop.
  /// - [idle]: an idle client releases its sockets after this, so a
  ///   finished script exits; [connections] caps the sockets per host.
  /// - [resume]: a GET piped into a file (`get(u) | bar > Fs.file(f)`)
  ///   skips a complete file (same `content-length`, or any file when the
  ///   server sends none), resumes a `.part` with `Range` (a 206; anything
  ///   else restarts), and renames the finished file into place. Stored
  ///   bytes are replayed through the pipes, so a bar counts the whole file
  ///   and a hash verifies it; a pipe that is not a pass-through (gzip, a
  ///   filter) downloads from scratch. A transport failure keeps the `.part`
  ///   for the next run, any other failure deletes it. The GET is sent at
  ///   the end of the current synchronous block unless such a pipeline
  ///   claims it first, so awaiting it, or not using it, sends it as usual.
  /// - [limit]: the most bytes a body read into memory (`bytes`, `text`,
  ///   `json`, `html`) may decode to; past it the read fails with a
  ///   [ContentException], so a gzip bomb cannot fill the heap. Piping a
  ///   body into a file has no limit.
  static Client client({
    String? base,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30),
    int retries = 2,
    Rate? rate,
    bool check = false,
    Cookies? cookies,
    ({String cookie, String header})? csrf,
    String? proxy,
    String? cache,
    Duration ttl = const Duration(hours: 1),
    List<String> insecure = const [],
    Duration idle = const Duration(milliseconds: 100),
    int connections = 6,
    bool resume = false,
    int limit = 256 << 20,
  }) {
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'must not be negative');
    if (retries < 0) throw ArgumentError.value(retries, 'retries', 'must not be negative');
    if (connections < 1) throw ArgumentError.value(connections, 'connections', 'must be at least 1');
    final settings = _Settings(
      base: base == null ? null : Uri.parse(base),
      headers: headers,
      timeout: timeout,
      retries: retries,
      rate: rate,
      check: check,
      cookies: cookies ?? Cookies(),
      csrf: csrf,
      cache: cache,
      ttl: ttl,
      resume: resume,
      limit: limit,
    );
    return _Client(
      settings,
      _Conn(insecure: insecure, proxy: proxy, idle: idle, connections: connections, timeout: timeout),
    );
  }

  /// One [Client] over several: each request goes to the member with the
  /// fewest requests in flight whose [Rate] has a free slot (ties
  /// round-robin). A 429 benches that member until its window frees and
  /// the request retries on another (counting against `retries`). For
  /// several accounts, mirrors (`base:` per member) or proxies.
  static Client pool(List<Client> members) {
    if (members.isEmpty) throw ArgumentError.value(members, 'members', 'must not be empty');
    return _Pool([for (final m in members) ..._flat(m)]);
  }

  /// Serve HTTP on [host]:[port] (loopback, a free port by default) until
  /// [Server.close]: one [handler] call per request, whose [Reply] is sent.
  /// For a CLI OAuth login (the loopback redirect), a webhook, a folder
  /// preview. A handler error is a 500 with no detail sent, and is logged to
  /// stderr. No routing table: `switch (request.path())` is the router.
  static Future<Server> serve(
    FutureOr<Reply> Function(Request request) handler, {
    int port = 0,
    String host = '127.0.0.1',
  }) async {
    final server = Server._(await HttpServer.bind(host, port));
    server.url(); // fix the address while bound
    server._server.listen((req) {
      final done = server._answer(req, handler);
      server._inFlight.add(done);
      done.whenComplete(() => server._inFlight.remove(done));
    }, onError: (_) {});
    return server;
  }

  static List<_Client> _flat(Client c) => switch (c) {
    _Client() => [c],
    _Pool() => c._members,
  };
}

/// An HTTP session: settings, a cookie jar and connections. A verb completes
/// when the headers arrive; the body streams as a [Reader].
///
/// Redirects are followed for every verb, up to 10 hops: 301/302/303 after
/// a POST become a GET (the body is dropped); 307/308 keep the method and
/// resend an in-memory body. A cross-origin hop drops credential headers.
/// [query] values may be `String`, `num`, `bool`, null (drops the key) or an
/// `Iterable` of those (repeats the key).
sealed class Client implements Closeable {
  /// A variant of this client: a given setting replaces this one's (null
  /// keeps it; [headers] merge by name). The copy shares the jar, the
  /// [Rate] and the connections unless it overrides them.
  Client copy({
    String? base,
    Map<String, String>? headers,
    Duration? timeout,
    int? retries,
    Rate? rate,
    bool? check,
    Cookies? cookies,
    ({String cookie, String header})? csrf,
    String? proxy,
    String? cache,
    Duration? ttl,
    List<String>? insecure,
    Duration? idle,
    int? connections,
    bool? resume,
    int? limit,
  });

  /// The cookie jar: persist it with `cookies().encode()`.
  Cookies cookies();

  Future<Response> get(String url, {Map<String, Object?>? query, Map<String, String>? headers});

  Future<Response> head(String url, {Map<String, Object?>? query, Map<String, String>? headers});

  Future<Response> delete(String url, {Map<String, Object?>? query, Map<String, String>? headers});

  Future<Response> post(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers});

  Future<Response> put(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers});

  Future<Response> patch(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers});

  /// Cancel this client's in-flight requests, body reads and waits (they
  /// fail with [HttpRequestException], [RequestFailure.aborted]) and wait
  /// for them to settle. Idempotent; a request after close fails the same way.
  @override
  Future<void> close();
}

/// Everything [Http.client] takes that a [_Client] reads per request.
final class _Settings {
  _Settings({
    required this.base,
    required this.headers,
    required this.timeout,
    required this.retries,
    required this.rate,
    required this.check,
    required this.cookies,
    required this.csrf,
    required this.cache,
    required this.ttl,
    required this.resume,
    required this.limit,
  });

  final Uri? base;
  final Map<String, String> headers;
  final Duration timeout;
  final int retries;
  final Rate? rate;
  final bool check;
  final Cookies cookies;
  final ({String cookie, String header})? csrf;
  final String? cache;
  final Duration ttl;
  final bool resume;
  final int limit;
}

/// One `HttpClient` with its socket settings, counted by the requests and
/// live responses of every client that shares it. When the count reaches
/// 0 the sockets close after [idle], so a sequential loop keeps one
/// connection while a finished script exits.
final class _Conn {
  _Conn({
    required this.insecure,
    required this.proxy,
    required this.idle,
    required this.connections,
    required this.timeout,
  }) : _trusted = [for (final h in insecure) h.toLowerCase()];

  final List<String> insecure;
  final String? proxy;
  final Duration idle;
  final int connections;
  final Duration timeout;
  final List<String> _trusted;

  HttpClient? _client;
  var _active = 0;
  Timer? _closer;

  /// Clients sharing this connection set; the last one to close shuts it.
  var owners = 0;

  void leave() {
    if (--owners == 0) {
      _closer?.cancel();
      _closer = null;
      _shut();
    }
  }

  HttpClient retain() {
    _active++;
    _closer?.cancel();
    _closer = null;
    return _client ??= _build();
  }

  void release() {
    _active--;
    assert(_active >= 0, 'connection count over-released');
    if (_active == 0) {
      _closer?.cancel();
      _closer = Timer(idle, () {
        _closer = null;
        if (_active == 0) _shut();
      });
    }
  }

  void _shut() {
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }

  HttpClient _build() {
    final c = HttpClient()
      ..maxConnectionsPerHost = connections
      ..connectionTimeout = timeout;
    if (_trusted.isNotEmpty) {
      c.badCertificateCallback = (cert, host, port) {
        final h = host.toLowerCase();
        return _trusted.any((t) => h == t || h.endsWith('.$t'));
      };
    }
    final p = proxy;
    if (p == null) {
      c.findProxy = HttpClient.findProxyFromEnvironment;
    } else {
      final u = Uri.parse(p.contains('://') ? p : 'http://$p');
      final port = u.hasPort ? u.port : 80;
      c.findProxy = (_) => 'PROXY ${u.host}:$port';
      if (u.userInfo.isNotEmpty) {
        final [user, ...pass] = Uri.decodeComponent(u.userInfo).split(':');
        c.addProxyCredentials(u.host, port, '', HttpClientBasicCredentials(user, pass.join(':')));
      }
    }
    return c;
  }

  bool sameAs({List<String>? insecure, String? proxy, Duration? idle, int? connections}) =>
      (insecure == null || _sameList(insecure, this.insecure)) &&
      (proxy == null || proxy == this.proxy) &&
      (idle == null || idle == this.idle) &&
      (connections == null || connections == this.connections);
}

bool _sameList(List<String> a, List<String> b) => a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);

final class _Client extends Client {
  _Client(this._s, this._conn) {
    _conn.owners++;
  }

  final _Settings _s;
  final _Conn _conn;

  final _halt = rate.Halt();
  final _requests = <HttpClientRequest>{};
  final _responses = <Response>{};
  final _sends = <Future<void>>{};
  var _closed = false;

  /// Requests in flight, for [_Pool]'s choice.
  var _inFlight = 0;

  /// Until when [_Pool] skips this member after a 429.
  DateTime? _benched;

  @override
  Client copy({
    String? base,
    Map<String, String>? headers,
    Duration? timeout,
    int? retries,
    Rate? rate,
    bool? check,
    Cookies? cookies,
    ({String cookie, String header})? csrf,
    String? proxy,
    String? cache,
    Duration? ttl,
    List<String>? insecure,
    Duration? idle,
    int? connections,
    bool? resume,
    int? limit,
  }) {
    final s = _s;
    final conn = _conn.sameAs(insecure: insecure, proxy: proxy, idle: idle, connections: connections)
        ? _conn
        : _Conn(
            insecure: insecure ?? _conn.insecure,
            proxy: proxy ?? _conn.proxy,
            idle: idle ?? _conn.idle,
            connections: connections ?? _conn.connections,
            timeout: timeout ?? _conn.timeout,
          );
    return _Client(
      _Settings(
        base: base == null ? s.base : Uri.parse(base),
        headers: headers == null ? s.headers : _merge(s.headers, headers),
        timeout: timeout ?? s.timeout,
        retries: retries ?? s.retries,
        rate: rate ?? s.rate,
        check: check ?? s.check,
        cookies: cookies ?? s.cookies,
        csrf: csrf ?? s.csrf,
        cache: cache ?? s.cache,
        ttl: ttl ?? s.ttl,
        resume: resume ?? s.resume,
        limit: limit ?? s.limit,
      ),
      conn,
    );
  }

  @override
  Cookies cookies() => _s.cookies;

  @override
  Future<Response> get(String url, {Map<String, Object?>? query, Map<String, String>? headers}) {
    if (!_s.resume) return _send('GET', url, query: query, headers: headers);
    _resolve(url, query); // a bad URL throws now, as for any verb
    return _Lazy(this, url, query, headers);
  }

  @override
  Future<Response> head(String url, {Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('HEAD', url, query: query, headers: headers);

  @override
  Future<Response> delete(String url, {Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('DELETE', url, query: query, headers: headers);

  @override
  Future<Response> post(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('POST', url, body: body, query: query, headers: headers);

  @override
  Future<Response> put(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('PUT', url, body: body, query: query, headers: headers);

  @override
  Future<Response> patch(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('PATCH', url, body: body, query: query, headers: headers);

  /// `resume: true` delivery of a GET to [path] through pass-through [pipes].
  Future<void> _resume(
    String url,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    String path,
    List<Pipe> pipes,
  ) async {
    Stream<List<int>> through(Stream<List<int>> input) {
      var out = input;
      for (final p in pipes) {
        out = p.transform(out);
      }
      return out;
    }

    Future<Response> fetch(int from) => _send(
      'GET',
      url,
      query: query,
      headers: from > 0 ? {...?headers, 'range': 'bytes=$from-'} : headers,
      check: false,
    );

    void sized(int bytes) {
      for (final p in pipes) {
        if (p case final Sized s) s.sized(bytes);
      }
    }

    final file = File(path), part = File('$path.part');
    if (await file.exists()) {
      final res = await fetch(0);
      final size = res.size();
      if (res.ok() && (size == null || size == await file.length())) {
        await res.close();
        sized(await file.length());
        if (pipes.isNotEmpty) await through(file.openRead()).drain<void>(); // bars finish, hashes verify
        return;
      }
      await res.close(); // changed (or an error page, which the fresh GET reports)
      if (await part.exists()) await part.delete();
    }
    var have = await part.exists() ? await part.length() : 0;
    var res = await fetch(have);
    if (have > 0 && res.status() != 206) {
      // No range support: a 200 is the whole body, so use it from 0.
      if (res.status() == 200) {
        have = 0;
      } else {
        await res.close();
        have = 0;
        res = await fetch(0);
      }
    } else if (have > 0 && !(res.header('content-range') ?? '').startsWith('bytes $have-')) {
      // A 206 for some other range would splice the wrong bytes on.
      await res.close();
      have = 0;
      res = await fetch(0);
    }
    await res.check();
    if (res.size() case final size?) sized(have + size);
    await part.parent.create(recursive: true);
    final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    try {
      // Replayed bytes are already on disk: the pipes see them, the file
      // does not get them twice (pass-through pipes change nothing).
      var skip = pipes.isEmpty ? 0 : have;
      final body = res.stream();
      final input = skip == 0 ? body : _concat(part.openRead(0, have), body);
      await for (final chunk in through(input)) {
        if (skip >= chunk.length) {
          skip -= chunk.length;
          continue;
        }
        sink.add(skip == 0 ? chunk : chunk.sublist(skip));
        skip = 0;
      }
      await sink.close();
    } catch (e) {
      await sink.close().catchError((_) {});
      final transport = e is IOException || e is TimeoutException || e is HttpRequestException;
      if (!transport && await part.exists()) await part.delete();
      rethrow;
    }
    await part.rename(path);
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _halt.fire();
      for (final req in [..._requests]) {
        try {
          req.abort(HttpRequestException(req.method, names.redact(req.uri), RequestFailure.aborted));
        } catch (_) {}
      }
      for (final res in [..._responses]) {
        res._kill(HttpRequestException(res._method, names.redact(res._url), RequestFailure.aborted));
      }
      _conn.leave();
    }
    while (_sends.isNotEmpty) {
      await Future.wait([
        for (final f in [..._sends]) f.catchError((_) {}),
      ]);
    }
  }

  Uri _resolve(String url, Map<String, Object?>? query) {
    Uri uri;
    try {
      final parsed = Uri.parse(url);
      uri = _withQuery(_s.base?.resolveUri(parsed) ?? parsed, query);
    } on FormatException catch (e) {
      throw ArgumentError.value(url, 'url', 'invalid URL: ${e.message}');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError.value(url, 'url', 'must be an absolute http(s) URL (or relative to base:)');
    }
    return uri;
  }

  Future<Response> _send(
    String method,
    String url, {
    Map<String, Object?>? query,
    Body? body,
    Map<String, String>? headers,
    bool check = true,
    bool retry429 = true,
  }) {
    final uri = _resolve(url, query);
    final done = Completer<void>();
    final future = _run(method, uri, body, headers, check: check, retry429: retry429);
    _sends.add(done.future);
    _inFlight++;
    return future.whenComplete(() {
      _inFlight--;
      _sends.remove(done.future);
      done.complete();
    });
  }

  HttpRequestException _aborted(String method, Uri uri) =>
      HttpRequestException(method, names.redact(uri), RequestFailure.aborted);

  Future<Response> _run(
    String method,
    Uri uri,
    Body? body,
    Map<String, String>? headers, {
    required bool check,
    required bool retry429,
  }) async {
    if (_closed) throw _aborted(method, uri);
    final sent = _merge(_s.headers, headers ?? const {});
    // A Range answer is a slice: neither served from nor stored under the URL.
    final cache = method == 'GET' && !sent.keys.any((k) => k.toLowerCase() == 'range') ? _s.cache : null;
    if (cache != null) {
      final hit = await _Cache(cache).read(uri, sent, _s.ttl, this, method);
      if (hit != null) return _checked(hit, check);
    }
    final resendable = body is! _StreamBody;
    final idempotent = method == 'GET' || method == 'HEAD' || method == 'PUT' || method == 'DELETE';
    final pace = _s.rate;
    var attempt = 0;
    Duration? retryAfter;
    var banned = false;
    while (true) {
      if (attempt > 0) {
        final server = retryAfter;
        final wait = banned && pace != null ? rate.ban(pace, server) : retry.backoff(attempt - 1, server);
        await rate.sleep(wait, _halt);
        if (_closed) throw _aborted(method, uri);
      }
      if (pace != null) {
        await rate.take(pace, _halt);
        if (_closed) throw _aborted(method, uri);
      }
      retryAfter = null;
      banned = false;
      try {
        final res = await _attempt(method, uri, body, sent);
        final code = res.status();
        final again = code == 429 && retry429 || code == 503 || (idempotent && (code == 502 || code == 504));
        if (resendable && again && attempt < _s.retries) {
          retryAfter = retry.parseRetryAfter(res.header('retry-after'));
          banned = code == 429;
          await res._abandon();
          attempt++;
          continue;
        }
        if (cache != null && code == 200) return await _checked(await _Cache(cache).write(uri, sent, res, this), check);
        res._prefetch();
        return await _checked(res, check);
      } on _Failed catch (f) {
        if (_closed) throw _aborted(method, uri);
        final safe = !f.sent || idempotent;
        if (!resendable || !safe || attempt >= _s.retries || !retry.isRetryable(f.cause)) {
          Error.throwWithStackTrace(_naming(f.cause, method, uri), f.stack);
        }
        attempt++;
      }
    }
  }

  Future<Response> _checked(Response res, bool check) async => check && _s.check && !res.ok() ? res.check() : res;

  /// One send plus manual redirect following. Network failures arrive as
  /// [_Failed]; a redirect that cannot be followed throws as-is.
  Future<Response> _attempt(String method, Uri first, Body? body, Map<String, String> headers) async {
    final client = _conn.retain();
    var delivered = false;
    try {
      var currentMethod = method;
      var uri = first;
      var currentBody = body;
      var currentHeaders = headers;
      for (var hop = 0; ; hop++) {
        final resp = await _single(client, currentMethod, uri, currentBody, currentHeaders);
        final setCookie = resp.headers[HttpHeaders.setCookieHeader];
        if (setCookie != null) jar.storeSetCookies(_s.cookies, uri, setCookie);
        final location = _isRedirect(resp.statusCode) ? resp.headers.value('location') : null;
        if (location == null || location.isEmpty) {
          delivered = true;
          return Response._(resp, this, currentMethod, uri.toString(), head: currentMethod == 'HEAD');
        }
        if (hop >= _maxRedirects) {
          await _detach(resp);
          throw HttpRequestException(
            currentMethod,
            names.redact(uri),
            RequestFailure.redirects,
            'more than $_maxRedirects redirects',
          );
        }
        await _discard(resp);
        final parsed = Uri.tryParse(location);
        final next = parsed == null ? null : uri.resolveUri(parsed);
        if (next == null || (next.scheme != 'http' && next.scheme != 'https') || next.host.isEmpty) {
          throw HttpRequestException(
            currentMethod,
            names.redact(uri),
            RequestFailure.unsendable,
            'redirect to an unsupported URL "${names.redact(location)}"',
          );
        }
        final code = resp.statusCode;
        if ((code == 301 || code == 302) && currentMethod == 'POST' || code == 303 && currentMethod != 'HEAD') {
          currentMethod = 'GET';
          currentBody = null;
          currentHeaders = _without(currentHeaders, (k) => k == 'content-type' || k == 'content-length');
        } else if (currentBody is _StreamBody) {
          throw HttpRequestException(
            currentMethod,
            names.redact(uri),
            RequestFailure.unsendable,
            'redirect $code cannot resend a streamed body',
          );
        }
        if (uri.scheme != next.scheme || uri.host != next.host || uri.port != next.port) {
          currentHeaders = _without(currentHeaders, names.isSecretHeader);
        }
        uri = next;
      }
    } finally {
      if (!delivered) _conn.release();
    }
  }

  /// Send one request without following redirects. A failure before the
  /// request opens is unsent (safe to retry for any verb); after, it is sent.
  Future<HttpClientResponse> _single(
    HttpClient client,
    String method,
    Uri uri,
    Body? body,
    Map<String, String> headers,
  ) async {
    final limit = _s.timeout;
    TimeoutException noHeaders() => Timeout('no headers for ${limit.human()}', limit);
    HttpClientRequest req;
    try {
      req = await client.openUrl(method, uri).timeout(limit, onTimeout: () => throw noHeaders());
    } catch (e, st) {
      throw _Failed(e, st, sent: false);
    }
    if (_closed) {
      req.abort();
      throw _aborted(method, uri);
    }
    _requests.add(req);
    try {
      req.followRedirects = false;
      String? length;
      for (final MapEntry(:key, :value) in headers.entries) {
        if (key.toLowerCase() == 'content-length') {
          length = value;
        } else if (key.toLowerCase() != 'cookie') {
          req.headers.set(key, value);
        }
      }
      final cookie = _cookieHeader(uri, headers);
      if (cookie != null) req.headers.set('cookie', cookie);
      final csrf = _s.csrf;
      if (csrf != null && req.headers.value(csrf.header) == null) {
        final token = jar.valueFor(_s.cookies, uri, csrf.cookie);
        if (token != null) req.headers.set(csrf.header, token);
      }
      Stream<List<int>> upload;
      switch (body) {
        case _StreamBody(:final _reader):
          if (length != null) {
            final n = int.tryParse(length.trim());
            if (n == null || n < 0) {
              throw ArgumentError.value(length, 'headers[content-length]', 'must be a non-negative integer');
            }
            req.contentLength = n;
          } else {
            req.contentLength = -1;
          }
          req.bufferOutput = false;
          upload = _reader.stream();
        case null:
          req.contentLength = 0;
          upload = const Stream.empty();
        default:
          final encoded = _encode(body);
          req.contentLength = encoded.bytes.length;
          final type = encoded.type;
          if (type != null && req.headers.value('content-type') == null) req.headers.set('content-type', type);
          upload = _slices(encoded.bytes);
      }
      try {
        await _upload(req, upload, limit);
        return await req.close().timeout(limit, onTimeout: () => throw noHeaders());
      } catch (e, st) {
        try {
          req.abort();
        } catch (_) {}
        if (_closed) throw _aborted(method, uri);
        if (e is ArgumentError || e is HttpRequestException) rethrow;
        throw _Failed(e, st, sent: true);
      }
    } finally {
      _requests.remove(req);
    }
  }

  /// The jar's cookies for [uri] merged by name with a per-call `cookie`
  /// header (the caller wins).
  String? _cookieHeader(Uri uri, Map<String, String> headers) {
    final fromJar = jar.headerFor(_s.cookies, uri);
    String? given;
    for (final MapEntry(:key, :value) in headers.entries) {
      if (key.toLowerCase() == 'cookie') given = value;
    }
    if (given == null) return fromJar;
    if (fromJar == null) return given;
    final out = <String, String>{};
    for (final part in [...fromJar.split(';'), ...given.split(';')]) {
      final pair = part.trim();
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      out[eq < 0 ? pair : pair.substring(0, eq)] = pair;
    }
    return out.values.join('; ');
  }
}

const _maxRedirects = 10;

/// A transport failure inside [_Client._run]; [sent] says whether the
/// request may have reached the server.
final class _Failed {
  _Failed(this.cause, this.stack, {required this.sent});

  final Object cause;
  final StackTrace stack;
  final bool sent;
}

final class _Pool extends Client {
  _Pool(this._members);

  final List<_Client> _members;
  var _next = 0;
  _Client? _last;

  @override
  Client copy({
    String? base,
    Map<String, String>? headers,
    Duration? timeout,
    int? retries,
    Rate? rate,
    bool? check,
    Cookies? cookies,
    ({String cookie, String header})? csrf,
    String? proxy,
    String? cache,
    Duration? ttl,
    List<String>? insecure,
    Duration? idle,
    int? connections,
    bool? resume,
    int? limit,
  }) => _Pool([
    for (final m in _members)
      m.copy(
        base: base,
        headers: headers,
        timeout: timeout,
        retries: retries,
        rate: rate,
        check: check,
        cookies: cookies,
        csrf: csrf,
        proxy: proxy,
        cache: cache,
        ttl: ttl,
        insecure: insecure,
        idle: idle,
        connections: connections,
        resume: resume,
        limit: limit,
      ) as _Client,
  ]);

  @override
  Cookies cookies() => (_last ?? _members.first).cookies();

  /// The member with the fewest requests in flight whose [Rate] has a free
  /// slot and which is not benched; ties round-robin.
  _Client _pick() {
    final now = DateTime.now();
    _Client? best;
    var score = 0;
    for (var k = 0; k < _members.length; k++) {
      final m = _members[(_next + k) % _members.length];
      final benched = m._benched != null && m._benched!.isAfter(now);
      final pace = m._s.rate;
      final s = m._inFlight + (benched ? 1 << 20 : 0) + (pace != null && !rate.free(pace) ? 1 << 10 : 0);
      if (best == null || s < score) {
        best = m;
        score = s;
      }
    }
    _next = (_members.indexOf(best!) + 1) % _members.length;
    return _last = best;
  }

  Future<Response> _send(
    String method,
    String url, {
    Body? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final m = _pick();
      // Every member benched: wait for the first to come back instead of
      // sending into its ban at once.
      final bench = m._benched?.difference(DateTime.now());
      if (bench != null && bench > Duration.zero) {
        await rate.sleep(bench, m._halt);
        if (m._closed) throw m._aborted(method, Uri.parse(url));
      }
      final res = await m._send(method, url, body: body, query: query, headers: headers, check: false, retry429: false);
      if (res.status() == 429 && attempt < m._s.retries && body is! _StreamBody) {
        final server = retry.parseRetryAfter(res.header('retry-after'));
        final pace = m._s.rate;
        m._benched = DateTime.now().add(pace != null ? rate.ban(pace, server) : server ?? retry.backoff(attempt, null));
        await res._abandon();
        continue;
      }
      return m._checked(res, true);
    }
  }

  @override
  Future<Response> get(String url, {Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('GET', url, query: query, headers: headers);

  @override
  Future<Response> head(String url, {Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('HEAD', url, query: query, headers: headers);

  @override
  Future<Response> delete(String url, {Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('DELETE', url, query: query, headers: headers);

  @override
  Future<Response> post(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('POST', url, body: body, query: query, headers: headers);

  @override
  Future<Response> put(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('PUT', url, body: body, query: query, headers: headers);

  @override
  Future<Response> patch(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers}) =>
      _send('PATCH', url, body: body, query: query, headers: headers);

  @override
  Future<void> close() async {
    await Future.wait([for (final m in _members) m.close()]);
  }
}

/// A running [Http.serve]. Close it to stop: until then it keeps the script
/// alive, as a server should.
final class Server implements Closeable {
  Server._(this._server);

  final HttpServer _server;
  final _inFlight = <Future<void>>{};
  var _closed = false;

  /// Where it listens: `http://127.0.0.1:<port>/`.
  String url() => _url;

  late final String _url = () {
    final a = _server.address;
    final host = a.type == InternetAddressType.IPv6 ? '[${a.address}]' : a.address;
    return 'http://$host:${_server.port}/';
  }();

  /// Stop accepting connections and wait for the requests in flight.
  /// Idempotent.
  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _server.close();
    }
    while (_inFlight.isNotEmpty) {
      await Future.wait([..._inFlight]);
    }
  }

  Future<void> _answer(HttpRequest req, FutureOr<Reply> Function(Request) handler) async {
    final res = req.response;
    try {
      Reply reply;
      try {
        reply = await handler(Request._(req));
      } catch (e) {
        stderr.writeln('✗ ${req.method} ${names.redact(req.uri)}: $e'); // an OAuth code or token stays out of logs
        reply = const Reply.status(500);
      }
      res.statusCode = reply._status;
      switch (reply) {
        case _TextReply(:final _text):
          res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
          res.write(_text);
        case _JsonReply(:final _value):
          res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
          res.write(jsonEncode(_value));
        case _StreamReply(:final _body, :final _type):
          final type = _type ?? _typeFor(_body.origin().name());
          if (type != null) res.headers.set('content-type', type);
          await res.addStream(_body.stream());
        case _RedirectReply(:final _to):
          res.headers.set('location', _to);
        case _StatusReply():
          break;
      }
    } catch (e) {
      try {
        res.statusCode = 500;
      } catch (_) {}
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

/// A request to an [Http.serve] handler: a [Reader] of its body.
final class Request with Reader {
  Request._(this._req);

  final HttpRequest _req;

  /// `GET`, `POST` …
  String method() => _req.method;

  /// The path, `/` first, without the query.
  String path() => _req.uri.path;

  /// Query parameter [name] (the first one when repeated), or null.
  String? query(String name) => _req.uri.queryParameters[name];

  /// Request header [name] (case-insensitive), or null.
  String? header(String name) {
    final values = _req.headers[name];
    return values == null || values.isEmpty ? null : values.join(', ');
  }

  @override
  Origin origin() => Origin(url: _req.requestedUri.toString());

  @override
  Stream<List<int>> stream() => _req;
}

/// What an [Http.serve] handler answers.
sealed class Reply {
  const Reply._(this._status);

  final int _status;

  /// UTF-8 text.
  const factory Reply.text(String text, {int status}) = _TextReply;

  /// `jsonEncode(value)` as `application/json`.
  const factory Reply.json(Object? value, {int status}) = _JsonReply;

  /// Any [Reader] (an fs `File` sets `content-type` from its name).
  const factory Reply.stream(Reader body, {int status, String? type}) = _StreamReply;

  /// A 302 to [url].
  const factory Reply.redirect(String url) = _RedirectReply;

  /// A status with no body (`Reply.status(404)`).
  const factory Reply.status(int status) = _StatusReply;
}

final class _TextReply extends Reply {
  const _TextReply(this._text, {int status = 200}) : super._(status);
  final String _text;
}

final class _JsonReply extends Reply {
  const _JsonReply(this._value, {int status = 200}) : super._(status);
  final Object? _value;
}

final class _StreamReply extends Reply {
  const _StreamReply(this._body, {int status = 200, this._type}) : super._(status);
  final Reader _body;
  final String? _type;
}

final class _RedirectReply extends Reply {
  const _RedirectReply(this._to) : super._(302);
  final String _to;
}

final class _StatusReply extends Reply {
  const _StatusReply(super.status) : super._();
}

/// `content-type` for a file name, for the common web types.
String? _typeFor(String? name) {
  if (name == null) return null;
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (name.substring(dot + 1).toLowerCase()) {
    'html' || 'htm' => 'text/html; charset=utf-8',
    'css' => 'text/css; charset=utf-8',
    'js' || 'mjs' => 'text/javascript; charset=utf-8',
    'json' => 'application/json',
    'txt' || 'md' => 'text/plain; charset=utf-8',
    'svg' => 'image/svg+xml',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'ico' => 'image/x-icon',
    'pdf' => 'application/pdf',
    'wasm' => 'application/wasm',
    'mp4' => 'video/mp4',
    'zip' => 'application/zip',
    _ => null,
  };
}

/// [first] then [rest], as one stream.
Stream<List<int>> _concat(Stream<List<int>> first, Stream<List<int>> rest) async* {
  yield* first;
  yield* rest;
}

/// A GET of a `resume: true` client: sent at the end of the current
/// synchronous block, unless a pipeline into a file claims it first
/// (`Reader.to` asks before awaiting anything) and delivers it itself.
final class _Lazy implements Future<Response>, Resumable {
  _Lazy(this._client, this._url, this._query, this._headers) {
    scheduleMicrotask(() {
      if (!_claimed) _start();
    });
  }

  final _Client _client;
  final String _url;
  final Map<String, Object?>? _query;
  final Map<String, String>? _headers;
  Future<Response>? _sent;
  var _claimed = false;

  Future<Response> _start() => _sent ??= _client._send('GET', _url, query: _query, headers: _headers);

  @override
  bool claim() {
    if (_sent != null || _claimed) return false;
    return _claimed = true;
  }

  @override
  Future<void> resume(String path, List<Pipe> pipes) => _client._resume(_url, _query, _headers, path, pipes);

  @override
  Stream<Response> asStream() => _start().asStream();

  @override
  Future<Response> catchError(Function onError, {bool Function(Object error)? test}) =>
      _start().catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(Response value) onValue, {Function? onError}) =>
      _start().then(onValue, onError: onError);

  @override
  Future<Response> timeout(Duration timeLimit, {FutureOr<Response> Function()? onTimeout}) =>
      _start().timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<Response> whenComplete(FutureOr<void> Function() action) => _start().whenComplete(action);
}

/// GET answers stored under a folder: `<key>.body` plus `<key>.json`
/// (URL, status, headers, the request headers the answer varies on, time).
final class _Cache {
  _Cache(this._dir);

  final String _dir;

  /// The entry for [uri] as these credentials see it: a page fetched
  /// with one user's token or cookies is never served to another.
  String _key(Uri uri, Map<String, String> sent, _Client client) {
    final lower = {for (final e in sent.entries) e.key.toLowerCase(): e.value};
    final who =
        '${lower['authorization'] ?? ''}\n${lower['cookie'] ?? ''}\n${jar.headerFor(client._s.cookies, uri) ?? ''}';
    var h = 0xcbf29ce484222325;
    for (final c in utf8.encode('GET $uri\n$who')) {
      h = ((h ^ c) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return '$_dir/${h.toUnsigned(64).toRadixString(16).padLeft(16, '0')}';
  }

  Future<Response?> read(Uri uri, Map<String, String> sent, Duration ttl, _Client client, String method) async {
    final key = _key(uri, sent, client);
    try {
      final meta = jsonDecode(await File('$key.json').readAsString()) as Map<String, Object?>;
      final time = DateTime.fromMillisecondsSinceEpoch(meta['time'] as int);
      if (DateTime.now().difference(time) > ttl) return null;
      final vary = (meta['vary'] as Map).cast<String, Object?>();
      final lower = {for (final e in sent.entries) e.key.toLowerCase(): e.value};
      if (vary.entries.any((e) => lower[e.key] != e.value)) return null;
      final bytes = await File('$key.body').readAsBytes();
      return Response._cached(
        client,
        method,
        meta['url'] as String,
        meta['status'] as int,
        (meta['headers'] as Map).cast<String, String>(),
        bytes,
      );
    } on IOException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<Response> write(Uri uri, Map<String, String> sent, Response res, _Client client) async {
    final bytes = Uint8List.fromList(await res.bytes());
    final headers = <String, String>{};
    res._resp?.headers.forEach((name, values) {
      if (name != 'set-cookie') headers[name] = values.join(', '); // the jar has them; a file must not
    });
    final lower = {for (final e in sent.entries) e.key.toLowerCase(): e.value};
    final vary = {
      for (final name in (headers['vary'] ?? '').split(',').map((s) => s.trim().toLowerCase()))
        if (name.isNotEmpty && name != '*') name: lower[name],
    };
    final key = _key(uri, sent, client);
    if (!await Directory(_dir).exists()) {
      await Directory(_dir).create(recursive: true);
      await posix.chmod(_dir, 0x1c0); // 0700: bodies of authenticated pages live here
    }
    await File('$key.body').writeAsBytes(bytes);
    await File('$key.json').writeAsString(
      jsonEncode({
        'url': res.url(),
        'status': res.status(),
        'headers': headers,
        'vary': vary,
        'time': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    return Response._cached(client, res._method, res.url(), res.status(), headers, bytes);
  }
}

/// An HTTP response: a [Reader] of the body, streamed from the socket.
///
/// - A non-2xx status is still a [Response] (unless the client says
///   `check:`). [ok] tests 200–299. The readings ([text], [bytes], [lines])
///   work on any status, but only a 2xx body can be piped: [stream] (and so
///   `>`/`to`) throws the same [HttpStatusException] as [check] otherwise.
/// - [text] decodes with the charset in `content-type`, then
///   `<meta charset>` (HTML or an untyped body only), then UTF-8 (WHATWG CJK
///   decoders included). Unknown charsets fall back to UTF-8; bad bytes
///   become `�`.
/// - A body of up to 64 KB is read as the headers arrive, so an unread
///   response never keeps the script alive; [close] drops a longer unread
///   one. A body read or piped to the end releases the connection by itself.
///   The `Future<Response>` mirrors (`api.get(u).status()`) close the
///   response after reading.
final class Response with Reader implements Closeable {
  Response._(HttpClientResponse resp, this._client, this._method, this._url, {required this._head})
    : _resp = resp,
      _status = resp.statusCode,
      _headers = null {
    _client._responses.add(this);
  }

  /// A stored answer ([Http.client]'s `cache:`): no socket behind it.
  Response._cached(this._client, this._method, this._url, this._status, Map<String, String> headers, Uint8List bytes)
    : _resp = null,
      _headers = headers,
      _head = false {
    _cached = bytes;
    _done = _released = true;
  }

  final HttpClientResponse? _resp;
  final Map<String, String>? _headers;
  final _Client _client;
  final String _method;
  final int _status;

  /// The final URL, after redirects.
  final String _url;

  /// A HEAD response: no body follows, whatever `content-length` says.
  final bool _head;

  Uint8List? _cached;
  Future<Uint8List>? _reading;

  static const _prefix = 64 * 1024;
  StreamSubscription<List<int>>? _preSub;
  Completer<void>? _preReady; // the body ended, overflowed or failed
  final _preBuf = BytesBuilder(copy: false);
  var _preEnded = false, _preTaken = false;
  Object? _preError;
  StackTrace? _preStack;

  var _streaming = false;
  var _closed = false;
  var _done = false;
  var _released = false;

  bool get _empty => _head || _status == 204 || _status == 304;

  void _prefetch() {
    final len = _empty ? 0 : size();
    if (len != null && len > _prefix) return; // known to be long: streamed
    _streaming = true;
    final ready = _preReady = Completer<void>();
    _preSub = _bodyStream().listen(
      (chunk) {
        _preBuf.add(chunk);
        if (_preBuf.length > _prefix && !ready.isCompleted) {
          _preSub!.pause();
          ready.complete();
        }
      },
      onError: (Object e, StackTrace st) {
        _preError = e;
        _preStack = st;
        _preEnded = true;
        _finish();
        if (!ready.isCompleted) ready.complete();
      },
      onDone: () {
        _preEnded = true;
        _cached = _preBuf.takeBytes();
        _finish();
        if (!ready.isCompleted) ready.complete();
      },
      cancelOnError: true,
    );
  }

  /// The prefetched body as a stream: the cache, or the held prefix then
  /// the rest through the resumed subscription.
  Stream<List<int>> _fromPrefetch() async* {
    await _preReady!.future;
    final e = _preError;
    if (e != null) Error.throwWithStackTrace(e, _preStack!);
    if (_preEnded) {
      yield _cached!.asUnmodifiableView();
      return;
    }
    if (_preTaken) throw StateError('body already streaming: ${names.redact(url())}');
    _preTaken = true;
    yield _preBuf.takeBytes();
    final rest = StreamController<List<int>>();
    final sub = _preSub!
      ..onData(rest.add)
      ..onError((Object e, StackTrace st) {
        rest.addError(e, st);
        rest.close();
      })
      ..onDone(rest.close);
    rest.onCancel = sub.cancel;
    sub.resume();
    try {
      yield* rest.stream;
    } finally {
      _finish();
    }
  }

  /// HTTP status code (e.g. 200, 404).
  int status() => _status;

  /// Whether the status is 2xx.
  bool ok() => _status >= 200 && _status < 300;

  /// This response when 2xx; otherwise throws [HttpStatusException] with
  /// the body's first 200 characters (and drops the body).
  Future<Response> check() async {
    if (ok()) return this;
    throw await _statusError();
  }

  Future<HttpStatusException> _statusError() async {
    final snippet = await _snippet();
    final where = names.redact(_url);
    return HttpStatusException(
      'HTTP $_status $_method $where${snippet.isEmpty ? '' : ': $snippet'}',
      status: _status,
      method: _method,
      url: where,
      snippet: snippet,
    );
  }

  /// Response header [name] (case-insensitive) or `null` if absent.
  String? header(String name) {
    final headers = _headers;
    if (headers != null) return headers[name.toLowerCase()];
    final values = _resp!.headers[name];
    if (values == null || values.isEmpty) return null;
    return values.join(', ');
  }

  /// The final URL, after redirects.
  String url() => _url;

  /// The body's length in bytes as it will be read, or `null` when unknown
  /// (no `content-length`, or a compressed body decoded on the fly).
  int? size() {
    final encoding = header('content-encoding');
    if (encoding != null && encoding.toLowerCase() != 'identity' && _resp != null) return null;
    final n = int.tryParse(header('content-length')?.trim() ?? '');
    return n == null || n < 0 ? null : n;
  }

  /// A file name for the body: the `content-disposition` filename
  /// (`filename*=` wins over `filename=`, paths stripped), else the final
  /// URL's last segment, else `'download'`.
  String name() => names.fileName(url: _url, contentDisposition: header('content-disposition'));

  /// Where the body came from: final URL, status and file name.
  @override
  Origin origin() => Origin(url: _url, status: _status, name: name());

  /// The body as text (see the class doc for the charset rules); cached.
  @override
  Future<String> text() async => charset.Charset.decode(await bytes(), contentType: header('content-type'));

  /// The text line by line; works on any status, like [text].
  @override
  Stream<String> lines() => ok() ? super.lines() : Stream.fromFuture(text()).expand(LineSplitter.split);

  /// The body as bytes, cached like [text]: an unmodifiable view, no copy.
  @override
  Future<List<int>> bytes() async {
    if (_closed) throw StateError('response is closed: ${names.redact(url())}');
    final cached = _cached;
    if (cached != null) return cached.asUnmodifiableView();
    if (_preReady != null) return (await (_reading ??= _readAll())).asUnmodifiableView();
    final reading = _reading;
    if (reading != null) return (await reading).asUnmodifiableView();
    if (_streaming) throw StateError('body already streaming: ${names.redact(url())}');
    _streaming = true;
    return (await (_reading = _readAll())).asUnmodifiableView();
  }

  Future<Uint8List> _readAll() async {
    try {
      final out = BytesBuilder(copy: false);
      final limit = _client._s.limit;
      await for (final chunk in _preReady != null ? _fromPrefetch() : _bodyStream()) {
        out.add(chunk);
        if (out.length > limit) {
          await _abandon();
          throw ContentException(
            'response body over $limit bytes: pipe it to a file, or raise Http.client(limit:) '
            '(${names.redact(url())})',
          );
        }
      }
      return _cached = out.takeBytes();
    } finally {
      _reading = null;
      _finish();
    }
  }

  @override
  Stream<List<int>> stream() {
    if (_closed) throw StateError('response is closed: ${names.redact(url())}');
    if (!ok()) return _refused();
    final cached = _cached;
    if (cached != null) return Stream.value(cached.asUnmodifiableView());
    if (_preReady != null) return _fromPrefetch();
    if (_streaming) throw StateError('body already streaming: ${names.redact(url())}');
    _streaming = true;
    return _streamBody();
  }

  /// Only a 2xx body can be piped, so an error page is never saved.
  Stream<List<int>> _refused() async* {
    throw await _statusError();
  }

  Stream<List<int>> _streamBody() async* {
    try {
      yield* _bodyStream();
    } finally {
      _finish();
    }
  }

  /// Drop a body nobody will read, so the socket doesn't keep the script
  /// alive. Idempotent; a no-op after the body is consumed. Reading after
  /// [close] is a [StateError].
  @override
  Future<void> close() async {
    final ready = _preReady;
    if (ready != null) {
      _closed = true;
      if (_preEnded || _preTaken) return;
      // A short body still arriving gets the drain budget, then is dropped.
      if (_preBuf.length <= _prefix) await ready.future.timeout(_drainBudget, onTimeout: () {});
      if (!_preEnded) {
        await _preSub?.cancel();
        await _abandon();
      }
      return;
    }
    if (_closed || _done) {
      _closed = true;
      _finish();
      return;
    }
    final len = _empty ? 0 : size();
    if (len == null || len > _prefix) return _abandon();
    _closed = true;
    try {
      await _resp!.drain<void>().timeout(_drainBudget);
    } catch (_) {
      await _detach(_resp!);
    } finally {
      _finish();
    }
  }

  /// The first 200 characters of the body, whitespace collapsed, then the
  /// body is dropped. Empty when unreadable.
  Future<String> _snippet() async {
    final out = BytesBuilder(copy: false);
    try {
      final cached = _cached;
      if (cached != null) {
        out.add(cached.length > 1024 ? cached.sublist(0, 1024) : cached);
      } else if (_preReady != null && !_closed) {
        await _preReady!.future.timeout(_drainBudget, onTimeout: () {});
        out.add(_cached ?? _preBuf.toBytes());
      } else if (!_streaming && !_closed && !_done) {
        _streaming = true;
        await for (final chunk in _bodyStream()) {
          out.add(chunk);
          if (out.length >= 1024) break;
        }
      }
    } catch (_) {}
    await _abandon();
    final text = charset.Charset.decode(out.takeBytes(), contentType: header('content-type'));
    final flat = text.replaceAll(_spaces, ' ').trim();
    return flat.length > 200 ? '${flat.substring(0, 200)}...' : flat;
  }

  /// Drop the body without draining it: force-close the socket instead of
  /// waiting up to the full timeout for bytes nobody wants.
  Future<void> _abandon() async {
    _closed = true;
    if (!_done) {
      try {
        await _preSub?.cancel();
      } catch (_) {}
      final resp = _resp;
      if (resp != null) await _detach(resp);
    }
    _finish();
  }

  /// The socket's body with the stall timeout, which [_kill] can fail.
  Stream<List<int>> _bodyStream() {
    final limit = _client._s.timeout;
    late final StreamController<List<int>> out;
    StreamSubscription<List<int>>? sub;
    out = StreamController<List<int>>(
      sync: true,
      onListen: () {
        sub = _resp!
            .timeout(
              limit,
              onTimeout: (sink) =>
                  sink.addError(Timeout('body stalled for ${limit.human()}: $_method ${names.redact(_url)}', limit)),
            )
            .listen(out.add, onError: out.addError, onDone: out.close);
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () => sub?.cancel(),
    );
    _killer = (error) {
      sub?.cancel();
      if (!out.isClosed) {
        out.addError(error);
        out.close();
      }
    };
    return out.stream;
  }

  void Function(Object error)? _killer;

  /// Fail the body read in flight with [error] and drop the connection.
  void _kill(Object error) {
    _closed = true;
    final ready = _preReady;
    if (ready != null && !ready.isCompleted) {
      _preError = error;
      _preStack = StackTrace.current;
      _preEnded = true;
      ready.complete();
    }
    final killer = _killer;
    if (killer != null && !_done) {
      killer(error);
    } else if (!_done && _resp != null) {
      unawaited(_detach(_resp));
    }
    _finish();
  }

  void _finish() {
    _done = true;
    if (_released) return;
    _released = true;
    _client._responses.remove(this);
    _client._conn.release();
  }
}

final _spaces = RegExp(r'\s+');

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
///
/// Each reading mirror closes the response after reading: a response reached
/// only through a mirror can never be read later. [check] keeps it open.
extension ResponseFuture on Future<Response> {
  Future<T> _read<T>(T Function(Response r) read) async {
    final res = await this;
    try {
      return read(res);
    } finally {
      await res.close();
    }
  }

  Future<int> status() => _read((r) => r.status());

  Future<bool> ok() => _read((r) => r.ok());

  Future<String?> header(String name) => _read((r) => r.header(name));

  Future<String> url() => _read((r) => r.url());

  Future<int?> size() => _read((r) => r.size());

  Future<String> name() => _read((r) => r.name());

  /// `api.get(u).check().json()`.
  Future<Response> check() async => (await this).check();
}

/// The query string for [values]: `num`/`bool` as text, null drops the key,
/// an `Iterable` repeats it.
String _encodePairs(Map<String, Object?> values) {
  final out = StringBuffer();
  void add(String key, Object? value) {
    if (value == null) return;
    if (out.isNotEmpty) out.write('&');
    out
      ..write(Uri.encodeQueryComponent(key))
      ..write('=')
      ..write(
        Uri.encodeQueryComponent(switch (value) {
          String() => value,
          num() || bool() => '$value',
          _ => throw ArgumentError.value(value, key, 'must be a String, num, bool, null or an Iterable of those'),
        }),
      );
  }

  for (final MapEntry(:key, :value) in values.entries) {
    if (value is Iterable && value is! String) {
      for (final v in value) {
        add(key, v);
      }
    } else {
      add(key, value);
    }
  }
  return out.toString();
}

Uri _withQuery(Uri url, Map<String, Object?>? query) {
  if (query == null || query.isEmpty) return url;
  final added = _encodePairs(query);
  if (added.isEmpty) return url;
  return url.replace(query: url.hasQuery && url.query.isNotEmpty ? '${url.query}&$added' : added);
}

({List<int> bytes, String? type}) _encode(Body body) => switch (body) {
  _TextBody(:final _text) => (bytes: utf8.encode(_text), type: 'text/plain; charset=utf-8'),
  _BytesBody(:final _bytes) => (bytes: _bytes, type: null),
  _FormBody(:final _fields) => (bytes: utf8.encode(_encodePairs(_fields)), type: 'application/x-www-form-urlencoded'),
  _JsonBody(:final _value) => (bytes: utf8.encode(jsonEncode(_value)), type: 'application/json'),
  _StreamBody() => throw StateError('streamed body is not in memory'),
};

/// [base] with [extra] laid over it, names compared case-insensitively.
Map<String, String> _merge(Map<String, String> base, Map<String, String> extra) {
  if (extra.isEmpty) return base;
  if (base.isEmpty) return extra;
  final lower = {for (final k in extra.keys) k.toLowerCase()};
  return {
    for (final e in base.entries)
      if (!lower.contains(e.key.toLowerCase())) e.key: e.value,
    ...extra,
  };
}

Map<String, String> _without(Map<String, String> headers, bool Function(String lowerName) drop) => {
  for (final e in headers.entries)
    if (!drop(e.key.toLowerCase())) e.key: e.value,
};

/// [e] with the request in its message (`METHOD url`); types are kept.
Object _naming(Object e, String method, Uri url) {
  final what = '$method ${names.redact(url)}';
  return switch (e) {
    SocketException() => SocketException('${e.message}: $what', osError: e.osError, address: e.address, port: e.port),
    HandshakeException() => HandshakeException('${e.message}: $what', e.osError),
    CertificateException() => CertificateException('${e.message}: $what', e.osError),
    TlsException() => TlsException('${e.message}: $what', e.osError),
    TimeoutException() => Timeout('${e.message}: $what', e.duration),
    HttpException() => HttpException('${e.message}: $what', uri: Uri.tryParse(names.redact(e.uri ?? url))),
    _ => e,
  };
}

bool _isRedirect(int status) => status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

/// Send [body] on [req], failing only when no chunk moves for [limit]: a
/// long upload that keeps moving never times out, a server that stops
/// reading does.
Future<void> _upload(HttpClientRequest req, Stream<List<int>> body, Duration limit) async {
  final stalled = Completer<void>();
  Timer? watchdog;
  void arm() {
    watchdog?.cancel();
    watchdog = Timer(limit, () {
      if (!stalled.isCompleted) stalled.completeError(Timeout('upload stalled for ${limit.human()}', limit));
    });
  }

  arm();
  final sending = req.addStream(
    body.map((chunk) {
      arm();
      return chunk;
    }),
  );
  sending.ignore();
  try {
    await Future.any([sending, stalled.future]);
  } finally {
    watchdog?.cancel();
  }
}

/// [bytes] as 64 KiB views, so an in-memory upload is watched per chunk too.
Stream<List<int>> _slices(List<int> bytes) async* {
  const size = 64 * 1024;
  for (var i = 0; i < bytes.length; i += size) {
    final end = i + size > bytes.length ? bytes.length : i + size;
    yield bytes is Uint8List ? Uint8List.sublistView(bytes, i, end) : bytes.sublist(i, end);
  }
}

/// How long a body nobody reads may take to drain before its socket is
/// detached instead.
const _drainBudget = Duration(milliseconds: 200);

Future<void> _discard(HttpClientResponse resp) async {
  try {
    await resp.drain<void>().timeout(_drainBudget);
  } catch (_) {
    await _detach(resp);
  }
}

Future<void> _detach(HttpClientResponse resp) async {
  try {
    (await resp.detachSocket()).destroy();
  } catch (_) {}
}
