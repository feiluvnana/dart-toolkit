/// # Sitemaps
///
/// The format codec, spelled exactly like the rest: `parse`, `read`, `write`,
/// `format`. A sitemap arrives from outside Dart with its own words —
/// `<urlset>`, `<loc>`, `<sitemapindex>` — so it sits with the other formats
/// rather than with the networking code.
///
/// There is a parser here and no *loader*, because following a sitemap index
/// is a crawl and gets depth, dedupe and politeness for free:
///
/// ```dart
/// // setup: final index = 'https://x.test/sitemap.xml'.url;
/// final urls = await crawl(
///   [Fetch(index)],
///   (r) => parseSitemap(r.text).map(Fetch.new),
/// ).depth(8).flow.map((r) => r.url).toList();
/// ```
///
/// That is nine lines against ninety, and it cannot loop: `Sitemap.load`
/// carried its own visited set and its own `maxDepth: 8` to avoid the index
/// that points back at itself.
library;

import '../src/format.dart';
import 'format.dart';

// ============================================================================
// SITEMAPS (format.sitemap.*)
// ============================================================================

final RegExp _loc = RegExp(
  r'<loc>(?:<!\[CDATA\[)?\s*(https?://[^\]<\s]+)\s*(?:\]\]>)?</loc>',
  caseSensitive: false,
);

/// The sitemap codec. Reach it as [parseSitemap] or [DocumentFormat.sitemap].
///
/// Reads XML `<urlset>`, XML `<sitemapindex>` and newline-delimited plain
/// text alike, because all three are what a `Sitemap:` line points at and
/// which one arrived is not the caller's question.
class SitemapFormat
    with FileFormat<List<Uri>, Iterable<Uri>>
    implements DocumentFormat<List<Uri>> {
  /// Creates the codec. Prefer the shared [DocumentFormat.sitemap] instance.
  const SitemapFormat();

  /// Parses [text] into the URLs it names.
  ///
  /// Text that names none is the empty list rather than a throw — the
  /// contract every reader in this library keeps.
  @override
  List<Uri> parse(String text) {
    final matches = _loc.allMatches(text);
    final uris = <Uri>[];
    if (matches.isNotEmpty) {
      for (final match in matches) {
        final raw = match.group(1);
        if (raw == null) continue;
        final uri = Uri.tryParse(raw.trim());
        if (uri != null && uri.hasScheme) uris.add(uri);
      }
      return List<Uri>.unmodifiable(uris);
    }

    // A plain-text sitemap: one URL per line.
    for (var line in text.split(RegExp(r'\r?\n'))) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final uri = Uri.tryParse(line);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        uris.add(uri);
      }
    }
    return List<Uri>.unmodifiable(uris);
  }

  /// Whether [text] is a sitemap *index* rather than a leaf sitemap.
  ///
  /// A crawl following one does not need to ask — an index's children parse
  /// as URLs like any other, so `depth` bounds the descent — but a script
  /// reporting on a file does.
  bool nested(String text) => text.contains('<sitemapindex');

  /// Renders [value] as a `<urlset>` document.
  @override
  String format(Iterable<Uri> value) {
    final out = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">');
    for (final url in value) {
      out.writeln('  <url><loc>$url</loc></url>');
    }
    out.writeln('</urlset>');
    return out.toString();
  }
}
