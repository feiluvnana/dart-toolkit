import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/either.dart';
import '../util/time.dart';
import 'session.dart';

/// Handles one 2xx response: extract with [ScrapeContext.emit], expand with
/// [ScrapeContext.follow], end with [ScrapeContext.stop].
///
/// {@category Crawling}
typedef ScrapeHandler<T> = FutureOr<void> Function(ScrapeContext<T> ctx);

/// Schedules one more request from inside a handler. See [ScrapeContext.follow].
typedef Follow<T> =
    void Function(
      Object target, {
      ScrapeHandler<T>? callback,
      Map<String, Object?>? meta,
      Map<String, String>? headers,
      String method,
      String? body,
      Map<String, String>? fields,
      bool revisit,
      bool offsite,
    });

/// A request the crawl could not turn into a handled response. The [Left] of the scrape stream.
///
/// {@category Crawling}
sealed class ScrapeFailure {
  /// The URL the request was sent to.
  final Uri url;

  /// The request as it was scheduled.
  final http.BaseRequest request;

  /// Hops from a seed; seeds are 0.
  final int depth;

  /// The metadata the request carried.
  final Map<String, Object?> meta;

  const ScrapeFailure({required this.url, required this.request, required this.depth, required this.meta});
}

/// A transport error, TLS failure, timeout, or a body over the 16 MB cap.
///
/// {@category Crawling}
final class RequestFailed extends ScrapeFailure {
  final Object error;

  /// Requests sent before giving up.
  final int attempts;

  const RequestFailed({
    required super.url,
    required super.request,
    required super.depth,
    required super.meta,
    required this.error,
    required this.attempts,
  });

  @override
  String toString() => '${request.method} $url — $error ($attempts ${attempts == 1 ? 'attempt' : 'attempts'})';
}

/// A non-2xx response after retries; the body is still on [response].
///
/// {@category Crawling}
final class BadStatus extends ScrapeFailure {
  final http.Response response;

  const BadStatus({
    required super.url,
    required super.request,
    required super.depth,
    required super.meta,
    required this.response,
  });

  @override
  String toString() {
    final reason = response.reasonPhrase;
    return '${request.method} $url — ${response.statusCode}${reason == null || reason.isEmpty ? '' : ' $reason'}';
  }
}

/// The handler threw. Programmer errors — `follow(42)` — land here too.
///
/// {@category Crawling}
final class HandlerFailed extends ScrapeFailure {
  final Object error;

  const HandlerFailed({
    required super.url,
    required super.request,
    required super.depth,
    required super.meta,
    required this.error,
  });

  @override
  String toString() => '${request.method} $url — handler threw: $error';
}

/// One 2xx response and the controls for the crawl around it.
///
/// {@category Crawling}
class ScrapeContext<T> {
  /// The response; always 2xx.
  final http.Response response;

  /// The request as it was scheduled.
  final http.BaseRequest request;

  /// The URL that answered — after redirects. [resolve] and [follow] resolve against it.
  final Uri url;

  /// Hops from a seed; seeds are 0.
  final int depth;

  /// Responses handled so far in this crawl, this one included.
  final int pages;

  /// Metadata carried from the request that scheduled this one.
  final Map<String, Object?> meta;

  final void Function(T item) _emit;
  final Follow<T> _follow;
  final void Function() _stop;
  bool _isClosed = false;

  ScrapeContext({
    required this.response,
    required this.request,
    required this.url,
    required this.depth,
    required this.pages,
    required this.meta,
    required void Function(T item) emit,
    required Follow<T> follow,
    required void Function() stop,
  }) : _emit = emit,
       _follow = follow,
       _stop = stop;

  /// Resolves [href] — a [Uri] or a [String] — against [url], as [follow] does.
  Uri resolve(Object href) => _resolve(url, href);

  /// Emits [item] on the scrape stream.
  void emit(T item) {
    _checkOpen('emit');
    _emit(item);
  }

  /// Schedules a request for [target], a [Uri] or a [String] href resolved against [url].
  ///
  /// A target off the seeds' hosts, or with a non-http scheme, is dropped unless [offsite] is
  /// set; so is one the crawl already visited unless [revisit] is set. Pass at most one of
  /// [body] and [fields]. [callback] handles the response instead of the crawl's handler.
  void follow(
    Object target, {
    ScrapeHandler<T>? callback,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    String method = 'GET',
    String? body,
    Map<String, String>? fields,
    bool revisit = false,
    bool offsite = false,
  }) {
    _checkOpen('follow');
    if (body != null && fields != null) throw ArgumentError('Pass at most one of "body" and "fields".');
    _follow(
      target,
      callback: callback,
      meta: meta,
      headers: headers,
      method: method,
      body: body,
      fields: fields,
      revisit: revisit,
      offsite: offsite,
    );
  }

  /// Ends the crawl: the frontier is dropped and nothing more is sent. Handlers already running
  /// finish and their emits are delivered; the stream closes when the last one returns.
  void stop() {
    _checkOpen('stop');
    _stop();
  }

  void _checkOpen(String what) {
    if (_isClosed) throw StateError('Cannot $what after the handler has returned.');
  }
}

/// Scrape entry points. All forward to one engine.
///
/// The engine keeps 16 requests in flight, 8 per host; pauses a host that answers 429 or 503
/// for `Retry-After` or a capped backoff; retries a transport error or a 5xx twice, never a
/// TLS failure; times out after 30 s; abandons a body over 16 MB; follows redirects itself.
///
/// {@category Crawling}
extension UriScrapeExtensions on Uri {
  /// Crawls from this URL. Every decision is the handler's, made on its [ScrapeContext].
  ///
  /// ```dart
  /// await for (final item in url.scrape<Item>((ctx) {
  ///   ctx.emit(parse(ctx.response));
  ///   for (final a in ctx.response.html().$('a.next')) ctx.follow(a.attr('href')!);
  /// }).rights) { ... }
  /// ```
  Stream<Either<ScrapeFailure, T>> scrape<T>(ScrapeHandler<T> handler) => _scrape([http.Request('GET', this)], handler);
}

/// {@category Crawling}
extension IterableUriScrapeExtensions on Iterable<Uri> {
  /// Crawls from these URLs; see [UriScrapeExtensions.scrape].
  Stream<Either<ScrapeFailure, T>> scrape<T>(ScrapeHandler<T> handler) =>
      _scrape([for (final url in this) http.Request('GET', url)], handler);
}

/// {@category Crawling}
extension IterableRequestScrapeExtensions on Iterable<http.BaseRequest> {
  /// Crawls from these requests — any method, body or headers; see [UriScrapeExtensions.scrape].
  Stream<Either<ScrapeFailure, T>> scrape<T>(ScrapeHandler<T> handler) => _scrape(this, handler);
}

const _maxInFlight = 16;
const _perHost = 8;
const _retries = 2;
const _maxHops = 5;
const _bodyCap = 16 * 1024 * 1024;
const _userAgent = 'dart-toolkit';
final _timeout = 30.s;

/// Identity of a request for deduplication: the values, not a hash of them.
typedef _RequestKey = (String method, Uri url, String body);

_RequestKey _key(http.BaseRequest req) => (req.method.toUpperCase(), req.url, req is http.Request ? req.body : '');

bool _certain(Object e) =>
    e is HandshakeException || e is CertificateException || e is TlsException || e is _BodyTooLarge;

/// A body over the cap; the same on every attempt, so never retried.
final class _BodyTooLarge extends http.ClientException {
  _BodyTooLarge(Uri url) : super('Response body over $_bodyCap bytes', url);
}

class _Item<T> {
  final http.BaseRequest request;
  final ScrapeHandler<T>? callback;
  final Map<String, Object?> meta;
  final int depth;
  final bool revisit;
  final bool offsite;
  int attempt = 1;
  int hops = 0;

  _Item(
    this.request, {
    this.callback,
    this.meta = const {},
    this.depth = 0,
    this.revisit = false,
    this.offsite = false,
  });
}

class _Host<T> {
  final Queue<_Item<T>> queue = Queue<_Item<T>>();
  int inFlight = 0;
  int consecutiveFailures = 0;
  int backoffs = 0;
  bool paused = false;
  bool ready = false;
  Timer? pauseTimer;
}

Stream<Either<ScrapeFailure, T>> _scrape<T>(Iterable<http.BaseRequest> seeds, ScrapeHandler<T> handler) {
  late final StreamController<Either<ScrapeFailure, T>> controller;
  final lease = clientFor(null);
  final sessionHasUserAgent = lease.headers?.keys.any((k) => k.toLowerCase() == 'user-agent') ?? false;

  final seedHosts = <String>{for (final s in seeds) s.url.host.toLowerCase()};
  final visited = <_RequestKey>{};
  final hosts = <String, _Host<T>>{};
  final ready = Queue<_Host<T>>();
  final timers = <Timer>{};

  var inFlight = 0;
  var queued = 0;
  var waiting = 0;
  var running = 0;
  var pages = 0;
  var stopped = false;
  var closed = false;

  void close() {
    if (closed) return;
    closed = true;
    stopped = true;
    for (final t in timers) {
      t.cancel();
    }
    for (final h in hosts.values) {
      h.pauseTimer?.cancel();
    }
    lease.close();
    if (!controller.isClosed) controller.close();
  }

  void add(Either<ScrapeFailure, T> outcome) {
    if (!controller.isClosed) controller.add(outcome);
  }

  late final void Function() dispatch;

  _Host<T> hostOf(Uri url) => hosts.putIfAbsent(url.host.toLowerCase(), _Host<T>.new);

  void checkReady(_Host<T> host) {
    if (stopped || host.ready || host.paused || host.queue.isEmpty || host.inFlight >= _perHost) return;
    host.ready = true;
    ready.add(host);
  }

  void push(_Host<T> host, _Item<T> item, {bool first = false}) {
    first ? host.queue.addFirst(item) : host.queue.add(item);
    queued++;
    checkReady(host);
  }

  /// Requeues [item] at the front of its host after [delay]; the crawl stays open meanwhile.
  void requeue(_Host<T> host, _Item<T> item, Duration delay) {
    waiting++;
    late final Timer timer;
    timer = Timer(delay, () {
      timers.remove(timer);
      waiting--;
      if (stopped) return;
      push(host, item, first: true);
      dispatch();
    });
    timers.add(timer);
  }

  void pause(_Host<T> host, Duration duration) {
    host.paused = true;
    host.pauseTimer?.cancel();
    host.pauseTimer = Timer(duration, () {
      host.pauseTimer = null;
      host.paused = false;
      checkReady(host);
      dispatch();
    });
  }

  Duration retryAfter(http.Response res, _Host<T> host) {
    final seconds = int.tryParse(res.headers['retry-after']?.trim() ?? '');
    if (seconds != null) return Duration(seconds: seconds);
    final ms = 500 * (1 << host.backoffs.clamp(0, 6));
    host.backoffs++;
    return Duration(milliseconds: ms > 30000 ? 30000 : ms);
  }

  /// Schedules [item] unless it is off-scheme, off-host, or already visited.
  void enqueue(_Item<T> item) {
    if (stopped) return;
    final url = item.request.url;
    if (url.scheme != 'http' && url.scheme != 'https') return;
    if (!item.offsite && !seedHosts.contains(url.host.toLowerCase())) return;
    if (!item.revisit && !visited.add(_key(item.request))) return;
    push(hostOf(url), item);
  }

  void stop() {
    if (stopped) return;
    stopped = true;
    ready.clear();
    for (final h in hosts.values) {
      queued -= h.queue.length;
      h.queue.clear();
    }
    if (running == 0) close();
  }

  void transportFailure(_Host<T> host, _Item<T> item, Object e, StackTrace st) {
    host.consecutiveFailures++;
    if (stopped) return;
    if (!_certain(e) && host.consecutiveFailures < 3 && item.attempt <= _retries) {
      requeue(host, item, (200 * item.attempt++).ms);
      return;
    }
    add(
      Left(
        RequestFailed(
          url: item.request.url,
          request: item.request,
          depth: item.depth,
          meta: item.meta,
          error: e,
          attempts: item.attempt,
        ),
        st,
      ),
    );
  }

  void badStatus(_Item<T> item, http.Response res) => add(
    Left(
      BadStatus(
        url: res.request?.url ?? item.request.url,
        request: item.request,
        depth: item.depth,
        meta: item.meta,
        response: res,
      ),
      StackTrace.current,
    ),
  );

  void redirect(_Host<T> host, _Item<T> item, http.BaseRequest sent, http.Response res) {
    final location = res.headers['location']?.trim();
    if (location == null || location.isEmpty) return badStatus(item, res);
    if (item.hops >= _maxHops) {
      return add(
        Left(
          RequestFailed(
            url: sent.url,
            request: item.request,
            depth: item.depth,
            meta: item.meta,
            error: http.ClientException('Too many redirects', sent.url),
            attempts: item.attempt,
          ),
          StackTrace.current,
        ),
      );
    }
    final target = sent.url.resolve(location);
    if (target.scheme != 'http' && target.scheme != 'https') return badStatus(item, res);
    // A seed that redirects — apex to www — moves the crawl's home with it.
    if (item.depth == 0) {
      seedHosts.add(target.host.toLowerCase());
    } else if (!item.offsite && !seedHosts.contains(target.host.toLowerCase())) {
      return badStatus(item, res);
    }

    final status = res.statusCode;
    final downgrade =
        status == 303 || ((status == 301 || status == 302) && sent.method != 'GET' && sent.method != 'HEAD');
    final next = http.Request(downgrade ? 'GET' : sent.method, target);
    for (final MapEntry(:key, :value) in sent.headers.entries) {
      if (downgrade && (key.toLowerCase() == 'content-type' || key.toLowerCase() == 'content-length')) continue;
      next.headers[key] = value;
    }
    if (!downgrade && sent is http.Request) next.bodyBytes = sent.bodyBytes;
    if (!item.revisit && !visited.add(_key(next))) return;

    final hop = _Item<T>(
      next,
      callback: item.callback,
      meta: item.meta,
      depth: item.depth,
      revisit: item.revisit,
      offsite: item.offsite,
    )..hops = item.hops + 1;
    push(hostOf(target), hop, first: true);
  }

  Future<void> handle(_Item<T> item, http.BaseRequest sent, http.Response res) async {
    pages++;
    running++;
    final ctx = ScrapeContext<T>(
      response: res,
      request: item.request,
      url: sent.url,
      depth: item.depth,
      pages: pages,
      meta: item.meta,
      emit: (value) => add(Right(value)),
      follow: (target, {callback, meta, headers, method = 'GET', body, fields, revisit = false, offsite = false}) {
        final next = http.Request(method, _resolve(sent.url, target));
        if (body != null) next.body = body;
        if (fields != null) next.bodyFields = fields;
        if (headers != null) next.headers.addAll(headers);
        enqueue(
          _Item<T>(
            next,
            callback: callback,
            meta: {...item.meta, ...?meta},
            depth: item.depth + 1,
            revisit: revisit,
            offsite: offsite,
          ),
        );
        dispatch();
      },
      stop: stop,
    );
    try {
      await (item.callback ?? handler)(ctx);
    } catch (e, st) {
      add(Left(HandlerFailed(url: sent.url, request: item.request, depth: item.depth, meta: item.meta, error: e), st));
    } finally {
      ctx._isClosed = true;
      running--;
      if (stopped && running == 0) close();
    }
  }

  Future<void> execute(_Host<T> host, _Item<T> item) async {
    final sent = _clone(item.request);
    if (!sessionHasUserAgent) sent.headers.putIfAbsent('user-agent', () => _userAgent);

    final http.StreamedResponse streamed;
    try {
      streamed = await lease.client.send(sent).timeout(_timeout);
    } catch (e, st) {
      return transportFailure(host, item, e, st);
    }

    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in streamed.stream.timeout(_timeout)) {
        if (builder.length + chunk.length > _bodyCap) {
          throw _BodyTooLarge(sent.url);
        }
        builder.add(chunk);
      }
    } catch (e, st) {
      return transportFailure(host, item, e, st);
    }
    if (stopped) return;
    host.consecutiveFailures = 0;

    final res = http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      request: sent,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
    final status = res.statusCode;

    if (status >= 300 && status < 400) return redirect(host, item, sent, res);
    if (status == 429 || status == 503) {
      pause(host, retryAfter(res, host));
      if (item.attempt <= _retries) {
        item.attempt++;
        return push(host, item, first: true);
      }
      return badStatus(item, res);
    }
    if (status >= 500) {
      if (item.attempt <= _retries) return requeue(host, item, (200 * item.attempt++).ms);
      return badStatus(item, res);
    }
    if (status < 200 || status >= 300) return badStatus(item, res);

    host.backoffs = 0;
    await handle(item, sent, res);
  }

  dispatch = () {
    if (closed || stopped || controller.isPaused) return;
    while (inFlight < _maxInFlight && ready.isNotEmpty) {
      final host = ready.removeFirst();
      host.ready = false;
      if (host.paused || host.queue.isEmpty || host.inFlight >= _perHost) continue;
      final item = host.queue.removeFirst();
      queued--;
      host.inFlight++;
      inFlight++;
      checkReady(host);
      Future<void>(() => execute(host, item))
          .onError(
            (Object e, st) => add(
              Left(
                RequestFailed(
                  url: item.request.url,
                  request: item.request,
                  depth: item.depth,
                  meta: item.meta,
                  error: e,
                  attempts: item.attempt,
                ),
                st,
              ),
            ),
          )
          .whenComplete(() {
            host.inFlight--;
            inFlight--;
            checkReady(host);
            dispatch();
          });
    }
    if (inFlight == 0 && queued == 0 && waiting == 0) close();
  };

  for (final seed in seeds) {
    enqueue(_Item<T>(seed));
  }

  controller = StreamController<Either<ScrapeFailure, T>>(onListen: dispatch, onResume: dispatch, onCancel: close);
  return controller.stream;
}

Uri _resolve(Uri base, Object target) => switch (target) {
  Uri() => base.resolveUri(target),
  String() => base.resolve(target),
  _ => throw ArgumentError.value(target, 'target', 'Must be a Uri or a String href'),
};

/// A fresh, unfinalized copy the engine can send once per attempt, with redirects left to it.
/// A request that cannot be copied is sent as is; a retry of it fails as a [RequestFailed].
http.BaseRequest _clone(http.BaseRequest req) {
  if (req is! http.Request) return req..followRedirects = false;
  return http.Request(req.method, req.url)
    ..followRedirects = false
    ..persistentConnection = req.persistentConnection
    ..bodyBytes = req.bodyBytes
    ..headers.addAll(req.headers);
}
