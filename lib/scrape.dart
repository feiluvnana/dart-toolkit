/// Crawling: a queue, workers, retries, a cache, typed records out.
/// Composes `http`, `html` and `chrome` from this package plus an in-house
/// queue (about 200 lines).
///
/// ```dart
/// final albums = await Scrape.crawl<Album>(starts, listing,
///     perHostDelay: Duration(milliseconds: 250), cacheDir: '.cache/shop').toList();
/// Future<void> listing(Visit<Album> v) async {
///   final doc = await v.html();
///   v.follow(doc.$('a[href*="detail"]').attrs('href'), album);
/// }
/// ```
///
/// Public surface is exactly: [Scrape], [Visit].
/// - `Scrape.crawl()` visits start URLs and returns a `Stream` of records.
/// - [Visit] (a [Reader] of the page body) supports `finalUrl` `statusCode`
///   `isSuccess` `contentLength` `fileName` `follow` `emit`, mirroring the
///   `http.Response` names.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'chrome.dart';
import 'fs.dart';
import 'hash.dart';
import 'http.dart';

// Direct dependency on core (Origin/Reader) even though chrome.dart
// re-exports it.
// ignore: unnecessary_import
import 'core.dart';

import 'src/charset.dart' as charset;
import 'src/origin.dart' as names;
import 'src/retry.dart' as retry;

export 'core.dart';
export 'html.dart';

/// Entry point: crawl start URLs with a handler per kind of page.
abstract final class Scrape {
  /// Visit [urls] with [handler]; return a `Stream<T>` of every emitted
  /// record, in emission order. The stream completes when the queue is empty
  /// and every handler has returned. Cancelling the subscription stops the
  /// crawl: nothing new starts, visits in flight are dropped.
  ///
  /// Up to [concurrency] workers fetch at once; [perHostDelay] spaces
  /// requests to one host. Routing is by function: [Visit.follow] queues
  /// URLs for a handler. Each URL is visited once (absolute, fragment
  /// dropped). A 404 reaches its handler. Failures end the run, rethrown
  /// from the stream, unless [onError] reports the URL and the crawl goes on
  /// without that page. In HTTP mode the shared client is held for the crawl
  /// lifetime (see [Http.hold]); in browser mode [concurrency] tabs are kept
  /// and reused with `goTo` instead of opening one tab per URL.
  static Stream<T> crawl<T>(
    Iterable<String> urls,
    Future<void> Function(Visit<T> visit) handler, {
    int concurrency = 4,
    Duration? perHostDelay,
    int retries = 2,
    String? cacheDir,
    Map<String, String>? headers,
    Duration? timeout,
    Browser? browser,
    void Function(String url, Object error)? onError,
  }) {
    if (concurrency < 1) {
      throw ArgumentError.value(
          concurrency, 'concurrency', 'must be at least 1');
    }
    if (retries < 0) {
      throw ArgumentError.value(retries, 'retries', 'must not be negative');
    }
    final controller = StreamController<T>();
    final crawl = _Crawl<T>(
      concurrency: concurrency,
      perHostDelay: perHostDelay,
      retries: retries,
      cacheDir: cacheDir,
      headers: headers,
      timeout: timeout,
      browser: browser,
      onError: onError,
      out: controller,
    );
    controller.onListen = () {
      crawl.start(urls, handler);
    };
    controller
      ..onPause = crawl.pause
      ..onResume = crawl.resume
      ..onCancel = crawl.cancel;
    return controller.stream;
  }
}

/// One page being handled: a [Reader] of its body, so `html()` (with the
/// final URL as the base), `json()`, `text()` and `> file` mean what they
/// mean everywhere. With a [browser], `html()` is the rendered DOM snapshot
/// taken at fetch, parsed once. Reads return unmodifiable views of the one
/// in-memory body: O(1), no copy per read.
final class Visit<T> with Reader {
  Visit._http(this._url, this._status, this._body, this._crawl,
      this._contentType, this._disposition)
      : _dom = null;

  Visit._tab(this._url, this._status, this._body, this._crawl, this._dom)
      : _contentType = null,
        _disposition = null;

  Visit._cached(this._url, this._status, this._body, this._crawl,
      this._contentType, this._disposition)
      : _dom = null;

  final String _url;
  final int _status;
  final Uint8List _body;
  final _Crawl<T> _crawl;
  final String? _contentType;
  final String? _disposition;

  /// Rendered-DOM snapshot (browser mode only), parsed once by [html].
  final String? _dom;
  Elements? _parsed;

  /// The final URL after redirects.
  String finalUrl() => _url;

  /// The HTTP status. A 404 reaches its handler; [statusCode] tells it apart.
  int statusCode() => _status;

  /// Whether the status is 2xx.
  bool isSuccess() {
    final code = _status;
    return code >= 200 && code < 300;
  }

  /// The body length in bytes. The body is always in memory, so unlike
  /// `http`'s header reading this is never null.
  int contentLength() => _body.length;

  /// A file name for the body: the `content-disposition` filename
  /// (`filename*=` wins over `filename=`, paths stripped), else the final
  /// URL's last segment, else `'download'`. Same rules as `Response`
  /// (shared `src/origin.dart`).
  String fileName() =>
      names.fileName(url: _url, contentDisposition: _disposition);

  @override
  Origin origin() => Origin(url: _url, status: _status, name: fileName());

  /// Queue [urls] to be handled by [handler]. URLs are made absolute against
  /// this visit's URL and their fragment is dropped; an already-queued URL
  /// is skipped, whichever handler queued it. Bad URLs are skipped, like
  /// non-http(s). Returns this visit.
  Visit<T> follow(
    Iterable<String> urls,
    Future<void> Function(Visit<T> visit) handler,
  ) {
    for (final u in urls) {
      String? normalized;
      try {
        normalized = _crawl.normalize(_url, u);
      } catch (_) {
        // One bad href must not kill the crawl.
        continue;
      }
      _crawl.enqueue(normalized, handler);
    }
    return this;
  }

  /// Add a record to the run's output stream. Returns this visit.
  Visit<T> emit(T item) {
    _crawl.emit(item);
    return this;
  }

  @override
  Stream<List<int>> stream() => Stream.value(_body.asUnmodifiableView());

  @override
  Future<List<int>> bytes() async => _body.asUnmodifiableView();

  @override
  Future<String> text() async =>
      charset.Charset.decode(_body, contentType: _contentType);

  /// This page as [Elements]: the rendered DOM snapshot with a browser,
  /// parsed once per visit, else the body parsed with the final URL as the
  /// base.
  Future<Elements> html() async {
    final cached = _parsed;
    if (cached != null) return cached;
    final dom = _dom;
    final parsed = Html.parse(dom ?? await text(), baseUrl: _url);
    return _parsed = parsed;
  }
}

final class _Task<T> {
  _Task(this.url, this.handler);

  final String url;
  final Future<void> Function(Visit<T> visit) handler;
}

/// Pooled browser tabs: at most [size] tabs (one per worker) are ever open;
/// idle tabs are reused with [Page.goTo] instead of paying `Browser.open`
/// per URL. Tab setup (headers, viewport, blocks) happens once at open and
/// persists across reuses — the crawl passes one headers map anyway, so a
/// reused tab is configured exactly like a fresh one.
final class _TabPool {
  _TabPool(this._browser, this._size, {this.headers, this.timeout});

  final Browser _browser;
  final int _size;
  final Map<String, String>? headers;
  final Duration? timeout;
  final _idle = <Page>[];
  var _total = 0;
  var _closed = false;

  Future<Page> open(String url) async {
    final idle = _idle;
    if (idle.isNotEmpty) {
      final page = idle.removeLast();
      try {
        await page.goTo(url, timeout: timeout);
        return page;
      } catch (_) {
        // A dead tab never returns to the pool.
        _total--;
        try {
          await page.close();
        } catch (_) {}
      }
    }
    // At most _size workers fetch at once, so _total can never pass _size.
    assert(_total < _size, 'tab pool overflows its workers');
    _total++;
    try {
      return await _browser.open(url, headers: headers, timeout: timeout);
    } catch (_) {
      _total--;
      rethrow;
    }
  }

  void release(Page page) {
    if (_closed) {
      unawaited(page.close().then<void>((_) {}, onError: (_) {}));
      return;
    }
    _idle.add(page);
  }

  /// Drop a tab that broke mid-visit so the next acquire opens fresh.
  void drop(Page page) {
    _total--;
    unawaited(page.close().then<void>((_) {}, onError: (_) {}));
  }

  Future<void> close() async {
    _closed = true;
    final pages = List<Page>.of(_idle);
    _idle.clear();
    for (final page in pages) {
      try {
        await page.close();
      } catch (_) {}
    }
  }
}

final class _Crawl<T> {
  _Crawl({
    required this.concurrency,
    required this.perHostDelay,
    required this.retries,
    required this.cacheDir,
    required this.headers,
    required this.timeout,
    required this.browser,
    required this.onError,
    required this.out,
  }) : _clock = Stopwatch();

  final int concurrency;
  final Duration? perHostDelay;
  final int retries;
  final String? cacheDir;
  final Map<String, String>? headers;
  final Duration? timeout;
  final Browser? browser;
  final void Function(String url, Object error)? onError;
  final StreamController<T> out;

  /// Monotonic clock for per-host delays (no wall-clock jumps).
  final Stopwatch _clock;

  /// Next allowed slot per host, on [_clock].
  final _hostNext = <String, Duration>{};

  /// Held HTTP client (HTTP mode) and pooled tabs (browser mode).
  HttpHold? _hold;
  _TabPool? _tabs;

  final _queue = <_Task<T>>[];
  var _head = 0;
  final _seen = <String>{};
  var _active = 0;
  var _cancelled = false;
  Object? _failure;
  StackTrace? _failureStack;

  void start(
    Iterable<String> urls,
    Future<void> Function(Visit<T> visit) handler,
  ) {
    _clock.start();
    if (browser == null) {
      // One shared client for the whole crawl; released at drain.
      _hold = Http.hold();
    } else {
      _tabs = _TabPool(browser!,
          concurrency, headers: headers, timeout: timeout);
    }
    try {
      for (final u in urls) {
        enqueue(normalize(null, u), handler);
      }
    } catch (e, st) {
      _fail(null, e, st);
      unawaited(_drain());
      return;
    }
    for (var i = 0; i < concurrency; i++) {
      _worker();
    }
  }

  bool get _hasWork => _head < _queue.length;

  _Task<T> _take() {
    final task = _queue[_head++];
    // Compact the consumed prefix so a 10k-URL crawl doesn't hold it all.
    if (_head > 1024 && _head * 2 > _queue.length) {
      _queue.removeRange(0, _head);
      _head = 0;
    }
    return task;
  }

  /// Consumer backpressure: workers stop taking tasks while paused.
  Completer<void>? _gate;

  void pause() => _gate ??= Completer<void>();

  void resume() {
    final g = _gate;
    _gate = null;
    g?.complete();
  }

  void cancel() {
    _cancelled = true;
    resume();
    _queue.clear();
    _head = 0;
    _notify();
  }

  /// Make [url] absolute against [base] and drop its fragment.
  /// Non-http(s) links (`mailto:`, `tel:`, `javascript:`, `data:`) are
  /// skipped: null, never a failed visit.
  String? normalize(String? base, String url) {
    Uri uri;
    try {
      uri = base == null ? Uri.parse(url) : Uri.parse(base).resolve(url);
    } catch (e) {
      throw FormatException('invalid URL: $url ($e)');
    }
    if (!uri.hasScheme) {
      throw FormatException('relative URL without a page: $url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.removeFragment().toString();
  }

  void enqueue(
    String? url,
    Future<void> Function(Visit<T> visit) handler,
  ) {
    if (url == null) return;
    if (_cancelled || _failure != null) return;
    if (!_seen.add(url)) return;
    _queue.add(_Task(url, handler));
    _notify();
  }

  Completer<void>? _signal;

  void _notify() {
    final s = _signal;
    _signal = null;
    try {
      s?.complete();
    } catch (_) {}
  }

  /// Wait until an enqueue or a finish wakes us. Every enqueue and every
  /// finish notifies, and the take-to-wait stretch is synchronous, so no
  /// wake-up is ever missed and no timeout guard is needed.
  Future<void> _waitWork() async {
    final s = _signal ??= Completer<void>();
    await s.future;
  }

  void emit(T item) {
    if (_cancelled || _failure != null || out.isClosed) return;
    out.add(item);
  }

  Future<void> _worker() async {
    while (!_cancelled && _failure == null) {
      final gate = _gate;
      if (gate != null) {
        await gate.future;
        continue;
      }
      _Task<T>? task;
      if (_hasWork) {
        task = _take();
      } else {
        if (_active == 0) break;
        await _waitWork();
        continue;
      }
      _active++;
      try {
        await _visit(task);
      } catch (e, st) {
        final report = onError;
        if (report != null) {
          try {
            report(task.url, e);
          } catch (_) {}
        } else if (_failure == null) {
          _fail(task.url, e, st);
        }
      } finally {
        _active--;
        _notify();
      }
    }
    await _drain();
  }

  var _drained = false;

  Future<void> _drain() async {
    if (_drained || _active != 0 || _hasWork) return;
    _drained = true;
    try {
      await _tabs?.close();
    } catch (_) {}
    _tabs = null;
    try {
      await _hold?.close();
    } catch (_) {}
    _hold = null;
    final failure = _failure;
    if (failure != null) {
      out.addError(failure, _failureStack);
    }
    await out.close();
  }

  void _fail(String? url, Object e, StackTrace st) {
    // A failure ends the run: drop the queue so _drain can fire once the
    // visits in flight finish, and the stream errors. Without this the
    // workers exit but _drain waits on queued work forever.
    _failure = e;
    _failureStack = st;
    _queue.clear();
    _head = 0;
  }

  Future<void> _visit(_Task<T> task) async {
    final uri = Uri.parse(task.url);
    // Cache first: hits skip the delay and the network.
    final hit = cacheDir == null ? null : await _readCache(task.url);
    Visit<T> visit;
    Page? page;
    if (hit != null) {
      visit = Visit._cached(hit.finalUrl, hit.status, hit.body, this,
          hit.contentType, hit.disposition);
    } else {
      if (perHostDelay != null) await _polite(uri.host);
      final fetched = await _fetch(task.url);
      page = fetched.page;
      if (cacheDir != null) await _writeCache(task.url, fetched);
      visit = fetched.visit;
    }
    // A fetch that finished after a failure or cancel, or that redirected
    // to a URL already visited, is dropped; its tab still goes back.
    final landed = visit.finalUrl();
    if (_cancelled ||
        _failure != null ||
        (landed != task.url && !_seen.add(landed))) {
      if (page != null) _tabs?.release(page);
      return;
    }
    try {
      await task.handler(visit);
    } finally {
      if (page != null) _tabs?.release(page);
    }
  }

  Future<void> _polite(String host) async {
    // Reserve the next slot synchronously (no await between the read and the
    // write): concurrent workers on one host line up in slots instead of
    // all reading the same last time and firing together.
    final gap = perHostDelay!;
    final now = _clock.elapsed;
    final allowed = _hostNext[host];
    if (allowed == null || now >= allowed) {
      _hostNext[host] = now + gap;
      return;
    }
    _hostNext[host] = allowed + gap;
    await Future<void>.delayed(allowed - now);
  }

  Future<_Fetched<T>> _fetch(String url) async {
    // The HTTP path delegates retries to Http (transport errors, timeouts,
    // 5xx and 429 with backoff or Retry-After, in one place); the browser
    // path keeps its own loop around pooled tabs.
    if (browser == null) return _fetchHttp(url);
    Object? lastError;
    Duration? retryAfter;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(retry.backoff(attempt - 1, retryAfter));
      }
      retryAfter = null;
      try {
        final fetched = await _fetchTab(url);
        if (fetched.status == 429 || fetched.status >= 500) {
          retryAfter = retry.parseRetryAfter(fetched.retryAfter);
          lastError = io.HttpException(
            'HTTP ${fetched.status}: $url',
            uri: Uri.tryParse(url),
          );
          // A 5xx/429 tab is healthy: back to the pool for the retry.
          final tab = fetched.page;
          if (tab != null) _tabs?.release(tab);
          continue;
        }
        return fetched;
      } on _Retry catch (e) {
        lastError = e.cause;
        continue;
      }
    }
    throw lastError!;
  }

  Future<_Fetched<T>> _fetchHttp(String url) async {
    // Transport retries (and 5xx/429 with backoff) happen inside Http; an
    // exhausted 5xx/429 still comes back as a response and fails the visit
    // here, like any other failure.
    final res = await Http.get(url,
        headers: headers, timeout: timeout, retries: retries);
    final status = res.statusCode();
    if (status == 429 || status >= 500) {
      final finalUrl = res.finalUrl();
      await res.close();
      throw io.HttpException('HTTP $status: $finalUrl',
          uri: Uri.tryParse(finalUrl));
    }
    List<int> rawBody;
    String? contentType;
    String? disposition;
    String finalUrl;
    try {
      contentType = res.header('content-type');
      disposition = res.header('content-disposition');
      rawBody = await res.bytes();
      finalUrl = res.finalUrl();
    } finally {
      // bytes() releases the client by itself; close() is a no-op then.
      await res.close();
    }
    final body =
        rawBody is Uint8List ? rawBody : Uint8List.fromList(rawBody);
    return _Fetched(
      Visit._http(finalUrl, status, body, this, contentType, disposition),
      status,
      res.header('retry-after'),
      null,
    );
  }

  Future<_Fetched<T>> _fetchTab(String url) async {
    final pool = _tabs!;
    Page page;
    try {
      // open() carries the timeout inside, so a late tab is closed by
      // open itself instead of orphaned by an outer .timeout().
      page = await pool.open(url);
    } on TimeoutException catch (e) {
      throw _Retry(e);
    } on io.IOException catch (e) {
      throw _Retry(e);
    } catch (e) {
      // A Chrome navigation failure is a bare net::ERR_… Exception: name
      // the URL as a SocketException so it retries like any network error.
      throw _Retry(io.SocketException('navigation failed: $url ($e)'));
    }
    try {
      // One DOM serialize per visit: this snapshot feeds both the body and
      // Visit.html() (which used to serialize a second time via content).
      final status = await page
          .evaluate<num>(
            'performance.getEntriesByType("navigation")[0]?.responseStatus ?? 0',
          )
          .timeout(timeout ?? const Duration(seconds: 30));
      final content = await page
          .evaluate<String>('document.documentElement.outerHTML')
          .timeout(timeout ?? const Duration(seconds: 30));
      final dom = content ?? '';
      final code = (status ?? 0).toInt();
      final finalUrl = await page.url();
      return _Fetched(
        Visit._tab(finalUrl, code == 0 ? 200 : code, utf8.encode(dom), this,
            dom),
        code == 0 ? 200 : code,
        null,
        page,
      );
    } catch (e) {
      // A broken tab never returns to the pool: the next acquire opens fresh.
      pool.drop(page);
      if (e is TimeoutException) throw _Retry(e);
      if (e is io.IOException) throw _Retry(e);
      rethrow;
    }
  }

  String _cacheKey(String url) => Hash.md5().add(url).hexDigest();

  Future<_Hit?> _readCache(String url) async {
    try {
      final dir = cacheDir!;
      final key = _cacheKey(url);
      final metaFile = Fs.file('$dir/$key.json');
      if (!await metaFile.exists()) return null;
      final meta =
          jsonDecode(await metaFile.text()) as Map<String, dynamic>;
      final bodyFile = Fs.file('$dir/$key.body');
      if (!await bodyFile.exists()) return null;
      final raw = await bodyFile.bytes();
      return _Hit(
        meta['finalUrl'] as String,
        (meta['status'] as num).toInt(),
        raw is Uint8List ? raw : Uint8List.fromList(raw),
        meta['contentType'] as String?,
        meta['contentDisposition'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String url, _Fetched<T> fetched) async {
    try {
      final dir = cacheDir!;
      final key = _cacheKey(url);
      final visit = fetched.visit;
      await (Reader.of(visit._body) > Fs.file('$dir/$key.body'));
      await Fs.file('$dir/$key.json').write(
        jsonEncode({
          'finalUrl': visit._url,
          'status': visit._status,
          'contentType': visit._contentType,
          'contentDisposition': visit._disposition,
        }),
      );
    } catch (_) {
      // Caching is best-effort; a full disk must not fail the crawl.
    }
  }
}

final class _Fetched<T> {
  _Fetched(this.visit, this.status, this.retryAfter, this.page);

  final Visit<T> visit;
  final int status;
  final String? retryAfter;
  final Page? page;
}

final class _Hit {
  _Hit(this.finalUrl, this.status, this.body, this.contentType,
      this.disposition);

  final String finalUrl;
  final int status;
  final Uint8List body;
  final String? contentType;
  final String? disposition;
}

final class _Retry {
  _Retry(this.cause);

  final Object cause;
}
