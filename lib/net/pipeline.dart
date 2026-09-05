import 'dart:async';
import 'dart:io';

import '../io/file.dart';
import 'http.dart';
import 'downloader.dart';
import 'engine.dart';

// ============================================================================
// PIPELINE REQUEST, RESPONSE, SCHEDULER & ROUTER
// ============================================================================

/// HTTP request model representing a queued or in-flight crawl task.
class Request<T> {
  /// Target URI of the request.
  final Uri url;

  /// HTTP method (e.g. `GET`, `POST`, `HEAD`).
  final String method;

  /// Request HTTP headers.
  final Map<String, String> headers;

  /// Optional payload for POST or PUT requests.
  final Object? body;

  /// Priority score used by [Priority] scheduler. Higher values are dequeued earlier.
  final int priority;

  /// Routing tag used to map requests to specific `app.tag(...)` handlers.
  final String? tag;

  /// Arbitrary context metadata passed along with the request.
  final Map<String, Object?> meta;

  /// Back-reference to the parent [Engine], if scheduled.
  Engine<T>? engine;

  /// Creates a [Request] instance.
  Request(
    Object url, {
    this.method = 'GET',
    Map<String, String>? headers,
    this.body,
    this.priority = 0,
    this.tag,
    Map<String, Object?>? meta,
    this.engine,
  }) : url = url is Uri ? url : Uri.parse(url.toString()),
       headers = headers ?? {},
       meta = meta ?? {};

  /// Creates a GET request.
  factory Request.get(
    Object url, {
    Map<String, String>? headers,
    int priority = 0,
    String? tag,
    Map<String, Object?>? meta,
  }) => Request(
    url,
    method: 'GET',
    headers: headers,
    priority: priority,
    tag: tag,
    meta: meta,
  );

  /// Creates a POST request with an optional payload.
  factory Request.post(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    int priority = 0,
    String? tag,
    Map<String, Object?>? meta,
  }) => Request(
    url,
    method: 'POST',
    body: body,
    headers: headers,
    priority: priority,
    tag: tag,
    meta: meta,
  );

  @override
  String toString() => '$method $url';
}

/// HTTP response received from downloading a [Request].
///
/// Inherits HTML parsing, jQuery-like selection (`$()`), URL extraction (`links()`, `srcs()`),
/// and atomic file saving (`save()`) from [HttpResponse], while adding crawler flow controls
/// (`follow`, `emit`, `meta`, `tag`, `stop`).
class Response<T> extends HttpResponse {
  /// The originating request.
  final Request<T> request;

  /// Reference to the active [Engine].
  Engine<T>? engine;

  /// Creates a [Response] instance.
  Response({
    required this.request,
    super.status = 200,
    super.headers = const {},
    super.bytes = const [],
    this.engine,
  }) : super(url: request.url);

  /// Request metadata payload.
  Map<String, Object?> get meta => request.meta;

  /// Request routing tag.
  String? get tag => request.tag;

  /// Downloader component associated with this response's crawl engine.
  Downloader<T>? get downloader => engine?.downloader;

  /// Emits an item to the crawler engine stream (1-word).
  void emit(T item) {
    if (engine == null) throw StateError('No engine attached to this response');
    engine!.emit(item);
  }

  /// Adds a new URL or [Request] to the crawler engine queue (1-word).
  void add(Object urlOrReq) {
    if (engine == null) throw StateError('No engine attached to this response');
    engine!.add(urlOrReq);
  }

  /// Resolves [url] against the current response URL and schedules a GET request (1-word).
  ///
  /// Automatically sets the `Referer` header to the current request URL.
  ///
  /// ```dart
  /// res.follow('/next-page', tag: 'listing');
  /// ```
  void follow(
    Object url, {
    String? tag,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    int priority = 0,
  }) {
    if (engine == null) throw StateError('No engine attached to this response');
    final target = url is Uri ? url : request.url.resolve(url.toString());
    final hdrs = <String, String>{
      'Referer': request.url.toString(),
      ...?headers,
    };
    engine!.add(
      Request<T>.get(
        target,
        headers: hdrs,
        tag: tag,
        meta: meta,
        priority: priority,
      ),
    );
  }

  /// Signals the crawler engine to stop processing further requests (1-word).
  void stop([String reason = 'Stopped']) => engine?.stop(reason);

  /// Saves downloaded content to a local file path.
  ///
  /// If [sourceUrl] is provided, downloads the asset from [sourceUrl] (resolved against
  /// the current response URL) directly to [filePath].
  /// Otherwise, writes the response's own [bytes] to [filePath].
  @override
  Future<File> save(
    Object filePath, [
    Object? sourceUrl,
    String part = '.part',
  ]) async {
    final file = filePath is File ? filePath : File(filePath.toString());
    if (sourceUrl != null) {
      final resolved = request.url.resolve(sourceUrl.toString());
      if (engine != null) {
        await engine!.downloader.save(file, resolved, part: part);
        return file;
      } else {
        return Fs.download(resolved, file, part: part);
      }
    } else {
      return Fs.write(file, bytes, part: part);
    }
  }

  @override
  String toString() => '$status ${request.url} (${bytes.length} bytes)';
}

/// Handler signature for processing crawler responses.
typedef Process<T> = FutureOr<void> Function(
  Response<T> response,
  Engine<T> engine,
);

/// Declarative response router matching requests by URL patterns, tags, or status codes.
class Router<T> {
  final List<_Rule<T>> _rules = [];
  Process<T>? _fallback;

  /// Back-reference to the parent [Engine].
  Engine<T>? engine;

  /// Binds the router to an [Engine].
  void attach(Engine<T> engine) {
    this.engine = engine;
  }

  /// Whether the router contains any matching rules or a fallback handler.
  bool get isNotEmpty => _rules.isNotEmpty || _fallback != null;

  /// Whether the router is completely empty.
  bool get isEmpty => !isNotEmpty;

  /// Number of defined routing rules.
  int get length => _rules.length;

  /// Registers a route matching URL string patterns or regular expressions.
  ///
  /// ```dart
  /// router.on(RegExp(r'/item/\d+'), (res, app) async {
  ///   ...
  /// });
  /// ```
  Router<T> on(Pattern pattern, Process<T> handler) {
    _rules.add(
      _Rule<T>(
        test: (res) =>
            pattern.allMatches(res.request.url.toString()).isNotEmpty,
        handler: handler,
      ),
    );
    return this;
  }

  /// Registers a route matching requests scheduled with [name] as their tag.
  ///
  /// ```dart
  /// router.tag('profile', (res, app) async {
  ///   ...
  /// });
  /// ```
  Router<T> tag(String name, Process<T> handler) {
    _rules.add(
      _Rule<T>(test: (res) => res.request.tag == name, handler: handler),
    );
    return this;
  }

  /// Registers a route matching a specific HTTP response [code].
  ///
  /// ```dart
  /// router.status(404, (res, app) => print('Page not found: ${res.url}'));
  /// ```
  Router<T> status(int code, Process<T> handler) {
    _rules.add(_Rule<T>(test: (res) => res.status == code, handler: handler));
    return this;
  }

  /// Registers a default fallback handler invoked when no rules match the response.
  Router<T> fallback(Process<T> handler) {
    _fallback = handler;
    return this;
  }

  /// Evaluates routing rules against [response] and invokes the first matching handler.
  /// Returns `true` if a matching rule or explicit fallback handled the response, `false` otherwise.
  Future<bool> handle(Response<T> response, Engine<T> engine) async {
    for (final rule in _rules) {
      if (rule.test(response)) {
        await rule.handler(response, engine);
        return true;
      }
    }
    if (_fallback != null) {
      await _fallback!(response, engine);
      return true;
    }
    return false;
  }

  /// Evaluates routing rules against [response] and invokes the first matching handler.
  Future<void> call(Response<T> response, Engine<T> engine) async {
    await handle(response, engine);
  }
}

class _Rule<T> {
  final bool Function(Response<T> res) test;
  final Process<T> handler;

  _Rule({required this.test, required this.handler});
}
