/// # Pipeline Request, Response & Router
///
/// The units a crawl moves through: a [Request] the engine schedules, the
/// [Response] a handler receives, and the [Router] that decides which handler
/// runs.
library;

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'engine.dart';
import 'http.dart';

/// Converts [target] (URL string, raw HTML, file path, or arbitrary string) into a [Uri].
Uri coerce(String target, {Uri? base}) {
  final str = target.trim();
  if (str.isEmpty) return Uri();

  // Recognized schemes come first: a URL is a URL even when its query happens
  // to carry markup-looking characters, so `?q=</b>` stays a request rather
  // than becoming an inline document.
  if (str.startsWith('http://') ||
      str.startsWith('https://') ||
      str.startsWith('file://') ||
      str.startsWith('data:') ||
      str.startsWith('string:')) {
    return Uri.parse(str);
  }

  // HTML content
  if (str.startsWith('<') || str.contains('</') || str.contains('/>')) {
    return Uri.dataFromString(str, mimeType: 'text/html', encoding: utf8);
  }

  // Resolve relative against base
  if (base != null &&
      (base.scheme == 'http' ||
          base.scheme == 'https' ||
          base.scheme == 'file')) {
    return base.resolve(str);
  }

  // Local file
  if (p.isAbsolute(str)) {
    return Uri.file(str);
  }

  final parsed = Uri.tryParse(str);
  if (parsed != null && parsed.hasScheme) {
    return parsed;
  }

  return Uri(scheme: 'string', path: Uri.encodeComponent(str));
}

// ============================================================================
// PIPELINE REQUEST, RESPONSE & ROUTER
// ============================================================================

/// A scheduled request, carrying routing metadata through the pipeline.
///
/// [tag] and [meta] survive the round trip, so a handler that queued a request
/// can recognise the response and recover the context it queued it with:
///
/// ```dart
/// res.follow(href, tag: 'song', meta: {'name': a.text});
/// // later, in the 'song' handler:
/// final name = res.meta['name'] as String;
/// ```
class Request<T> {
  /// The absolute URL to fetch.
  final Uri url;

  /// The HTTP method.
  final HttpMethod method;

  /// Headers for this request alone, merged over the client's defaults.
  final Map<String, String> headers;

  /// The request body, if any.
  final Body? body;

  /// Scheduling weight. Higher values are served first; ties keep insertion
  /// order.
  final int priority;

  /// A label used to route the response. See [Router.tag].
  final String? tag;

  /// Arbitrary context carried to the response, untouched by the engine.
  final Map<String, Object?> meta;

  /// Whether to de-duplicate this request. Defaults to true.
  final bool dedupe;

  /// Crawl depth of this request (0 for seed requests).
  final int depth;

  /// The engine that scheduled this request, set on [Engine.add].
  Engine<dynamic>? engine;

  /// Creates a request for [url].
  Request(
    this.url, {
    this.method = HttpMethod.get,
    Map<String, String>? headers,
    this.body,
    this.priority = 0,
    this.tag,
    Map<String, Object?>? meta,
    this.engine,
    this.dedupe = true,
    this.depth = 0,
  }) : headers = headers ?? {},
       meta = meta ?? {};

  /// Restores a request from the map [toJson] produced.
  ///
  /// [engine] is not part of the serialized form: a restored request belongs
  /// to whichever engine schedules it next.
  ///
  /// Throws [FormatException] when [json] carries no usable `url`.
  factory Request.fromJson(Map<String, Object?> json) {
    final url = Uri.tryParse(json['url'] as String? ?? '');
    if (url == null) {
      throw FormatException('Request has no usable url: ${json['url']}');
    }
    final wire = (json['method'] as String? ?? 'GET').toUpperCase();
    final body = json['body'];
    return Request<T>(
      url,
      method: HttpMethod.values.firstWhere(
        (m) => m.wire == wire,
        orElse: () => HttpMethod.get,
      ),
      headers: {
        for (final entry in (json['headers'] as Map? ?? const {}).entries)
          entry.key.toString(): entry.value.toString(),
      },
      body:
          body is Map
              ? Body.fromJson(body.cast<String, Object?>())
              : null,
      priority: (json['priority'] as num? ?? 0).toInt(),
      tag: json['tag'] as String?,
      meta: (json['meta'] as Map? ?? const {}).cast<String, Object?>(),
      dedupe: json['dedupe'] as bool? ?? true,
      depth: (json['depth'] as num? ?? 0).toInt(),
    );
  }

  /// Serializes this request to a JSON-compatible map.
  ///
  /// This is what a crawl writes when it saves its frontier, so everything
  /// scheduling and routing depend on round-trips: the method, headers, body,
  /// priority, tag, depth and [meta]. Values in [meta] must be JSON-encodable
  /// to survive; anything else throws when the snapshot is written.
  Map<String, Object?> toJson() => {
    'url': url.toString(),
    if (method != HttpMethod.get) 'method': method.wire,
    if (headers.isNotEmpty) 'headers': headers,
    if (body != null) 'body': body!.toJson(),
    if (priority != 0) 'priority': priority,
    if (tag != null) 'tag': tag,
    if (meta.isNotEmpty) 'meta': meta,
    if (!dedupe) 'dedupe': false,
    if (depth != 0) 'depth': depth,
  };

  @override
  String toString() => '${method.wire} $url';
}

/// A fetched response, with the pipeline controls a handler needs.
///
/// Extends [HttpResponse], so [HttpResponse.$], [HttpResponse.$xpath] and
/// [HttpResponse.body] are all available.
class Response<T> extends HttpResponse {
  /// The request that produced this response.
  final Request<T> request;

  /// The engine running this pipeline, or `null` for a standalone fetch.
  Engine<dynamic>? engine;

  /// Creates a response. Normally produced by a [Downloader].
  Response({
    required this.request,
    Uri? url,
    Uri? requested,
    super.status = 200,
    super.headers = const {},
    super.bytes = const [],
    super.encoding,
    super.cached,
    this.engine,
  }) : super(url: url ?? request.url, requested: requested ?? request.url);

  /// Crawl depth of the request that produced this response.
  int get depth => request.depth;

  /// The context [Request.meta] this response's request carried.
  Map<String, Object?> get meta => request.meta;

  /// The [Request.tag] this response's request carried.
  String? get tag => request.tag;

  /// Emits [item] as a pipeline result. See [Engine.emit].
  ///
  /// Throws [StateError] when the response has no engine.
  void emit(T item) => _engine.emit(item);

  /// Schedules [url], resolved against this page, with a `Referer` header.
  ///
  /// This is how a crawl advances: a handler follows the links it finds.
  /// Relative URLs resolve against [Response.url], and duplicates are dropped
  /// by the engine's [Deduplicator].
  ///
  /// Pass [method] and [body] to follow a form rather than a link — a search
  /// that posts its query, a paginator behind a POST — instead of reaching for
  /// `engine.add` by hand:
  ///
  /// ```dart
  /// res.follow(
  ///   res.$('form.search').attr('action')!,
  ///   method: HttpMethod.post,
  ///   body: Body.form({'q': 'widgets', 'page': '2'}),
  ///   tag: 'results',
  /// );
  /// ```
  ///
  /// De-duplication accounts for the body, so two posts to one URL with
  /// different fields are two requests rather than one.
  ///
  /// Throws [StateError] when the response has no engine.
  void follow(
    String url, {
    HttpMethod method = HttpMethod.get,
    Body? body,
    String? tag,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    int priority = 0,
    bool dedupe = true,
  }) => _engine.add(
    Request<T>(
      coerce(url, base: this.url),
      method: method,
      body: body,
      headers: {'Referer': this.url.toString(), ...?headers},
      tag: tag,
      meta: meta,
      priority: priority,
      dedupe: dedupe,
      depth: request.depth + 1,
    ),
  );

  /// Stops the pipeline after in-flight work settles. See [Engine.stop].
  void stop([String reason = 'Stopped']) => _engine.stop(reason);

  Engine<dynamic> get _engine {
    final engine = this.engine;
    if (engine == null) {
      throw StateError(
        'This response has no engine attached, so it cannot emit, follow, or stop. '
        'Responses from a standalone fetch are not part of a pipeline.',
      );
    }
    return engine;
  }

  @override
  String toString() => '$status $url (${bytes.length} bytes)';
}

/// Handles one [Response] in a pipeline.
///
/// The engine is reachable as [Response.engine], so it is not passed
/// separately.
///
/// Named `Handler` and not `Process`: Dart resolves a package import over a
/// `dart:` one without complaining, so exporting `Process` quietly stopped
/// `Process` meaning `dart:io`'s for every user of this library — while
/// `system.adopt(Process)` still meant that one.
typedef Handler<T> = FutureOr<void> Function(Response<T> response);

/// Dispatches responses to the first matching handler.
///
/// Reachable as [Engine.router]. Rules are tested in registration order, and
/// [fallback] catches anything unmatched.
///
/// ```dart
/// engine.router
///   ..on(RegExp(r'/album$'), (res) { ... })
///   ..tag('disc', (res) { ... })
///   ..status(404, (res) => log.warn('missing ${res.url}'));
/// ```
class Router<T> {
  final List<_Rule<T>> _rules = [];
  Handler<T>? _fallback;

  /// Whether any rule or fallback is registered.
  bool get isNotEmpty => _rules.isNotEmpty || _fallback != null;

  /// Whether no rule or fallback is registered.
  bool get isEmpty => !isNotEmpty;

  /// The number of registered rules, excluding any fallback.
  int get length => _rules.length;

  /// Routes responses whose URL matches [pattern].
  Router<T> on(Pattern pattern, Handler<T> handler) =>
      _add((res) => pattern.allMatches(res.url.toString()).isNotEmpty, handler);

  /// Routes responses whose request carried [Request.tag] equal to [name].
  Router<T> tag(String name, Handler<T> handler) =>
      _add((res) => res.tag == name, handler);

  /// Routes responses with HTTP status [code].
  Router<T> status(int code, Handler<T> handler) =>
      _add((res) => res.status == code, handler);

  /// Handles anything no rule matched.
  Router<T> fallback(Handler<T> handler) {
    _fallback = handler;
    return this;
  }

  /// Runs the first matching handler; returns whether one ran.
  Future<bool> handle(Response<T> response) async {
    for (final rule in _rules) {
      if (!rule.test(response)) continue;
      await rule.handler(response);
      return true;
    }
    final fallback = _fallback;
    if (fallback == null) return false;
    await fallback(response);
    return true;
  }

  Router<T> _add(bool Function(Response<T> res) test, Handler<T> handler) {
    _rules.add(_Rule<T>(test, handler));
    return this;
  }
}

class _Rule<T> {
  final bool Function(Response<T> res) test;
  final Handler<T> handler;

  const _Rule(this.test, this.handler);
}
