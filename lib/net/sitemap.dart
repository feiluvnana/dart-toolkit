/// # Sitemap XML & Text Parser
///
/// Parses standard Sitemap protocol XML files (`<urlset>` with `<url><loc>`),
/// Sitemap Index files (`<sitemapindex>` with `<sitemap><loc>`), and plain text
/// URL lists. Supports recursive loading of sitemap indices.
library;

import 'dart:async';

import 'net.dart';

/// Sitemap parser and fetcher.
class Sitemap {
  static final RegExp _locRegex = RegExp(
    r'<loc>(?:<!\[CDATA\[)?\s*(https?://[^\]<\s]+)\s*(?:\]\]>)?</loc>',
    caseSensitive: false,
  );

  /// Whether [content] represents a sitemap index rather than a leaf sitemap.
  static bool nested(String content) => content.contains('<sitemapindex');

  /// Parses [content] into a list of [Uri]s.
  ///
  /// Supports XML `<urlset>`, `<sitemapindex>`, and newline-delimited plain text.
  static List<Uri> parse(String content) {
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
      return List.unmodifiable(uris);
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
    return List.unmodifiable(uris);
  }

  /// Fetches a sitemap from [url] and parses its URLs.
  ///
  /// If the target is a Sitemap Index and [recursive] is `true`, fetches all
  /// linked child sitemaps and returns the aggregated leaf URLs.
  static Future<List<Uri>> load(
    Uri url, {
    HttpClient? client,
    bool recursive = true,
  }) async {
    final c = client ?? net.http;
    final res = await c.get(url);
    if (!res.ok) return const [];

    final isIdx = nested(res.body);
    final uris = parse(res.body);

    if (isIdx && recursive) {
      final results = <Uri>[];
      for (final childUrl in uris) {
        final childUris = await load(childUrl, client: c, recursive: true);
        results.addAll(childUris);
      }
      return List.unmodifiable(results);
    }

    return uris;
  }
}
