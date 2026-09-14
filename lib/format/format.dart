/// # Formats
///
/// File formats: knowledge Dart does not have about how a document is shaped.
/// One pair of functions per format — [parseHtml], [parseJson]/[toJsonString],
/// [parseYaml]/[toYamlString], [parseToml]/[toTomlString],
/// [parseCsv]/[toCsvString], [parseRobots], [parseSitemap] — plus archives in
/// `zip.dart`.
///
/// Seven of the eight formats are codecs, and every one implements [DocumentFormat],
/// which is what lets a response be read through any of them without `net`
/// learning which:
///
/// ```dart
/// res.parse(DocumentFormat.html).$('h1').text;
/// res.parse(DocumentFormat.json).at('data.items');
/// ```
///
/// Archives are the eighth and are **not** a codec: an archive is a container
/// of files, not a document with a shape, so there is no cursor to hand back
/// and `parse(String)` is the wrong signature for bytes. They have [zip],
/// [unzip], [zipBytes], [listArchive] and [extractFromArchive] instead.
///
/// **Not executables.** Wrapping a binary is [run] plus arguments, and a
/// script that wants `git`, `gh`, `docker` or `ffmpeg` already has the whole
/// of each of them there — where a wrapper only ever has the five subcommands
/// somebody thought to add.
///
/// ```dart
/// final page = parseHtml(res.text);
/// final cfg = await const YamlFormat().read('config.yaml');
/// await const YamlFormat().write('config.yaml', cfg.raw);
/// await zip('site', 'site.zip');
/// ```
library;

import 'dart:io';

import '../io/entry.dart';
import '../src/format.dart';
import '../src/csv.dart';
import '../src/fs.dart';
import '../src/json.dart';
import '../src/markup.dart';
import 'csv.dart';
import 'html.dart';
import 'json.dart';
import 'robots.dart';
import 'sitemap.dart';
import 'toml.dart';
import 'yaml.dart';
import 'zip.dart';

export 'csv.dart';
export 'form.dart';
export 'html.dart' hide $, $xpath;
export 'json.dart';
export 'robots.dart';
export 'sitemap.dart';
export 'toml.dart';
export 'yaml.dart';
export 'zip.dart';

// ============================================================================
// TOP-LEVEL FORMAT & CODEC HELPERS
// ============================================================================

/// Parses HTML string into a chainable [Markup] cursor with CSS/XPath selectors.
Markup parseHtml(String html) => const HtmlFormat().parse(html);

/// Parses JSON string into a [Json] document cursor.
Json parseJson(String json) => const JsonFormat().parse(json);

/// Encodes [data] as JSON string, indented by [indent] spaces.
String toJsonString(Object? data, {int indent = 2}) =>
    const JsonFormat().format(data, indent: indent);

/// Parses YAML string into a document cursor.
Json parseYaml(String yaml) => const YamlFormat().parse(yaml);

/// Formats [data] as YAML string.
String toYamlString(Object? data) => const YamlFormat().format(data);

/// Parses TOML string into a document cursor.
Json parseToml(String toml) => const TomlFormat().parse(toml);

/// Formats [data] as TOML string.
String toTomlString(Object? data) => const TomlFormat().format(data);

/// Parses CSV text into a [Csv] cursor.
Csv parseCsv(String text, {String delimiter = ','}) =>
    const CsvFormat().parse(text, delimiter: delimiter);

/// Formats record rows or a grid of cells as CSV text.
String toCsvString(
  Iterable<dynamic> rows, {
  List<String>? headers,
  String delimiter = ',',
  String newline = '\n',
}) {
  final first = rows.firstOrNull;
  if (first is Map) {
    return const CsvFormat().format(
      rows.cast<Map<String, Object?>>(),
      headers: headers,
      delimiter: delimiter,
      newline: newline,
    );
  }
  if (first is Iterable) {
    return const CsvFormat().cells(
      rows.map((r) => (r as Iterable).cast<Object?>().toList()),
      headers: headers,
      delimiter: delimiter,
      newline: newline,
    );
  }
  return const CsvFormat().format(
    rows.cast<Map<String, Object?>>(),
    headers: headers,
    delimiter: delimiter,
    newline: newline,
  );
}

/// Parses a `robots.txt` file content into a [Robots] evaluator.
Robots parseRobots(String content) => const RobotsFormat().parse(content);

/// Parses a sitemap XML or text content into a list of [Uri]s.
List<Uri> parseSitemap(String content) => const SitemapFormat().parse(content);

/// Reading a document off the disk and writing one back, for the codecs that
/// all do it the same way.
///
/// Every `read` in this domain is `io` plus [DocumentFormat.parse], and every [write]
/// is [format] plus an atomic `io` write, so both are written once here rather
/// than five times each. A file that is not there parses as the empty string,
/// which every codec already reads as the empty cursor — so a missing optional
/// config needs no [hasContent] in front of it.
///
/// ```dart
/// final cfg = await const YamlFormat().read('config.yaml');
/// await const YamlFormat().write('config.yaml', cfg.raw);
/// ```
///
/// [writeJson] is JSON\'s shorthand over [write] — the same call with a shorter
/// name for the format everyone uses, and the same `.part` staging.
mixin FileFormat<T, V> implements DocumentFormat<T> {
  /// Reads the document at [path] through [DocumentFormat.parse].
  Future<T> read(String path) async {
    final file = File(path);
    if (!await file.exists()) return parse('');
    return parse(await file.readAsString());
  }

  /// Renders [value] as this format's text.
  ///
  /// `V` is what the format actually takes — raw data for `json`, `yaml` and
  /// `toml`, a [Markup] cursor for `html`, rows for `csv`. This declaration is
  /// what lets [write] reach it without knowing which.
  String format(V value);

  /// Writes [value] to [path] atomically, staged through a `.part` file.
  ///
  /// The inverse of [read], and one line over [format]: the file appears whole
  /// or not at all, which is this library's rule for every write.
  Future<FileSystemEntry> write(String path, V value) async =>
      Fs.entryFor((await Fs.write(path, format(value))).path);
}
