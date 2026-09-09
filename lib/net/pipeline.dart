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
  /// Throws [StateError] when the response has no engine.
  void follow(
    String url, {
    String? tag,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    int priority = 0,
    bool dedupe = true,
  }) => _engine.add(
    Request<T>(
      coerce(url, base: this.url),
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
typedef Process<T> = FutureOr<void> Function(Response<T> response);

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
  Process<T>? _fallback;

  /// Whether any rule or fallback is registered.
  bool get isNotEmpty => _rules.isNotEmpty || _fallback != null;

  /// Whether no rule or fallback is registered.
  bool get isEmpty => !isNotEmpty;

  /// The number of registered rules, excluding any fallback.
  int get length => _rules.length;

  /// Routes responses whose URL matches [pattern].
  Router<T> on(Pattern pattern, Process<T> handler) =>
      _add((res) => pattern.allMatches(res.url.toString()).isNotEmpty, handler);

  /// Routes responses whose request carried [Request.tag] equal to [name].
  Router<T> tag(String name, Process<T> handler) =>
      _add((res) => res.tag == name, handler);

  /// Routes responses with HTTP status [code].
  Router<T> status(int code, Process<T> handler) =>
      _add((res) => res.status == code, handler);

  /// Handles anything no rule matched.
  Router<T> fallback(Process<T> handler) {
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

  Router<T> _add(bool Function(Response<T> res) test, Process<T> handler) {
    _rules.add(_Rule<T>(test, handler));
    return this;
  }
}

class _Rule<T> {
  final bool Function(Response<T> res) test;
  final Process<T> handler;

  const _Rule(this.test, this.handler);
}
