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
/// final cfg  = await format.yaml.read('config.yaml');
/// final pkg  = await format.json.read('package.json');
/// final page = format.html.parse(res.body);
/// await format.yaml.write('config.yaml', cfg.raw);
/// await format.zip.pack('site', 'site.zip');
///
/// res.parse(format.html).$('h1').text;    // through the codec seam
///
/// // an executable is system.run, not a wrapper:
/// final head = await system.run('git', ['rev-parse', '--short', 'HEAD']);
/// ```
library;

import 'dart:io';

import '../io/entry.dart';
import '../src/codec.dart';
import '../src/fs.dart';
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
// FORMAT DOMAIN (format.*) - File Formats
// ============================================================================

/// The `format` domain: file formats.
const FormatAccessor format = FormatAccessor();

/// Entry point for the wrapped formats, reachable as [format].
///
/// Each format keeps its own vocabulary; this type only holds the names, so
/// adding one is a getter here and a file beside this one.
///
/// ```dart
/// await format.zip.unpack('release.tar.gz', 'out');
/// final version = (await format.json.read('package.json')).text('version');
/// ```
class FormatAccessor {
  /// Creates the accessor. Prefer the shared [format] instance.
  const FormatAccessor();

  /// Archives: packing, unpacking, inspecting and raw (de)compression.
  ZipAccessor get zip => const ZipAccessor();

  /// HTML: parsing a page into a [Markup] cursor, and writing one back.
  HtmlAccessor get html => const HtmlAccessor();

  /// JSON: reading a document as a [Json] cursor, and writing one back.
  JsonAccessor get json => const JsonAccessor();

  /// YAML: the same three members as [json], over the same cursor.
  YamlAccessor get yaml => const YamlAccessor();

  /// TOML: the same three members again.
  TomlAccessor get toml => const TomlAccessor();

  /// `robots.txt`: reading one into the evaluator a crawl obeys.
  ///
  /// It was `net.robots(content)` through 5.5.0, in the domain whose own
  /// doc says it parses nothing.
  RobotsAccessor get robots => const RobotsAccessor();

  /// Sitemaps: XML `<urlset>`, XML `<sitemapindex>` and plain text alike.
  ///
  /// It was `net.sitemap(content)` through 5.5.0, beside `Sitemap.load`,
  /// which is a crawl and is written as one now.
  SitemapAccessor get sitemap => const SitemapAccessor();

  /// CSV: reading a table as a [Csv] cursor, and writing one back.
  ///
  /// It was `io.csv` through 5.1.0. A format is a subject by Rule 1, and this
  /// was the only one filed under the axis that happened to read the bytes.
  CsvAccessor get csv => const CsvAccessor();
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
/// final cfg = await format.yaml.read('config.yaml');
/// await format.yaml.write('config.yaml', cfg.raw);
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
