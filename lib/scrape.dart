/// Crawling: a queue, a limit, retries, a cache, typed records out.
/// Composes `http`, `html` and `chrome` from this package plus an in-house
/// queue (about 200 lines).
///
/// ```dart
/// final albums = await Scrape.run<Album>(starts, listing,
///     delay: Duration(milliseconds: 250), cache: '.cache/shop').toList();
/// Future<void> listing(Visit<Album> v) async {
///   final doc = await v.html();
///   v.follow(doc.$('a[href*="detail"]').attrs('href'), album);
/// }
/// ```
///
/// Public surface is exactly: [Scrape], [Visit].
/// - `Scrape.run()` visits start URLs and returns a `Stream` of records.
/// - [Visit] (a [Reader] of the page body) supports `url` `status` `follow` `emit`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';

export 'core.dart';

/// Entry point: crawl start URLs with a handler per kind of page.
abstract final class Scrape {
  /// Visit [urls] with [handler]; return a `Stream<T>` of every emitted
  /// record, in emission order. The stream completes when the queue is empty
  /// and every handler has returned. Cancelling the subscription stops the
  /// crawl: nothing new starts, visits in flight are dropped.
  ///
  /// Routing is by function: [Visit.follow] queues URLs for a handler.
  /// Each URL is visited once (absolute, fragment dropped). A 404 reaches
  /// its handler. Failures end the run, rethrown from the stream, unless
  /// [onError] reports the URL and the crawl goes on without that page.
  static Stream<T> run<T>(
    Iterable<String> urls,
    Future<void> Function(Visit<T> visit) handler, {
    int limit = 4,
    Duration? delay,
    int retries = 2,
    String? cache,
    Map<String, String>? headers,
    Duration? timeout,
    Browser? browser,
    void Function(String url, Object error)? onError,
  }) {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    }
    if (retries < 0) {
      throw ArgumentError.value(retries, 'retries', 'must not be negative');
    }
    final controller = StreamController<T>();
    final crawl = _Crawl<T>(
      limit: limit,
      delay: delay,
      retries: retries,
      cache: cache,
      headers: headers,
      timeout: timeout,
      browser: browser,
      onError: onError,
      out: controller,
    );
    controller.onListen = () {
      crawl.start(urls, handler);
    };
    controller.onCancel = crawl.cancel;
    return controller.stream;
  }
}

/// One page being handled: a [Reader] of its body, so `html()` (with the
/// final URL as the base), `json()`, `text()` and `> file` mean what they
/// mean everywhere. With a [browser], `html()` is the rendered DOM.
final class Visit<T> with Reader {
  Visit._http(this._url, this._status, this._body, this._crawl)
      : _page = null;

  Visit._tab(
    this._url,
    this._status,
    this._body,
    this._crawl,
    Page page,
  ) : _page = page;

  Visit._cached(this._url, this._status, this._body, this._crawl)
      : _page = null;

  final String _url;
  final int _status;
  final List<int> _body;
  final _Crawl<T> _crawl;
  final Page? _page;

  /// The final URL after redirects.
  String url() => _url;

  /// The HTTP status. A 404 reaches its handler; [status] tells it apart.
  int status() => _status;

  /// Queue [urls] to be handled by [handler]. URLs are made absolute against
  /// this visit's URL and their fragment is dropped; an already-queued URL
  /// is skipped, whichever handler queued it. Returns this visit.
  Visit<T> follow(
    Iterable<String> urls,
    Future<void> Function(Visit<T> visit) handler,
  ) {
    for (final u in urls) {
      _crawl.enqueue(_crawl.normalize(_url, u), handler);
    }
    return this;
  }

  /// Add a record to the run's output stream. Returns this visit.
  Visit<T> emit(T item) {
    _crawl.emit(item);
    return this;
  }

  @override
  Stream<List<int>> stream() => Stream.value(_body);

  /// This page as [Elements]: the rendered DOM with a browser, else the
  /// body parsed with the final URL as the base.
  Future<Elements> html() async {
    final page = _page;
    if (page != null) return page.html();
    return Html.parse(await text(), baseUrl: _url);
  }
}

final class _Task<T> {
  _Task(this.url, this.handler);

  final String url;
  final Future<void> Function(Visit<T> visit) handler;
}

final class _Crawl<T> {
  _Crawl({
    required this.limit,
    required this.delay,
    required this.retries,
    required this.cache,
    required this.headers,
    required this.timeout,
    required this.browser,
    required this.onError,
    required this.out,
  });

  final int limit;
  final Duration? delay;
  final int retries;
  final String? cache;
  final Map<String, String>? headers;
  final Duration? timeout;
  final Browser? browser;
  final void Function(String url, Object error)? onError;
  final StreamController<T> out;

  final _queue = <_Task<T>>[];
  var _head = 0;
  final _seen = <String>{};
  final _hostLast = <String, DateTime>{};
  var _active = 0;
  var _cancelled = false;
  Object? _failure;
  StackTrace? _failureStack;

  void start(
    Iterable<String> urls,
    Future<void> Function(Visit<T> visit) handler,
  ) {
    try {
      for (final u in urls) {
        enqueue(normalize(null, u), handler);
      }
    } catch (e, st) {
      _fail(null, e, st);
      _drain();
      return;
    }
    for (var i = 0; i < limit; i++) {
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

  void cancel() {
    _cancelled = true;
  }

  /// Make [url] absolute against [base] and drop its fragment.
  String normalize(String? base, String url) {
    Uri uri;
    try {
      uri = base == null ? Uri.parse(url) : Uri.parse(base).resolve(url);
    } catch (e) {
      throw FormatException('invalid URL: $url ($e)');
    }
    if (!uri.hasScheme) {
      throw FormatException('relative URL without a page: $url');
    }
    return uri.removeFragment().toString();
  }

  void enqueue(
    String url,
    Future<void> Function(Visit<T> visit) handler,
  ) {
    if (_cancelled || _failure != null) return;
    if (!_seen.add(url)) return;
    _queue.add(_Task(url, handler));
  }

  void emit(T item) {
    if (_cancelled || _failure != null || out.isClosed) return;
    out.add(item);
  }

  Future<void> _worker() async {
    while (!_cancelled && _failure == null) {
      _Task<T>? task;
      if (_hasWork) {
        task = _take();
      } else {
        if (_active == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
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
      }
    }
    _drain();
  }

  var _drained = false;

  void _drain() {
    if (_drained || _active != 0 || _hasWork) return;
    // Wait for sibling workers sharing the queue.
    Future<void>.delayed(const Duration(milliseconds: 50)).then((_) {
      if (_active != 0 || _hasWork) return;
      if (_drained) return;
      _drained = true;
      final failure = _failure;
      if (failure != null) {
        out.addError(failure, _failureStack);
      }
      out.close();
    });
  }

  void _fail(String? url, Object e, StackTrace st) {
    _failure = e;
    _failureStack = st;
  }

  Future<void> _visit(_Task<T> task) async {
    final uri = Uri.parse(task.url);
    // Cache first: hits skip the delay and the network.
    final hit = cache == null ? null : await _readCache(task.url);
    Visit<T> visit;
    if (hit != null) {
      visit = Visit._cached(hit.finalUrl, hit.status, hit.body, this);
    } else {
      if (delay != null) await _polite(uri.host);
      final fetched = await _fetch(task.url);
      if (cache != null) await _writeCache(task.url, fetched);
      visit = fetched.visit;
    }
    if (_cancelled || _failure != null) return;
    try {
      await task.handler(visit);
    } finally {
      await visit._page?.close();
    }
  }

  Future<void> _polite(String host) async {
    // Reserve the next slot synchronously (no await between the read and the
    // write): concurrent workers on one host line up in slots instead of
    // all reading the same last time and firing together.
    final gap = delay!;
    final now = DateTime.now();
    final allowed = _hostLast[host];
    if (allowed == null || !now.isBefore(allowed)) {
      _hostLast[host] = now.add(gap);
      return;
    }
    _hostLast[host] = allowed.add(gap);
    await Future<void>.delayed(allowed.difference(now));
  }

  Future<_Fetched<T>> _fetch(String url) async {
    Object? lastError;
    Duration? retryAfter;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_backoff(attempt - 1, retryAfter));
      }
      retryAfter = null;
      try {
        final fetched = browser == null
            ? await _fetchHttp(url)
            : await _fetchTab(url);
        if (fetched.status == 429 || fetched.status >= 500) {
          retryAfter = _parseRetryAfter(fetched.retryAfter);
          lastError = StateError(
            'HTTP ${fetched.status}: $url',
          );
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

  Duration _backoff(int attempt, Duration? server) {
    final backoff = Duration(seconds: 1 << attempt);
    if (server == null) return backoff;
    return server > backoff ? server : backoff;
  }

  static Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final secs = int.tryParse(value.trim());
    if (secs != null && secs >= 0) return Duration(seconds: secs);
    try {
      final date = io.HttpDate.parse(value.trim());
      final wait = date.difference(DateTime.now().toUtc());
      if (wait > Duration.zero) return wait;
    } catch (_) {}
    return null;
  }

  Future<_Fetched<T>> _fetchHttp(String url) async {
    Response res;
    try {
      res = await Http.get(url, headers: headers, timeout: timeout);
    } on TimeoutException catch (e) {
      throw _Retry(e);
    } on io.IOException catch (e) {
      throw _Retry(e);
    }
    List<int> body;
    try {
      body = await res.bytes();
    } on TimeoutException catch (e) {
      throw _Retry(e);
    } on io.IOException catch (e) {
      throw _Retry(e);
    }
    return _Fetched(
      Visit._http(res.url(), res.status(), body, this),
      res.status(),
      res.header('retry-after'),
    );
  }

  Future<_Fetched<T>> _fetchTab(String url) async {
    final page = await browser!
        .open(url, headers: headers)
        .timeout(
          timeout ?? const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException(
            'tab never loaded: $url',
            timeout,
          ),
        );
    try {
      final content = await page
          .eval<String>('document.documentElement.outerHTML')
          .timeout(timeout ?? const Duration(seconds: 30));
      final status = await page
          .eval<num>(
            'performance.getEntriesByType("navigation")[0]?.responseStatus ?? 0',
          )
          .timeout(timeout ?? const Duration(seconds: 30));
      final body = utf8.encode(content ?? '');
      final code = (status ?? 0).toInt();
      return _Fetched(
        Visit._tab(await page.url(), code == 0 ? 200 : code, body, this, page),
        code == 0 ? 200 : code,
        null,
      );
    } catch (e) {
      try {
        await page.close();
      } catch (_) {}
      if (e is TimeoutException) throw _Retry(e);
      if (e is io.IOException) throw _Retry(e);
      rethrow;
    }
  }

  String _cacheKey(String url) => Hash.md5().add(url).hex();

  Future<_Hit?> _readCache(String url) async {
    try {
      final dir = cache!;
      final key = _cacheKey(url);
      final metaFile = Fs.file('$dir/$key.json');
      if (!await metaFile.exists()) return null;
      final meta =
          jsonDecode(await metaFile.text()) as Map<String, dynamic>;
      final bodyFile = Fs.file('$dir/$key.body');
      if (!await bodyFile.exists()) return null;
      return _Hit(
        meta['finalUrl'] as String,
        (meta['status'] as num).toInt(),
        await bodyFile.bytes(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String url, _Fetched<T> fetched) async {
    try {
      final dir = cache!;
      final key = _cacheKey(url);
      final visit = fetched.visit;
      await Fs.file('$dir/$key.body').write(visit._body);
      await Fs.file('$dir/$key.json').write(
        jsonEncode({'finalUrl': visit._url, 'status': visit._status}),
      );
    } catch (_) {
      // Caching is best-effort; a full disk must not fail the crawl.
    }
  }
}

final class _Fetched<T> {
  _Fetched(this.visit, this.status, this.retryAfter);

  final Visit<T> visit;
  final int status;
  final String? retryAfter;
}

final class _Hit {
  _Hit(this.finalUrl, this.status, this.body);

  final String finalUrl;
  final int status;
  final List<int> body;
}

final class _Retry {
  _Retry(this.cause);

  final Object cause;
}
