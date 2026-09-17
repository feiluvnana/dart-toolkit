import 'dart:async';
import 'dart:collection';

import 'package:http/http.dart' as http;

import '../async/cancellation_token.dart';
import '../util/time.dart';
import 'session.dart';

/// Callback for processing a scrape response in a type-safe context.
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
    });

/// Context provided to scraping callbacks: the response, and controls for emitting
/// items and following links.
///
/// {@category Crawling}
class ScrapeContext<T> {
  /// The received HTTP response.
  final http.Response response;

  /// The request associated with this response.
  final http.BaseRequest request;

  /// Metadata carried over from previous requests in the scraping pipeline.
  final Map<String, Object?> meta;

  /// The URL that was requested, and the base [resolve] and [follow] resolve against.
  ///
  /// `package:http` does not expose the URL a redirect landed on, so after a 3xx this
  /// is still the URL asked for. Use absolute hrefs, or `<base href>`, on such pages.
  final Uri url;

  final void Function(T item) _emit;
  final Follow<T> _follow;
  bool _isClosed = false;

  ScrapeContext({
    required this.response,
    required this.request,
    required this.meta,
    required this.url,
    required void Function(T item) emit,
    required Follow<T> follow,
  }) : _emit = emit,
       _follow = follow;

  /// Resolves [href] — a [Uri] or a [String] — against [url], as [follow] does.
  Uri resolve(Object href) => _resolve(url, href);

  /// Emits a typed item [item] to the output stream.
  void emit(T item) {
    _checkOpen('emit');
    _emit(item);
  }

  /// Follows a [target] URL, scheduling a new request with optional [callback], [meta], and [headers].
  ///
  /// [target] must be a [Uri] or a [String] href, resolved against this response's URL.
  /// Pass at most one of [body] (a raw request body) and [fields] (form-encoded fields).
  /// Set [revisit] to re-request a URL the crawl has already visited.
  void follow(
    Object target, {
    ScrapeHandler<T>? callback,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    String method = 'GET',
    String? body,
    Map<String, String>? fields,
    bool revisit = false,
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
    );
  }

  /// Follows multiple [targets]; the named arguments are those of [follow].
  void followAll(
    Iterable<Object> targets, {
    ScrapeHandler<T>? callback,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    String method = 'GET',
    String? body,
    Map<String, String>? fields,
    bool revisit = false,
  }) {
    for (final target in targets) {
      follow(
        target,
        callback: callback,
        meta: meta,
        headers: headers,
        method: method,
        body: body,
        fields: fields,
        revisit: revisit,
      );
    }
  }

  void _checkOpen(String what) {
    if (_isClosed) throw StateError('Cannot $what after scrape handler execution has completed.');
  }
}

final _requestMetaExpando = Expando<Map<String, Object?>>('req_meta');
final _requestCallbackExpando = Expando<Object>('req_callback');
final _requestRevisitExpando = Expando<bool>('req_revisit');

/// Identity of a request for deduplication: the values, not a hash of them.
typedef _RequestKey = (String method, Uri url, String body);

_RequestKey _makeRequestKey(http.BaseRequest req) =>
    (req.method.toUpperCase(), req.url, req is http.Request ? req.body : '');

/// Scrape entry points. All forward to one engine.
///
/// {@category Crawling}
extension UriScrapeExtensions on Uri {
  /// Scrapes this URL with a type-safe Scrapy-style response handler.
  ///
  /// [delay] is waited by each slot before its request; with [concurrency] above one it
  /// paces slots, not the crawl. [retries] re-sends after a thrown error, a 429 or a 5xx,
  /// honouring `Retry-After`.
  ///
  /// ```dart
  /// await for (final item in url.scrape<Item>((ctx) {
  ///   ctx.emit(parse(ctx.response));
  ///   ctx.followAll(ctx.response.html().$('a.next').map((a) => a.attr('href')!));
  /// })) { ... }
  /// ```
  Stream<T> scrape<T>(
    ScrapeHandler<T> parse, {
    int concurrency = 4,
    Duration? delay,
    http.Client? client,
    int retries = 2,
    CancelToken? cancelToken,
  }) => _scrape([http.Request('GET', this)], parse, concurrency, delay, client, retries, cancelToken);
}

/// {@category Crawling}
extension IterableUriScrapeExtensions on Iterable<Uri> {
  /// Scrapes these URLs; see [UriScrapeExtensions.scrape].
  Stream<T> scrape<T>(
    ScrapeHandler<T> parse, {
    int concurrency = 4,
    Duration? delay,
    http.Client? client,
    int retries = 2,
    CancelToken? cancelToken,
  }) => _scrape(
    [for (final url in this) http.Request('GET', url)],
    parse,
    concurrency,
    delay,
    client,
    retries,
    cancelToken,
  );
}

/// {@category Crawling}
extension IterableRequestScrapeExtensions on Iterable<http.BaseRequest> {
  /// Scrapes these requests — any method, body or headers; see [UriScrapeExtensions.scrape].
  Stream<T> scrape<T>(
    ScrapeHandler<T> parse, {
    int concurrency = 4,
    Duration? delay,
    http.Client? client,
    int retries = 2,
    CancelToken? cancelToken,
  }) => _scrape(this, parse, concurrency, delay, client, retries, cancelToken);
}

bool _retryable(int status) => status == 429 || status >= 500;

Duration _retryAfter(http.BaseResponse res, int attempt) {
  final header = res.headers['retry-after'];
  final seconds = header == null ? null : int.tryParse(header.trim());
  return seconds != null ? Duration(seconds: seconds) : (200 * attempt).ms;
}

/// Internal functional scraping engine using standard `package:http`.
Stream<T> _scrape<T>(
  Iterable<http.BaseRequest> seeds,
  ScrapeHandler<T> parse,
  int concurrency,
  Duration? delay,
  http.Client? client,
  int retries,
  CancelToken? cancelToken,
) {
  final limit = concurrency > 0 ? concurrency : 1;
  late final StreamController<T> controller;
  final lease = clientFor(client);
  final httpClient = lease.client;
  final visited = <_RequestKey>{};
  final queue = Queue<http.BaseRequest>();
  final active = <Future<void>>{};
  var isStopped = false;
  void Function()? unregister;

  bool cancelled() => isStopped || (cancelToken != null && cancelToken.isCancelled);

  void finish() {
    unregister?.call();
    lease.close();
    if (!controller.isClosed) controller.close();
  }

  void enqueue(http.BaseRequest req) {
    final revisit = _requestRevisitExpando[req] ?? false;
    if (!revisit && !visited.add(_makeRequestKey(req))) return;
    queue.add(req);
  }

  seeds.forEach(enqueue);

  void schedule() {
    if (cancelled() || controller.isClosed) return;
    // A paused consumer stops the crawl: without this the engine runs the whole
    // frontier to completion and buffers every item in the controller.
    if (controller.isPaused) return;

    while (queue.isNotEmpty && active.length < limit) {
      final req = queue.removeFirst();

      late final Future<void> task;
      task = Future<void>(() async {
        try {
          if (delay != null && delay > Duration.zero) await Future<void>.delayed(delay);
          if (cancelled()) return;

          http.Response? rawRes;
          for (var attempt = 0; rawRes == null && !cancelled(); attempt++) {
            try {
              final res = await http.Response.fromStream(await httpClient.send(_cloneRequest(req)));
              if (_retryable(res.statusCode) && attempt < retries) {
                await Future<void>.delayed(_retryAfter(res, attempt + 1));
                continue;
              }
              rawRes = res;
            } catch (_) {
              if (attempt >= retries) rethrow;
              await Future<void>.delayed((200 * (attempt + 1)).ms);
            }
          }
          if (rawRes == null || cancelled()) return;

          final reqMeta = _requestMetaExpando[req] ?? const {};
          final baseUri = rawRes.request?.url ?? req.url;

          final ctx = ScrapeContext<T>(
            response: rawRes,
            request: req,
            meta: reqMeta,
            url: baseUri,
            emit: (item) {
              if (!controller.isClosed) controller.add(item);
            },
            follow:
                (
                  Object target, {
                  ScrapeHandler<T>? callback,
                  Map<String, Object?>? meta,
                  Map<String, String>? headers,
                  String method = 'GET',
                  String? body,
                  Map<String, String>? fields,
                  bool revisit = false,
                }) {
                  final nextReq = http.Request(method, _resolve(baseUri, target));
                  if (body != null) nextReq.body = body;
                  if (fields != null) nextReq.bodyFields = fields;
                  if (headers != null) nextReq.headers.addAll(headers);
                  _requestMetaExpando[nextReq] = {...reqMeta, ...?meta};
                  if (callback != null) _requestCallbackExpando[nextReq] = callback;
                  if (revisit) _requestRevisitExpando[nextReq] = true;
                  enqueue(nextReq);
                  schedule();
                },
          );

          final rawHandler = _requestCallbackExpando[req];
          final handler = rawHandler is ScrapeHandler<T> ? rawHandler : parse;

          try {
            await handler(ctx);
          } finally {
            ctx._isClosed = true;
          }
        } catch (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        } finally {
          active.remove(task);
          if (queue.isEmpty && active.isEmpty) {
            finish();
          } else {
            schedule();
          }
        }
      });
      active.add(task);
    }

    if (queue.isEmpty && active.isEmpty) finish();
  }

  controller = StreamController<T>(
    onListen: () {
      unregister = cancelToken?.onCancel(() {
        isStopped = true;
        finish();
      });
      schedule();
    },
    onCancel: () {
      isStopped = true;
      unregister?.call();
      lease.close();
    },
    onResume: schedule,
  );

  return controller.stream;
}

Uri _resolve(Uri base, Object target) => switch (target) {
  Uri() => base.resolveUri(target),
  String() => base.resolve(target),
  _ => throw ArgumentError.value(target, 'target', 'Must be a Uri or a String href'),
};

http.BaseRequest _cloneRequest(http.BaseRequest req) {
  if (req is http.Request) {
    return http.Request(req.method, req.url)
      ..followRedirects = req.followRedirects
      ..maxRedirects = req.maxRedirects
      ..persistentConnection = req.persistentConnection
      ..bodyBytes = req.bodyBytes
      ..headers.addAll(req.headers);
  }
  return req;
}
