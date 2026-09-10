/// # Sitemap XML & Text Parser
///
/// Parses standard Sitemap protocol XML files (`<urlset>` with `<url><loc>`),
/// Sitemap Index files (`<sitemapindex>` with `<sitemap><loc>`), and plain text
/// URL lists. Supports recursive loading of sitemap indices.
library;

import 'dart:async';

import '../util/sequence.dart';
import 'net.dart';

/// Sitemap parser and fetcher.
class Sitemap {
  static final RegExp _locRegex = RegExp(
    r'<loc>(?:<!\[CDATA\[)?\s*(https?://[^\]<\s]+)\s*(?:\]\]>)?</loc>',
    caseSensitive: false,
  );

  /// Whether [content] represents a sitemap index rather than a leaf sitemap.
  static bool nested(String content) => content.contains('<sitemapindex');

  /// Parses [content] into the [Uri]s it names.
  ///
  /// Supports XML `<urlset>`, `<sitemapindex>`, and newline-delimited plain text.
  static Sequence<Uri> parse(String content) {
    final matches = _locRegex.allMatches(content);
    if (matches.isNotEmpty) {
      final uris = <Uri>[];
      for (final m in matches) {
        final raw = m.group(1);
        if (raw != null) {
          final uri = Uri.tryParse(raw.trim());
          if (uri != null && uri.hasScheme) {
            uris.add(uri);
          }
        }
      }
      return Sequence(List<Uri>.unmodifiable(uris));
    }

    // Plain-text sitemap: one URL per line
    final uris = <Uri>[];
    for (var line in content.split(RegExp(r'\r?\n'))) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final uri = Uri.tryParse(line);
      if (uri != null &&
          uri.hasScheme &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        uris.add(uri);
      }
    }
    return Sequence(List<Uri>.unmodifiable(uris));
  }

  /// The deepest chain of sitemap indices [load] will follow.
  static const int maxDepth = 8;

  /// Fetches a sitemap from [url] and parses its URLs.
  ///
  /// If the target is a Sitemap Index and [recursive] is `true`, fetches all
  /// linked child sitemaps and returns the aggregated leaf URLs. An index that
  /// points back at itself, or at another index that points back to it, is
  /// followed only once: every fetched URL is remembered, and the descent
  /// stops at [maxDepth] regardless.
  static Future<Sequence<Uri>> load(
    Uri url, {
    Fetcher? client,
    bool recursive = true,
    int maxDepth = maxDepth,
  }) => _load(
    url,
    client ?? net.http,
    recursive: recursive,
    remaining: maxDepth,
    visited: <String>{},
  );

  static Future<Sequence<Uri>> _load(
    Uri url,
    Fetcher client, {
    required bool recursive,
    required int remaining,
    required Set<String> visited,
  }) async {
    if (!visited.add(url.removeFragment().toString())) {
      return const Sequence<Uri>.empty();
    }

    final res = await client.get(url);
    if (!res.ok) return const Sequence<Uri>.empty();

    final isIdx = nested(res.body);
    final uris = parse(res.body);

    if (isIdx && recursive && remaining > 0) {
      final results = <Uri>[];
      for (final childUrl in uris.list) {
        results.addAll(
          (await _load(
            childUrl,
            client,
            recursive: true,
            remaining: remaining - 1,
            visited: visited,
          )).list,
        );
      }
      return Sequence(List<Uri>.unmodifiable(results));
    }

    return uris;
  }
}
