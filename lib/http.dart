/// Minimal HTTP client. Thin facade over SDK `dart:io` `HttpClient`.
///
/// ```dart
/// final api = Http.client(base: 'https://api.example.com/', headers: {'authorization': token});
/// final me = await api.get('me').json();
/// final cdn = Http.client(resume: true);
/// await (cdn.get(isoUrl) & Console.bar('d.iso') > Fs.file('d.iso'));   // skips, resumes, renames atomically
/// await api.put('upload', body: .stream(Fs.file('d.iso') & Console.bar('upload')));
/// ```
///
/// Public surface is exactly: [Http], [Client], [Response], [Body],
/// [HttpStatusException], [HttpRequestException], [RequestFailure],
/// [SessionException], [Feed], [FeedPage].
/// - `Http.client(...)` holds the settings a script states once (base,
///   headers, cookies, retries, pacing); `client.copy(...)` is a variant
///   that stays one session. `Http.pool([...])` spreads requests over
///   several clients.
/// - [Client] verbs `get` `head` `delete` `post` `put` `patch` return a
///   [Response]; `cookies` is the jar. With `resume: true`, a GET piped
///   into a file skips a complete file and resumes a partial one.
/// - [Response] supports `status` `ok` `check` `header` `url` `size` `name`
///   (plus [Reader]/[Closeable]).
/// - [Client] `sent` counts the requests put on the wire.
/// - [Feed] walks a newest-first listing page by page (`run((page) {…})`,
///   a [FeedPage] with `items` `add` `stop`): up to what is known, with a
///   cursor file that survives an interrupted run.
/// - [Body] is a sealed request body: `.text` `.bytes` `.form` `.json`
///   `.multipart` `.stream`. A [Body.stream] (or a multipart with
///   `files:`) is sent once and never retried.
/// - [HttpStatusException] is what `check` and piping a non-2xx body throw;
///   [HttpRequestException] is a request that was aborted or could not
///   follow a redirect.
/// A non-2xx status throws [HttpStatusException] by default; with
/// `check: false` it is a [Response] and only network failures and
/// timeouts throw. Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'core.dart';
export 'core.dart';

import 'src/charset.dart' as charset;
import 'src/cookies.dart' as jar;
import 'src/cookies.dart' show Cookies;
import 'src/decoders.dart';
import 'src/exit.dart' as signals;
import 'src/missing.dart' show missing;
import 'src/origin.dart' as names;
import 'src/rate.dart' as rate;
import 'src/rate.dart' show Rate;
import 'src/resume.dart';
import 'src/retry.dart' as retry;
import 'src/time.dart' show SpanUtils;
import 'src/timeout.dart';

part 'src/http/feed.dart';
part 'src/http/proxy.dart';
part 'src/http/response.dart';

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

  /// Streamed from [reader]: sent once, never retried. The length and
  /// type come from its `origin()` when it knows them (a file, in-memory
  /// bytes, a named reader), unless `headers:` give them; otherwise it
  /// goes chunked.
  const factory Body.stream(Reader reader) = _StreamBody;

  /// `multipart/form-data`: [fields] as text, then [files] streamed from
  /// their readers (`origin().name()` is the filename, the type comes from
  /// it). With [files] the body is sent once, like [Body.stream].
  ///
  /// ```dart
  /// await api.post('upload', body: .multipart({'title': 'Cat'}, files: {'file': Fs.file('cat.jpg')}));
  /// ```
  const factory Body.multipart(Map<String, String> fields, {Map<String, Reader> files}) = _MultipartBody;

  /// Whether the bytes can be produced again (a retry, a 307/308 resend).
  bool get _resendable => true;
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

  @override
  bool get _resendable => false;
}

final class _MultipartBody extends Body {
  const _MultipartBody(this._fields, {this._files = const {}}) : super._();

  final Map<String, String> _fields;
  final Map<String, Reader> _files;

  @override
  bool get _resendable => _files.isEmpty;

  /// The body as byte chunks and [Reader]s, in order.
  List<Object> _pieces(String boundary) {
    String quote(String s) => s.replaceAll('"', '%22').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
    String head(String name) => '--$boundary\r\nContent-Disposition: form-data; name="${quote(name)}"';
    final out = <Object>[
      for (final MapEntry(:key, :value) in _fields.entries) utf8.encode('${head(key)}\r\n\r\n$value\r\n'),
    ];
    for (final MapEntry(:key, :value) in _files.entries) {
      final origin = value.origin();
      final file = origin.name() ?? origin.path()?.split(RegExp(r'[\\/]')).last ?? key;
      out
        ..add(
          utf8.encode(
            '${head(key)}; filename="${quote(file)}"\r\n'
            'Content-Type: ${_typeFor(file) ?? 'application/octet-stream'}\r\n\r\n',
          ),
        )
        ..add(value)
        ..add(const [13, 10]);
    }
    out.add(utf8.encode('--$boundary--\r\n'));
    return out;
  }
}

/// A multipart boundary: random, so no part contains it.
String _boundary() {
  final r = Random.secure();
  return 'dart-toolkit-${List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

Stream<List<int>> _streamPieces(List<Object> pieces) async* {
  for (final p in pieces) {
    if (p is Reader) {
      yield* p.stream();
    } else {
      yield p as List<int>;
    }
  }
}

/// What `check` and piping a non-2xx body throw: the status, the
/// method, the final URL and the body's first line as fields, so callers
/// switch on `status` instead of parsing the message. Extends [HttpException],
/// so an existing `on HttpException` keeps catching it.
final class HttpStatusException extends HttpException implements ToolkitException {
  HttpStatusException(super.message, {required this.status, required this.method, required this.url, this.snippet = ''})
    : super(uri: Uri.tryParse(url)) {
    // A 4xx is the server's answer to this request: `pool` never retries
    // it (408 and 429 say "later", so they are retried).
    if (status >= 400 && status < 500 && status != 408 && status != 429) retry.permanent(this);
    // A 404/410 is "the source is not there" for every reading's `or:`.
    if (status == 404 || status == 410) missing(this);
  }

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

/// A logged-in session that is not any more: the request landed on one of
/// the client's `login:` paths (a redirect to the sign-in page) instead of
/// what it asked for. [url] is where it landed.
final class SessionException extends ToolkitException {
  SessionException(this.url) : super('logged out: the request landed on $url; log in again and refresh the session') {
    retry.permanent(this);
  }

  /// Where the request landed (credentials redacted).
  final String url;

  @override
  String toString() => 'SessionException: $message';
}

/// A request that was aborted or could not follow a redirect. Extends
/// [HttpException], so an existing `on HttpException` keeps catching it.
final class HttpRequestException extends HttpException implements ToolkitException {
  HttpRequestException(this.method, this.url, this.reason, [String? detail])
    : super('${detail ?? reason.name}: $method $url', uri: Uri.tryParse(url)) {
    retry.permanent(this);
  }

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
  ///   wins for that call. Secret ones (`authorization`, `cookie`, names
  ///   with `token`, `key`, `auth` …) go only to [base]'s origin, or without
  ///   [base] to the first request's. Without a `user-agent` one, requests
  ///   send the user-agent the jar's session file names (its `user-agent:`
  ///   line), else a current desktop Chrome's. utils' `HttpUtils.page` /
  ///   `HttpUtils.api` are what a desktop browser sends.
  /// - [timeout]: the connect, the wait for the headers, then any stall
  ///   streaming.
  /// - [retries] (3): re-sends only when the request provably was not
  ///   processed. Any in-memory body retries on connect/DNS failures before
  ///   sending, 429 and 503; GET, HEAD, PUT and DELETE also on timeouts,
  ///   network errors and 502/504. Backoff doubles from 1 s with ±25%
  ///   jitter; `Retry-After` is honoured (capped at 5 min unless [rate] is
  ///   set, then a 429 waits the window out). TLS failures never retry.
  /// - [rate] paces every send (each host apart with `perHost: true`);
  ///   [check] (true) throws [HttpStatusException] on a non-2xx status;
  ///   `check: false` returns the [Response] to branch on its `status()`.
  /// - [cookies]: the jar (a fresh one when null): `set-cookie` (redirect
  ///   hops too) updates it, and a per-call `cookie` header merges by name.
  /// - [csrf] copies a cookie into a header on every send.
  /// - [proxy]: `http://host:port` or `socks5://host:port` (credentials
  ///   allowed, port 1080 by default, names resolved by a SOCKS proxy); null
  ///   reads `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` like curl.
  /// - [resume]: a GET piped into a file (`get(u) & bar > Fs.file(f)`)
  ///   skips a complete file (same `content-length`, or any file when the
  ///   server sends none), resumes a `.part` with `Range` and `If-Range` (its
  ///   ETag or Last-Modified, kept in `.part.tag`; a 206 for exactly the
  ///   missing bytes, anything else restarts), and renames the finished
  ///   file into place. Stored
  ///   bytes are replayed through the pipes, so a bar counts the whole file
  ///   (and its rate only the new bytes) and a hash verifies it; a pipe that is not a pass-through (gzip, a
  ///   filter) downloads from scratch. A transport failure keeps the `.part`
  ///   for the next run, any other failure deletes it. The GET is sent at
  ///   the end of the current synchronous block unless such a pipeline
  ///   claims it first, so awaiting it, or not using it, sends it as usual.
  /// - [max]: the most bytes a body read into memory (`bytes`, `text`,
  ///   `json`, `html`) may decode to; past it the read fails with a
  ///   [ContentException], so a gzip bomb cannot fill the heap. Piping a
  ///   body into a file has no limit.
  /// - [login]: paths of the site's sign-in pages (`/accounts/login`); a
  ///   response that lands on one, after redirects, throws
  ///   [SessionException]: the session in [cookies] has run out.
  static Client client({
    String? base,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30),
    int retries = 3,
    Rate? rate,
    bool check = true,
    Cookies? cookies,
    ({String cookie, String header})? csrf,
    String? proxy,
    bool resume = false,
    int max = 256 << 20,
    List<String> login = const [],
  }) {
    if (max < 0) throw ArgumentError.value(max, 'max', 'must not be negative');
    if (retries < 0) throw ArgumentError.value(retries, 'retries', 'must not be negative');
    final settings = _Settings(
      base: base == null ? null : Uri.parse(base),
      headers: headers,
      timeout: timeout,
      retries: retries,
      rate: rate,
      check: check,
      cookies: cookies ?? Cookies(),
      csrf: csrf,
      resume: resume,
      max: max,
      login: login,
    );
    return _Client(settings, _Conn(proxy: proxy, timeout: timeout));
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
/// resend an in-memory body. A cross-origin hop drops credential headers;
/// an https → http hop is followed with a warning on stderr.
/// [query] values may be `String`, `num`, `bool`, a `Map` (sent as JSON, as
/// GraphQL's `variables`), null (drops the key) or an `Iterable` of those
/// (repeats the key).
sealed class Client implements Closeable {
  /// A variant of this client with other [headers] (merged by name),
  /// [timeout], [retries], [rate] or [proxy] (null keeps this one's); any
  /// other setting is a new [Http.client]. The copy shares the jar, and the
  /// [Rate] and the connections unless it overrides them, counts in this
  /// client's [sent] and closes with it.
  Client copy({Map<String, String>? headers, Duration? timeout, int? retries, Rate? rate, String? proxy});

  /// The cookie jar: persist it with `cookies().encode()`.
  Cookies cookies();

  /// How many requests this client has put on the wire: every attempt and
  /// redirect hop. A pool counts its members.
  int sent();

  /// GET [url] (relative to `base:`), [query] appended; completes when the
  /// headers arrive. With `resume: true`, `get(u) > file` skips and resumes.
  Future<Response> get(String url, {Map<String, Object?>? query, Map<String, String>? headers});

  /// HEAD [url]: the status and headers, no body.
  Future<Response> head(String url, {Map<String, Object?>? query, Map<String, String>? headers});

  /// DELETE [url].
  Future<Response> delete(String url, {Map<String, Object?>? query, Map<String, String>? headers});

  /// POST [body] to [url].
  Future<Response> post(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers});

  /// PUT [body] at [url].
  Future<Response> put(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers});

  /// PATCH [url] with [body].
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
    required this.resume,
    required this.max,
    required this.login,
  });

  final Uri? base;
  final Map<String, String> headers;
  final Duration timeout;
  final int retries;
  final Rate? rate;
  final bool check;
  final Cookies cookies;
  final ({String cookie, String header})? csrf;
  final bool resume;
  final int max;
  final List<String> login;
}

/// One `HttpClient` with its socket settings, counted by the requests and
/// live responses of every client that shares it. When the count reaches
/// 0 the sockets close after [_idle], so a sequential loop keeps one
/// connection while a finished script exits.
final class _Conn {
  _Conn({required this.proxy, required this.timeout}) : _proxy = proxy == null ? null : _Proxy.parse(proxy);

  static const _idle = Duration(milliseconds: 100);
  static const _perHost = 6;

  final String? proxy;
  final Duration timeout;
  final _Proxy? _proxy;

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
      _closer = Timer(_idle, () {
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
      ..maxConnectionsPerHost = _perHost
      ..connectionTimeout = timeout;
    final p = _proxy;
    if (p == null) {
      c.findProxy = HttpClient.findProxyFromEnvironment;
    } else {
      p.apply(c, timeout);
    }
    return c;
  }

  bool sameAs({String? proxy, Duration? timeout}) =>
      (timeout == null || timeout == this.timeout) && (proxy == null || proxy == this.proxy);
}

/// One send's own backoffs, rate waits and requests: Ctrl-C or a cancelled
/// scope stops only these (the send fails with [InterruptedException]),
/// never the client's other calls; a body being read fails on its own.
final class _Call {
  _Call(rate.Halt client) : halt = rate.Halt.under(client);

  final rate.Halt halt;
  final requests = <HttpClientRequest>{};

  void stop() {
    halt.fire();
    for (final req in [...requests]) {
      try {
        req.abort(const InterruptedException());
      } catch (_) {}
    }
  }
}

final class _Client extends Client {
  _Client(this._s, this._conn, [this._parent]) {
    _conn.owners++;
  }

  /// The client this one is a [copy] of.
  final _Client? _parent;

  final _Settings _s;
  final _Conn _conn;

  final _halt = rate.Halt();
  final _requests = <HttpClientRequest>{};
  final _responses = <Response>{};
  final _sends = <Future<void>>{};
  var _closed = false;

  /// Requests in flight, for [_Pool]'s choice.
  var _inFlight = 0;

  /// The origin secret client headers are for: `base:`'s, else the first
  /// request's. Other origins get the rest of the client headers.
  late String? _home = _s.base == null ? null : _origin(_s.base!);

  /// The client headers for [uri], secrets only at home.
  Map<String, String> _headersFor(Uri uri) {
    final here = _origin(uri);
    if ((_home ??= here) == here || _s.headers.isEmpty) return _s.headers;
    return _without(_s.headers, names.isSecretHeader);
  }

  var _sent = 0;

  /// The open clients [copy] made: counted in [sent], closed by [close]. A
  /// copy that closes leaves its count here and drops out.
  final _copies = <_Client>[];

  @override
  int sent() => _copies.fold(_sent, (n, c) => n + c.sent());

  /// Until when [_Pool] skips this member after a 429.
  DateTime? _benched;

  @override
  Client copy({Map<String, String>? headers, Duration? timeout, int? retries, Rate? rate, String? proxy}) {
    final s = _s;
    final conn = _conn.sameAs(proxy: proxy, timeout: timeout)
        ? _conn
        : _Conn(proxy: proxy ?? _conn.proxy, timeout: timeout ?? _conn.timeout);
    final copy = _Client(
      _Settings(
        base: s.base,
        headers: headers == null ? s.headers : _merge(s.headers, headers),
        timeout: timeout ?? s.timeout,
        retries: retries ?? s.retries,
        rate: rate ?? s.rate,
        check: s.check,
        cookies: s.cookies,
        csrf: s.csrf,
        resume: s.resume,
        max: s.max,
        login: s.login,
      ),
      conn,
      this,
    );
    _copies.add(copy);
    return copy;
  }

  @override
  Cookies cookies() => _s.cookies;

  @override
  Future<Response> get(String url, {Map<String, Object?>? query, Map<String, String>? headers}) {
    if (!_s.resume) return _send('GET', url, query: query, headers: headers);
    _resolve(url, query); // a bad URL throws now, as for any verb
    return _Lazy(
      () => _send('GET', url, query: query, headers: headers),
      (extra) => _send('GET', url, query: query, headers: {...?headers, ...extra}, check: false),
    );
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
    await Future.wait([
      for (final c in [..._copies]) c.close(),
    ]);
    while (_sends.isNotEmpty) {
      await Future.wait([
        for (final f in [..._sends]) f.catchError((_) {}),
      ]);
    }
    // Every send has finished: the count is final.
    if (_parent case final p? when p._copies.remove(this)) p._sent += sent();
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
    if (signals.interrupted) return Future.error(const InterruptedException());
    final done = Completer<void>();
    final call = _Call(_halt);
    final future = signals.interruptible(
      _run(method, uri, body, headers, call, check: check, retry429: retry429),
      stop: call.stop,
    );
    _sends.add(done.future);
    _inFlight++;
    return future.whenComplete(() {
      call.halt.fire();
      _inFlight--;
      _sends.remove(done.future);
      done.complete();
    });
  }

  HttpRequestException _aborted(String method, Uri uri) =>
      HttpRequestException(method, names.redact(uri), RequestFailure.aborted);

  /// Stop before sending again: closed, or interrupted.
  void _stopped(String method, Uri uri) {
    if (_closed) throw _aborted(method, uri);
    if (signals.interrupted) throw const InterruptedException();
  }

  Future<Response> _run(
    String method,
    Uri uri,
    Body? body,
    Map<String, String>? headers,
    _Call call, {
    required bool check,
    required bool retry429,
  }) async {
    _stopped(method, uri);
    final sent = _merge(_headersFor(uri), headers ?? const {});
    final resendable = body?._resendable ?? true;
    final idempotent = method == 'GET' || method == 'HEAD' || method == 'PUT' || method == 'DELETE';
    final pace = _s.rate;
    var attempt = 0;
    Duration? retryAfter;
    var banned = false;
    while (true) {
      if (attempt > 0) {
        final server = retryAfter;
        final wait = banned && pace != null
            ? rate.ban(pace, server, host: uri.host)
            : retry.backoff(attempt - 1, server);
        await rate.sleep(wait, call.halt);
        _stopped(method, uri);
      }
      if (pace != null) {
        await rate.take(pace, call.halt, host: uri.host);
        _stopped(method, uri);
      }
      retryAfter = null;
      banned = false;
      try {
        final res = await _attempt(method, uri, body, sent, call);
        final code = res.status();
        final again = code == 429 && retry429 || code == 503 || (idempotent && (code == 502 || code == 504));
        if (resendable && again && attempt < _s.retries) {
          retryAfter = retry.parseRetryAfter(res.header('retry-after'));
          banned = code == 429;
          await res._abandon();
          attempt++;
          continue;
        }
        res._prefetch();
        return await _checked(res, check);
      } on _Failed catch (f) {
        _stopped(method, uri);
        final safe = !f.sent || idempotent;
        if (!resendable || !safe || attempt >= _s.retries || !retry.isRetryable(f.cause)) {
          Error.throwWithStackTrace(_naming(f.cause, method, uri), f.stack);
        }
        attempt++;
      }
    }
  }

  Future<Response> _checked(Response res, bool check) async {
    final path = Uri.tryParse(res.url())?.path ?? '';
    if (_s.login.any(path.startsWith)) {
      await res.close();
      throw SessionException(names.redact(Uri.parse(res.url())));
    }
    return check && _s.check && !res.ok() ? res.check() : res;
  }

  /// One send plus manual redirect following. Network failures arrive as
  /// [_Failed]; a redirect that cannot be followed throws as-is.
  Future<Response> _attempt(String method, Uri first, Body? body, Map<String, String> headers, _Call call) async {
    final client = _conn.retain();
    var delivered = false;
    try {
      var currentMethod = method;
      var uri = first;
      var currentBody = body;
      var currentHeaders = headers;
      for (var hop = 0; ; hop++) {
        final resp = await _single(client, currentMethod, uri, currentBody, currentHeaders, call);
        final setCookie = resp.headers[HttpHeaders.setCookieHeader];
        if (setCookie != null) jar.storeSetCookies(_s.cookies, uri, setCookie);
        final raw = _isRedirect(resp.statusCode) ? resp.headers.value('location') : null;
        final location = raw == null ? null : _utf8Header(raw);
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
        } else if (currentBody != null && !currentBody._resendable) {
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
        if (uri.scheme == 'https' && next.scheme == 'http') {
          stderr.writeln('warning: $currentMethod ${names.redact(uri)} redirected from https to ${names.redact(next)}');
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
    _Call call,
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
    call.requests.add(req);
    _sent++;
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
      if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        req.headers.set('user-agent', jar.agentOf(_s.cookies) ?? _userAgent);
      }
      final cookie = _cookieHeader(uri, headers);
      if (cookie != null) req.headers.set('cookie', cookie);
      final csrf = _s.csrf;
      if (csrf != null && req.headers.value(csrf.header) == null) {
        final token = jar.valueFor(_s.cookies, uri, csrf.cookie);
        if (token != null) req.headers.set(csrf.header, token);
      }
      void streamed() {
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
      }

      Stream<List<int>> upload;
      switch (body) {
        case _StreamBody(:final _reader):
          final o = _reader.origin();
          final path = o.path();
          var size = o.size();
          if (length == null && size == null && path != null) {
            try {
              size = await File(path).length();
            } on FileSystemException {
              // not a file: chunked
            }
          }
          length ??= size?.toString();
          final type = _typeFor(o.name() ?? path?.split(RegExp(r'[\\/]')).last);
          if (type != null && req.headers.value('content-type') == null) req.headers.set('content-type', type);
          streamed();
          upload = _reader.stream();
        case _MultipartBody():
          final boundary = _boundary();
          final pieces = body._pieces(boundary);
          if (req.headers.value('content-type') == null) {
            req.headers.set('content-type', 'multipart/form-data; boundary=$boundary');
          }
          if (pieces.any((p) => p is Reader)) {
            streamed();
            upload = _streamPieces(pieces);
          } else {
            final bytes = [for (final p in pieces) ...p as List<int>];
            req.contentLength = bytes.length;
            upload = _slices(bytes);
          }
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
      call.requests.remove(req);
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

/// The `user-agent` every request sends unless a header or the jar's
/// session file names one: a current desktop Chrome, since many sites refuse
/// or degrade a `Dart/…` client.
const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36';

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
  Client copy({Map<String, String>? headers, Duration? timeout, int? retries, Rate? rate, String? proxy}) {
    if (proxy != null) {
      throw ArgumentError.value(proxy, 'proxy', 'a pool keeps each member\'s proxy: copy the members, then pool them');
    }
    return _Pool([
      for (final m in _members) m.copy(headers: headers, timeout: timeout, retries: retries, rate: rate) as _Client,
    ]);
  }

  @override
  Cookies cookies() => (_last ?? _members.first).cookies();

  @override
  int sent() => _members.fold(0, (n, m) => n + m._sent);

  /// The member with the fewest requests in flight whose [Rate] has a free
  /// slot and which is not benched; ties round-robin.
  _Client _pick(String host) {
    final now = DateTime.now();
    _Client? best;
    var score = 0;
    for (var k = 0; k < _members.length; k++) {
      final m = _members[(_next + k) % _members.length];
      final benched = m._benched != null && m._benched!.isAfter(now);
      final pace = m._s.rate;
      final s = m._inFlight + (benched ? 1 << 20 : 0) + (pace != null && !rate.free(pace, host: host) ? 1 << 10 : 0);
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
    bool check = true,
  }) async {
    final uri = _members.first._resolve(url, query);
    for (var attempt = 0; ; attempt++) {
      final m = _pick(uri.host);
      // Every member benched: wait for the first to come back instead of
      // sending into its ban at once.
      final bench = m._benched?.difference(DateTime.now());
      if (bench != null && bench > Duration.zero) {
        final halt = rate.Halt.under(m._halt);
        try {
          await signals.interruptible(rate.sleep(bench, halt), stop: halt.fire);
        } finally {
          halt.fire();
        }
        if (m._closed) throw m._aborted(method, m._resolve(url, query));
      }
      final res = await m._send(method, url, body: body, query: query, headers: headers, check: false, retry429: false);
      if (res.status() == 429 && attempt < m._s.retries && (body?._resendable ?? true)) {
        final server = retry.parseRetryAfter(res.header('retry-after'));
        final pace = m._s.rate;
        m._benched = DateTime.now().add(
          pace != null ? rate.ban(pace, server, host: uri.host) : server ?? retry.backoff(attempt, null),
        );
        await res._abandon();
        continue;
      }
      return m._checked(res, check);
    }
  }

  @override
  Future<Response> get(String url, {Map<String, Object?>? query, Map<String, String>? headers}) {
    if (!_members.any((m) => m._s.resume)) return _send('GET', url, query: query, headers: headers);
    _members.first._resolve(url, query); // a bad URL throws now, as for any verb
    return _Lazy(
      () => _send('GET', url, query: query, headers: headers),
      (extra) => _send('GET', url, query: query, headers: {...?headers, ...extra}, check: false),
    );
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

  @override
  Future<void> close() async {
    await Future.wait([for (final m in _members) m.close()]);
  }
}

/// [first] then [rest], as one stream.
Stream<List<int>> _concat(Stream<List<int>> first, Stream<List<int>> rest) async* {
  yield* first;
  yield* rest;
}

/// A GET of a `resume: true` client: sent at the end of the current
/// synchronous block, unless a pipeline into a file claims it first
/// (`Reader >` asks before awaiting anything) and delivers it itself.
final class _Lazy implements Future<Response>, Resumable {
  _Lazy(this._send, this._fetch) {
    scheduleMicrotask(() {
      if (!_claimed) _start();
    });
  }

  final Future<Response> Function() _send;

  /// The GET with extra headers (a `Range`), never `check:`ed.
  final Future<Response> Function(Map<String, String> extra) _fetch;
  Future<Response>? _sent;
  var _claimed = false;

  Future<Response> _start() => _sent ??= _send();

  @override
  bool claim() {
    if (_sent != null || _claimed) return false;
    return _claimed = true;
  }

  @override
  Future<void> resume(Writer to, List<Pipe> pipes) => _deliver(_fetch, to, pipes);

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

/// `resume: true` delivery of a GET to [to]'s path, or into a [Folder]
/// under the response's name, through pass-through [pipes]: skip a
/// complete file, resume a `.part`, rename into place.
Future<void> _deliver(Future<Response> Function(Map<String, String> extra) fetch, Writer to, List<Pipe> pipes) async {
  Stream<List<int>> through(Stream<List<int>> input) {
    var out = input;
    for (final p in pipes) {
      out = p.transform(out);
    }
    return out;
  }

  void sized(int bytes) {
    for (final p in pipes) {
      sizers[p]?.call(bytes);
    }
  }

  // Bytes about to come back from disk: rate meters leave them out. Called
  // right before [through] starts the pipes, which read the count then.
  void replayed(int bytes) {
    for (final p in pipes) {
      replays[p]?.call(bytes);
    }
  }

  // Stored bytes go through the pipes, so bars finish and hashes verify.
  Future<void> replay(File f) async {
    final length = await f.length();
    sized(length);
    replayed(length);
    if (pipes.isNotEmpty) await through(f.openRead()).drain<void>();
  }

  // The .part's validator (a strong ETag, else Last-Modified) sits in
  // .part.tag, written before any byte: sent back as If-Range, a file
  // that changed answers 200 and restarts instead of being spliced.
  // A folder learns the file's name from the first answer.
  Response? first;
  final String path;
  if (to is Folder) {
    first = await fetch(const {});
    try {
      path = into(to, first.origin()).origin().path()!;
    } catch (_) {
      await first.close();
      rethrow;
    }
  } else {
    path = to.origin().path()!;
  }
  final file = File(path), part = File('$path.part'), tagFile = File('$path.part.tag');
  Response? res;
  var have = 0;
  if (await file.exists()) {
    first ??= await fetch(const {});
    final size = first.size();
    if (first.ok() && (size == null || size == await file.length())) {
      await first.close();
      return replay(file);
    }
    await first.check(); // an error page throws what check() throws
    if (await part.exists()) await part.delete();
    if (await tagFile.exists()) await tagFile.delete();
    res = first; // the file changed: this full answer is the new one
  } else {
    have = await part.exists() ? await part.length() : 0;
    final kept = have > 0 && await tagFile.exists() ? (await tagFile.readAsString()).trim() : '';
    if (have > 0) await first?.close(); // a .part to resume: ask for the rest instead
    res = have == 0 && first != null
        ? first
        : await fetch(have > 0 ? {'range': 'bytes=$have-', if (kept.isNotEmpty) 'if-range': kept} : const {});
    if (have > 0) {
      final range = (res.header('content-range') ?? '').trim();
      if (res.status() == 416 && _unsatisfied.firstMatch(range)?[1] == '$have') {
        // The .part already holds every byte: finish it, no download.
        await res.close();
        await replay(part);
        await part.rename(path);
        if (await tagFile.exists()) await tagFile.delete();
        return;
      }
      if (res.status() == 200) {
        have = 0; // no range support: a 200 is the whole body, so use it from 0
      } else if (res.status() != 206 || !range.startsWith('bytes $have-')) {
        // Any other answer, or a 206 for some other range, would splice the wrong bytes on.
        await res.close();
        have = 0;
        res = await fetch(const {});
      }
    }
  }
  await res.check();
  if (res.size() case final size?) sized(have + size);
  if (have == 0) {
    final etag = res.header('etag');
    final tag = etag != null && !etag.startsWith('W/') ? etag : res.header('last-modified');
    await tagFile.parent.create(recursive: true);
    if (tag != null) {
      await tagFile.writeAsString(tag);
    } else if (await tagFile.exists()) {
      await tagFile.delete();
    }
  }
  await part.parent.create(recursive: true);
  final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
  try {
    // Replayed bytes are already on disk: the pipes see them, the file
    // does not get them twice (pass-through pipes change nothing).
    var skip = pipes.isEmpty ? 0 : have;
    final body = res.stream();
    final input = skip == 0 ? body : _concat(part.openRead(0, have), body);
    replayed(skip);
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
    if (!transport && await tagFile.exists()) await tagFile.delete();
    rethrow;
  }
  await part.rename(path);
  if (await tagFile.exists()) await tagFile.delete();
}

/// `content-range: bytes */<length>` of a 416.
final _unsatisfied = RegExp(r'^bytes\s+\*/(\d+)$', caseSensitive: false);

/// The query string for [values]: `num`/`bool` as text, a `Map` as JSON,
/// null drops the key, an `Iterable` repeats it.
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
          Map() => jsonEncode(value),
          _ => throw ArgumentError.value(value, key, 'must be a String, num, bool, Map, null or an Iterable of those'),
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
  _StreamBody() || _MultipartBody() => throw StateError('body is not encoded in memory'),
};

/// `scheme://host:port`, the port spelled out.
String _origin(Uri u) => '${u.scheme}://${u.host.toLowerCase()}:${u.port}';

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
  return retry.carry(e, switch (e) {
    SocketException() => SocketException('${e.message}: $what', osError: e.osError, address: e.address, port: e.port),
    HandshakeException() => HandshakeException('${e.message}: $what', e.osError),
    CertificateException() => CertificateException('${e.message}: $what', e.osError),
    TlsException() => TlsException('${e.message}: $what', e.osError),
    TimeoutException() => Timeout('${e.message}: $what', e.duration),
    HttpException() => HttpException('${e.message}: $what', uri: Uri.tryParse(names.redact(e.uri ?? url))),
    _ => e,
  });
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
    'avif' => 'image/avif',
    'bmp' => 'image/bmp',
    'tif' || 'tiff' => 'image/tiff',
    'mp4' => 'video/mp4',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'mkv' => 'video/x-matroska',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'zip' => 'application/zip',
    'gz' || 'tgz' => 'application/gzip',
    'tar' => 'application/x-tar',
    '7z' => 'application/x-7z-compressed',
    _ => null,
  };
}

/// A header value as the server sent it: dart:io reads header bytes as
/// Latin-1, so a raw UTF-8 value (a non-ASCII `location`, a `filename="…"`)
/// is decoded again when its bytes are valid UTF-8.
String _utf8Header(String value) {
  var high = false;
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c > 0xFF) return value;
    if (c >= 0x80) high = true;
  }
  if (!high) return value;
  try {
    return utf8.decode(latin1.encode(value));
  } on FormatException {
    return value;
  }
}
