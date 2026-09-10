/// # HTTP Cache
///
/// An on-disk store of responses, so a second run over the same pages
/// revalidates or skips them instead of downloading them all again.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../src/fs.dart';
import '../util/hash.dart';
import 'http.dart';

// ============================================================================
// HTTP CACHE
// ============================================================================

const HashAccessor _hash = HashAccessor();

/// One response held in an [HttpCache], with the moment it was stored.
///
/// [fresh] answers whether it can be served without asking the server at all;
/// [validators] are the headers that ask cheaply when it cannot.
class CacheEntry {
  /// The stored response.
  final Reply response;

  /// When it was stored.
  final DateTime stored;

  /// Creates an entry.
  CacheEntry({required this.response, required this.stored});

  /// Restores an entry from the map [toJson] produced.
  ///
  /// Throws [FormatException] when [json] holds no usable entry.
  factory CacheEntry.fromJson(Map<String, Object?> json) {
    final url = Uri.tryParse(json['url'] as String? ?? '');
    final stored = DateTime.tryParse(json['stored'] as String? ?? '');
    if (url == null || stored == null) {
      throw const FormatException('Cache entry has no usable url or date');
    }
    return CacheEntry(
      stored: stored,
      response: Reply(
        url: url,
        status: (json['status'] as num? ?? 200).toInt(),
        headers: {
          for (final entry in (json['headers'] as Map? ?? const {}).entries)
            entry.key.toString(): entry.value.toString(),
        },
        bytes: base64Decode(json['body'] as String? ?? ''),
        cached: true,
      ),
    );
  }

  /// How long this response may be served without revalidating, from
  /// `Cache-Control: max-age` or from `Expires` against `Date`.
  ///
  /// `null` when the server said nothing about freshness, and [Duration.zero]
  /// when it said `no-cache` — both of which mean ask before serving.
  Duration? get lifetime {
    final control = response.headers['cache-control']?.toLowerCase();
    if (control != null) {
      if (control.contains('no-cache') || control.contains('no-store')) {
        return Duration.zero;
      }
      final maxAge = RegExp(r'max-age\s*=\s*(\d+)').firstMatch(control);
      if (maxAge != null) {
        return Duration(seconds: int.parse(maxAge.group(1)!));
      }
    }

    final expires = response.headers['expires'];
    if (expires == null) return null;
    try {
      final until = HttpDate.parse(expires);
      final from = response.headers['date'];
      final since = from == null ? stored : HttpDate.parse(from);
      final span = until.difference(since);
      return span.isNegative ? Duration.zero : span;
    } catch (_) {
      // An unparseable Expires is not a promise of anything.
      return null;
    }
  }

  /// Whether this response is still within its [lifetime].
  bool get fresh {
    final span = lifetime;
    if (span == null || span == Duration.zero) return false;
    return DateTime.now().difference(stored) < span;
  }

  /// The headers that ask the server whether this entry is still good.
  ///
  /// Empty when the response carried neither an `ETag` nor a `Last-Modified`,
  /// which leaves nothing to revalidate with and means a plain refetch.
  Map<String, String> get validators {
    final etag = response.headers['etag'];
    final modified = response.headers['last-modified'];
    return {
      if (etag != null) 'If-None-Match': etag,
      if (modified != null) 'If-Modified-Since': modified,
    };
  }

  /// Serializes this entry to a JSON-compatible map.
  Map<String, Object?> toJson() => {
    'version': HttpCache.version,
    'url': response.url.toString(),
    'stored': stored.toIso8601String(),
    'status': response.status,
    'headers': response.headers,
    // Base64: a cached response is as likely to be an image as a page.
    'body': base64Encode(response.bytes),
  };

  @override
  String toString() =>
      'CacheEntry(${response.status} ${response.url}, '
      'stored: ${stored.toIso8601String()}, fresh: $fresh)';
}

/// Responses kept on disk between runs, reachable through
/// `Fetcher(cache: ...)` and `net.crawl(...).cache(...)`.
///
/// Re-running a scrape over pages that have not changed is the common case
/// while an extractor is being written. With a cache the second run asks each
/// server whether anything moved — an `ETag` or `If-Modified-Since` exchange
/// that transfers no body — and serves what it already has when the answer is
/// no. A response still inside its `max-age` is served without asking at all.
///
/// ```dart
/// final client = Fetcher(cache: HttpCache('.cache'));
/// final res = await client.get('https://example.com'.url);
/// if (res.cached) print('served from disk');
/// ```
///
/// One file per URL, named by a digest of it. There is no eviction: a cache is
/// cleared with [clear] or by deleting the directory.
class HttpCache {
  /// The version of the stored format this class writes and reads.
  static const int version = 1;

  /// The directory holding the stored responses.
  final String dir;

  /// Creates a cache over [dir], which is created on the first write.
  const HttpCache(this.dir);

  /// The file [url] is stored in, whether or not it exists.
  String path(Uri url) => p.join(dir, '${_hash.sha(url.toString())}.json');

  /// The entry stored for [url], or `null` when nothing is stored.
  ///
  /// A file that cannot be read is treated as a miss and removed: a corrupt
  /// cache should cost a refetch, never a failed crawl.
  Future<CacheEntry?> read(Uri url) async {
    final file = File(path(url));
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) throw const FormatException('not an entry');
      final json = decoded.cast<String, Object?>();
      if ((json['version'] as num? ?? version).toInt() > version) {
        return null;
      }
      return CacheEntry.fromJson(json);
    } catch (_) {
      await remove(url);
      return null;
    }
  }

  /// Stores [response] under [url], replacing anything already there.
  Future<File> write(Uri url, Reply response) async {
    await Fs.mkdir(dir);
    final entry = CacheEntry(response: response, stored: DateTime.now());
    return Fs.dump(path(url), entry.toJson(), pretty: false);
  }

  /// Forgets [url]. Returns whether anything was stored.
  Future<bool> remove(Uri url) async {
    final file = File(path(url));
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }

  /// Forgets everything, leaving the directory in place.
  Future<int> clear() async {
    final directory = Directory(dir);
    if (!await directory.exists()) return 0;
    var removed = 0;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        await entity.delete();
        removed++;
      }
    }
    return removed;
  }

  @override
  String toString() => 'HttpCache($dir)';
}
