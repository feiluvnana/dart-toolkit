part of '../../http.dart';

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
/// What [HookContext.follow] was asked for, on its way to the engine. The named arguments
/// are spelled once, here, rather than once per hop between the hook and the frontier.
final class _Plan<T> {
  final ResponseHook<T>? onResponse;
  final ErrorHook<T>? onError;
  final Map<String, Object?>? meta;
  final Map<String, String>? headers;
  final String method;
  final String? text;
  final List<int>? bytes;
  final Map<String, String>? form;
  final Object? json;
  final bool revisit;
  final bool offsite;

  const _Plan({
    this.onResponse,
    this.onError,
    this.meta,
    this.headers,
    this.method = 'GET',
    this.text,
    this.bytes,
    this.form,
    this.json,
    this.revisit = false,
    this.offsite = false,
  });
}

typedef _Follow<T> = bool Function(Object target, _Plan<T> plan);

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
  final Request request;

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
  final Response response;

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
/// hops, a 16 MB body cap, a 30 s cap on `Retry-After`, no page or depth limit, and a scope of
/// the seeds' hosts with or without `www.`. The context is not reachable once the hook
/// returns. Anything per request — a header, the `user-agent` — is [Scrape.onRequest]'s.
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

  /// The longest a server's `Retry-After` may hold a host. A request asking for longer
  /// fails instead of waiting, so one header cannot park the crawl for hours.
  Duration maxRetryAfter = const Duration(seconds: 30);

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

  /// Whether each host's `/robots.txt` is fetched once and obeyed.
  ///
  /// A path it forbids for this crawl's `user-agent` is dropped and counted in
  /// [ScrapeSummary.dropped]; a `Crawl-delay` it asks for raises [delay] for that host
  /// alone, never lowers it. A site with no `robots.txt`, or one that cannot be read,
  /// forbids nothing.
  bool robots = false;

  final List<Request> _seeds;
  final Map<Uri, Map<String, Object?>> _seedMeta = {};

  InitContext._(this._seeds);

  /// The starting points so far.
  List<Uri> get seeds => [for (final s in _seeds) s.url];

  /// Adds a starting point.
  void seed(Uri url, {Map<String, Object?>? meta}) {
    url = url.removeFragment();
    _seeds.add(Request('GET', url));
    if (meta != null) _seedMeta[url] = meta;
  }
}

/// A request about to be sent. Edit [request] — a header, the `user-agent`, a signature — or
/// [skip] it.
///
/// {@category Crawling}
final class RequestContext {
  /// The request as it will be sent; its `headers` are yours to edit.
  final Request request;

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
  final _Follow<T> _follow;
  final void Function() _stop;
  bool _closed = false;

  HookContext._(this._emit, this._follow, this._stop);

  /// The URL this hook is about; [resolve] and [follow] resolve against it.
  Uri get url;

  /// The request as it was scheduled.
  Request get request;

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
  /// set. The body is at most one of [text], [bytes], [form] and [json], the same four words
  /// [Request] and [UriExtensions.post] take. [onResponse] and [onError] override the crawl's
  /// hooks for this request.
  bool follow(
    Object target, {
    ResponseHook<T>? onResponse,
    ErrorHook<T>? onError,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    String method = 'GET',
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    bool revisit = false,
    bool offsite = false,
  }) {
    _open('follow');
    final scheduled = _follow(
      target,
      _Plan<T>(
        onResponse: onResponse,
        onError: onError,
        meta: meta,
        headers: headers,
        method: method,
        text: text,
        bytes: bytes,
        form: form,
        json: json,
        revisit: revisit,
        offsite: offsite,
      ),
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
  final Response response;

  @override
  final Request request;

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
    required _Follow<T> follow,
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
  Request get request => failure.request;
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
/// and `.cancellable` apply. Nothing is sent until it is listened to.
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

  factory Scrape._of(Iterable<Request> seeds, {Client? client}) {
    final hooks = _Hooks<T>(seeds.toList(), client: client);
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
  Scrape<T> scrape<T>() => Scrape<T>._of([Request('GET', removeFragment())]);
}

/// {@category Crawling}
extension IterableUriScrapeExtensions on Iterable<Uri> {
  /// A crawl seeded here.
  Scrape<T> scrape<T>() => Scrape<T>._of([for (final url in this) Request('GET', url.removeFragment())]);
}

/// {@category Crawling}
extension IterableRequestScrapeExtensions on Iterable<Request> {
  /// A crawl seeded with these requests — any method, body or headers.
  Scrape<T> scrape<T>() => Scrape<T>._of(this);
}

// ---------------------------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------------------------

final class _Hooks<T> {
  final List<Request> seeds;

  /// The client this crawl was started on, when it was started from one
  /// ([ClientExtensions.scrape]) rather than inside an [Http.scope]. A crawl cannot read the
  /// ambient client at construction — `onListen` runs in the listener's zone, not the
  /// builder's — so a held client travels here instead.
  final Client? client;
  InitHook<T>? onInit;
  RequestHook? onRequest;
  ResponseHook<T>? onResponse;
  ErrorHook<T>? onError;
  FinishHook? onFinish;

  _Hooks(this.seeds, {this.client});
}

/// Sent unless the request, [Scrape.onRequest] or the scope names one.
const _userAgent = 'dart-toolkit';

/// Identity of a request for deduplication. The body is hashed rather than kept: the set
/// lives as long as the crawl, and a POST-driven crawl would otherwise retain every body.
typedef _RequestKey = (String method, Uri url, int body);

_RequestKey _key(Request req) => (req.method, req.url, _fnv1a(req.bytes));

/// FNV-1a, 64-bit. Wide enough that two different bodies to one URL colliding — which
/// would silently drop a page — is not a practical concern.
int _fnv1a(List<int> bytes) {
  var h = 0xcbf29ce484222325;
  for (final b in bytes) {
    h = (h ^ b) * 0x100000001b3;
  }
  return h;
}

/// Headers that stay behind when a redirect leaves the host.
const _credential = {'authorization', 'cookie', 'proxy-authorization'};

/// `www.example.com` and `example.com` are one site.
String _site(String host) => host.startsWith('www.') ? host.substring(4) : host;

/// Failures that will not change on a second attempt.
bool _certain(Object e) =>
    e is HandshakeException || e is CertificateException || e is TlsException || e is _BodyTooLarge;

/// A body over the cap; the same on every attempt, so never retried.
final class _BodyTooLarge extends ClientException {
  const _BodyTooLarge(int cap, Uri url) : super('Response body over $cap bytes', url);
}

class _Item<T> {
  final Request request;
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

  /// This host's `/robots.txt`, fetched at most once; the future is shared so the
  /// requests that start together wait on one fetch rather than each making their own.
  Future<_Robots>? robots;

  /// A gap this host asked for through `Crawl-delay`. The crawl's own [InitContext.delay]
  /// still applies; whichever is longer wins, so robots can slow a host but never hurry it.
  Duration gap = Duration.zero;
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
  final lease = hooks.client == null ? _clientFor() : _ClientLease(hooks.client!, false);
  final scopeHasUserAgent = lease.headers?.keys.any((k) => k.toLowerCase() == 'user-agent') ?? false;

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

  // Keyed by site, not host: `www.example.com` and `example.com` are one server, and the
  // crawl already treats them as one for scope. Two buckets would double `perHost` and
  // halve `delay` for any site linked both ways.
  _Host<T> hostOf(Uri url) => hosts.putIfAbsent(_site(url.host), _Host<T>.new);

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

  /// How long to hold [host], or `null` when the server asked for longer than
  /// [InitContext.maxRetryAfter] and the request should fail rather than wait.
  Duration? retryAfter(Response res, _Host<T> host) {
    final header = res.headers['retry-after']?.trim() ?? '';
    Duration? asked;
    if (int.tryParse(header) case final seconds?) {
      asked = Duration(seconds: seconds);
    } else if (header.isNotEmpty) {
      try {
        final wait = HttpDate.parse(header).difference(DateTime.now());
        asked = wait.isNegative ? Duration.zero : wait;
      } on FormatException {
        // Not a date either; fall through to the backoff.
      }
    }
    if (asked != null) return asked > cfg.maxRetryAfter ? null : asked;
    final ms = 500 * (1 << host.backoffs.clamp(0, 6));
    host.backoffs++;
    return Duration(milliseconds: ms > 30000 ? 30000 : ms);
  }

  /// [host]'s rules, fetched once. Never through the frontier: robots.txt is not a page
  /// the crawl is for, and a failure to read it is not a failure of the crawl.
  Future<_Robots> robotsFor(_Host<T> host, Uri url) => host.robots ??= () async {
    try {
      final res = await lease.client
          .send(Request('GET', url.replace(path: '/robots.txt', query: null, fragment: null)))
          .timeout(cfg.timeout);
      final body = await res.read().timeout(cfg.timeout);
      // A 4xx is a site with no rules; a 5xx is a site that cannot say, and the
      // conservative reading — refuse everything — would strand a whole crawl on one
      // bad deploy, so both are read as open.
      return body.isOk ? _Robots.parse(body.text, _userAgent) : _Robots.open;
    } catch (_) {
      return _Robots.open;
    }
  }();

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

  _Follow<T> followFrom(_Item<T> item, Uri base) => (target, plan) {
    final next = Request(
      plan.method,
      _resolve(base, target),
      headers: plan.headers,
      text: plan.text,
      bytes: plan.bytes,
      form: plan.form,
      json: plan.json,
    );
    final scheduled = enqueue(
      _Item<T>(
        next,
        onResponse: plan.onResponse,
        onError: plan.onError,
        meta: {...item.meta, ...?plan.meta},
        depth: item.depth + 1,
        revisit: plan.revisit,
        offsite: plan.offsite,
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

  StatusFailed statusFailed(_Item<T> item, Response res) => StatusFailed(
    url: res.url ?? item.request.url,
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

  Future<void> redirect(_Host<T> host, _Item<T> item, Request sent, Response res) {
    final location = res.headers['location']?.trim();
    if (location == null || location.isEmpty) return fail(host, item, statusFailed(item, res), StackTrace.current);
    if (item.hops >= cfg.redirects) {
      final e = ClientException('Too many redirects', sent.url);
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
    final next = Request(downgrade ? 'GET' : sent.method, target);
    final crossHost = target.host != sent.url.host;
    for (final MapEntry(:key, :value) in sent.headers.entries) {
      final k = key.toLowerCase();
      if (downgrade && (k == 'content-type' || k == 'content-length')) continue;
      // Credentials do not follow a redirect to another host, as a browser's would not.
      if (crossHost && _credential.contains(k)) continue;
      next.headers[key] = value;
    }
    if (!downgrade) next.bytes = sent.bytes;
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

  Future<void> handle(_Host<T> host, _Item<T> item, Request sent, Response res) async {
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
    if (!scopeHasUserAgent) sent.headers.putIfAbsent('user-agent', () => _userAgent);

    if (cfg.robots) {
      final rules = await robotsFor(host, sent.url);
      if (!rules.allows(sent.url)) {
        dropped++;
        return;
      }
      // The site's own gap, where it asks for a longer one than the crawl already keeps.
      if (rules.crawlDelay case final asked? when asked > host.gap) host.gap = asked;
    }

    if (hooks.onRequest case final hook?) {
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
    final StreamedResponse streamed;
    final pending = lease.client.send(sent);
    try {
      streamed = await pending.timeout(cfg.timeout);
    } catch (e, st) {
      // A send that lands after the timeout still holds a connection until its body is
      // read, so the abandoned response is drained rather than left to the client's reaper.
      unawaited(pending.then(_drain, onError: (Object _) {}));
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

    final res = Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      request: sent,
      url: streamed.url,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      reasonPhrase: streamed.reasonPhrase,
    );
    final status = res.statusCode;

    if (status >= 300 && status < 400) return redirect(host, item, sent, res);
    if (status == 429 || status == 503) {
      final wait = retryAfter(res, host);
      if (wait == null) return fail(host, item, statusFailed(item, res), StackTrace.current);
      pause(host, wait);
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
      final gap = host.gap > cfg.delay ? host.gap : cfg.delay;
      if (gap > Duration.zero) {
        final wait = host.nextSend.difference(now);
        if (wait > Duration.zero) {
          pause(host, wait);
          continue;
        }
        host.nextSend = now.add(gap);
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

/// A fresh copy the engine can send once per attempt, with redirects left to it.
Request _clone(Request req) => req.copy()..followRedirects = false;
