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
  ///
  /// The rules are read for the `user-agent` the request goes out with — the one
  /// [Scrape.onRequest] or the scope set, else this crawl's own — so a crawl that names
  /// itself is held to what the site says to it.
  bool robots = false;

  /// Whether each seed's site's sitemaps seed the crawl as well.
  ///
  /// They are the ones its `/robots.txt` lists on `Sitemap:` lines, or `/sitemap.xml` when it
  /// lists none; a sitemap index is followed to the sitemaps it names, and a gzipped one is
  /// read as it is. Every page they list is a seed — in scope, deduplicated and, with
  /// [robots], obeyed like any other — so a whole-site crawl is one line:
  ///
  /// ```dart
  /// site.scrape<Page>().onInit((ctx) => ctx..sitemaps = true..robots = true).onResponse(parse);
  /// ```
  bool sitemaps = false;

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

  /// Schedules a request for [target]: a [Uri], a [String] href resolved against [url], or
  /// the [Element]s a query matched, each by its `href` — else its `src`:
  ///
  /// ```dart
  /// ctx.follow(ctx.response.html.$('a.next'));   // pagination, whether or not there is a next
  /// ```
  ///
  /// Returns whether anything was scheduled. A target outside the crawl's scope, or with a
  /// non-http scheme, is dropped unless [offsite] is set; so is one already visited unless
  /// [revisit] is set, and an element with neither attribute. The body is at most one of [text], [bytes], [form] and [json], the same four words
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

/// A crawl you can hold, subclass and test: the five hooks of [Scrape], as methods.
///
/// `url.scrape<T>()` is the short spelling of this class, and the same engine runs both: a
/// chain is a [Crawler] whose hooks are the closures it was given. Subclass it when the crawl
/// has state of its own — a count, what it has seen, where it is writing — which is then a
/// field rather than a variable a closure captures, and a crawl that can be built in a test
/// and run against a `MockClient`.
///
/// The hooks are the chain's, with the same names, the same contexts and the same defaults:
/// [onInit] holds every setting and the seeds, [onRequest] edits a request, [onResponse]
/// handles a 2xx, [onError] decides about a failure — which is a [Left] unless it acts — and
/// [onFinish] hears the summary. Override the ones the crawl needs.
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
///     for (final b in ctx.response.html.$('.book')) {
///       if (titles.add(b.$('h2').text)) ctx.emit(Book.of(b));
///     }
///     ctx.follow(ctx.response.html.$('a.next'));
///   }
/// }
///
/// await for (final book in Books(home).run().rights) { ... }
/// ```
///
/// {@category Crawling}
abstract class Crawler<T> {
  /// The seeds the chain's receiver named; a subclass seeds in [onInit].
  final List<Request> _seeds = [];

  /// The client a chain was built on ([ClientExtensions.scrape]); `null` reads the scope's
  /// when the crawl is listened to.
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

  /// The crawl, as the stream [Scrape] is: nothing is sent until it is listened to, and each
  /// listen is a crawl of its own over the same object.
  Stream<Either<ScrapeFailure, T>> run() {
    late final StreamController<Either<ScrapeFailure, T>> controller;
    controller = StreamController(onListen: () => _run(this, controller));
    return controller.stream;
  }

  // What the engine calls. A chain answers with the closures it holds, `null` where it was
  // given none, so a hook nobody registered costs a crawl nothing — not even its context.
  InitHook<T>? get _init => onInit;
  RequestHook? get _request => onRequest;
  ResponseHook<T>? get _response => onResponse;
  ErrorHook<T>? get _error => onError;
  FinishHook? get _finish => onFinish;
}

/// The crawler a [Scrape] chain builds: the hooks it registered, and nothing of its own.
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

/// A crawl: five hooks on a chain, consumed as a stream — the short spelling of [Crawler].
///
/// It is a `Stream<Either<ScrapeFailure, T>>`, so `.rights`, `.lefts`, `.unwrap()`, `.take`
/// and `.cancellable` apply. Nothing is sent until it is listened to.
///
/// ```dart
/// final items = url.scrape<Item>()
///     .onInit((ctx) => ctx..concurrency = 8..pages = 50)
///     .onResponse((ctx) {
///       ctx.emit(parse(ctx.response));
///       ctx.follow(ctx.response.html.$('a.next'));
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

// ---------------------------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------------------------

/// Sent unless the request, [Scrape.onRequest] or the scope names one.
const _userAgent = 'dart-toolkit';

/// Identity of a request for deduplication: one 64-bit FNV-1a over the method, the URL and
/// the body. A number rather than the `Uri` and the body, because the set lives as long as the
/// crawl — a million URLs held whole was half a gigabyte — and at 64 bits two different
/// requests colliding, which would silently drop a page, is not a practical concern.
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

int _keyOf(Request req) => _key(req.method, req.url, _identity(req));

/// What makes one body another: its bytes, or for a `files:` body — whose bytes are never
/// held — its fields and each file's path and size, which is what a second upload of the same
/// form would differ in.
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

/// A body over the cap; the same on every attempt, so never retried.
final class _BodyTooLarge extends ClientException {
  const _BodyTooLarge(int cap, Uri url) : super('Response body over $cap bytes', url);
}

/// The most of a `robots.txt` that is read. RFC 9309 asks a crawler to read at least 500 KiB
/// and lets it ignore the rest, so a longer file is cut here rather than refused.
const _robotsCap = 512 * 1024;

/// The most a sitemap may be, compressed or not: the protocol's own limit is 50 MB
/// uncompressed. The file comes from the site being crawled, so it is capped like a page.
const _sitemapCap = 50 * 1024 * 1024;

/// One request waiting in the frontier.
///
/// A follow is held as its URL and the plan it was scheduled with, and becomes a [Request] —
/// headers and all — only when it is about to be sent: a frontier is mostly URLs that are
/// waiting, and a million `Request`s waiting is a lot of `Headers` nobody has read yet.
class _Item<T> {
  final Uri url;
  final _Plan<T> plan;
  final Map<String, Object?> meta;
  final int depth;

  /// A starting point the caller named. Only one of these moves the crawl's home when it
  /// redirects; a page a sitemap listed is at depth 0 too, and must not.
  final bool seed;
  Request? _request;
  int attempt = 1;
  int hops = 0;

  /// The keys of the redirect chain this item is on, the first request's included. A hop back
  /// to one of them is the chain's own business — a login that redirects to itself with a
  /// cookie — and is bounded by the hop budget rather than by the visited set.
  List<int>? chain;

  _Item(this.url, this.plan, {Request? request, this.meta = const {}, this.depth = 0, this.seed = false})
    : _request = request;

  Request get request => _request ??= Request(plan.method, url, headers: plan.headers);

  ResponseHook<T>? get onResponse => plan.onResponse;
  ErrorHook<T>? get onError => plan.onError;
  bool get revisit => plan.revisit;
  bool get offsite => plan.offsite;

  /// The dedupe key, computed without building the request when there is no body to hash.
  int get key => _request == null ? _key(plan.method.toUpperCase(), url) : _keyOf(_request!);
}

class _Host<T> {
  final Queue<_Item<T>> queue = Queue<_Item<T>>();

  /// This host's `/robots.txt`, fetched at most once; the future is shared so the
  /// requests that start together wait on one fetch rather than each making their own.
  /// `null` inside it is a site with no file, or one that could not be read.
  Future<String?>? robots;

  /// [robots] read for each `user-agent` that has asked, since the groups differ by agent.
  final Map<String, _Robots> rules = {};

  /// A gap this host asked for through `Crawl-delay`. The crawl's own [InitContext.delay]
  /// still applies; whichever is longer wins, so robots can slow a host but never hurry it.
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
  final lease = switch (crawler._client) {
    final held? => _ClientLease(held, false),
    null => _clientFor(),
  };
  // The scope's `user-agent`, which it stamps on at send time, after the engine has looked.
  final scopeAgent = lease.headers == null ? null : Headers(lease.headers)['user-agent'];

  final seedHosts = <String>{for (final s in cfg._seeds) _site(s.url.host)};
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

  // Keyed by origin — scheme, site and port — which is what robots.txt belongs to and what
  // one server is. `www.example.com` and `example.com` are one site, as they are for scope:
  // two buckets would double `perHost` and halve `delay` for any site linked both ways.
  _Host<T> hostOf(Uri url) => hosts.putIfAbsent('${url.scheme}://${_site(url.host)}:${url.port}', _Host<T>.new);

  /// A file the crawl reads for itself — robots.txt, a sitemap — as the bytes the server
  /// sent, or `null` for anything but a 2xx. Never through the frontier: it is not a page the
  /// crawl is for, and a failure to read it is not a failure of the crawl. Raw, so a browser
  /// client fetches the file rather than rendering it.
  ///
  /// At most [cap] bytes are read: past it the file is cut there when [cut], else it is
  /// `null`, like a file that could not be read.
  Future<Uint8List?> fetchOwn(Uri url, String agent, {required int cap, bool cut = false}) async {
    try {
      final request = Request('GET', url, headers: {'user-agent': agent})
        ..[Request.raw] = true
        ..[_Retry.none] = true;
      final res = await lease.client.send(request).timeout(cfg.timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.stream.timeout(cfg.timeout)) {
        if (builder.length + chunk.length > cap) {
          if (!cut) return null;
          builder.add(Uint8List.sublistView(Uint8List.fromList(chunk), 0, cap - builder.length));
          break;
        }
        builder.add(chunk);
      }
      return res.isOk ? builder.takeBytes() : null;
    } catch (_) {
      return null;
    }
  }

  /// [host]'s `/robots.txt`, fetched once. A 4xx is a site with no rules; a 5xx is a site
  /// that cannot say, and the conservative reading — refuse everything — would strand a
  /// whole crawl on one bad deploy, so both are read as open.
  Future<String?> robotsText(_Host<T> host, Uri url, String agent) => host.robots ??= fetchOwn(
    url.replace(path: '/robots.txt', query: null, fragment: null),
    agent,
    cap: _robotsCap,
    cut: true,
  ).then((bytes) => bytes == null ? null : utf8.decode(bytes, allowMalformed: true));

  /// [host]'s rules for [agent].
  Future<_Robots> robotsFor(_Host<T> host, Uri url, String agent) async {
    final text = await robotsText(host, url, agent);
    if (text == null) return _Robots.open;
    return host.rules[agent] ??= _Robots.parse(text, agent);
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
      final agent = scopeAgent ?? _userAgent;
      robotsFor(host, item.url, agent).then(
        (rules) {
          host.robotsResolved = true;
          if (rules.crawlDelay case final asked? when asked > host.gap) host.gap = asked;
          checkReady(host);
          dispatch();
        },
        onError: (Object _) {
          host.robotsResolved = true;
          checkReady(host);
          dispatch();
        },
      );
    }
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
    if (_Retry.retryAfter(res.headers) case final asked?) return asked > cfg.maxRetryAfter ? null : asked;
    return _Retry.backoff(host.backoffs++);
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
    if (!item.revisit && !visited.add(item.key)) return drop();
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
    // A follow that adds no metadata shares its parent's, which for most crawls is the one
    // empty map: a million follows would otherwise be a million copies of nothing.
    final meta = plan.meta == null && item.meta.isEmpty ? const <String, Object?>{} : {...item.meta, ...?plan.meta};
    bool one(Object target) {
      final href = switch (target) {
        Element(:final attributes) => attributes['href'] ?? attributes['src'],
        _ => target,
      };
      if (href == null) return drop();
      final url = _resolve(base, href);
      final next = _Item<T>(url, plan, meta: meta, depth: item.depth + 1);
      // A body is encoded now, so a `follow` that cannot build one fails in the hook that
      // asked, and so the body is there to be hashed for the visited set.
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

    var scheduled = false;
    if (target is Iterable<Element>) {
      for (final e in target) {
        if (one(e)) scheduled = true;
      }
    } else {
      scheduled = one(target);
    }
    dispatch();
    return scheduled;
  };

  HookFailed hookFailed(_Item<T> item, Uri url, Object e) =>
      HookFailed(url: url, request: item.request, depth: item.depth, meta: item.meta, error: e);

  /// The engine has given up on [item]: the error hook decides, else the failure is a [Left].
  Future<void> fail(_Host<T> host, _Item<T> item, ScrapeFailure failure, StackTrace st) async {
    if (stopped) {
      // The crawl is over; a request that failed in flight is not news, a hook that threw is.
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
      followFrom(item, failure.url),
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

  /// [res] answered [item], and the answer is a failure.
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

  Future<void> transportFailure(_Host<T> host, _Item<T> item, Uri url, Object e, StackTrace st) {
    if (stopped) return Future.value();
    if (_replayable(item.request.method) && !_certain(e) && item.attempt <= cfg.retries) {
      requeue(host, item, (200 * item.attempt).ms);
      return Future.value();
    }
    return fail(host, item, requestFailed(item, url, e), st);
  }

  Future<void> redirect(_Host<T> host, _Item<T> item, Request sent, Response res) {
    final location = res.headers['location']?.trim();
    if (location == null || location.isEmpty) return refuse(host, item, res);
    if (item.hops >= cfg.redirects) {
      final e = ClientException('Too many redirects', sent.url);
      return fail(host, item, requestFailed(item, sent.url, e), StackTrace.current);
    }
    final target = _page(sent.url.resolve(location));
    if (target.scheme != 'http' && target.scheme != 'https') {
      return refuse(host, item, res);
    }
    // A seed that redirects — apex to www — moves the crawl's home with it. Only a seed: a
    // page a sitemap listed is at depth 0 as well, and one that redirected off the site
    // would otherwise take the crawl with it.
    if (item.seed) {
      seedHosts.add(_site(target.host));
    } else if (!item.offsite && !inScope(target)) {
      return refuse(host, item, res);
    }

    // The same policy the client and the scope follow, and the directives go with it: a hop
    // of a rendered crawl still wants the wait the request it came from asked for.
    final next = sent._hop(target, res.statusCode);
    final key = _keyOf(next);
    final chain = item.chain ?? [_keyOf(item.request)];
    // Back to a URL of this very chain — `/login` setting a cookie and sending the browser to
    // `/login` again — is followed, and the hop budget is what stops a loop. Anywhere else
    // already visited is a page this crawl has, and is counted as the drop it is.
    if (!chain.contains(key) && !item.revisit && item.plan.onResponse == null && !visited.add(key)) {
      dropped++;
      return Future.value();
    }

    final hop = _Item<T>(next.url, item.plan, request: next, meta: item.meta, depth: item.depth, seed: item.seed)
      ..hops = item.hops + 1
      ..chain = [...chain, key];
    push(hostOf(target), hop, first: true);
    return Future.value();
  }

  Future<void> handle(_Host<T> host, _Item<T> item, Uri answered, Response res) async {
    pages++;
    final hook = item.onResponse ?? crawler._response;
    if (hook == null) return;
    running++;
    final ctx = ResponseContext<T>._(
      response: res,
      request: item.request,
      url: answered,
      depth: item.depth,
      pages: pages,
      meta: item.meta,
      emit: (value) => add(Right(value)),
      follow: followFrom(item, answered),
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
    final sent = _clone(item.request)..[_Retry.none] = true;
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

    // After the hook, so the rules read are the ones for the agent that will be announced.
    if (cfg.robots) {
      final agent = sent.headers['user-agent'] ?? scopeAgent ?? _userAgent;
      final rules = await robotsFor(host, sent.url, agent);
      if (!rules.allows(sent.url)) {
        dropped++;
        return;
      }
      // The site's own gap, where it asks for a longer one than the crawl already keeps.
      if (rules.crawlDelay case final asked? when asked > host.gap) host.gap = asked;
    }
    if (stopped) return;

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
    bytes += builder.length;

    final res = Response.bytes(
      builder.takeBytes(),
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
      final wait = replayable ? retryAfter(res, host) : _Retry.after(streamed, item.attempt, once: true);
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
    // A client that follows redirects itself — a browser does, whatever it is asked — answers
    // from somewhere other than where it was sent. That URL is the page: links resolve against
    // it, it is deduplicated, and a hop off the site is out of scope as the engine's own would be.
    final answered = _page(res.url ?? sent.url);
    if (answered != sent.url) {
      if (item.seed) {
        seedHosts.add(_site(answered.host));
      } else if (!item.offsite && !inScope(answered)) {
        return refuse(host, item, res);
      }
      if (!item.revisit && !visited.add(_key(sent.method, answered))) {
        dropped++;
        return;
      }
    }
    await handle(host, item, answered, res);
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
      ).onError((Object e, st) => add(Left(requestFailed(item, item.url, e), st))).whenComplete(() {
        host.inFlight--;
        inFlight--;
        checkReady(host);
        dispatch();
      });
    }
    if (inFlight == 0 && queued == 0 && waiting == 0 && running == 0) close();
  };

  /// Seeds the crawl from the sitemaps of [origin]'s site; see [InitContext.sitemaps].
  ///
  /// An index is read [InitContext.perHost] sitemaps at a time — one at a time under a
  /// [InitContext.delay], which is a site asking to be read slowly.
  Future<void> seedSitemaps(Uri origin) async {
    final agent = scopeAgent ?? _userAgent;
    final listed = switch (await robotsText(hostOf(origin), origin, agent)) {
      final text? => _Robots.sitemaps(text, origin),
      null => const <Uri>[],
    };
    final pending = Queue.of(listed.isEmpty ? [origin.resolve('/sitemap.xml')] : listed);
    final read = <Uri>{};
    final lanes = cfg.delay > Duration.zero ? 1 : cfg.perHost;
    final done = Completer<void>();
    var active = 0;
    late final void Function() pump;
    pump = () {
      // An index may name itself, or a thousand sitemaps; neither is a reason to run forever.
      while (active < lanes && pending.isNotEmpty && !stopped && read.length < 1000) {
        final map = pending.removeFirst();
        if (!read.add(map)) continue;
        active++;
        fetchOwn(map, agent, cap: _sitemapCap)
            .then((bytes) async {
              if (bytes == null || stopped) return;
              final (:pages, :maps) = await _sitemap(bytes, map);
              pending.addAll(maps);
              for (final page in pages) {
                enqueue(_Item<T>(_page(page), none));
              }
              dispatch();
            })
            .catchError((Object _) {})
            .whenComplete(() {
              active--;
              pump();
            });
      }
      if (active == 0 && !done.isCompleted) done.complete();
    };
    pump();
    await done.future;
  }

  for (final seed in cfg._seeds) {
    enqueue(_Item<T>(seed.url, none, request: seed, meta: cfg._seedMeta[seed.url] ?? const {}, seed: true));
  }
  if (cfg.sitemaps) {
    // `waiting` holds the crawl open while the sitemaps are read, as a retry's timer does.
    for (final origin in {for (final s in cfg._seeds) s.url.replace(path: '/', query: null, fragment: null)}) {
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
  // ^C, or whatever cancelled the scope, ends the crawl the way [HookContext.stop] does.
  unhear = token?.onCancel(stop);
  dispatch();
}

/// [url] as a page: without its fragment, and without an empty query — `/p#a`, `/p#b` and
/// `/p?` are all `/p`.
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
  String() => _page(base.resolve(target)),
  _ => throw ArgumentError.value(target, 'target', 'Must be a Uri, a String href or an Element'),
};

/// A fresh copy the engine can send once per attempt, with redirects left to it.
Request _clone(Request req) => req.copy()..followRedirects = false;

final _sitemapIndex = RegExp(r'<sitemapindex[\s>]', caseSensitive: false);
final _sitemapUrlset = RegExp(r'<urlset[\s>]', caseSensitive: false);
final _sitemapLoc = RegExp(r'<loc\b[^>]*>(.*?)</loc>', caseSensitive: false, dotAll: true);

/// The pages and the further sitemaps one sitemap names, resolved against where it came from.
///
/// A `<urlset>`'s `<url><loc>`s are pages and a `<sitemapindex>`'s `<sitemap><loc>`s are
/// sitemaps, matched by local name so a prefixed one reads the same; a gzipped file — the
/// `.xml.gz` most large sites serve — is unpacked first, and one that is not XML is read as
/// the plain-text form the protocol also allows, a URL a line. A file that cannot be read
/// names nothing.
Future<({List<Uri> pages, List<Uri> maps})> _sitemap(Uint8List bytes, Uri from) async {
  final pages = <Uri>[];
  final maps = <Uri>[];
  Uint8List? raw = bytes;
  if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in _inflated(Stream.value(bytes), _Encoding.gzip, from)) {
        if (builder.length + chunk.length > _sitemapCap) {
          raw = null;
          break;
        }
        builder.add(chunk);
      }
      if (raw != null) raw = builder.takeBytes();
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
