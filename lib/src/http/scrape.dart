part of '../../scrape.dart';

/// What reads one page: a crawl's `onResponse`, or one a follow names for its page.
typedef _OnResponse<T> = FutureOr<void> Function(ResponseContext<T> ctx);

/// What decides a page's failure: a crawl's `onError`, or one a follow names for its page.
typedef _OnError<T> = FutureOr<void> Function(ErrorContext<T> ctx);

// ---- contexts ------------------------------------------------------------------------------

/// What every crawl hook is handed: the page it is about ([url], [depth], [attempt], [meta]),
/// [stop] for the whole crawl, and the page's [Work]: `defer` a cleanup to when the page ends,
/// `step` or `warn` on its row.
///
/// {@category Crawling}
sealed class HookContext<T> implements Work {
  final _Engine<T> _engine;
  final _Page<T> _at;
  final Work _work;
  bool _closed = false;

  HookContext._(this._engine, this._at, this._work);

  /// Where the request goes, or the URL that answered.
  Uri get url;

  /// Hops from a seed; seeds are 0.
  int get depth => _at.depth;

  /// 1 for the first send of this page, more on each retry a hook asked for.
  int get attempt;

  /// What the follow that scheduled this page carried.
  Map<String, Object?> get meta => _at.meta;

  /// Ends the crawl: nothing more is sent, and the pages being read finish. A stopped crawl is a
  /// finished one: its store is cleared.
  void stop() {
    _open('stop');
    _engine.stop();
  }

  @override
  void amount(int received, {int? total, Unit unit = Unit.bytes}) => _work.amount(received, total: total, unit: unit);

  @override
  void step(String phrase) => _work.step(phrase);

  @override
  void warn(String note) => _work.warn(note);

  @override
  void defer(FutureOr<void> Function() cleanup) => _work.defer(cleanup);

  @override
  Status<Object?, Object?>? get ended => _work.ended;

  @override
  bool get isStopped => _work.isStopped;

  void _open(String what) {
    if (_closed) throw StateError('Cannot $what after the hook has returned');
  }
}

/// A request about to be sent. Edit [request] (its headers, the `user-agent`, a signature;
/// `ctx.request = ctx.request.copy(json: …)` for its body), or [skip] it.
///
/// {@category Crawling}
final class RequestContext<T> extends HookContext<T> {
  /// The request as it will be sent; reassign it to change its URL, method or body.
  Request request;

  @override
  final int attempt;

  bool _skipped = false;

  RequestContext._(super._engine, super._at, super._work, this.request, this.attempt) : super._();

  @override
  Uri get url => request.url;

  /// The headers as they will be sent.
  Headers get headers => request.headers;

  /// Sets a request directive: `ctx[Chrome.render] = Render(waitFor: '.item')`.
  void operator []=(RequestKey<Object> key, Object value) => request[key] = value;

  /// Sends nothing: the page is `Skipped(page, 'skipped')`.
  void skip() {
    _open('skip');
    _skipped = true;
  }
}

/// What a hook holding a page or a failure can do beyond reading it: [emit], [follow], [send].
mixin _Scheduling<T> on HookContext<T> {
  /// Where a relative link is resolved from.
  Uri get _base => url;

  /// Adds [item] to this page's items: `Done(page, items)` once the hooks return, and
  /// `crawl.items`.
  void emit(T item) {
    _open('emit');
    _acted();
    _items.add(item);
  }

  List<T> get _items;

  /// Schedules a GET of [url], resolved against this page (its `<base href>`, else its URL);
  /// `null` schedules nothing, so a link that may be missing reads in one expression. [meta] is
  /// carried to that page's hooks, [headers] sent with it; [onResponse] reads it and [onError]
  /// decides its failure instead of the crawl's. Answers whether it was scheduled: one already
  /// seen, too deep, not http(s) or outside `within` is not.
  ///
  /// ```dart
  /// ctx.follow(ctx.html.$('a.next').firstOrNull?.link);
  /// ctx.follow(ctx.json['next'].to<Uri?>());
  /// ```
  bool follow(
    Uri? url, {
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    FutureOr<void> Function(ResponseContext<T> ctx)? onResponse,
    FutureOr<void> Function(ErrorContext<T> ctx)? onError,
  }) {
    _open('follow');
    if (url == null) return false;
    final target = _resolve(_base, url);
    return _scheduled(Request('GET', target, headers: headers), meta, onResponse, onError);
  }

  /// Schedules [request] as it is (its method, headers and body), its URL resolved against this
  /// page: a form as a browser submits it is `ctx.send(form.submission)`. Dropped as [follow]
  /// drops.
  bool send(
    Request request, {
    Map<String, Object?>? meta,
    FutureOr<void> Function(ResponseContext<T> ctx)? onResponse,
    FutureOr<void> Function(ErrorContext<T> ctx)? onError,
  }) {
    _open('send');
    final target = _resolve(_base, request.url);
    return _scheduled(target == request.url ? request.copy() : request.copy(url: target), meta, onResponse, onError);
  }

  bool _scheduled(Request request, Map<String, Object?>? meta, _OnResponse<T>? onResponse, _OnError<T>? onError) {
    final added = meta == null || meta.isEmpty ? null : meta;
    final done = _engine.schedule(
      request,
      depth: _at.depth + 1,
      meta: added == null ? _at.meta : {..._at.meta, ...added},
      added: added,
      onResponse: onResponse,
      onError: onError,
    );
    if (done) _acted();
    return done;
  }

  void _acted() {}
}

/// The crawl's starting points, added once before anything is sent; it may be async, to read
/// them from a file or an API first.
///
/// {@category Crawling}
final class InitContext<T> {
  final _Engine<T> _engine;
  bool _closed = false;

  InitContext._(this._engine);

  /// Adds a GET of [url] as a seed; see [ResponseContext.follow].
  bool follow(
    Uri url, {
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    FutureOr<void> Function(ResponseContext<T> ctx)? onResponse,
    FutureOr<void> Function(ErrorContext<T> ctx)? onError,
  }) => send(
    Request('GET', url, headers: headers),
    meta: meta,
    onResponse: onResponse,
    onError: onError,
  );

  /// Adds [request] as a seed, sent as it is: a login POST, a search form's submission.
  bool send(
    Request request, {
    Map<String, Object?>? meta,
    FutureOr<void> Function(ResponseContext<T> ctx)? onResponse,
    FutureOr<void> Function(ErrorContext<T> ctx)? onError,
  }) {
    if (_closed) throw StateError('Cannot send after onInit has returned');
    return _engine.schedule(
      request,
      depth: 0,
      meta: meta ?? const {},
      onResponse: onResponse,
      onError: onError,
      seed: true,
    );
  }
}

/// One 2xx response, and the controls for the crawl around it.
///
/// {@category Crawling}
final class ResponseContext<T> extends HookContext<T> with _Scheduling<T> {
  /// The response; always 2xx.
  final Response response;

  /// The request as it went out.
  final Request request;

  /// The URL that answered, after redirects.
  @override
  final Uri url;

  @override
  final int attempt;

  @override
  final List<T> _items;

  Duration? _retry;

  ResponseContext._(
    super._engine,
    super._at,
    super._work,
    this.response,
    this.request,
    this.url,
    this.attempt,
    this._items,
  ) : super._();

  /// The response parsed as HTML, once however often it is read.
  Html get html => response.html;

  /// The response parsed as JSON: `ctx.follow(ctx.json['next'].to<Uri?>())`.
  Doc get json => response.json;

  /// The response parsed as XML (a feed, a sitemap); parsed once.
  Xml get xml => response.xml;

  /// The page's `<base href>`, read only once something else has parsed the HTML.
  Uri? _baseRead;

  @override
  Uri get _base {
    if (_baseRead case final read?) return read;
    final parsed = HtmlInternals.parsed(response);
    return parsed == null ? url : _baseRead = parsed.base ?? url;
  }

  /// Sends this page again after [after], dropping what this attempt emitted: a soft error
  /// behind a 200. It counts against the crawl's retry policy, a `Warned` each; past it the page
  /// fails.
  void retry({Duration after = Duration.zero}) {
    _open('retry');
    _retry = after;
  }
}

/// A page that failed: a non-2xx (a `StatusException` holding the `Response`), the network (a
/// `ClientException`), a timeout. Unless the hook acts ([retry], [ignore], [emit] or a [follow]
/// that was scheduled), the page fails with [error].
///
/// {@category Crawling}
final class ErrorContext<T> extends HookContext<T> with _Scheduling<T> {
  final Object error;
  final StackTrace stackTrace;

  /// The request that failed.
  final Request request;

  @override
  final int attempt;

  @override
  final List<T> _items;

  Duration? _retry;
  bool _decided = false;

  ErrorContext._(
    super._engine,
    super._at,
    super._work,
    this.error,
    this.stackTrace,
    this.request,
    this.attempt,
    this._items,
  ) : super._();

  @override
  Uri get url => request.url;

  /// Sends the page again after [after]; it counts against the crawl's retry policy, a `Warned`
  /// each, and past it the page fails with [error].
  void retry({Duration after = Duration.zero}) {
    _open('retry');
    _decided = true;
    _retry = after;
  }

  /// Lets the page end `Done` with what it emitted: the failure is not the crawl's.
  void ignore() {
    _open('ignore');
    _decided = true;
  }

  @override
  void _acted() => _decided = true;
}

// ---- the class form ------------------------------------------------------------------------

/// A crawl you can hold, subclass and test: `url.crawl`'s hooks as methods, and its settings as
/// the constructor's. Both run one engine; a subclass is how hooks are shared between crawls.
///
/// ```dart
/// final class Books extends Crawler<Book> {
///   final titles = <String>{};
///   Books() : super(robots: true, depth: 2);
///
///   @override
///   void onResponse(ResponseContext<Book> ctx) {
///     for (final b in ctx.html.$('.book')) {
///       if (titles.add(b.$('h2').text)) ctx.emit(Book.of(b));
///     }
///     ctx.follow(ctx.html.$('a.next').firstOrNull?.link);
///   }
/// }
///
/// await Books().run([home]).show('Books');
/// ```
///
/// {@category Crawling}
abstract class Crawler<T> {
  final int? _depth;
  final int? _pages;
  final bool _robots;
  final bool _sitemaps;
  final bool Function(Uri url)? _within;
  final Store? _store;
  final int _concurrency;
  final Uri Function(Uri url)? _canonical;

  /// The crawl's settings; the enclosing [Http.scope] supplies the rest (timeout, retries,
  /// cookies, `perHost`, `delay`), so a crawl and the calls around it share one policy.
  ///
  /// - [depth]: pages more hops than this from a seed are not followed.
  /// - [pages]: the crawl stops after this many pages answered 2xx.
  /// - [robots]: each origin's `/robots.txt` is read once and obeyed, for the `user-agent` each
  ///   request goes out with; a forbidden page is `Skipped(page, 'robots')`, and a
  ///   `Crawl-delay` spaces that host's pages. A missing or unreadable file forbids nothing.
  /// - [sitemaps]: the sitemaps of each seed's origin seed the crawl too: those robots.txt
  ///   names, else `/sitemap.xml`; indexes are followed and gzip is read.
  /// - [within]: which URLs a follow may go to; by default the seeds' hosts, `www.` or not. A
  ///   redirect out of it is `Skipped(page, 'outside')`.
  /// - [store]: the frontier and the pages seen, kept as the crawl goes: a rerun with it carries
  ///   on (its seeds added to what is left), `store.clear()` starts over, and a crawl that
  ///   finishes clears it. Under a store, `meta` must be JSON-ready, and a follow cannot carry
  ///   an `onResponse` or `onError` of its own (it is resumed with the crawl's).
  /// - [concurrency]: pages in flight in all; to one host, `Http.scope(perHost:)`, else 4.
  /// - [canonical]: what makes two URLs one page, for the seen check only:
  ///   `canonical: (u) => u.withQuery({'sid': null})`.
  Crawler({
    int? depth,
    int? pages,
    bool robots = false,
    bool sitemaps = false,
    bool Function(Uri url)? within,
    Store? store,
    int concurrency = 8,
    Uri Function(Uri url)? canonical,
  }) : _depth = depth,
       _pages = pages,
       _robots = robots,
       _sitemaps = sitemaps,
       _within = within,
       _store = store,
       _concurrency = concurrency,
       _canonical = canonical {
    if (depth != null && depth < 0) throw ArgumentError.value(depth, 'depth', 'Invalid depth, expected at least 0');
    if (pages != null && pages < 1) throw ArgumentError.value(pages, 'pages', 'Invalid pages, expected at least 1');
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'Invalid concurrency, expected at least 1');
    }
  }

  /// Once, before anything is sent: more seeds, on an [InitContext]. May be async.
  FutureOr<void> onInit(InitContext<T> ctx) {}

  /// Before every send, retries included: edit [RequestContext.request], or skip it.
  FutureOr<void> onRequest(RequestContext<T> ctx) {}

  /// On every 2xx: emit items, follow links.
  FutureOr<void> onResponse(ResponseContext<T> ctx) {}

  /// When a page failed: retry it, ignore it, emit a fallback, or let it fail.
  FutureOr<void> onError(ErrorContext<T> ctx) {}

  /// The crawl from [seeds] (GETs), started at once, with the scope's settings where it is
  /// called. Each run is a crawl of its own.
  Crawl<T> run(Iterable<Uri> seeds) => Crawl._(_Engine<T>(this, [for (final url in seeds) Request('GET', url)]));

  // What the engine calls: `null` for a hook nobody wrote, so it costs nothing, not even its
  // context. A subclass's methods are always called.
  FutureOr<void> Function(InitContext<T>)? get _init => onInit;
  FutureOr<void> Function(RequestContext<T>)? get _request => onRequest;
  FutureOr<void> Function(ResponseContext<T>)? get _response => onResponse;
  FutureOr<void> Function(ErrorContext<T>)? get _error => onError;
}

/// The crawler `url.crawl` builds: its named hooks, a missing one costing nothing.
final class _Hooked<T> extends Crawler<T> {
  @override
  final FutureOr<void> Function(InitContext<T>)? _init;
  @override
  final FutureOr<void> Function(RequestContext<T>)? _request;
  @override
  final FutureOr<void> Function(ResponseContext<T>)? _response;
  @override
  final FutureOr<void> Function(ErrorContext<T>)? _error;

  _Hooked(
    this._init,
    this._request,
    this._response,
    this._error, {
    required super.depth,
    required super.pages,
    required super.robots,
    required super.sitemaps,
    required super.within,
    required super.store,
    required super.concurrency,
    required super.canonical,
  });
}

/// Crawling from a URL.
///
/// {@category Crawling}
extension UriCrawl on Uri {
  /// A crawl seeded here: a [Crawl], a `Batch` of pages, started at once. The settings and
  /// hooks are [Crawler]'s: [onInit] adds seeds, [onRequest] edits or skips a send,
  /// [onResponse] reads each 2xx, [onError] decides a failure.
  ///
  /// ```dart
  /// final crawl = url.crawl<Item>(
  ///   depth: 3, pages: 500, robots: true, store: app / 'crawl',
  ///   onResponse: (ctx) {
  ///     for (final a in ctx.html.$('h2 a')) ctx.emit(Item(a.text, a.link));
  ///     ctx.follow(ctx.html.$('.next').firstOrNull?.link);
  ///   },
  /// );
  /// await crawl.show('Crawling');
  /// final items = await crawl.items.toList();
  /// ```
  Crawl<T> crawl<T>({
    int? depth,
    int? pages,
    bool robots = false,
    bool sitemaps = false,
    bool Function(Uri url)? within,
    Store? store,
    int concurrency = 8,
    Uri Function(Uri url)? canonical,
    FutureOr<void> Function(InitContext<T> ctx)? onInit,
    FutureOr<void> Function(RequestContext<T> ctx)? onRequest,
    FutureOr<void> Function(ResponseContext<T> ctx)? onResponse,
    FutureOr<void> Function(ErrorContext<T> ctx)? onError,
  }) => _Hooked<T>(
    onInit,
    onRequest,
    onResponse,
    onError,
    depth: depth,
    pages: pages,
    robots: robots,
    sitemaps: sitemaps,
    within: within,
    store: store,
    concurrency: concurrency,
    canonical: canonical,
  ).run([this]);
}

// ---- the crawl -----------------------------------------------------------------------------

/// A crawl under way: a `Batch` of pages. Each page is `Running(page)` while it is fetched and
/// read, `Done(page, items)` once its hooks finish (a page with no items too),
/// `Skipped(page, 'robots')` or `('outside')`, or `Failed`; every retry is a `Warned`. [items]
/// is what the hooks emitted, page after page. `count` is known once nothing more follows.
///
/// Awaited, every page's items in the order the pages were taken, or a `BatchException`
/// holding the pages that failed.
///
/// {@category Crawling}
final class Crawl<T> implements Batch<Uri, List<T>> {
  final _Engine<T> _engine;
  late final Batch<_Page<T>, List<T>> _pages = _engine.pages().parallelize(
    _engine.visit,
    concurrency: _engine.crawler._concurrency,
  );
  late final Future<List<List<T>>> _done = _pages.then<List<List<T>>>(
    (values) => values,
    onError: (Object e, StackTrace st) {
      if (e is! BatchException<_Page<T>, List<T>>) Error.throwWithStackTrace(e, st);
      final failures = [
        for (final failure in e.failures)
          if (failure.error is! _Skip) _about(failure) as Failed<Uri, List<T>>,
      ];
      if (failures.isEmpty) return e.values;
      Error.throwWithStackTrace(BatchException<Uri, List<T>>(failures, e.values, e.count), st);
    },
  );

  Crawl._(this._engine) {
    // Started at once, and its pages' failures handled here: a skipped page is no failure.
    _done;
  }

  /// Every item the hooks emitted, page by page as each finishes; a listener that comes late
  /// hears those so far first. It ends with the crawl: with its [BatchException] when a page
  /// failed (a page skipped by robots or `within` is no failure), so whatever is chained on the
  /// items fails too rather than finishing short.
  Stream<T> get items {
    StreamSubscription<List<T>>? pages;
    late final StreamController<T> out;
    out = StreamController<T>(
      sync: true,
      onListen: () {
        pages = _pages.values.listen(
          (page) {
            for (final item in page) {
              out.add(item);
            }
          },
          onError: out.addError,
          onDone: () async {
            final statuses = await settled;
            final failures = [
              for (final s in statuses)
                if (s is Failed<Uri, List<T>>) s,
            ];
            if (failures.isNotEmpty) {
              final values = [
                for (final s in statuses)
                  if (s case Done(:final value)) value,
              ];
              out.addError(BatchException<Uri, List<T>>(failures, values, statuses.length));
            }
            await out.close();
          },
        );
      },
      onPause: () => pages?.pause(),
      onResume: () => pages?.resume(),
      onCancel: () => pages?.cancel(),
    );
    return out.stream;
  }

  static Status<Uri, List<T>> _aboutPage<T>(Status<_Page<T>, List<T>> status) => switch (status) {
    Failed(:final item, error: _Skip(:final reason)) => Skipped(item.url, reason, label: status.label),
    _ => StatusInternals.about(status, status.item.url, status.label),
  };

  Status<Uri, List<T>> _about(Status<_Page<T>, List<T>> status) => _aboutPage(status);

  @override
  int? get count => _pages.count;

  @override
  Stream<Status<Uri, List<T>>> get statuses => _pages.statuses.map(_about);

  @override
  Stream<List<T>> get values => _pages.values;

  @override
  Future<List<Status<Uri, List<T>>>> get settled {
    _done.ignore();
    return _pages.settled.then((all) => [for (final s in all) _about(s)]);
  }

  @override
  Future<Map<Uri, List<T>>> toMap() async {
    await _done;
    return {
      for (final status in await settled)
        if (status case Done(:final item, :final value)) item: value,
    };
  }

  @override
  void cancel([String reason = 'cancelled']) {
    _engine.cancel();
    _pages.cancel(reason);
  }

  @override
  Stream<List<List<T>>> asStream() => _done.asStream();

  @override
  Future<List<List<T>>> catchError(Function onError, {bool Function(Object error)? test}) =>
      _done.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(List<List<T>> value) onValue, {Function? onError}) =>
      _done.then(onValue, onError: onError);

  @override
  Future<List<List<T>>> timeout(Duration timeLimit, {FutureOr<List<List<T>>> Function()? onTimeout}) =>
      _done.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<List<List<T>>> whenComplete(FutureOr<void> Function() action) => _done.whenComplete(action);

  @override
  String toString() => 'Crawl(${_pages.count ?? '?'} pages)';
}

/// A page deliberately not read: robots forbade it, it led outside, a hook skipped it.
final class _Skip implements Exception {
  final String reason;
  const _Skip(this.reason);

  @override
  String toString() => reason;
}

/// One page waiting in the frontier or being read: its request (and redirect chain), where it
/// came from, and the hooks of its own that read it, if any. Once read it keeps only its [url]
/// and [depth]: a finished page is a crawl's `Done` until the crawl ends.
final class _Page<T> {
  /// `null` once the page has been read.
  Request? request;
  final Uri url;
  final int depth;
  Map<String, Object?> meta;
  _OnResponse<T>? onResponse;
  _OnError<T>? onError;

  /// A seed the caller named: only it moves the crawl's home when it redirects.
  final bool seed;

  /// Its id in the store, when there is one.
  int? id;

  _Page(
    Request this.request, {
    required this.depth,
    required this.meta,
    this.onResponse,
    this.onError,
    this.seed = false,
  }) : url = request.url;

  /// Lets go of what only reading the page needed.
  void _spend() {
    request = null;
    meta = const {};
    onResponse = null;
    onError = null;
  }

  @override
  String toString() => '$url';
}

/// One host's share of the frontier.
final class _Host<T> {
  final queue = Queue<_Page<T>>();
  int inFlight = 0;

  /// `Crawl-delay` from robots.txt.
  Duration gap = Duration.zero;

  /// When the next page may go, on the crawl's clock: a `Crawl-delay` or a `Retry-After`.
  Duration readyAt = Duration.zero;

  /// Whether robots.txt has been read, when the crawl obeys it.
  bool robotsKnown = false;
  bool robotsAsked = false;

  /// Whether it is in the engine's ready queue: a flag, so a push never scans the queue.
  bool ready = false;
}

/// RFC 9309 asks for at least 500 KiB of a `robots.txt`; a longer one is cut, not refused.
const _robotsCap = 512 * 1024;

/// The sitemap protocol's own limit, applied compressed or not.
const _sitemapCap = 50 * 1024 * 1024;

/// The most of a page's body read before it fails.
const _bodyCap = 32 << 20;

/// Sent when the request, `onRequest`, the scope and the client name no `user-agent`.
const _userAgent = 'dart-toolkit';

final class _Engine<T> {
  final Crawler<T> crawler;
  final List<Request> _seeds;
  final Object _settings = HttpInternals.settings();

  _Engine(this.crawler, this._seeds) {
    final token = Cancel.token;
    if (token != null) _unhear = token.onCancel(cancel);
  }

  void Function()? _unhear;
  final _hosts = <String, _Host<T>>{};
  final _ready = Queue<_Host<T>>();
  final _visited = <int>{};
  final _seedHosts = <String>{};
  final _robotsFiles = <String, Future<_RobotsTxt?>>{};
  final _rules = <(String, String), _Robots>{};
  final _backlog = Queue<Uri>();
  _Journal? _journal;
  Completer<void>? _wake;
  Completer<void>? _unlock;

  var _inFlight = 0;
  var _queued = 0;

  /// Robots files and sitemaps being read: the crawl stays open for them.
  var _busy = 0;

  /// Pages answered 2xx and read.
  var _handled = 0;
  var _stopped = false;
  var _cancelled = false;
  String _agent = _userAgent;

  int get _perHost => HttpInternals.perHost(_settings) ?? 4;

  void stop() {
    if (_stopped) return;
    _stopped = true;
    for (final host in _hosts.values) {
      _queued -= host.queue.length;
      host
        ..queue.clear()
        ..ready = false;
    }
    _ready.clear();
    _backlog.clear();
    _journal?.flush();
    _notify();
  }

  void cancel() {
    _cancelled = true;
    _notify();
  }

  void _notify() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  // ---- the frontier ------------------------------------------------------------------------

  /// The pages in the order they may go: a page only when its host has room and is due, so a
  /// slot is never held waiting. It ends when nothing is queued, in flight, or being read.
  Stream<_Page<T>> pages() async* {
    try {
      await _begin();
      while (true) {
        final next = await _next();
        if (next == null) break;
        yield next;
      }
      if (!_cancelled) {
        // Finished: the store is cleared, so the next run starts over.
        await _journal?.erase();
      }
    } finally {
      await _journal?.close();
      _unlock?.complete();
      _unhear?.call();
    }
  }

  Future<void> _begin() async {
    final store = crawler._store;
    if (store != null) {
      final locked = Completer<void>();
      _unlock = Completer<void>();
      unawaited(
        store.lock(() {
          locked.complete();
          return _unlock!.future;
        }),
      );
      await locked.future;
      final journal = _journal = _Journal(store, () => _handled);
      final saved = await journal.read();
      if (saved != null) {
        _visited.addAll(saved.visited);
        _handled = saved.pages;
      }
      final frontier = saved?.frontier ?? const [];
      final ids = await journal.start(_visited, frontier);
      for (var i = 0; i < frontier.length; i++) {
        _push(_thawed(frontier[i])..id = ids[i]);
      }
    }
    final defaulted = await HttpInternals.agent(_settings);
    if (defaulted != null) _agent = defaulted;
    for (final seed in _seeds) {
      schedule(seed, depth: 0, meta: const {}, seed: true);
    }
    if (crawler._init case final init?) {
      final ctx = InitContext<T>._(this);
      try {
        await init(ctx);
      } finally {
        ctx._closed = true;
      }
    }
    if (crawler._sitemaps) {
      for (final origin in {
        for (final s in _seeds) Uri(scheme: s.url.scheme, host: s.url.host, port: s.url.port, path: '/'),
      }) {
        _busy++;
        unawaited(
          _readSitemaps(origin).catchError((Object _) {}).whenComplete(() {
            // a sitemap that fails adds no pages; the crawl goes on
            _busy--;
            _notify();
          }),
        );
      }
    }
  }

  /// The next page that may go now, waiting until one may; `null` once the crawl is over.
  Future<_Page<T>?> _next() async {
    while (true) {
      if (_cancelled) return _over();
      final budget = crawler._pages;
      if (budget != null && _handled >= budget) stop();
      if (_stopped) {
        if (_inFlight == 0) return _over();
        await _waitFor(null);
        continue;
      }
      _refill();
      Duration? soonest;
      if (budget == null || _handled + _inFlight < budget) {
        final now = Clock.current.elapsed;
        for (var tried = _ready.length; tried > 0; tried--) {
          final host = _ready.removeFirst();
          if (host.queue.isEmpty) {
            host.ready = false;
            continue;
          }
          _ready.add(host);
          if (host.inFlight >= _perHost || (crawler._robots && !host.robotsKnown)) continue;
          final page = host.queue.first;
          var due = host.readyAt - now;
          final limited = HttpInternals.dueIn(_settings, page.url);
          if (limited > due) due = limited;
          if (limited > Duration.zero) _hearRoom(page.url);
          if (due > Duration.zero) {
            if (soonest == null || due < soonest) soonest = due;
            continue;
          }
          host.queue.removeFirst();
          _queued--;
          host.inFlight++;
          _inFlight++;
          if (host.gap > Duration.zero) {
            final next = host.gap.jittered();
            host.readyAt = now + (next < host.gap ? host.gap : next);
          }
          return page;
        }
      }
      if (_queued == 0 && _inFlight == 0 && _busy == 0 && _backlog.isEmpty) return _over();
      await _waitFor(soonest);
    }
  }

  /// Hosts whose per-host permits wake the frontier when they free.
  final _heard = <String, void Function()>{};

  /// The crawl is over: nothing is listened to any more.
  _Page<T>? _over() {
    for (final stop in _heard.values) {
      stop();
    }
    _heard.clear();
    return null;
  }

  void _hearRoom(Uri url) => _heard.putIfAbsent(_origin(url), () => HttpInternals.onRoom(_settings, url, _notify));

  /// Until something changes, or [after] passes.
  Future<void> _waitFor(Duration? after) {
    final wake = _wake ??= Completer<void>();
    if (after == null) return wake.future;
    final timer = Timer(after, _notify);
    return wake.future.whenComplete(timer.cancel);
  }

  /// Sitemap pages into the frontier, as much as it can use: a 50k-page sitemap crawled for 50
  /// pages never holds 50k requests.
  void _refill() {
    while (_backlog.isNotEmpty && _queued < crawler._concurrency * 4) {
      schedule(Request('GET', _page(_backlog.removeFirst())), depth: 0, meta: const {});
    }
  }

  _Host<T> _hostOf(Uri url) => _hosts.putIfAbsent(_origin(url), _Host<T>.new);

  void _push(_Page<T> page, {bool first = false}) {
    final host = _hostOf(page.url);
    first ? host.queue.addFirst(page) : host.queue.add(page);
    _queued++;
    if (!host.ready) _ready.add(host..ready = true);
    if (crawler._robots && !host.robotsAsked) {
      host.robotsAsked = true;
      _busy++;
      _robotsFor(page.url, _agent)
          .then((rules) {
            _slow(host, rules);
          }, onError: (Object _) {})
          .whenComplete(() {
            // unreadable: it forbids nothing
            host.robotsKnown = true;
            _busy--;
            _notify();
          });
    }
    _notify();
  }

  /// Schedules [request] unless it is too deep, not http(s), outside `within`, or seen. Under a
  /// store, [added] (the part of [meta] this follow brings; all of it when not given) is checked
  /// to be JSON-ready: what it inherits was checked when its page was scheduled.
  bool schedule(
    Request request, {
    required int depth,
    required Map<String, Object?> meta,
    Map<String, Object?>? added,
    _OnResponse<T>? onResponse,
    _OnError<T>? onError,
    bool seed = false,
  }) {
    if (_stopped || _cancelled) return false;
    if (_journal != null) {
      if (onResponse != null || onError != null) {
        throw ArgumentError.value(
          onResponse ?? onError,
          onResponse != null ? 'onResponse' : 'onError',
          'Invalid follow: a crawl with a store resumes its pages with its own hooks; route by meta instead',
        );
      }
      _jsonReady(added ?? meta);
    }
    final url = _page(request.url);
    final page = _Page<T>(
      request.url == url ? request : request.copy(url: url),
      depth: depth,
      meta: meta,
      onResponse: onResponse,
      onError: onError,
      seed: seed,
    );
    if (crawler._depth case final most? when depth > most) return false;
    if (url.scheme != 'http' && url.scheme != 'https') return false;
    if (seed) {
      _seedHosts.add(_site(url.host));
    } else if (!_within(url)) {
      return false;
    }
    final key = _keyOf(page.request!);
    if (!_visited.add(key)) return false;
    if (_journal case final journal?) page.id = journal.queued(_frozen(page), key);
    _push(page);
    return true;
  }

  bool _within(Uri url) => crawler._within?.call(url) ?? _seedHosts.contains(_site(url.host));

  int _keyOf(Request request) {
    final canonical = crawler._canonical;
    final url = canonical == null ? request.url : _page(canonical(request.url));
    return _key(request.method, url, MessageInternals.identity(request));
  }

  // ---- a page --------------------------------------------------------------------------------

  /// [page] read: sent (its redirects followed), its hooks run, as a task of its own whose work
  /// the contexts carry.
  Task<List<T>> visit(_Page<T> page) => TaskInternals.start(page.url, HttpInternals.label(page.url), (work) async {
    final host = _hostOf(page.url);
    try {
      return await _read(page, host, work);
    } finally {
      host.inFlight--;
      _inFlight--;
      if (!_cancelled && page.id != null) _journal?.done(page.id!);
      page._spend();
      _notify();
    }
  });

  Future<List<T>> _read(_Page<T> page, _Host<T> host, Work work) async {
    final policy = HttpInternals.retry(_settings);
    final items = <T>[];
    var current = page.request!;
    var hops = 0;
    final chain = <int>[_keyOf(current)];
    for (var attempt = 1; ;) {
      items.clear();
      var sent = current.copy()..followRedirects = false;
      if (!sent.headers.containsKey('user-agent')) sent.headers['user-agent'] = _agent;
      final onRequest = crawler._request;
      if (onRequest != null) {
        final ctx = RequestContext<T>._(this, page, work, sent, attempt);
        try {
          await onRequest(ctx);
        } finally {
          ctx._closed = true;
        }
        if (ctx._skipped) throw const _Skip('skipped');
        sent = ctx.request..followRedirects = false;
      }
      if (crawler._robots) {
        // The rules for the agent that will be announced.
        final rules = await _robotsFor(sent.url, sent.headers['user-agent'] ?? _agent);
        if (!rules.allows(sent.url)) throw const _Skip('robots');
        _slow(_hostOf(sent.url), rules);
      }
      Response? res;
      Object? error;
      StackTrace trace = StackTrace.empty;
      try {
        res = await HttpInternals.retrying(
          _settings,
          sent,
          () => _fetch(sent, work),
          step: work.step,
          onWait: (wait) {
            // The server asked the whole host to wait.
            final until = Clock.current.elapsed + wait;
            if (until > host.readyAt) host.readyAt = until;
          },
        );
      } on CancelledException {
        rethrow;
      } on Exception catch (e, st) {
        error = e;
        trace = st;
      }

      if (res != null && res.statusCode >= 300 && res.statusCode < 400) {
        Uri? to;
        try {
          to = HttpInternals.redirect(res.statusCode, res.headers, sent.url);
        } on FormatException catch (e, st) {
          error = e;
          trace = st;
          res = null;
        }
        if (res != null) {
          if (to == null) {
            error = StatusException(res);
            trace = StackTrace.current;
            res = null;
          } else {
            final target = _page(to);
            if (hops >= sent.redirects) throw ClientException('More than ${sent.redirects} redirects', page.url);
            if (target.scheme != 'http' && target.scheme != 'https') throw const _Skip('outside');
            if (page.seed && crawler._within == null) {
              // A seed that moves (apex to www) takes the crawl's home with it.
              _seedHosts.add(_site(target.host));
            } else if (!_within(target)) {
              throw const _Skip('outside');
            }
            final next = HttpInternals.hop(sent, target, res.statusCode);
            final key = _keyOf(next);
            // A hop back into this chain is followed (a login redirecting to itself with a
            // cookie); one to a page seen elsewhere ends this one, read there.
            if (!chain.contains(key) && page.onResponse == null && page.onError == null) {
              if (!_visited.add(key)) return items;
              _journal?.visited(key);
            }
            chain.add(key);
            current = next;
            hops++;
            continue;
          }
        }
      }

      if (res != null) {
        final answered = _page(res.url ?? sent.url);
        // A client that redirects itself (a browser) answers from elsewhere.
        if (answered != _page(sent.url) && !page.seed && !_within(answered)) throw const _Skip('outside');
        final onResponse = page.onResponse ?? crawler._response;
        _handled++;
        if (onResponse == null) return items;
        final ctx = ResponseContext<T>._(this, page, work, res, sent, answered, attempt, items);
        try {
          await onResponse(ctx);
        } finally {
          ctx._closed = true;
        }
        if (ctx._retry case final after?) {
          _handled--;
          attempt = await _again(policy, attempt, after, 'retry asked by onResponse', work, page);
          continue;
        }
        return items;
      }

      final onError = page.onError ?? crawler._error;
      if (onError == null) Error.throwWithStackTrace(error!, trace);
      final ctx = ErrorContext<T>._(this, page, work, error!, trace, sent, attempt, items);
      try {
        await onError(ctx);
      } finally {
        ctx._closed = true;
      }
      if (ctx._retry case final after?) {
        attempt = await _again(policy, attempt, after, error, work, page, trace: trace);
        continue;
      }
      if (ctx._decided) return items;
      Error.throwWithStackTrace(error, trace);
    }
  }

  /// One send of [request]: a redirect as it is (its body dropped), a 2xx with its body, any
  /// other status a [StatusException].
  Future<Response> _fetch(Request request, Work work) async {
    final res = await HttpInternals.exchange(_settings, request, step: work.step);
    if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.containsKey('location')) {
      unawaited(HttpInternals.drain(res));
      return Response.bytes(const [], res.statusCode, headers: res.headers, request: request, url: res.url);
    }
    if (!res.isOk) throw await HttpInternals.refused(res, request);
    final body = await HttpInternals.readCapped(res, cap: _bodyCap, url: request.url);
    return Response.bytes(
      body,
      res.statusCode,
      headers: res.headers,
      request: request,
      url: res.url,
      reasonPhrase: res.reasonPhrase,
    );
  }

  /// The next attempt after a hook's retry, once [after] has passed, a `Warned` on the page; past
  /// [policy]'s tries the page fails with [cause].
  Future<int> _again(
    Retry policy,
    int attempt,
    Duration after,
    Object cause,
    Work work,
    _Page<T> page, {
    StackTrace? trace,
  }) async {
    if (attempt > policy.times) {
      if (cause is String) throw ClientException('Gave up after $attempt tries: $cause', page.url);
      Error.throwWithStackTrace(cause, trace ?? StackTrace.current);
    }
    TaskInternals.warn(RetryWarning(attempt, policy.times, after, cause));
    work.step('retry $attempt/${policy.times}');
    if (after > Duration.zero) await after.delay();
    return attempt + 1;
  }

  // ---- robots.txt and sitemaps ---------------------------------------------------------------

  /// A file the crawl reads for itself (robots.txt, a sitemap), raw, capped at [cap] (cut there
  /// when [cut]); `null` for a non-2xx or any failure.
  Future<Uint8List?> _own(Uri url, String agent, {required int cap, bool cut = false}) async {
    final request = Request('GET', url, headers: {'user-agent': agent})..[Request.raw] = true;
    final StreamedResponse res;
    try {
      res = await HttpInternals.exchange(_settings, request);
    } on Exception catch (_) {
      return null; // unreachable: as good as none
    }
    if (!res.isOk) {
      unawaited(HttpInternals.drain(res).catchError((Object _) {})); // best-effort: draining only frees the connection
      return null;
    }
    try {
      return await HttpInternals.readCapped(res, cap: cap, url: url, cut: cut);
    } on Exception catch (_) {
      return null; // cut off: as good as none
    }
  }

  /// [url]'s origin's robots.txt, read once. A 5xx reads as open too: refusing everything would
  /// strand a crawl on one bad deploy.
  Future<_RobotsTxt?> _robotsTxt(Uri url) {
    final site = Uri(scheme: url.scheme, host: url.host, port: url.port, path: '/robots.txt');
    return _robotsFiles[_origin(url)] ??= _own(
      site,
      _agent,
      cap: _robotsCap,
      cut: true,
    ).then((bytes) => bytes == null ? null : _RobotsTxt.parse(utf8.decode(bytes, allowMalformed: true), site));
  }

  Future<_Robots> _robotsFor(Uri url, String agent) async {
    final file = await _robotsTxt(url);
    if (file == null) return _Robots.open;
    return _rules[(_origin(url), agent)] ??= file.forAgent(agent);
  }

  void _slow(_Host<T> host, _Robots rules) {
    if (rules.crawlDelay case final asked? when asked > host.gap) host.gap = asked;
  }

  /// Seeds the crawl from [origin]'s sitemaps: those its robots.txt names, else `/sitemap.xml`;
  /// indexes followed, at most a thousand sitemaps.
  Future<void> _readSitemaps(Uri origin) async {
    final listed = (await _robotsTxt(origin))?.sitemaps ?? const <Uri>[];
    final pending = Queue.of(listed.isEmpty ? [origin.resolve('/sitemap.xml')] : listed);
    final read = <Uri>{};
    while (pending.isNotEmpty && !_stopped && !_cancelled && read.length < 1000) {
      final map = pending.removeFirst();
      if (!read.add(map)) continue;
      final bytes = await _own(map, _agent, cap: _sitemapCap);
      if (bytes == null) continue;
      final (:pages, :maps) = await _sitemap(bytes, map);
      pending.addAll(maps);
      _backlog.addAll(pages);
      _notify();
    }
  }
}

/// [meta], checked to come back from JSON as it is: an [ArgumentError] naming the key that would
/// not.
void _jsonReady(Map<String, Object?> meta) {
  for (final MapEntry(:key, :value) in meta.entries) {
    try {
      final encoded = jsonEncode(value);
      if (jsonEncode(jsonDecode(encoded)) != encoded) throw const FormatException();
    } catch (_) {
      throw ArgumentError.value(
        value,
        'meta',
        'Invalid meta "$key": a crawl with a store keeps JSON-ready values only',
      );
    }
  }
}

/// [page] as a store entry: everything a later run needs to send it again, body included.
Map<String, Object?> _frozen<T>(_Page<T> page) {
  final request = page.request!;
  return {
    'url': '${request.url}',
    'method': request.method,
    'depth': page.depth,
    if (page.meta.isNotEmpty) 'meta': page.meta,
    if (request.headers.isNotEmpty) 'headers': Map<String, String>.of(request.headers),
    if (MessageInternals.freeze(request) case final body when body.isNotEmpty) 'body': body,
    if (page.seed) 'seed': true,
  };
}

/// The page [entry] froze, as [_frozen] wrote it.
_Page<T> _thawed<T>(Map<String, Object?> entry) {
  final request = MessageInternals.thaw(
    entry['method'] as String? ?? 'GET',
    Uri.parse(entry['url']! as String),
    (entry['headers'] as Map?)?.cast<String, String>(),
    (entry['body'] as Map?)?.cast<String, Object?>() ?? const {},
  );
  return _Page<T>(
    request,
    depth: entry['depth'] as int? ?? 0,
    meta: (entry['meta'] as Map?)?.cast<String, Object?>() ?? const {},
    seed: entry['seed'] == true,
  );
}

/// [url]'s origin: robots.txt and a host's share of the frontier belong to one.
String _origin(Uri url) => HttpInternals.origin(url);

/// A host with or without its `www.`: the default `within` treats them as one site.
String _site(String host) {
  final lower = host.toLowerCase();
  return lower.startsWith('www.') ? lower.substring(4) : lower;
}

/// A request's identity for the seen check: 64-bit FNV-1a over method, URL and body. A number,
/// because the set lives as long as the crawl: a million URLs held whole was half a gigabyte.
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

/// [url] as a page: `/p#a`, `/p#b` and `/p?` are all `/p`.
Uri _page(Uri url) {
  url = url.removeFragment();
  if (url.hasAuthority && url.path.isEmpty) url = url.replace(path: '/');
  if (!url.hasQuery || url.query.isNotEmpty) return url;
  final text = '$url';
  return Uri.parse(text.substring(0, text.length - 1));
}

/// [target] against [base], as a page; see [_page].
Uri _resolve(Uri base, Uri target) => _page(base.resolveUri(target));

final _sitemapIndex = RegExp(r'<sitemapindex[\s>]', caseSensitive: false);
final _sitemapUrlset = RegExp(r'<urlset[\s>]', caseSensitive: false);
final _sitemapLoc = RegExp(r'<loc\b[^>]*>(.*?)</loc>', caseSensitive: false, dotAll: true);

/// XML's five named entities and its character references: all a `<loc>` holds (`&amp;` in
/// nearly every URL with a query), so a 50k-URL sitemap is not 50k HTML parses.
final _xmlEntity = RegExp('&(amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);');

String _entity(Match m) => switch (m[1]!) {
  'amp' => '&',
  'lt' => '<',
  'gt' => '>',
  'quot' => '"',
  'apos' => "'",
  final ref => switch (int.tryParse(
    ref[1] == 'x' ? ref.substring(2) : ref.substring(1),
    radix: ref[1] == 'x' ? 16 : 10,
  )) {
    final code? when code > 0 && code <= 0x10ffff => String.fromCharCode(code),
    _ => m[0]!,
  },
};

/// The pages and sitemaps one sitemap names: `<urlset>` locs are pages, `<sitemapindex>` locs
/// sitemaps; gzip is unpacked, and non-XML is the plain-text form, a URL a line.
Future<({List<Uri> pages, List<Uri> maps})> _sitemap(Uint8List bytes, Uri from) async {
  final pages = <Uri>[];
  final maps = <Uri>[];
  Uint8List? raw = bytes;
  if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    try {
      final out = BytesBuilder(copy: false);
      await for (final chunk in Stream<List<int>>.value(bytes).transform(gzip.decoder)) {
        out.add(chunk);
        if (out.length > _sitemapCap) throw const FormatException('sitemap over the protocol limit');
      }
      raw = out.takeBytes();
    } on Exception catch (_) {
      raw = null; // corrupt, cut short or too large: it names nothing
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
      } else if (loc.contains('<')) {
        // Stray markup needs the HTML decoder; a plain URL is already its own text.
        loc = Html.parse(loc).text;
      } else if (loc.contains('&')) {
        loc = loc.replaceAllMapped(_xmlEntity, _entity);
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
