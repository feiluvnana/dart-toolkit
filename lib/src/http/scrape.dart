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

/// What [HookContext.follow] was asked for, on its way to the engine.
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
  final Map<String, Path>? files;
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
    this.files,
    this.revisit = false,
    this.offsite = false,
  });

  bool get _bodied => text != null || bytes != null || form != null || json != null || files != null;
}

typedef _Follow<T> = bool Function(Object target, _Plan<T> plan);

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
  String toString() => '${request.method} $url — ${_status(response.statusCode, response.reasonPhrase)}';
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

/// The crawl's settings and seeds, set once in [Scrape.onInit]. Anything per request — a
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

  /// The longest a server's `Retry-After` may hold a host; a request asking for longer fails
  /// instead, so one header cannot park the crawl for hours.
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

  /// Whether each host's `/robots.txt` is fetched once and obeyed, for the `user-agent` each
  /// request goes out with. A forbidden path counts in [ScrapeSummary.dropped]; a
  /// `Crawl-delay` raises [delay] for that host, never lowers it. A missing or unreadable
  /// file forbids nothing.
  bool robots = false;

  /// Whether the sitemaps of each seed's site seed the crawl too: those `/robots.txt` lists,
  /// else `/sitemap.xml`; indexes are followed and gzip is read. Their pages are scoped,
  /// deduplicated and robots-checked like any other.
  ///
  /// ```dart
  /// site.scrape<Page>().onInit((ctx) => ctx..sitemaps = true..robots = true).onResponse(parse);
  /// ```
  bool sitemaps = false;

  /// What makes two URLs one page, for the visited check only — requests still go to the URL
  /// followed.
  ///
  /// ```dart
  /// ctx.canonical = (u) => u.replace(queryParameters: {...u.queryParameters}..remove('sid'));
  /// ```
  Uri Function(Uri url)? canonical;

  final List<Request> _seeds;
  final Map<Uri, Map<String, Object?>> _seedMeta = {};

  InitContext._(this._seeds);

  /// The starting points so far.
  List<Uri> get seeds => [for (final s in _seeds) s.url];

  /// Adds a starting point.
  void seed(Uri url, {Map<String, Object?>? meta}) {
    url = _page(url);
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

  /// The URL this hook is about; [resolve] and [follow] resolve against it, or against the
  /// page's `<base href>` once its HTML has been read.
  Uri get url;

  Uri get _base => url;

  /// The request as it was scheduled.
  Request get request;

  /// Hops from a seed; seeds are 0.
  int get depth;

  /// Metadata carried from the request that scheduled this one.
  Map<String, Object?> get meta;

  /// Resolves [href] — a [Uri], a [String], an [Element] by its `href` else `src`, or the
  /// first of a query's [Elements] — as [follow] does.
  ///
  /// ```dart
  /// final file = ctx.resolve(ctx.html.$('a.download'));
  /// ```
  ///
  /// Throws a [StateError] for an element with neither, or a query that matched nothing.
  Uri resolve(Object href) => _resolve(_base, switch (href) {
    List<Element>(isEmpty: true) => throw StateError('Nothing matched the selector'),
    List<Element>(:final first) => _link(first) ?? (throw StateError('<${first.name}> has no href or src')),
    Element() => _link(href) ?? (throw StateError('<${href.name}> has no href or src')),
    _ => href,
  });

  /// Emits [item] on the scrape stream.
  void emit(T item) {
    _open('emit');
    _acted();
    _emit(item);
  }

  /// Schedules a request for [target]: what [resolve] takes, any [Iterable] of it, or a
  /// [JsonDocument] holding a string, a list or `null` (nothing).
  ///
  /// ```dart
  /// ctx.follow(ctx.html.$('a.next'));      // pagination, whether or not there is a next
  /// ctx.follow(ctx.response.json['next']); // one URL, a list of them, or null on the last page
  /// ```
  ///
  /// Returns whether anything was scheduled. Out of scope or non-http is dropped unless
  /// [offsite]; already visited, unless [revisit]. The body words are [Request]'s;
  /// [onResponse] and [onError] override the crawl's hooks for this request.
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
    Map<String, Path>? files,
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
        files: files,
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

  /// The response parsed as HTML — [Response.html], parsed once however often it is read.
  HtmlDocument get html => response.html;

  /// The page's `<base href>`, read only once something else has parsed the HTML.
  Uri? _baseRead;

  @override
  Uri get _base => _baseRead ?? (response._html == null ? url : _baseRead = response._html!.base ?? url);

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

/// A crawl you can hold, subclass and test: the five hooks of [Scrape], as methods.
///
/// `url.scrape<T>()` is the short spelling; the same engine runs both. Subclass when the
/// crawl has state of its own, which is then a field rather than a captured variable.
///
/// ```dart
/// final class Books extends Crawler<Book> {
///   final Uri home;
///   final titles = <String>{};
///   Books(this.home);
///
///   @override
///   void onInit(InitContext<Book> ctx) => ctx..seed(home)..robots = true;
///
///   @override
///   void onResponse(ResponseContext<Book> ctx) {
///     for (final b in ctx.html.$('.book')) {
///       if (titles.add(b.$('h2').text)) ctx.emit(Book.of(b));
///     }
///     ctx.follow(ctx.html.$('a.next'));
///   }
/// }
///
/// await for (final book in Books(home).run().rights) { ... }
/// ```
///
/// {@category Crawling}
abstract class Crawler<T> {
  /// The chain's receiver; a subclass seeds in [onInit].
  final List<Request> _seeds = [];

  /// From [ClientExtensions.scrape]; `null` takes the scope's on listen.
  Client? _client;

  /// Once, before anything is sent: settings and seeds, on an [InitContext]. May be async.
  FutureOr<void> onInit(InitContext<T> ctx) {}

  /// Before every send, retries included.
  FutureOr<void> onRequest(RequestContext ctx) {}

  /// On every 2xx.
  FutureOr<void> onResponse(ResponseContext<T> ctx) {}

  /// When the engine has given up on a request; the failure is a [Left] unless this acts.
  FutureOr<void> onError(ErrorContext<T> ctx) {}

  /// Once, after the last item. If it throws, the error is the stream's last event.
  FutureOr<void> onFinish(ScrapeSummary summary) {}

  /// The crawl as a stream: nothing is sent until listened to, and each listen is a crawl.
  Stream<Either<ScrapeFailure, T>> run() {
    late final StreamController<Either<ScrapeFailure, T>> controller;
    controller = StreamController(onListen: () => _run(this, controller));
    return controller.stream;
  }

  // What the engine calls. A chain answers `null` for a hook it was not given, so that hook
  // costs nothing — not even its context.
  InitHook<T>? get _init => onInit;
  RequestHook? get _request => onRequest;
  ResponseHook<T>? get _response => onResponse;
  ErrorHook<T>? get _error => onError;
  FinishHook? get _finish => onFinish;
}

/// The crawler a [Scrape] chain builds.
final class _Chain<T> extends Crawler<T> {
  InitHook<T>? init;
  RequestHook? request;
  ResponseHook<T>? response;
  ErrorHook<T>? error;
  FinishHook? finish;

  @override
  InitHook<T>? get _init => init;
  @override
  RequestHook? get _request => request;
  @override
  ResponseHook<T>? get _response => response;
  @override
  ErrorHook<T>? get _error => error;
  @override
  FinishHook? get _finish => finish;
}

/// A crawl: five hooks on a chain, consumed as a `Stream<Either<ScrapeFailure, T>>` — the
/// short spelling of [Crawler]. Nothing is sent until it is listened to.
///
/// ```dart
/// final items = url.scrape<Item>()
///     .onInit((ctx) => ctx..concurrency = 8..pages = 50)
///     .onResponse((ctx) {
///       ctx.emit(parse(ctx.response));
///       ctx.follow(ctx.html.$('a.next'));
///     })
///     .onError((ctx) => log('${ctx.failure}'))
///     .onFinish((s) => log('$s'));
///
/// await for (final item in items.rights) { ... }
/// ```
///
/// {@category Crawling}
final class Scrape<T> extends StreamView<Either<ScrapeFailure, T>> {
  final _Chain<T> _chain;

  Scrape._(this._chain) : super(_chain.run());

  factory Scrape._of(Iterable<Request> seeds, {Client? client}) => Scrape._(
    _Chain<T>()
      .._seeds.addAll(seeds)
      .._client = client,
  );

  /// Once, on listen, with every setting on an [InitContext]. May be async.
  Scrape<T> onInit(InitHook<T> hook) => this.._chain.init = hook;

  /// Before every send, retries included.
  Scrape<T> onRequest(RequestHook hook) => this.._chain.request = hook;

  /// On every 2xx.
  Scrape<T> onResponse(ResponseHook<T> hook) => this.._chain.response = hook;

  /// When the engine has given up on a request; the failure is a [Left] unless the hook acts.
  Scrape<T> onError(ErrorHook<T> hook) => this.._chain.error = hook;

  /// Once, after the last item. If it throws, the error is the stream's last event.
  Scrape<T> onFinish(FinishHook hook) => this.._chain.finish = hook;
}

/// Scrape entry points; see [Scrape].
///
/// {@category Crawling}
extension UriScrapeExtensions on Uri {
  /// A crawl seeded here.
  Scrape<T> scrape<T>() => Scrape<T>._of([Request('GET', _page(this))]);
}

/// {@category Crawling}
extension IterableUriScrapeExtensions on Iterable<Uri> {
  /// A crawl seeded here.
  Scrape<T> scrape<T>() => Scrape<T>._of([for (final url in this) Request('GET', _page(url))]);
}

/// {@category Crawling}
extension IterableRequestScrapeExtensions on Iterable<Request> {
  /// A crawl seeded with these requests — any method, body or headers.
  Scrape<T> scrape<T>() => Scrape<T>._of(this);
}

/// Sent unless the request, [Scrape.onRequest] or the scope names one.
const _userAgent = 'dart-toolkit';

/// A request's dedupe identity: 64-bit FNV-1a over method, URL and body. A number, because
/// the visited set lives as long as the crawl — a million URLs held whole was half a gigabyte.
int _key(String method, Uri url, [List<int> body = const []]) {
  var h = 0xcbf29ce484222325;
  for (final c in method.codeUnits) {
    h = (h ^ c) * 0x100000001b3;
  }
  h = (h ^ 0x20) * 0x100000001b3;
  for (final c in '$url'.codeUnits) {
    h = (h ^ c) * 0x100000001b3;
  }
  h = (h ^ 0x0a) * 0x100000001b3;
  for (final b in body) {
    h = (h ^ b) * 0x100000001b3;
  }
  return h;
}

/// A body's identity: its bytes, or for `files:` (never held) its fields and each file's
/// path and size.
List<int> _identity(Request req) => switch (req._multipart) {
  null => req.bytes,
  final body => utf8.encode(
    [
      for (final MapEntry(:key, :value) in body.fields.entries) '$key=$value',
      for (final MapEntry(:key, :value) in body.files.entries) '$key@${value.absolute}#${value.asFile.lengthSync()}',
    ].join('\n'),
  ),
};

/// `www.example.com` and `example.com` are one site.
String _site(String host) => host.startsWith('www.') ? host.substring(4) : host;

/// Failures that will not change on a second attempt.
bool _certain(Object e) =>
    e is HandshakeException || e is CertificateException || e is TlsException || e is _BodyTooLarge;

/// A body over the cap; never retried.
final class _BodyTooLarge extends ClientException {
  const _BodyTooLarge(int cap, Uri url) : super('Response body over $cap bytes', url);
}

/// RFC 9309 asks for at least 500 KiB of a `robots.txt`; a longer one is cut, not refused.
const _robotsCap = 512 * 1024;

/// The sitemap protocol's own limit, applied compressed or not.
const _sitemapCap = 50 * 1024 * 1024;

/// One request waiting in the frontier, held as a URL and a plan until it is sent: a million
/// waiting `Request`s is a lot of `Headers` nobody has read yet.
class _Item<T> {
  final Uri url;
  final _Plan<T> plan;
  final Map<String, Object?> meta;
  final int depth;

  /// A seed the caller named: only it moves the crawl's home when it redirects; a sitemap's
  /// page is at depth 0 too, and must not.
  final bool seed;
  Request? _request;
  int attempt = 1;
  int hops = 0;

  /// The keys of this item's redirect chain. A hop back into it — a login redirecting to
  /// itself with a cookie — is bounded by the hop budget, not the visited set.
  List<int>? chain;

  _Item(this.url, this.plan, {Request? request, this.meta = const {}, this.depth = 0, this.seed = false})
    : _request = request;

  Request get request => _request ??= Request(plan.method, url, headers: plan.headers);

  ResponseHook<T>? get onResponse => plan.onResponse;
  ErrorHook<T>? get onError => plan.onError;
  bool get revisit => plan.revisit;
  bool get offsite => plan.offsite;
}

class _Host<T> {
  final Queue<_Item<T>> queue = Queue<_Item<T>>();

  /// This host's `/robots.txt`, fetched once and shared; `null` inside is none or unreadable.
  Future<_RobotsTxt?>? robots;

  /// [robots] per `user-agent`, since the groups differ by agent.
  final Map<String, _Robots> rules = {};

  /// `Crawl-delay`; the longer of it and [InitContext.delay] applies.
  Duration gap = Duration.zero;
  int inFlight = 0;
  int backoffs = 0;
  DateTime nextSend = DateTime.fromMillisecondsSinceEpoch(0);
  bool paused = false;
  DateTime pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool ready = false;
  bool robotsResolved = false;
  bool robotsFetching = false;
  Timer? pauseTimer;
}

Future<void> _run<T>(Crawler<T> crawler, StreamController<Either<ScrapeFailure, T>> controller) async {
  // Read in the zone that listened, which is the one whose ^C this crawl should hear.
  final token = Cancel.token;
  if (token != null && token.isCancelled) return controller.close();
  // A copy: `ctx.seed` adds to it, and a crawler run twice must not start from both runs' seeds.
  final cfg = InitContext<T>._([...crawler._seeds]);
  if (crawler._init case final init?) {
    // A listener gone while an async init runs ends the crawl before its first request.
    var gone = false;
    controller.onCancel = () => gone = true;
    try {
      await init(cfg);
    } catch (e, st) {
      controller.addError(e, st);
      return controller.close();
    }
    if (gone) return;
  }
  if (cfg.concurrency < 1) cfg.concurrency = 1;
  if (cfg.perHost < 1) cfg.perHost = 1;
  if (cfg.retries < 0) cfg.retries = 0;
  if (cfg.redirects < 0) cfg.redirects = 0;
  final started = DateTime.now();
  final lease = switch (crawler._client) {
    final held? => _ClientLease(held, false),
    null => _clientFor(),
  };
  // The scope stamps its `user-agent` at send time, after the engine has looked.
  final scopeAgent = lease.headers == null ? null : Headers(lease.headers)['user-agent'];

  final seedHosts = <String>{for (final s in cfg._seeds) _site(s.url.host)};
  final canonical = cfg.canonical;
  Uri canon(Uri url) => canonical == null ? url : _page(canonical(url));
  int keyOf(Request req) => _key(req.method, canon(req.url), _identity(req));

  /// Without building the request when there is no body.
  int itemKey(_Item<T> item) =>
      item._request == null ? _key(item.plan.method.toUpperCase(), canon(item.url)) : keyOf(item._request!);
  final inScope = cfg.scope ?? (Uri url) => seedHosts.contains(_site(url.host));
  final visited = <int>{};
  final hosts = <String, _Host<T>>{};
  final ready = Queue<_Host<T>>();
  final timers = <Timer>{};
  final none = _Plan<T>();

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
  void Function()? unhear;

  void close() {
    if (closed) return;
    closed = true;
    stopped = true;
    unhear?.call();
    for (final t in timers) {
      t.cancel();
    }
    for (final h in hosts.values) {
      h.pauseTimer?.cancel();
    }
    lease.close();
    if (controller.isClosed) return;
    final finish = crawler._finish;
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
    if (outcome is Left) failures++;
    controller.add(outcome);
  }

  late final void Function() dispatch;

  /// Sitemap readers holding pages back until the frontier has room; see [seedSitemaps].
  final refills = <void Function()>{};

  // Keyed by scheme, site and port: `www.` and bare are one bucket, or a site linked both
  // ways would get double `perHost` and half `delay`.
  _Host<T> hostOf(Uri url) => hosts.putIfAbsent('${url.scheme}://${_site(url.host)}:${url.port}', _Host<T>.new);

  /// A file the crawl reads for itself — robots.txt, a sitemap — outside the frontier, raw,
  /// capped at [cap] (cut there when [cut]); `null` for a non-2xx or any failure.
  Future<Uint8List?> fetchOwn(Uri url, String agent, {required int cap, bool cut = false}) async {
    final request = Request('GET', url, headers: {'user-agent': agent})
      ..[Request.raw] = true
      ..[_Retry.none] = true;
    final abort = CancelToken();
    final pending = Cancel.scope(() => lease.client.send(request), token: abort);
    final StreamedResponse res;
    try {
      res = await pending.timeout(cfg.timeout);
    } catch (_) {
      abort.cancel();
      unawaited(pending.then(_drain, onError: (Object _) {}));
      return null;
    }
    if (!res.isOk) {
      unawaited(_drain(res).catchError((Object _) {}));
      return null;
    }
    try {
      return await _readCapped(res.stream, cap: cap, url: url, timeout: cfg.timeout, cut: cut);
    } catch (_) {
      return null;
    }
  }

  /// [host]'s `/robots.txt`, fetched once. A 5xx reads as open too: refusing everything
  /// would strand a crawl on one bad deploy.
  Future<_RobotsTxt?> robotsTxt(_Host<T> host, Uri url, String agent) {
    final site = Uri(scheme: url.scheme, host: url.host, port: url.port, path: '/robots.txt');
    return host.robots ??= fetchOwn(
      site,
      agent,
      cap: _robotsCap,
      cut: true,
    ).then((bytes) => bytes == null ? null : _RobotsTxt.parse(utf8.decode(bytes, allowMalformed: true), site));
  }

  Future<_Robots> robotsFor(_Host<T> host, Uri url, String agent) async {
    final file = await robotsTxt(host, url, agent);
    if (file == null) return _Robots.open;
    return host.rules[agent] ??= file.forAgent(agent);
  }

  void slow(_Host<T> host, _Robots rules) {
    if (rules.crawlDelay case final asked? when asked > host.gap) host.gap = asked;
  }

  void checkReady(_Host<T> host) {
    if (stopped ||
        host.ready ||
        host.paused ||
        host.queue.isEmpty ||
        host.inFlight >= cfg.perHost ||
        (cfg.robots && !host.robotsResolved)) {
      return;
    }
    host.ready = true;
    ready.add(host);
  }

  void push(_Host<T> host, _Item<T> item, {bool first = false}) {
    first ? host.queue.addFirst(item) : host.queue.add(item);
    queued++;
    if (cfg.robots && !host.robotsResolved && !host.robotsFetching) {
      host.robotsFetching = true;
      robotsFor(host, item.url, scopeAgent ?? _userAgent).catchError((Object _) => _Robots.open).then((rules) {
        host.robotsResolved = true;
        slow(host, rules);
        checkReady(host);
        dispatch();
      });
    }
    checkReady(host);
  }

  /// Requeues [item] at its host's front after [after]; the crawl stays open meanwhile.
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

  /// How long to hold [host], or `null` to fail rather than wait past
  /// [InitContext.maxRetryAfter]; with [once] (not replayable), only a `Retry-After` is waited.
  Duration? retryAfter(Response res, _Host<T> host, {bool once = false}) {
    if (_Retry.retryAfter(res.headers) case final asked?) return asked > cfg.maxRetryAfter ? null : asked;
    return once ? null : _Retry.backoff(host.backoffs++);
  }

  /// Whether [item] left scope by redirecting to [to]. A seed does not: it moves the crawl's
  /// home with it (apex to www).
  bool strays(_Item<T> item, Uri to) {
    if (!item.seed) return !item.offsite && !inScope(to);
    seedHosts.add(_site(to.host));
    return false;
  }

  bool drop() {
    dropped++;
    return false;
  }

  /// Schedules [item] unless it is too deep, off-scheme, out of scope, or already visited.
  bool enqueue(_Item<T> item) {
    if (stopped) return false;
    if (cfg.depth case final max? when item.depth > max) return drop();
    final url = item.url;
    if (url.scheme != 'http' && url.scheme != 'https') return drop();
    if (!item.offsite && !inScope(url)) return drop();
    if (!item.revisit && !visited.add(itemKey(item))) return drop();
    push(hostOf(url), item);
    return true;
  }

  void stop() {
    if (stopped) return;
    stopped = true;
    for (final refill in refills.toList()) {
      refill();
    }
    ready.clear();
    for (final h in hosts.values) {
      queued -= h.queue.length;
      h.queue.clear();
    }
    if (running == 0) close();
  }

  _Follow<T> followFrom(_Item<T> item, Uri Function() base) => (target, plan) {
    // A follow adding no metadata shares the one empty map rather than copying nothing.
    final meta = plan.meta == null && item.meta.isEmpty ? const <String, Object?>{} : {...item.meta, ...?plan.meta};
    bool one(Object href) {
      final Uri url;
      try {
        url = _resolve(base(), href);
      } on FormatException {
        return drop();
      }
      final next = _Item<T>(url, plan, meta: meta, depth: item.depth + 1);
      // Encoded now: a bad body fails in the hook that asked, and is there to be hashed.
      if (plan._bodied) {
        next._request = Request(
          plan.method,
          url,
          headers: plan.headers,
          text: plan.text,
          bytes: plan.bytes,
          form: plan.form,
          json: plan.json,
          files: plan.files,
        );
      }
      return enqueue(next);
    }

    bool each(Object? target) {
      switch (target) {
        case null:
          return false;
        case Element():
          return switch (_link(target)) {
            final href? => one(href),
            null => drop(),
          };
        case JsonDocument(:final raw):
          return each(raw);
        case Iterable():
          var scheduled = false;
          for (final t in target) {
            if (each(t)) scheduled = true;
          }
          return scheduled;
        default:
          return one(target);
      }
    }

    final scheduled = each(target);
    dispatch();
    return scheduled;
  };

  HookFailed hookFailed(_Item<T> item, Uri url, Object e) =>
      HookFailed(url: url, request: item.request, depth: item.depth, meta: item.meta, error: e);

  /// The engine has given up on [item]: the error hook decides, else it is a [Left].
  Future<void> fail(_Host<T> host, _Item<T> item, ScrapeFailure failure, StackTrace st) async {
    if (stopped) {
      // Over: a request failing in flight is not news, a hook that threw is.
      if (failure is HookFailed) add(Left(failure, st));
      if (running == 0) close();
      return;
    }
    final hook = item.onError ?? crawler._error;
    if (hook == null) return add(Left(failure, st));

    running++;
    final ctx = ErrorContext<T>._(
      failure,
      item.attempt,
      (value) => add(Right(value)),
      followFrom(item, () => failure.url),
      (after) => requeue(host, item, after),
      stop,
    );
    try {
      await hook(ctx);
      if (!ctx._handled) add(Left(failure, st));
    } catch (e, hookSt) {
      add(Left(hookFailed(item, failure.url, e), hookSt));
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

  Future<void> refuse(_Host<T> host, _Item<T> item, Response res) => fail(
    host,
    item,
    StatusFailed(
      url: res.url ?? item.request.url,
      request: item.request,
      depth: item.depth,
      meta: item.meta,
      response: res,
    ),
    StackTrace.current,
  );

  Future<void> transportFailure(_Host<T> host, _Item<T> item, Uri url, Object e, StackTrace st) async {
    if (stopped) return;
    if (_replayable(item.request.method) && !_certain(e) && item.attempt <= cfg.retries) {
      return requeue(host, item, (200 * item.attempt).ms);
    }
    return fail(host, item, requestFailed(item, url, e), st);
  }

  Future<void> redirect(_Host<T> host, _Item<T> item, Request sent, Response res) async {
    final location = res.headers['location']?.trim();
    if (location == null || location.isEmpty) return refuse(host, item, res);
    if (item.hops >= cfg.redirects) {
      final e = ClientException('Too many redirects', sent.url);
      return fail(host, item, requestFailed(item, sent.url, e), StackTrace.current);
    }
    final Uri target;
    try {
      target = _resolve(sent.url, location);
    } on FormatException catch (e, st) {
      return fail(host, item, requestFailed(item, sent.url, e), st);
    }
    if ((target.scheme != 'http' && target.scheme != 'https') || strays(item, target)) {
      return refuse(host, item, res);
    }
    // The client's redirect policy, directives included.
    final next = sent._hop(target, res.statusCode);
    final key = keyOf(next);
    final chain = item.chain ?? [keyOf(item.request)];
    // A hop back into this chain is followed (see [_Item.chain]); anywhere else visited drops.
    if (!chain.contains(key) && !item.revisit && item.plan.onResponse == null && !visited.add(key)) {
      dropped++;
      return;
    }
    final hop = _Item<T>(next.url, item.plan, request: next, meta: item.meta, depth: item.depth, seed: item.seed)
      ..hops = item.hops + 1
      ..chain = [...chain, key];
    push(hostOf(target), hop, first: true);
  }

  Future<void> handle(_Host<T> host, _Item<T> item, Uri answered, Response res) async {
    pages++;
    final hook = item.onResponse ?? crawler._response;
    if (hook == null) return;
    running++;
    late final ResponseContext<T> ctx;
    ctx = ResponseContext<T>._(
      response: res,
      request: item.request,
      url: answered,
      depth: item.depth,
      pages: pages,
      meta: item.meta,
      emit: (value) => add(Right(value)),
      follow: followFrom(item, () => ctx._base),
      stop: stop,
    );
    try {
      await hook(ctx);
    } catch (e, st) {
      ctx._closed = true;
      running--;
      await fail(host, item, hookFailed(item, answered, e), st);
      return;
    }
    ctx._closed = true;
    running--;
    if (stopped && running == 0) close();
  }

  Future<void> execute(_Host<T> host, _Item<T> item) async {
    final sent = item.request.copy()
      ..followRedirects = false
      ..[_Retry.none] = true;
    if (scopeAgent == null) sent.headers.putIfAbsent('user-agent', () => _userAgent);

    if (crawler._request case final hook?) {
      final ctx = RequestContext._(sent, item.depth, item.attempt, item.meta);
      try {
        await hook(ctx);
      } catch (e, st) {
        return fail(host, item, hookFailed(item, sent.url, e), st);
      }
      if (ctx._skipped) return;
    }

    // After the hook, so the rules are those for the agent that will be announced.
    if (cfg.robots) {
      final rules = await robotsFor(host, sent.url, sent.headers['user-agent'] ?? scopeAgent ?? _userAgent);
      if (!rules.allows(sent.url)) {
        dropped++;
        return;
      }
      slow(host, rules);
    }
    if (stopped) return;

    requests++;
    // Its own token, so a timeout aborts the request; the crawl's ^C reaches it mid-body too.
    final abort = CancelToken();
    final unhear = token?.onCancel(() => abort.cancel(token.reason));
    final StreamedResponse streamed;
    final Uint8List body;
    try {
      final pending = Cancel.scope(() => lease.client.send(sent), token: abort);
      try {
        streamed = await pending.timeout(cfg.timeout);
      } catch (_) {
        abort.cancel();
        // A late answer still holds a connection until its body is read.
        unawaited(pending.then(_drain, onError: (Object _) {}));
        rethrow;
      }
      body = await _readCapped(streamed.stream, cap: cfg.bodyLimit, url: sent.url, timeout: cfg.timeout);
    } catch (e, st) {
      unhear?.call();
      return transportFailure(host, item, sent.url, e, st);
    }
    unhear?.call();
    if (stopped) return;
    bytes += body.length;

    final res = Response.bytes(
      body,
      streamed.statusCode,
      request: sent,
      url: streamed.url,
      headers: streamed.headers,
      reasonPhrase: streamed.reasonPhrase,
    );
    final status = res.statusCode;

    if (status >= 300 && status < 400) return redirect(host, item, sent, res);
    final replayable = _replayable(sent.method);
    if (status == 429 || status == 503) {
      final wait = retryAfter(res, host, once: !replayable);
      if (wait == null) return refuse(host, item, res);
      pause(host, wait);
      if (item.attempt <= cfg.retries) {
        retries++;
        item.attempt++;
        return push(host, item, first: true);
      }
      return refuse(host, item, res);
    }
    if (status >= 500) {
      if (replayable && item.attempt <= cfg.retries) return requeue(host, item, (200 * item.attempt).ms);
      return refuse(host, item, res);
    }
    if (status < 200 || status >= 300) return refuse(host, item, res);

    host.backoffs = 0;
    // A client that redirects itself (a browser) answers from elsewhere; that URL is the page,
    // scoped and deduplicated as the engine's own hop would be.
    final answered = _page(res.url ?? sent.url);
    if (answered != sent.url) {
      if (strays(item, answered)) return refuse(host, item, res);
      if (!item.revisit && !visited.add(_key(sent.method, canon(answered)))) {
        dropped++;
        return;
      }
    }
    await handle(host, item, answered, res);
    if (cfg.pages case final max? when pages >= max) stop();
  }

  dispatch = () {
    if (closed || stopped || controller.isPaused) return;
    for (final refill in refills.toList()) {
      refill();
    }
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
      ).onError((Object e, st) => add(Left(requestFailed(item, item.url, e), st))).whenComplete(() {
        host.inFlight--;
        inFlight--;
        checkReady(host);
        dispatch();
      });
    }
    if (inFlight == 0 && queued == 0 && waiting == 0 && running == 0) close();
  };

  /// Seeds the crawl from [origin]'s sitemaps, [InitContext.perHost] at a time (one under a
  /// [InitContext.delay]). Under [InitContext.pages] the frontier gets only what it can use;
  /// the rest wait here as URLs, so a 50k-page site crawled for 50 never holds 50k requests.
  Future<void> seedSitemaps(Uri origin) async {
    final agent = scopeAgent ?? _userAgent;
    final listed = (await robotsTxt(hostOf(origin), origin, agent))?.sitemaps ?? const <Uri>[];
    final pending = Queue.of(listed.isEmpty ? [origin.resolve('/sitemap.xml')] : listed);
    final read = <Uri>{};
    final backlog = Queue<Uri>();
    final lanes = cfg.delay > Duration.zero ? 1 : cfg.perHost;
    final done = Completer<void>();
    var active = 0;
    bool full() => cfg.pages != null && pages + inFlight + queued >= cfg.pages!;
    late final void Function() pump;
    pump = () {
      while (backlog.isNotEmpty && !stopped && !full()) {
        enqueue(_Item<T>(_page(backlog.removeFirst()), none));
      }
      // An index may name itself, or a thousand sitemaps.
      while (active < lanes && backlog.isEmpty && pending.isNotEmpty && !stopped && read.length < 1000) {
        final map = pending.removeFirst();
        if (!read.add(map)) continue;
        active++;
        fetchOwn(map, agent, cap: _sitemapCap)
            .then((bytes) async {
              if (bytes == null || stopped) return;
              final (:pages, :maps) = await _sitemap(bytes, map);
              pending.addAll(maps);
              backlog.addAll(pages);
            })
            .catchError((Object _) {})
            .whenComplete(() {
              active--;
              pump();
              dispatch();
            });
      }
      if (active == 0 && (stopped || backlog.isEmpty) && !done.isCompleted) done.complete();
    };
    refills.add(pump);
    pump();
    await done.future;
    refills.remove(pump);
  }

  if (cfg.pages case final max? when max <= 0) return close();
  for (final seed in cfg._seeds) {
    enqueue(_Item<T>(seed.url, none, request: seed, meta: cfg._seedMeta[seed.url] ?? const {}, seed: true));
  }
  if (cfg.sitemaps) {
    // `waiting` holds the crawl open while sitemaps are read.
    for (final origin in {
      for (final s in cfg._seeds) Uri(scheme: s.url.scheme, host: s.url.host, port: s.url.port, path: '/'),
    }) {
      waiting++;
      unawaited(
        seedSitemaps(origin).catchError((Object _) {}).whenComplete(() {
          waiting--;
          dispatch();
        }),
      );
    }
  }

  controller
    ..onResume = dispatch
    ..onCancel = close;
  // A cancelled scope (^C) ends the crawl as [HookContext.stop] does.
  unhear = token?.onCancel(stop);
  dispatch();
}

/// [url] as a page: `/p#a`, `/p#b` and `/p?` are all `/p`.
Uri _page(Uri url) {
  url = url.removeFragment();
  if (url.hasAuthority && url.path.isEmpty) url = url.replace(path: '/');
  if (!url.hasQuery || url.query.isNotEmpty) return url;
  final text = '$url';
  return Uri.parse(text.substring(0, text.length - 1));
}

/// [target] against [base], as a page; see [_page].
Uri _resolve(Uri base, Object target) => switch (target) {
  Uri() => _page(base.resolveUri(target)),
  String() => _page(base.resolve(target.trim().replaceAll(_tabOrNewline, ''))),
  _ => throw ArgumentError.value(target, 'target', 'Must be a Uri, a String href or an Element'),
};

/// Stripped from an href anywhere in it, as a browser does.
final _tabOrNewline = RegExp('[\t\n\r]');

/// Where an element links: its `href`, else its `src`.
String? _link(Element e) => e.attributes['href'] ?? e.attributes['src'];

/// [stream] read to at most [cap] bytes, each chunk within [timeout]; past [cap] it is cut
/// when [cut], else a [_BodyTooLarge].
Future<Uint8List> _readCapped(
  Stream<List<int>> stream, {
  required int cap,
  required Uri url,
  Duration? timeout,
  bool cut = false,
}) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in timeout == null ? stream : stream.timeout(timeout)) {
    if (builder.length + chunk.length > cap) {
      if (!cut) throw _BodyTooLarge(cap, url);
      builder.add(chunk.sublist(0, cap - builder.length));
      break;
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

final _sitemapIndex = RegExp(r'<sitemapindex[\s>]', caseSensitive: false);
final _sitemapUrlset = RegExp(r'<urlset[\s>]', caseSensitive: false);
final _sitemapLoc = RegExp(r'<loc\b[^>]*>(.*?)</loc>', caseSensitive: false, dotAll: true);

/// The pages and sitemaps one sitemap names: `<urlset>` locs are pages, `<sitemapindex>` locs
/// sitemaps; gzip is unpacked, and non-XML is the plain-text form, a URL a line.
Future<({List<Uri> pages, List<Uri> maps})> _sitemap(Uint8List bytes, Uri from) async {
  final pages = <Uri>[];
  final maps = <Uri>[];
  Uint8List? raw = bytes;
  if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    try {
      raw = await _readCapped(_inflated(Stream.value(bytes), _Encoding.gzip, from), cap: _sitemapCap, url: from);
    } catch (_) {
      raw = null;
    }
  }
  if (raw == null) return (pages: pages, maps: maps);
  final text = utf8.decode(raw, allowMalformed: true);
  Uri? read(String href) => switch (Uri.tryParse(href.trim())) {
    final url? when href.trim().isNotEmpty => from.resolveUri(url),
    _ => null,
  };
  if (_sitemapIndex.hasMatch(text) || _sitemapUrlset.hasMatch(text)) {
    final into = _sitemapIndex.hasMatch(text) ? maps : pages;
    for (final m in _sitemapLoc.allMatches(text)) {
      var loc = m[1]!.trim();
      if (loc.startsWith('<![CDATA[') && loc.endsWith(']]>')) {
        loc = loc.substring(9, loc.length - 3).trim();
      } else {
        loc = loc.html.text;
      }
      if (read(loc) case final url?) into.add(url);
    }
  } else {
    for (final line in text.split('\n')) {
      if (read(line) case final url? when url.scheme == 'http' || url.scheme == 'https') pages.add(url);
    }
  }
  return (pages: pages, maps: maps);
}
