import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/either.dart';
import '../util/time.dart';
import 'session.dart';

/// Runs once, on listen, before anything is sent; see [InitContext].
typedef InitHook<T> = FutureOr<void> Function(InitContext<T> ctx);

/// Runs before a request is sent; see [RequestContext].
typedef RequestHook = FutureOr<void> Function(RequestContext ctx);

/// Runs on every 2xx; see [ResponseContext].
typedef ResponseHook<T> = FutureOr<void> Function(ResponseContext<T> ctx);

/// Runs when the engine has given up on a request; see [ErrorContext].
typedef ErrorHook<T> = FutureOr<void> Function(ErrorContext<T> ctx);

/// Runs once, after the last item; see [ScrapeSummary].
typedef FinishHook = FutureOr<void> Function(ScrapeSummary summary);

/// Schedules one more request from inside a hook. See [ResponseContext.follow].
typedef Follow<T> =
    bool Function(
      Object target, {
      ResponseHook<T>? onResponse,
      ErrorHook<T>? onError,
      Map<String, Object?>? meta,
      Map<String, String>? headers,
      String method,
      String? body,
      Map<String, String>? fields,
      bool revisit,
      bool offsite,
    });

// ---------------------------------------------------------------------------------------------
// Failures
// ---------------------------------------------------------------------------------------------

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

/// A transport error, TLS failure, timeout, or a body over the cap.
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
final class StatusFailed extends ScrapeFailure {
  final http.Response response;

  const StatusFailed({
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

/// A hook threw. Programmer errors — `follow(42)` — land here too.
///
/// {@category Crawling}
final class HookFailed extends ScrapeFailure {
  final Object error;

  const HookFailed({
    required super.url,
    required super.request,
    required super.depth,
    required super.meta,
    required this.error,
  });

  @override
  String toString() => '${request.method} $url — hook threw: $error';
}

// ---------------------------------------------------------------------------------------------
// Contexts
// ---------------------------------------------------------------------------------------------

/// The crawl's settings, all of them, set once in [Scrape.onInit].
///
/// Defaults: 16 requests in flight, 8 per host, no delay, 30 s timeout, 2 retries, 5 redirect
/// hops, a 16 MB body cap, no page or depth limit, and a scope of the seeds' hosts with or
/// without `www.`. Changes after the hook returns have no effect. Anything per request — a
/// header, the `user-agent` — is [Scrape.onRequest]'s.
///
/// {@category Crawling}
final class InitContext<T> {
  /// Requests in flight overall.
  int concurrency = 16;

  /// Requests in flight to one host.
  int perHost = 8;

  /// Minimum gap between two requests to the same host.
  Duration delay = Duration.zero;

  /// Wait for headers and for each body chunk.
  Duration timeout = 30.s;

  /// Re-sends after a transport error or a 5xx; never after a TLS failure.
  int retries = 2;

  /// Redirect hops followed before a request fails.
  int redirects = 5;

  /// Bytes of body read before a response is abandoned.
  int bodyLimit = 16 * 1024 * 1024;

  /// Stops the crawl after this many 2xx responses.
  int? pages;

  /// Drops requests deeper than this many hops from a seed.
  int? depth;

  /// Which URLs [ResponseContext.follow] may go to. Default: the seeds' hosts, `www.` or not.
  bool Function(Uri url)? scope;

  final List<http.BaseRequest> _seeds;
  final Map<Uri, Map<String, Object?>> _seedMeta = {};

  InitContext._(this._seeds);

  /// The starting points so far.
  List<Uri> get seeds => [for (final s in _seeds) s.url];

  /// Adds a starting point.
  void seed(Uri url, {Map<String, Object?>? meta}) {
    url = url.removeFragment();
    _seeds.add(http.Request('GET', url));
    if (meta != null) _seedMeta[url] = meta;
  }
}

/// A request about to be sent. Edit [request] — a header, the `user-agent`, a signature — or
/// [skip] it.
///
/// {@category Crawling}
final class RequestContext {
  /// The request as it will be sent; its `headers` are yours to edit.
  final http.Request request;

  /// Hops from a seed; seeds are 0.
  final int depth;

  /// 1 for the first send, more on a retry.
  final int attempt;

  /// Metadata carried from the request that scheduled this one.
  final Map<String, Object?> meta;

  bool _skipped = false;

  RequestContext._(this.request, this.depth, this.attempt, this.meta);

  /// Where the request is going.
  Uri get url => request.url;

  /// Drops the request. Nothing is sent and nothing is reported.
  void skip() => _skipped = true;
}

/// What a hook holding a page or a failure can do: [emit], [follow], [stop].
///
/// {@category Crawling}
sealed class HookContext<T> {
  final void Function(T item) _emit;
  final Follow<T> _follow;
  final void Function() _stop;
  bool _closed = false;

  HookContext._(this._emit, this._follow, this._stop);

  /// The URL this hook is about; [resolve] and [follow] resolve against it.
  Uri get url;

  /// The request as it was scheduled.
  http.BaseRequest get request;

  /// Hops from a seed; seeds are 0.
  int get depth;

  /// Metadata carried from the request that scheduled this one.
  Map<String, Object?> get meta;

  /// Resolves [href] — a [Uri] or a [String] — against [url], as [follow] does.
  Uri resolve(Object href) => _resolve(url, href);

  /// Emits [item] on the scrape stream.
  void emit(T item) {
    _open('emit');
    _acted();
    _emit(item);
  }

  /// Schedules a request for [target], a [Uri] or a [String] href resolved against [url].
  ///
  /// Returns whether it was scheduled. A target outside the crawl's scope, or with a non-http
  /// scheme, is dropped unless [offsite] is set; so is one already visited unless [revisit] is
  /// set. Pass at most one of [body] and [fields]. [onResponse] and [onError] override the
  /// crawl's hooks for this request.
  bool follow(
    Object target, {
    ResponseHook<T>? onResponse,
    ErrorHook<T>? onError,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    String method = 'GET',
    String? body,
    Map<String, String>? fields,
    bool revisit = false,
    bool offsite = false,
  }) {
    _open('follow');
    if (body != null && fields != null) throw ArgumentError('Pass at most one of "body" and "fields".');
    final scheduled = _follow(
      target,
      onResponse: onResponse,
      onError: onError,
      meta: meta,
      headers: headers,
      method: method,
      body: body,
      fields: fields,
      revisit: revisit,
      offsite: offsite,
    );
    if (scheduled) _acted();
    return scheduled;
  }

  /// Ends the crawl: the frontier is dropped and nothing more is sent. Hooks already running
  /// finish and their emits are delivered; the stream closes when the last one returns.
  void stop() {
    _open('stop');
    _stop();
  }

  void _acted() {}

  void _open(String what) {
    if (_closed) throw StateError('Cannot $what after the hook has returned.');
  }
}

/// One 2xx response and the controls for the crawl around it.
///
/// {@category Crawling}
final class ResponseContext<T> extends HookContext<T> {
  /// The response; always 2xx.
  final http.Response response;

  @override
  final http.BaseRequest request;

  /// The URL that answered — after redirects.
  @override
  final Uri url;

  @override
  final int depth;

  /// Responses handled so far in this crawl, this one included.
  final int pages;

  @override
  final Map<String, Object?> meta;

  ResponseContext._({
    required this.response,
    required this.request,
    required this.url,
    required this.depth,
    required this.pages,
    required this.meta,
    required void Function(T item) emit,
    required Follow<T> follow,
    required void Function() stop,
  }) : super._(emit, follow, stop);
}

/// A request the engine has given up on. Unless the hook acts — [retry], [ignore], [emit] or
/// a [follow] that was scheduled — [failure] goes to the stream as a [Left].
///
/// {@category Crawling}
final class ErrorContext<T> extends HookContext<T> {
  /// What went wrong: `switch` on it.
  final ScrapeFailure failure;

  /// Requests sent so far for this URL.
  final int attempt;

  final void Function(Duration after) _retry;
  bool _handled = false;

  ErrorContext._(this.failure, this.attempt, super.emit, super.follow, this._retry, super.stop) : super._();

  @override
  Uri get url => failure.url;
  @override
  http.BaseRequest get request => failure.request;
  @override
  int get depth => failure.depth;
  @override
  Map<String, Object?> get meta => failure.meta;

  /// Sends the request again [after] a wait, past the engine's own retry budget.
  void retry({Duration after = Duration.zero}) {
    _open('retry');
    _handled = true;
    _retry(after);
  }

  /// Swallows the failure: nothing goes to the stream.
  void ignore() {
    _open('ignore');
    _handled = true;
  }

  @override
  void _acted() => _handled = true;
}

/// What a crawl did, handed to [Scrape.onFinish].
///
/// {@category Crawling}
final class ScrapeSummary {
  /// 2xx responses handled.
  final int pages;

  /// Failures that reached the stream.
  final int failures;

  /// Requests sent, retries and redirect hops included.
  final int requests;

  /// Re-sends, by the engine or by [ErrorContext.retry].
  final int retries;

  /// Follows not sent: already visited, out of scope, too deep, or not http(s).
  final int dropped;

  /// Body bytes received.
  final int bytes;

  final Duration elapsed;

  const ScrapeSummary({
    required this.pages,
    required this.failures,
    required this.requests,
    required this.retries,
    required this.dropped,
    required this.bytes,
    required this.elapsed,
  });

  @override
  String toString() =>
      '$pages pages, $failures failures, $requests requests, $dropped dropped in ${elapsed.inMilliseconds} ms';
}

// ---------------------------------------------------------------------------------------------
// The chain
// ---------------------------------------------------------------------------------------------

/// A crawl: five hooks on a chain, consumed as a stream.
///
/// It is a `Stream<Either<ScrapeFailure, T>>`, so `.rights`, `.lefts`, `.unwrap()`, `.take`
/// and `.cancelWith` apply. Nothing is sent until it is listened to.
///
/// ```dart
/// final items = url.scrape<Item>()
///     .onInit((ctx) => ctx..concurrency = 8..pages = 50)
///     .onResponse((ctx) {
///       ctx.emit(parse(ctx.response));
///       for (final a in ctx.response.html().$('a.next')) ctx.follow(a.attr('href')!);
///     })
///     .onError((ctx) => log('${ctx.failure}'))
///     .onFinish((s) => log('$s'));
///
/// await for (final item in items.rights) { ... }
/// ```
///
/// {@category Crawling}
final class Scrape<T> extends StreamView<Either<ScrapeFailure, T>> {
  final _Hooks<T> _hooks;

  Scrape._(this._hooks, StreamController<Either<ScrapeFailure, T>> controller) : super(controller.stream);

  factory Scrape._of(Iterable<http.BaseRequest> seeds) {
    final hooks = _Hooks<T>(seeds.toList());
    late final StreamController<Either<ScrapeFailure, T>> controller;
    controller = StreamController(onListen: () => _run(hooks, controller));
    return Scrape._(hooks, controller);
  }

  /// Once, on listen, with every setting on an [InitContext]. May be async.
  Scrape<T> onInit(InitHook<T> hook) {
    _hooks.onInit = hook;
    return this;
  }

  /// Before every send, retries included.
  Scrape<T> onRequest(RequestHook hook) {
    _hooks.onRequest = hook;
    return this;
  }

  /// On every 2xx.
  Scrape<T> onResponse(ResponseHook<T> hook) {
    _hooks.onResponse = hook;
    return this;
  }

  /// When the engine has given up on a request; the failure is a [Left] unless the hook acts.
  Scrape<T> onError(ErrorHook<T> hook) {
    _hooks.onError = hook;
    return this;
  }

  /// Once, after the last item. If it throws, the error is the stream's last event.
  Scrape<T> onFinish(FinishHook hook) {
    _hooks.onFinish = hook;
    return this;
  }
}

/// Scrape entry points; see [Scrape].
///
/// {@category Crawling}
extension UriScrapeExtensions on Uri {
  /// A crawl seeded here.
  Scrape<T> scrape<T>() => Scrape<T>._of([http.Request('GET', removeFragment())]);
}

/// {@category Crawling}
extension IterableUriScrapeExtensions on Iterable<Uri> {
  /// A crawl seeded here.
  Scrape<T> scrape<T>() => Scrape<T>._of([for (final url in this) http.Request('GET', url.removeFragment())]);
}

/// {@category Crawling}
extension IterableRequestScrapeExtensions on Iterable<http.BaseRequest> {
  /// A crawl seeded with these requests — any method, body or headers.
  Scrape<T> scrape<T>() => Scrape<T>._of(this);
}

// ---------------------------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------------------------

final class _Hooks<T> {
  final List<http.BaseRequest> seeds;
  InitHook<T>? onInit;
  RequestHook? onRequest;
  ResponseHook<T>? onResponse;
  ErrorHook<T>? onError;
  FinishHook? onFinish;

  _Hooks(this.seeds);
}

/// Sent unless the request, [Scrape.onRequest] or the session names one.
const _userAgent = 'dart-toolkit';

/// Identity of a request for deduplication: the values, not a hash of them.
typedef _RequestKey = (String method, Uri url, String body);

_RequestKey _key(http.BaseRequest req) => (req.method.toUpperCase(), req.url, req is http.Request ? req.body : '');

/// Headers that stay behind when a redirect leaves the host.
const _credential = {'authorization', 'cookie', 'proxy-authorization'};

/// `www.example.com` and `example.com` are one site.
String _site(String host) => host.startsWith('www.') ? host.substring(4) : host;

/// Failures that will not change on a second attempt.
bool _certain(Object e) =>
    e is HandshakeException || e is CertificateException || e is TlsException || e is _BodyTooLarge;

/// A body over the cap; the same on every attempt, so never retried.
final class _BodyTooLarge extends http.ClientException {
  _BodyTooLarge(int cap, Uri url) : super('Response body over $cap bytes', url);
}

class _Item<T> {
  final http.BaseRequest request;
  final ResponseHook<T>? onResponse;
  final ErrorHook<T>? onError;
  final Map<String, Object?> meta;
  final int depth;
  final bool revisit;
  final bool offsite;
  int attempt = 1;
  int hops = 0;

  _Item(
    this.request, {
    this.onResponse,
    this.onError,
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
  DateTime nextSend = DateTime.fromMillisecondsSinceEpoch(0);
  bool paused = false;
  DateTime pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool ready = false;
  Timer? pauseTimer;
}

Future<void> _run<T>(_Hooks<T> hooks, StreamController<Either<ScrapeFailure, T>> controller) async {
  final cfg = InitContext<T>._(hooks.seeds);
  if (hooks.onInit case final init?) {
    try {
      await init(cfg);
    } catch (e, st) {
      controller.addError(e, st);
      return controller.close();
    }
  }
  if (cfg.concurrency < 1) cfg.concurrency = 1;
  if (cfg.perHost < 1) cfg.perHost = 1;
  if (cfg.retries < 0) cfg.retries = 0;
  if (cfg.redirects < 0) cfg.redirects = 0;
  final started = DateTime.now();
  final lease = clientFor(null);
  final sessionHasUserAgent = lease.headers?.keys.any((k) => k.toLowerCase() == 'user-agent') ?? false;

  final seedHosts = <String>{for (final s in cfg._seeds) _site(s.url.host)};
  final inScope = cfg.scope ?? (Uri url) => seedHosts.contains(_site(url.host));
  final visited = <_RequestKey>{};
  final hosts = <String, _Host<T>>{};
  final ready = Queue<_Host<T>>();
  final timers = <Timer>{};

  var inFlight = 0;
  var queued = 0;
  var waiting = 0;
  var running = 0;
  var pages = 0;
  var failures = 0;
  var requests = 0;
  var retries = 0;
  var dropped = 0;
  var bytes = 0;
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
    if (controller.isClosed) return;
    final finish = hooks.onFinish;
    if (finish == null) return unawaited(controller.close());
    final summary = ScrapeSummary(
      pages: pages,
      failures: failures,
      requests: requests,
      retries: retries,
      dropped: dropped,
      bytes: bytes,
      elapsed: DateTime.now().difference(started),
    );
    Future.sync(() => finish(summary))
        .then<void>((_) {}, onError: (Object e, StackTrace st) => controller.addError(e, st))
        .whenComplete(controller.close);
  }

  void add(Either<ScrapeFailure, T> outcome) {
    if (controller.isClosed) return;
    if (outcome.isLeft) failures++;
    controller.add(outcome);
  }

  late final void Function() dispatch;

  _Host<T> hostOf(Uri url) => hosts.putIfAbsent(url.host, _Host<T>.new);

  void checkReady(_Host<T> host) {
    if (stopped || host.ready || host.paused || host.queue.isEmpty || host.inFlight >= cfg.perHost) return;
    host.ready = true;
    ready.add(host);
  }

  void push(_Host<T> host, _Item<T> item, {bool first = false}) {
    first ? host.queue.addFirst(item) : host.queue.add(item);
    queued++;
    checkReady(host);
  }

  /// Requeues [item] at the front of its host after [after]; the crawl stays open meanwhile.
  void requeue(_Host<T> host, _Item<T> item, Duration after) {
    retries++;
    item.attempt++;
    waiting++;
    late final Timer timer;
    timer = Timer(after, () {
      timers.remove(timer);
      waiting--;
      if (stopped) return;
      push(host, item, first: true);
      dispatch();
    });
    timers.add(timer);
  }

  /// Holds [host] for [duration], or for the rest of a longer hold already in place.
  void pause(_Host<T> host, Duration duration) {
    final until = DateTime.now().add(duration);
    if (host.paused && host.pausedUntil.isAfter(until)) return;
    host.paused = true;
    host.pausedUntil = until;
    host.pauseTimer?.cancel();
    host.pauseTimer = Timer(duration, () {
      host.pauseTimer = null;
      host.paused = false;
      checkReady(host);
      dispatch();
    });
  }

  Duration retryAfter(http.Response res, _Host<T> host) {
    final header = res.headers['retry-after']?.trim() ?? '';
    if (int.tryParse(header) case final seconds?) return Duration(seconds: seconds);
    if (header.isNotEmpty) {
      try {
        final wait = HttpDate.parse(header).difference(DateTime.now());
        return wait.isNegative ? Duration.zero : wait;
      } on FormatException {
        // Not a date either; fall through to the backoff.
      }
    }
    final ms = 500 * (1 << host.backoffs.clamp(0, 6));
    host.backoffs++;
    return Duration(milliseconds: ms > 30000 ? 30000 : ms);
  }

  /// Schedules [item] unless it is too deep, off-scheme, out of scope, or already visited.
  bool enqueue(_Item<T> item) {
    if (stopped) return false;
    bool drop() {
      dropped++;
      return false;
    }

    if (cfg.depth case final max? when item.depth > max) return drop();
    final url = item.request.url;
    if (url.scheme != 'http' && url.scheme != 'https') return drop();
    if (!item.offsite && !inScope(url)) return drop();
    if (!item.revisit && !visited.add(_key(item.request))) return drop();
    push(hostOf(url), item);
    return true;
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

  Follow<T> followFrom(_Item<T> item, Uri base) =>
      (target, {onResponse, onError, meta, headers, method = 'GET', body, fields, revisit = false, offsite = false}) {
        final next = http.Request(method, _resolve(base, target));
        if (body != null) next.body = body;
        if (fields != null) next.bodyFields = fields;
        if (headers != null) next.headers.addAll(headers);
        final scheduled = enqueue(
          _Item<T>(
            next,
            onResponse: onResponse,
            onError: onError,
            meta: {...item.meta, ...?meta},
            depth: item.depth + 1,
            revisit: revisit,
            offsite: offsite,
          ),
        );
        dispatch();
        return scheduled;
      };

  /// The engine has given up on [item]: the error hook decides, else the failure is a [Left].
  Future<void> fail(_Host<T> host, _Item<T> item, ScrapeFailure failure, StackTrace st) async {
    if (stopped) {
      // The crawl is over; a request that failed in flight is not news, a hook that threw is.
      if (failure is HookFailed) add(Left(failure, st));
      if (running == 0) close();
      return;
    }
    final hook = item.onError ?? hooks.onError;
    if (hook == null) return add(Left(failure, st));

    running++;
    final ctx = ErrorContext<T>._(
      failure,
      item.attempt,
      (value) => add(Right(value)),
      followFrom(item, failure.url),
      (after) => requeue(host, item, after),
      stop,
    );
    try {
      await hook(ctx);
      if (!ctx._handled) add(Left(failure, st));
    } catch (e, hookSt) {
      add(
        Left(HookFailed(url: failure.url, request: item.request, depth: item.depth, meta: item.meta, error: e), hookSt),
      );
    } finally {
      ctx._closed = true;
      running--;
      if (stopped && running == 0) close();
    }
  }

  RequestFailed requestFailed(_Item<T> item, Uri url, Object e) => RequestFailed(
    url: url,
    request: item.request,
    depth: item.depth,
    meta: item.meta,
    error: e,
    attempts: item.attempt,
  );

  StatusFailed statusFailed(_Item<T> item, http.Response res) => StatusFailed(
    url: res.request?.url ?? item.request.url,
    request: item.request,
    depth: item.depth,
    meta: item.meta,
    response: res,
  );

  Future<void> transportFailure(_Host<T> host, _Item<T> item, Uri url, Object e, StackTrace st) {
    host.consecutiveFailures++;
    if (stopped) return Future.value();
    if (!_certain(e) && host.consecutiveFailures < 3 && item.attempt <= cfg.retries) {
      requeue(host, item, (200 * item.attempt).ms);
      return Future.value();
    }
    return fail(host, item, requestFailed(item, url, e), st);
  }

  Future<void> redirect(_Host<T> host, _Item<T> item, http.BaseRequest sent, http.Response res) {
    final location = res.headers['location']?.trim();
    if (location == null || location.isEmpty) return fail(host, item, statusFailed(item, res), StackTrace.current);
    if (item.hops >= cfg.redirects) {
      final e = http.ClientException('Too many redirects', sent.url);
      return fail(host, item, requestFailed(item, sent.url, e), StackTrace.current);
    }
    final target = sent.url.resolve(location);
    if (target.scheme != 'http' && target.scheme != 'https') {
      return fail(host, item, statusFailed(item, res), StackTrace.current);
    }
    // A seed that redirects — apex to www — moves the crawl's home with it.
    if (item.depth == 0) {
      seedHosts.add(_site(target.host));
    } else if (!item.offsite && !inScope(target)) {
      return fail(host, item, statusFailed(item, res), StackTrace.current);
    }

    final status = res.statusCode;
    final downgrade =
        status == 303 || ((status == 301 || status == 302) && sent.method != 'GET' && sent.method != 'HEAD');
    final next = http.Request(downgrade ? 'GET' : sent.method, target);
    final crossHost = target.host != sent.url.host;
    for (final MapEntry(:key, :value) in sent.headers.entries) {
      final k = key.toLowerCase();
      if (downgrade && (k == 'content-type' || k == 'content-length')) continue;
      // Credentials do not follow a redirect to another host, as a browser's would not.
      if (crossHost && _credential.contains(k)) continue;
      next.headers[key] = value;
    }
    if (!downgrade && sent is http.Request) next.bodyBytes = sent.bodyBytes;
    if (!item.revisit && !visited.add(_key(next))) return Future.value();

    final hop = _Item<T>(
      next,
      onResponse: item.onResponse,
      onError: item.onError,
      meta: item.meta,
      depth: item.depth,
      revisit: item.revisit,
      offsite: item.offsite,
    )..hops = item.hops + 1;
    push(hostOf(target), hop, first: true);
    return Future.value();
  }

  Future<void> handle(_Host<T> host, _Item<T> item, http.BaseRequest sent, http.Response res) async {
    pages++;
    final hook = item.onResponse ?? hooks.onResponse;
    if (hook == null) return;
    running++;
    final ctx = ResponseContext<T>._(
      response: res,
      request: item.request,
      url: sent.url,
      depth: item.depth,
      pages: pages,
      meta: item.meta,
      emit: (value) => add(Right(value)),
      follow: followFrom(item, sent.url),
      stop: stop,
    );
    try {
      await hook(ctx);
    } catch (e, st) {
      ctx._closed = true;
      running--;
      await fail(
        host,
        item,
        HookFailed(url: sent.url, request: item.request, depth: item.depth, meta: item.meta, error: e),
        st,
      );
      return;
    }
    ctx._closed = true;
    running--;
    if (stopped && running == 0) close();
  }

  Future<void> execute(_Host<T> host, _Item<T> item) async {
    final sent = _clone(item.request);
    if (!sessionHasUserAgent) sent.headers.putIfAbsent('user-agent', () => _userAgent);

    if (hooks.onRequest case final hook? when sent is http.Request) {
      final ctx = RequestContext._(sent, item.depth, item.attempt, item.meta);
      try {
        await hook(ctx);
      } catch (e, st) {
        return fail(
          host,
          item,
          HookFailed(url: sent.url, request: item.request, depth: item.depth, meta: item.meta, error: e),
          st,
        );
      }
      if (ctx._skipped) return;
    }

    requests++;
    final http.StreamedResponse streamed;
    try {
      streamed = await lease.client.send(sent).timeout(cfg.timeout);
    } catch (e, st) {
      return transportFailure(host, item, sent.url, e, st);
    }

    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in streamed.stream.timeout(cfg.timeout)) {
        if (builder.length + chunk.length > cfg.bodyLimit) throw _BodyTooLarge(cfg.bodyLimit, sent.url);
        builder.add(chunk);
      }
    } catch (e, st) {
      return transportFailure(host, item, sent.url, e, st);
    }
    if (stopped) return;
    host.consecutiveFailures = 0;
    bytes += builder.length;

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
      if (item.attempt <= cfg.retries) {
        retries++;
        item.attempt++;
        return push(host, item, first: true);
      }
      return fail(host, item, statusFailed(item, res), StackTrace.current);
    }
    if (status >= 500) {
      if (item.attempt <= cfg.retries) return requeue(host, item, (200 * item.attempt).ms);
      return fail(host, item, statusFailed(item, res), StackTrace.current);
    }
    if (status < 200 || status >= 300) return fail(host, item, statusFailed(item, res), StackTrace.current);

    host.backoffs = 0;
    await handle(host, item, sent, res);
    if (cfg.pages case final max? when pages >= max) stop();
  }

  dispatch = () {
    if (closed || stopped || controller.isPaused) return;
    final now = DateTime.now();
    while (inFlight < cfg.concurrency && ready.isNotEmpty) {
      if (cfg.pages case final max? when pages + inFlight >= max) break;
      final host = ready.removeFirst();
      host.ready = false;
      if (host.paused || host.queue.isEmpty || host.inFlight >= cfg.perHost) continue;
      if (cfg.delay > Duration.zero) {
        final wait = host.nextSend.difference(now);
        if (wait > Duration.zero) {
          pause(host, wait);
          continue;
        }
        host.nextSend = now.add(cfg.delay);
      }
      final item = host.queue.removeFirst();
      queued--;
      host.inFlight++;
      inFlight++;
      checkReady(host);
      Future<void>(
        () => execute(host, item),
      ).onError((Object e, st) => add(Left(requestFailed(item, item.request.url, e), st))).whenComplete(() {
        host.inFlight--;
        inFlight--;
        checkReady(host);
        dispatch();
      });
    }
    if (inFlight == 0 && queued == 0 && waiting == 0 && running == 0) close();
  };

  for (final seed in cfg._seeds) {
    enqueue(_Item<T>(seed, meta: cfg._seedMeta[seed.url] ?? const {}));
  }

  controller
    ..onResume = dispatch
    ..onCancel = close;
  dispatch();
}

/// [target] against [base], without its fragment: `/p#a` and `/p#b` are one page.
Uri _resolve(Uri base, Object target) => switch (target) {
  Uri() => base.resolveUri(target).removeFragment(),
  String() => base.resolve(target).removeFragment(),
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
