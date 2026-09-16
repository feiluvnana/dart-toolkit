import 'dart:async';
import 'dart:collection';

import 'package:http/http.dart' as http;

import '../util/time.dart';

/// Callback for processing an [http.Response] in the scraping pipeline.
///
/// Can return `void` (using `res.emit(item)`), a single [T], or an `Iterable<T>`
/// which will be automatically emitted to the output stream.
typedef ResponseCallback = FutureOr<dynamic> Function(http.Response res);

final _metaExpando = Expando<Map<String, dynamic>>('scrape_meta');
final _emitExpando = Expando<void Function(Object? item)>('scrape_emit');
final _followExpando =
    Expando<
      void Function(
        Object target, {
        ResponseCallback? callback,
        Map<String, dynamic>? meta,
        Map<String, String>? headers,
        bool dontFilter,
      })
    >('scrape_follow');

final _requestMetaExpando = Expando<Map<String, dynamic>>('req_meta');
final _requestCallbackExpando = Expando<ResponseCallback>('req_callback');
final _requestDontFilterExpando = Expando<bool>('req_dont_filter');

/// Scraping extensions on [http.Response].
extension ScrapeResponseExtension on http.Response {
  /// Metadata carried over from previous requests in the scraping chain.
  Map<String, dynamic> get meta => _metaExpando[this] ?? const {};

  /// Emits a scraped data [item] to the output stream.
  void emit<T>(T item) {
    final emitFn = _emitExpando[this];
    if (emitFn != null) {
      emitFn(item);
    }
  }

  /// Emits multiple scraped data [items] to the output stream.
  void emitAll<T>(Iterable<T> items) {
    for (final item in items) {
      emit<T>(item);
    }
  }

  /// Follows a [target] URL (resolving relative paths automatically),
  /// scheduling a new request with an optional [callback] and [meta].
  void follow(
    Object target, {
    ResponseCallback? callback,
    Map<String, dynamic>? meta,
    Map<String, String>? headers,
    bool dontFilter = false,
  }) {
    final followFn = _followExpando[this];
    if (followFn != null) {
      followFn(target, callback: callback, meta: meta, headers: headers, dontFilter: dontFilter);
    }
  }

  /// Follows multiple [targets], scheduling new requests.
  void followAll(
    Iterable<Object> targets, {
    ResponseCallback? callback,
    Map<String, dynamic>? meta,
    Map<String, String>? headers,
    bool dontFilter = false,
  }) {
    for (final target in targets) {
      follow(target, callback: callback, meta: meta, headers: headers, dontFilter: dontFilter);
    }
  }
}

/// Convenience scrape extensions on URI objects.
extension ScrapeUriExtension on Uri {
  /// Scrapes this URI with a Scrapy-style response handler.
  Stream<T> scrape<T>(
    ResponseCallback parse, {
    int concurrency = 4,
    Duration? delay,
    http.Client? client,
    int maxRetries = 2,
  }) => _scrape<T>(this, parse, concurrency: concurrency, delay: delay, client: client, maxRetries: maxRetries);
}

/// Convenience scrape extensions on iterables of URIs.
extension ScrapeIterableUriExtension on Iterable<Uri> {
  /// Scrapes this collection of URIs with a Scrapy-style response handler.
  Stream<T> scrape<T>(
    ResponseCallback parse, {
    int concurrency = 4,
    Duration? delay,
    http.Client? client,
    int maxRetries = 2,
  }) => _scrape<T>(this, parse, concurrency: concurrency, delay: delay, client: client, maxRetries: maxRetries);
}

/// Convenience scrape extensions on [http.BaseRequest] objects.
extension ScrapeBaseRequestExtension on http.BaseRequest {
  /// Scrapes this request with a Scrapy-style response handler.
  Stream<T> scrape<T>(
    ResponseCallback parse, {
    int concurrency = 4,
    Duration? delay,
    http.Client? client,
    int maxRetries = 2,
  }) => _scrape<T>(this, parse, concurrency: concurrency, delay: delay, client: client, maxRetries: maxRetries);
}

/// Convenience scrape extensions on iterables of [http.BaseRequest] objects.
extension ScrapeIterableBaseRequestExtension on Iterable<http.BaseRequest> {
  /// Scrapes this collection of requests with a Scrapy-style response handler.
  Stream<T> scrape<T>(
    ResponseCallback parse, {
    int concurrency = 4,
    Duration? delay,
    http.Client? client,
    int maxRetries = 2,
  }) => _scrape<T>(this, parse, concurrency: concurrency, delay: delay, client: client, maxRetries: maxRetries);
}

/// Internal functional scraping engine using standard `package:http`.
Stream<T> _scrape<T>(
  Object seeds,
  ResponseCallback parse, {
  int concurrency = 4,
  Duration? delay,
  http.Client? client,
  int maxRetries = 2,
}) {
  late final StreamController<T> controller;
  final httpClient = client ?? http.Client();
  final visited = <Uri>{};
  final queue = Queue<http.BaseRequest>();
  final active = <Future<void>>{};
  final limit = concurrency > 0 ? concurrency : 1;
  var isStopped = false;

  void enqueue(http.BaseRequest req) {
    final dontFilter = _requestDontFilterExpando[req] ?? false;
    if (!dontFilter && !visited.add(req.url)) return;
    queue.add(req);
  }

  http.BaseRequest? toRequest(Object seed) {
    if (seed is http.BaseRequest) {
      return seed;
    } else if (seed is Uri) {
      return http.Request('GET', seed);
    } else if (seed is String) {
      final parsed = Uri.tryParse(seed);
      if (parsed != null) return http.Request('GET', parsed);
    }
    return null;
  }

  if (seeds is Iterable<Object>) {
    for (final s in seeds) {
      final req = toRequest(s);
      if (req != null) enqueue(req);
    }
  } else if (seeds is Iterable) {
    for (final dynamic s in seeds) {
      if (s is Object) {
        final req = toRequest(s);
        if (req != null) enqueue(req);
      }
    }
  } else {
    final req = toRequest(seeds);
    if (req != null) enqueue(req);
  }

  void schedule() {
    if (isStopped || controller.isClosed) return;

    while (queue.isNotEmpty && active.length < limit) {
      final req = queue.removeFirst();

      late final Future<void> task;
      task = Future<void>(() async {
        try {
          if (delay != null && delay > .zero) {
            await Future<void>.delayed(delay);
          }
          if (isStopped) return;

          http.Response? rawRes;
          var attempts = 0;
          while (attempts <= maxRetries && rawRes == null && !isStopped) {
            try {
              final streamed = await httpClient.send(_cloneRequest(req));
              rawRes = await http.Response.fromStream(streamed);
            } catch (err) {
              attempts++;
              if (attempts > maxRetries) rethrow;
              await Future<void>.delayed((200 * attempts).ms);
            }
          }

          if (isStopped || rawRes == null) return;

          final reqMeta = _requestMetaExpando[req] ?? const {};
          _metaExpando[rawRes] = reqMeta;
          _emitExpando[rawRes] = (item) {
            if (!controller.isClosed && item is T) {
              controller.add(item);
            }
          };
          _followExpando[rawRes] =
              (
                Object target, {
                ResponseCallback? callback,
                Map<String, dynamic>? meta,
                Map<String, String>? headers,
                bool dontFilter = false,
              }) {
                final baseUri = rawRes?.request?.url ?? req.url;
                final resolvedUri = _resolve(baseUri, target);
                if (resolvedUri != null) {
                  final nextReq = http.Request('GET', resolvedUri);
                  if (headers != null) nextReq.headers.addAll(headers);
                  _requestMetaExpando[nextReq] = {...reqMeta, ...?meta};
                  if (callback != null) _requestCallbackExpando[nextReq] = callback;
                  if (dontFilter) _requestDontFilterExpando[nextReq] = true;
                  enqueue(nextReq);
                  schedule();
                }
              };

          final handler = _requestCallbackExpando[req] ?? parse;
          final result = await handler(rawRes);
          if (result != null && !controller.isClosed) {
            if (result is Iterable<T>) {
              for (final item in result) {
                controller.add(item);
              }
            } else if (result is T) {
              controller.add(result);
            }
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
    onListen: schedule,
    onCancel: () {
      isStopped = true;
      if (client == null) httpClient.close();
    },
  );

  return controller.stream;
}

http.BaseRequest _cloneRequest(http.BaseRequest original) {
  if (original is http.Request) {
    final cloned = http.Request(original.method, original.url);
    cloned.headers.addAll(original.headers);
    cloned.encoding = original.encoding;
    cloned.followRedirects = original.followRedirects;
    cloned.maxRedirects = original.maxRedirects;
    cloned.persistentConnection = original.persistentConnection;
    if (original.bodyBytes.isNotEmpty) {
      cloned.bodyBytes = original.bodyBytes;
    }
    _copyExpando(original, cloned);
    return cloned;
  }
  return original;
}

void _copyExpando(http.BaseRequest from, http.BaseRequest to) {
  final meta = _requestMetaExpando[from];
  if (meta != null) _requestMetaExpando[to] = meta;
  final cb = _requestCallbackExpando[from];
  if (cb != null) _requestCallbackExpando[to] = cb;
  final df = _requestDontFilterExpando[from];
  if (df != null) _requestDontFilterExpando[to] = df;
}

Uri? _resolve(Uri base, Object target) {
  if (target is Uri) {
    return target.isAbsolute ? target : base.resolveUri(target);
  } else if (target is String) {
    final trimmed = target.trim();
    if (trimmed.isEmpty) return null;
    return base.resolve(trimmed);
  }
  return null;
}
