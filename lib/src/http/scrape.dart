import 'dart:async';
import 'dart:collection';

import 'package:http/http.dart' as http;

import '../async/cancellation_token.dart';
import '../util/time.dart';

/// Context provided to scraping callbacks containing the HTTP response and controls for emitting items and following links.
///
/// {@category Crawling}
class ScrapeContext<T> {
  /// The received HTTP response.
  final http.Response response;

  /// The request associated with this response.
  final http.BaseRequest request;

  /// Metadata carried over from previous requests in the scraping pipeline.
  final Map<String, dynamic> meta;

  final void Function(T item) _emit;
  final void Function(
    Object target, {
    FutureOr<void> Function(ScrapeContext<T> ctx)? callback,
    Map<String, dynamic>? meta,
    Map<String, String>? headers,
    String method,
    String? body,
    Map<String, String>? fields,
    bool allowDuplicates,
  })
  _follow;

  bool _isClosed = false;

  ScrapeContext({
    required this.response,
    required this.request,
    required this.meta,
    required void Function(T item) emit,
    required void Function(
      Object target, {
      FutureOr<void> Function(ScrapeContext<T> ctx)? callback,
      Map<String, dynamic>? meta,
      Map<String, String>? headers,
      String method,
      String? body,
      Map<String, String>? fields,
      bool allowDuplicates,
    })
    follow,
  }) : _emit = emit,
       _follow = follow;

  /// Emits a typed item [item] to the output stream.
  void emit(T item) {
    if (_isClosed) {
      throw StateError('Cannot emit after scrape handler execution has completed.');
    }
    _emit(item);
  }

  /// Emits multiple typed items [items] to the output stream.
  void emitAll(Iterable<T> items) {
    for (final item in items) {
      emit(item);
    }
  }

  /// Follows a [target] URL, scheduling a new request with optional [callback], [meta], and [headers].
  ///
  /// [target] must be a [Uri] or a [String] href, resolved against this response's URL.
  /// Pass at most one of [body] (a raw request body) and [fields] (form-encoded fields).
  /// Set [allowDuplicates] to re-request a URL the crawl has already visited.
  void follow(
    Object target, {
    FutureOr<void> Function(ScrapeContext<T> ctx)? callback,
    Map<String, dynamic>? meta,
    Map<String, String>? headers,
    String method = 'GET',
    String? body,
    Map<String, String>? fields,
    bool allowDuplicates = false,
  }) {
    if (_isClosed) {
      throw StateError('Cannot follow after scrape handler execution has completed.');
    }
    if (body != null && fields != null) {
      throw ArgumentError('Pass at most one of "body" and "fields".');
    }
    _follow(
      target,
      callback: callback,
      meta: meta,
      headers: headers,
      method: method,
      body: body,
      fields: fields,
      allowDuplicates: allowDuplicates,
    );
  }

  /// Follows multiple [targets], scheduling new requests.
  void followAll(
    Iterable<Object> targets, {
    FutureOr<void> Function(ScrapeContext<T> ctx)? callback,
    Map<String, dynamic>? meta,
    Map<String, String>? headers,
    String method = 'GET',
    String? body,
    Map<String, String>? fields,
    bool allowDuplicates = false,
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
        allowDuplicates: allowDuplicates,
      );
    }
  }

  void _close() {
    _isClosed = true;
  }
}

/// Callback for processing a scrape response in a type-safe context.
///
/// {@category Crawling}
typedef ScrapeHandler<T> = FutureOr<void> Function(ScrapeContext<T> ctx);

final _requestMetaExpando = Expando<Map<String, dynamic>>('req_meta');
final _requestCallbackExpando = Expando<Object>('req_callback');
final _requestDontFilterExpando = Expando<bool>('req_dont_filter');

typedef _RequestKey = (String method, Uri url, int bodyHash);

_RequestKey _makeRequestKey(http.BaseRequest req) {
  var bodyHash = 0;
  if (req is http.Request) {
    bodyHash = Object.hash(req.body, Object.hashAll(req.headers.entries.map((e) => Object.hash(e.key, e.value))));
  }
  return (req.method.toUpperCase(), req.url, bodyHash);
}

/// Scrape entry points.
///
/// All four forward to one engine; the defaults live there so a change to
/// `concurrency` is a one-line edit rather than five.
///
/// {@category Crawling}
extension UriScrapeExtensions on Uri {
  /// Scrapes this URL with a type-safe Scrapy-style response handler.
  ///
  /// ```dart
  /// await for (final item in url.scrape<Item>((ctx) {
  ///   ctx.emit(parse(ctx.response));
  ///   ctx.followAll(ctx.response.html().$('a.next').map((a) => a.attr('href')!));
  /// })) { ... }
  /// ```
  Stream<T> scrape<T>(
    ScrapeHandler<T> parse, {
    int? concurrency,
    Duration? delay,
    http.Client? client,
    int? maxRetries,
    CancellationToken? cancelToken,
  }) => _scrape([http.Request('GET', this)], parse, concurrency, delay, client, maxRetries, cancelToken);
}

/// {@category Crawling}
extension IterableUriScrapeExtensions on Iterable<Uri> {
  /// Scrapes these URLs with a type-safe Scrapy-style response handler.
  Stream<T> scrape<T>(
    ScrapeHandler<T> parse, {
    int? concurrency,
    Duration? delay,
    http.Client? client,
    int? maxRetries,
    CancellationToken? cancelToken,
  }) => _scrape(
    [for (final url in this) http.Request('GET', url)],
    parse,
    concurrency,
    delay,
    client,
    maxRetries,
    cancelToken,
  );
}

/// {@category Crawling}
extension RequestScrapeExtensions on http.BaseRequest {
  /// Scrapes this request with a type-safe Scrapy-style response handler.
  Stream<T> scrape<T>(
    ScrapeHandler<T> parse, {
    int? concurrency,
    Duration? delay,
    http.Client? client,
    int? maxRetries,
    CancellationToken? cancelToken,
  }) => _scrape([this], parse, concurrency, delay, client, maxRetries, cancelToken);
}

/// {@category Crawling}
extension IterableRequestScrapeExtensions on Iterable<http.BaseRequest> {
  /// Scrapes these requests with a type-safe Scrapy-style response handler.
  Stream<T> scrape<T>(
    ScrapeHandler<T> parse, {
    int? concurrency,
    Duration? delay,
    http.Client? client,
    int? maxRetries,
    CancellationToken? cancelToken,
  }) => _scrape(this, parse, concurrency, delay, client, maxRetries, cancelToken);
}

/// Internal functional scraping engine using standard `package:http`.
Stream<T> _scrape<T>(
  Iterable<http.BaseRequest> seeds,
  ScrapeHandler<T> parse,
  int? concurrency,
  Duration? delay,
  http.Client? client,
  int? maxRetries,
  CancellationToken? cancelToken,
) {
  final limit = (concurrency ?? 4) > 0 ? (concurrency ?? 4) : 1;
  final retries = maxRetries ?? 2;
  late final StreamController<T> controller;
  final httpClient = client ?? http.Client();
  final visited = <_RequestKey>{};
  final queue = Queue<http.BaseRequest>();
  final active = <Future<void>>{};
  var isStopped = false;

  void enqueue(http.BaseRequest req) {
    final dontFilter = _requestDontFilterExpando[req] ?? false;
    final key = _makeRequestKey(req);
    if (!dontFilter && !visited.add(key)) return;
    queue.add(req);
  }

  for (final seed in seeds) {
    enqueue(seed);
  }

  void schedule() {
    if (isStopped || controller.isClosed || (cancelToken != null && cancelToken.isCancelled)) return;

    while (queue.isNotEmpty && active.length < limit) {
      final req = queue.removeFirst();

      late final Future<void> task;
      task = Future<void>(() async {
        try {
          if (delay != null && delay > Duration.zero) {
            await Future<void>.delayed(delay);
          }
          if (isStopped || (cancelToken != null && cancelToken.isCancelled)) return;

          http.Response? rawRes;
          var attempts = 0;
          while (attempts <= retries &&
              rawRes == null &&
              !isStopped &&
              (cancelToken == null || !cancelToken.isCancelled)) {
            try {
              final streamed = await httpClient.send(_cloneRequest(req));
              rawRes = await http.Response.fromStream(streamed);
            } catch (err) {
              attempts++;
              if (attempts > retries) rethrow;
              await Future<void>.delayed((200 * attempts).ms);
            }
          }

          if (isStopped || rawRes == null || (cancelToken != null && cancelToken.isCancelled)) return;

          final reqMeta = _requestMetaExpando[req] ?? const {};

          final ctx = ScrapeContext<T>(
            response: rawRes,
            request: req,
            meta: reqMeta,
            emit: (item) {
              if (!controller.isClosed) {
                controller.add(item);
              }
            },
            follow:
                (
                  Object target, {
                  FutureOr<void> Function(ScrapeContext<T> ctx)? callback,
                  Map<String, dynamic>? meta,
                  Map<String, String>? headers,
                  String method = 'GET',
                  String? body,
                  Map<String, String>? fields,
                  bool allowDuplicates = false,
                }) {
                  final baseUri = rawRes?.request?.url ?? req.url;
                  final resolvedUri = _resolve(baseUri, target);
                  final nextReq = http.Request(method, resolvedUri);
                  if (body != null) nextReq.body = body;
                  if (fields != null) nextReq.bodyFields = fields;

                  if (headers != null) nextReq.headers.addAll(headers);
                  _requestMetaExpando[nextReq] = {...reqMeta, ...?meta};
                  if (callback != null) _requestCallbackExpando[nextReq] = callback;
                  if (allowDuplicates) _requestDontFilterExpando[nextReq] = true;
                  enqueue(nextReq);
                  schedule();
                },
          );

          final rawHandler = _requestCallbackExpando[req];
          final handler = rawHandler is ScrapeHandler<T> ? rawHandler : parse;

          try {
            await handler(ctx);
          } finally {
            ctx._close();
          }
        } catch (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        } finally {
          active.remove(task);
          if (queue.isEmpty && active.isEmpty && !controller.isClosed) {
            if (client == null) httpClient.close();
            controller.close();
          } else {
            schedule();
          }
        }
      });
      active.add(task);
    }

    if (queue.isEmpty && active.isEmpty && !controller.isClosed) {
      if (client == null) httpClient.close();
      controller.close();
    }
  }

  controller = StreamController<T>(
    onListen: () {
      cancelToken?.onCancel(() {
        isStopped = true;
        if (!controller.isClosed) {
          controller.close();
        }
      });
      schedule();
    },
    onCancel: () {
      isStopped = true;
      if (client == null) httpClient.close();
    },
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
    final copy = http.Request(req.method, req.url)
      ..followRedirects = req.followRedirects
      ..maxRedirects = req.maxRedirects
      ..persistentConnection = req.persistentConnection
      ..bodyBytes = req.bodyBytes
      ..headers.addAll(req.headers);
    return copy;
  }
  return req;
}
