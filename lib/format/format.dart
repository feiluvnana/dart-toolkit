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
/// Every codec is spelled identically — `parse`, `read`, `format` — so they
/// are learnable from each other, and every one implements [Codec], which is
/// what lets a response be read through any of them without `net` learning
/// which:
///
/// ```dart
/// final cfg  = await format.yaml.read('config.yaml');
/// final pkg  = await format.json.read('package.json');
/// final page = format.html.parse(res.body);
/// await format.zip.pack('site', 'site.zip');
///
/// res.parse(format.html).find('h1').text;    // through the codec seam
///
/// // an executable is system.run, not a wrapper:
/// final head = await system.run('git', ['rev-parse', '--short', 'HEAD']);
/// ```
library;

import 'dart:io';

import '../src/codec.dart';
import 'csv.dart';
import 'html.dart';
import 'json.dart';
import 'toml.dart';
import 'yaml.dart';
import 'zip.dart';

export 'csv.dart';
export 'html.dart' hide $, $xpath;
export 'json.dart';
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

  /// CSV: reading a table as a [Csv] cursor, and writing one back.
  ///
  /// It was `io.csv` through 5.1.0. A format is a subject by Rule 1, and this
  /// was the only one filed under the axis that happened to read the bytes.
  CsvAccessor get csv => const CsvAccessor();
}

/// Reading a document off the disk, for the codecs that all do it the same
/// way.
///
/// Every `read` in this domain is `io` plus [Codec.parse], so it is written
/// once here rather than four times. A file that is not there parses as the
/// empty string, which every codec already reads as the empty cursor — so a
/// missing optional config needs no `io.has` in front of it.
mixin FileCodec<T> implements Codec<T> {
  /// Reads the document at [path] through [Codec.parse].
  Future<T> read(String path) async {
    final file = File(path);
    if (!await file.exists()) return parse('');
    return parse(await file.readAsString());
  }
}
