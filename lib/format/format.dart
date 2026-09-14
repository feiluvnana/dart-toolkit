/// # Formats
///
/// File formats: knowledge Dart does not have about how a document is shaped.
/// **One codec per format, reached with a leading dot**, in both directions:
///
/// ```dart
/// final page = res.text.parse(.html);
/// final settings = await Path('config.yaml').read(.yaml);
/// await Path('config.yaml').write(settings.raw, as: .yaml);
/// ```
///
/// Seven of the eight formats are codecs, and every one implements
/// [DocumentFormat] — `parse` in, `format` out — which is what lets a response
/// or a file be read through any of them without `net` or `io` learning which.
/// Through 8.1.0 this was seven `parseX` functions, four `toXString`
/// functions, a separate `FileFormat` mixin for the disk and a `DocumentFormat`
/// interface for everything else; it is one interface and two members now.
///
/// Archives are the eighth and are **not** a codec: an archive is a container
/// of files, not a document with a shape, so there is no cursor to hand back
/// and `parse(String)` is the wrong signature for bytes. They are members of
/// the path instead — `zipTo`, `unzipInto`, `entries`, `extract`,
/// `writeArchive` — plus `gzip()`/`gunzip()` on the bytes themselves.
///
/// ```dart
/// await Path('site').zipTo('site.zip');
/// ```
///
/// **Not executables.** Wrapping a binary is [run] plus arguments, and a
/// script that wants `git`, `gh`, `docker` or `ffmpeg` already has the whole
/// of each of them there — where a wrapper only ever has the five subcommands
/// somebody thought to add.
/// {@category Formats}
library;

import '../src/format.dart';

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
// PARSING TEXT (String.parse)
// ============================================================================

/// Reading a document out of text you already hold.
///
/// One member for every format, with the codec as a leading dot — where 8.1.0
/// had seven top-level functions (`parseHtml`, `parseJson`, `parseYaml`,
/// `parseToml`, `parseCsv`, `parseRobots`, `parseSitemap`) and two of them
/// also spelled as members here.
///
/// ```dart
/// '{"a": 1}'.parse(.json).number('a');       // 1
/// '<h1>Hi</h1>'.parse(.html).$('h1').text;   // 'Hi'
/// 'a,b\n1,2'.parse(.csv).rows.first;         // ['1', '2']
/// ```
///
/// Writing goes the other way through the same codec:
/// `DocumentFormat.yaml.format(settings)`, or straight to disk with
/// `path.write(settings, as: .yaml)`.
///
/// Nothing here throws. Text that is not the format asked for gives the empty
/// cursor, because the caller asked for a document and the honest answer is
/// that there is not one.
extension StringFormatExtensions on String {
  /// This text read through [format].
  ///
  /// ```dart
  /// final settings = text.parse(.yaml);
  /// final page = body.parse(.html);
  /// ```
  T parse<T>(DocumentFormat<T, Object?> format) => format.parse(this);
}
