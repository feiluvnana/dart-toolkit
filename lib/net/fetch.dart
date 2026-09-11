/// # Requests (`Fetch`) and the transport seam (`Send`)
///
/// A [Fetch] is what goes out; a [Send] is anything that can answer one.
///
/// **A transport is a function.** Through 5.5.0 it was a four-class hierarchy
/// — `Downloader`, `DownloaderEvents`, `HttpDownloader`, `MapDownloader` —
/// and a subclass inherited an engine back-pointer, six mutable scheduling
/// fields, a worker loop with a per-host throttle table, and a `save()` hook
/// that threw `UnsupportedError` and had no caller anywhere in the library.
/// The whole contract a foreign transport needs is one line:
///
/// ```dart
/// // A headless browser, a fixture, and middleware — which had no spelling
/// // at all before.
/// Future<Reply> fixture(Fetch f) async =>
///     Reply.text('<h1>hi</h1>', fetch: f);
///
/// Send logged(Send inner) => (f) async {
///   final res = await inner(f);
///   print('${res.status} ${f.url}');
///   return res;
/// };
/// ```
///
/// [Fetcher] implements [Send] itself, so `net.http` is the default one and
/// `Crawl.using` takes any of them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../collection/dictionary.dart';
import '../collection/slot.dart';
import '../src/method.dart';
import 'http.dart';

// ============================================================================
// REQUESTS (Fetch) & THE TRANSPORT SEAM (Send)
// ============================================================================

/// Anything that can answer a [Fetch].
///
/// A [Fetcher] is one, so `net.http` is the default. A closure over a `Map`
/// is one, which is what `MapDownloader` was a public class for. A function
/// that wraps another is one, which is middleware and had no spelling before.
typedef Send = Future<Reply> Function(Fetch fetch);

/// Turns [target] — a URL, raw markup, a file path or a bare string — into a
/// [Uri].
///
/// Recognised schemes win, so `?q=</b>` stays a request rather than becoming
/// an inline document.
Uri coerce(String target, {Uri? base}) {
  final str = target.trim();
  if (str.isEmpty) return Uri();

  if (str.startsWith('http://') ||
      str.startsWith('https://') ||
      str.startsWith('file://') ||
      str.startsWith('data:') ||
      str.startsWith('string:')) {
    return Uri.parse(str);
  }

  if (str.startsWith('<') || str.contains('</') || str.contains('/>')) {
    return Uri.dataFromString(str, mimeType: 'text/html', encoding: utf8);
  }

  if (base != null &&
      (base.scheme == 'http' ||
          base.scheme == 'https' ||
          base.scheme == 'file')) {
    return base.resolve(str);
  }

  if (p.isAbsolute(str)) return Uri.file(str);

  final parsed = Uri.tryParse(str);
  if (parsed != null && parsed.hasScheme) return parsed;

  return Uri(scheme: 'string', path: Uri.encodeComponent(str));
}

/// A request: a URL, a method, and the context it carries.
///
/// [tag] and [meta] survive the round trip, so the function that produced a
/// request recognises the reply and recovers what it queued it with:
///
/// ```dart
/// // setup: const title = Slot<String>('title'); final res = Reply.text('');
/// res.follow('/song/1', tag: 'song', meta: [title('Hey Jude')]);
/// // later, for the reply to that:
/// final String? name = res.fetch.meta.read(title);
/// ```
///
/// **No type parameter.** It carried one through 5.5.0 — `Fetch<T>`, where
/// `T` was the *item* type a handler emitted — used in exactly one place, a
/// back-pointer to the engine that owned it. A request has no item type; it
/// had one because it held a pointer to something that did. Thirteen public
/// types were generic for that reason, and none of them is now.
final class Fetch {
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

  /// A label carried to the reply, for the `switch` inside a crawl's `next`.
  ///
  /// This is the router: `switch (res.fetch.tag)` is exhaustive-checked by
  /// the compiler, where `Router`, `route()` and `tag()` were three public
  /// members that were not.
  final String? tag;

  /// Context carried to the reply, untouched by the crawl.
  ///
  /// Read and written through [Slot]s, so what was stored comes back with
  /// its type — see the `Slotted` extension on [Dictionary].
  final Dictionary<String, Object?> meta;

  /// Whether to de-duplicate this request. Defaults to true.
  final bool dedupe;

  /// How many hops from a seed this is; `0` for a seed.
  final int depth;

  /// Creates a request for [url].
  Fetch(
    this.url, {
    this.method = HttpMethod.get,
    Map<String, String>? headers,
    this.body,
    this.priority = 0,
    this.tag,
    Iterable<(String, Object?)>? meta,
    this.dedupe = true,
    this.depth = 0,
  }) : headers = headers ?? {},
       meta = Dictionary.of(meta ?? const []);

  /// Restores a request from the map [toJson] produced.
  ///
  /// Throws [FormatException] when [json] carries no usable `url`.
  factory Fetch.fromJson(Map<String, Object?> json) {
    final url = Uri.tryParse(json['url'] as String? ?? '');
    if (url == null) {
      throw FormatException('Fetch has no usable url: ${json['url']}');
    }
    final body = json['body'];
    return Fetch(
      url,
      method: HttpMethod.of(json['method'] as String? ?? 'GET'),
      headers: {
        for (final entry in (json['headers'] as Map? ?? const {}).entries)
          entry.key.toString(): entry.value.toString(),
      },
      body: body is Map ? Body.fromJson(body.cast<String, Object?>()) : null,
      priority: (json['priority'] as num? ?? 0).toInt(),
      tag: json['tag'] as String?,
      meta: (json['meta'] as Map? ?? const {}).entries.map(
        (entry) => (entry.key.toString(), entry.value),
      ),
      dedupe: json['dedupe'] as bool? ?? true,
      depth: (json['depth'] as num? ?? 0).toInt(),
    );
  }

  /// Serializes this request to a JSON-compatible map.
  ///
  /// This is what a crawl writes when it saves its frontier, so everything
  /// scheduling depends on round-trips. Values in [meta] must be
  /// JSON-encodable to survive; anything else throws when the position is
  /// written.
  Map<String, Object?> toJson() => {
    'url': url.toString(),
    if (method != HttpMethod.get) 'method': method.wire,
    if (headers.isNotEmpty) 'headers': headers,
    if (body != null) 'body': body!.toJson(),
    if (priority != 0) 'priority': priority,
    if (tag != null) 'tag': tag,
    if (!meta.empty) 'meta': meta.map,
    if (!dedupe) 'dedupe': false,
    if (depth != 0) 'depth': depth,
  };

  @override
  String toString() => '${method.wire} $url';
}
