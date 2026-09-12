/// # Format Domain (`format.*`)
///
/// File formats: knowledge Dart does not have about how a document is shaped.
/// One name per format — `format.html`, `format.json`, `format.yaml`,
/// `format.toml`, `format.csv`, `format.zip` — because each would pass every
/// other test for a top-level name and they arrive with siblings. See Rule 2
/// in `NAMESPACE.md`.
///
/// The domain is called what it is. It was `tool` for four releases, which was
/// a word chosen before there was anything in it but an archiver, and which
/// invited exactly the thing its own doc comment spent a paragraph forbidding:
/// executables. `format.zip` cannot be misread as a wrapper around the `zip`
/// binary.
///
/// **Still not executables.** Wrapping a binary is `system.run` plus
/// arguments, and a script that wants `git`, `gh`, `docker` or `ffmpeg`
/// already has the whole of each of them there — where a wrapper only ever has
/// the five subcommands somebody thought to add. `tool.git` and `tool.gh` were
/// both tried and both removed for that reason, and the rename closes the
/// question.
///
/// Seven of the eight are codecs, spelled identically — `parse`, `read`,
/// `write`, `format` — and every one implements [Codec], which is what lets a
/// response be read through any of them without `net` learning which.
///
/// `format.zip` is the eighth and is **not** one: an archive is a container of
/// files, not a document with a shape, so there is no cursor to hand back and
/// `parse(String)` is the wrong signature for bytes. It has `pack`, `bundle`,
/// `unpack`, `extract` and `list` instead. It is in this domain because a
/// `.zip` is a file format; it is not a codec because there is nothing to
/// parse into.
///
/// ```dart
/// final cfg = await const YamlAccessor().read('config.yaml');
/// final pkg = await const JsonAccessor().read('package.json');
/// final page = Formats.html(res.body);
/// await const YamlAccessor().write('config.yaml', cfg.raw);
/// await Formats.zip('site', 'site.zip');
///
/// res.parse(Codec.html).$('h1').text;    // through the codec seam
///
/// // an executable is System.run, not a wrapper:
/// final head = await System.run('git', ['rev-parse', '--short', 'HEAD']);
/// ```
library;

import 'dart:io';

import '../io/entry.dart';
import '../src/codec.dart';
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
Markup parseHtml(String html) => const HtmlAccessor().parse(html);

/// Parses JSON string into a [Json] document cursor.
Json parseJson(String json) => const JsonAccessor().parse(json);

/// Encodes [data] as JSON string, indented by [indent] spaces.
String toJsonString(Object? data, {int indent = 2}) =>
    const JsonAccessor().format(data, indent: indent);

/// Parses YAML string into a document cursor.
Json parseYaml(String yaml) => const YamlAccessor().parse(yaml);

/// Formats [data] as YAML string.
String toYamlString(Object? data) => const YamlAccessor().format(data);

/// Parses TOML string into a document cursor.
Json parseToml(String toml) => const TomlAccessor().parse(toml);

/// Formats [data] as TOML string.
String toTomlString(Object? data) => const TomlAccessor().format(data);

/// Parses CSV text into a [Csv] cursor.
Csv parseCsv(
  String text, {
  String delimiter = ',',
}) => const CsvAccessor().parse(
  text,
  delimiter: delimiter,
);

/// Formats record rows or a grid of cells as CSV text.
String toCsvString(
  Iterable<dynamic> rows, {
  List<String>? headers,
  String delimiter = ',',
  String newline = '\n',
}) {
  final first = rows.firstOrNull;
  if (first is Map) {
    return const CsvAccessor().format(
      rows.cast<Map<String, Object?>>(),
      headers: headers,
      delimiter: delimiter,
      newline: newline,
    );
  }
  if (first is Iterable) {
    return const CsvAccessor().cells(
      rows.map((r) => (r as Iterable).cast<Object?>().toList()),
      headers: headers,
      delimiter: delimiter,
      newline: newline,
    );
  }
  return const CsvAccessor().format(
    rows.cast<Map<String, Object?>>(),
    headers: headers,
    delimiter: delimiter,
    newline: newline,
  );
}

/// Compresses a file or directory into an archive atomically.
Future<FileSystemEntry> zip(
  String source,
  String destination, {
  Format? format,
}) => const ZipAccessor().pack(source, destination, format: format);

/// Extracts a ZIP or tar archive to [destination] directory.
Future<List<File>> unzip(
  String archive,
  String destination, {
  Format? format,
}) => const ZipAccessor().unpack(archive, destination, format: format);

/// Parses a `robots.txt` file content into a [Robots] evaluator.
Robots parseRobots(String content) => const RobotsAccessor().parse(content);

/// Parses a sitemap XML or text content into a list of [Uri]s.
List<Uri> parseSitemap(String content) =>
    const SitemapAccessor().parse(content);

// ============================================================================
// STATIC HELPER HUB: Formats
// ============================================================================

/// Static helper hub for document formats, serialization, and archives.
///
/// Named [Formats] (plural) to avoid collision with [Format] enum.
///
/// Easily discoverable via IDE auto-complete:
/// ```dart
/// final doc = Formats.json('{"a": 1}');
/// final html = Formats.html('<h1>Hi</h1>');
/// final yaml = Formats.yaml('key: val');
/// final csv = Formats.csv('a,b\n1,2');
/// await Formats.zip('src', 'out.zip');
/// ```
abstract final class Formats {
  Formats._();

  /// Parses HTML string into a chainable [Markup] cursor with CSS/XPath selectors.
  static Markup html(String html) => parseHtml(html);

  /// Parses JSON string into a [Json] document cursor.
  static Json json(String json) => parseJson(json);

  /// Encodes [data] as JSON string, indented by [indent] spaces.
  static String toJson(Object? data, {int indent = 2}) =>
      toJsonString(data, indent: indent);

  /// Parses YAML string into a document cursor.
  static Json yaml(String yaml) => parseYaml(yaml);

  /// Formats [data] as YAML string.
  static String toYaml(Object? data) => toYamlString(data);

  /// Parses TOML string into a document cursor.
  static Json toml(String toml) => parseToml(toml);

  /// Formats [data] as TOML string.
  static String toToml(Object? data) => toTomlString(data);

  /// Parses CSV text into a [Csv] cursor.
  static Csv csv(String text, {String delimiter = ','}) =>
      parseCsv(text, delimiter: delimiter);

  /// Formats record rows or a grid of cells as CSV text.
  static String toCsv(
    Iterable<dynamic> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) =>
      toCsvString(
        rows,
        headers: headers,
        delimiter: delimiter,
        newline: newline,
      );

  /// Compresses a file or directory into an archive atomically.
  static Future<FileSystemEntry> zip(
    String source,
    String destination, {
    Format? format,
  }) =>
      const ZipAccessor().pack(source, destination, format: format);

  /// Extracts a ZIP or tar archive to [destination] directory.
  static Future<List<File>> unzip(
    String archive,
    String destination, {
    Format? format,
  }) =>
      const ZipAccessor().unpack(archive, destination, format: format);

  /// Parses a `robots.txt` file content into a [Robots] evaluator.
  static Robots robots(String content) => parseRobots(content);

  /// Parses a sitemap XML or text content into a list of [Uri]s.
  static List<Uri> sitemap(String content) => parseSitemap(content);
}


/// Reading a document off the disk and writing one back, for the codecs that
/// all do it the same way.
///
/// Every `read` in this domain is `io` plus [Codec.parse], and every [write]
/// is [format] plus an atomic `io` write, so both are written once here rather
/// than five times each. A file that is not there parses as the empty string,
/// which every codec already reads as the empty cursor — so a missing optional
/// config needs no `io.has` in front of it.
///
/// ```dart
/// final cfg = await const YamlAccessor().read('config.yaml');
/// await const YamlAccessor().write('config.yaml', cfg.raw);
/// ```
///
/// `io.dump(path, data)` is JSON's shorthand over [write] — the same call with
/// a shorter name for the format everyone uses, and the same `.part` staging.
mixin FileCodec<T, V> implements Codec<T> {
  /// Reads the document at [path] through [Codec.parse].
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
