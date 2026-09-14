/// # ArchiveFormat Codecs (`DocumentFormat`)
///
/// The seam between the domain that *fetches* bytes and the domain that
/// *understands* them. `net` has a body and something that reads bodies; it
/// never learns which format that something is. `format` has five readers and
/// no idea where the text came from.
///
/// It lives in `lib/src/` for the reason [Json] does: it is a pure value
/// both `net` and `format` need, and neither may depend on the other, so it
/// belongs to no domain. It sat under `lib/util/` through 5.4.0 without ever
/// being reachable as `util.` anything; it is exported from the package root
/// either way.
///
/// ```dart
/// res.parse(DocumentFormat.html).$('h1').text;
/// res.parse(DocumentFormat.json).at('data.items');
/// res.parse(DocumentFormat.yaml).text('version');
/// ```
///
/// Implementing it is the whole contract for a new format: one method, and
/// `read` from a file comes free with it.
library;

import '../format/format.dart';
import 'csv.dart';
import 'json.dart';
import 'markup.dart';

// ============================================================================
// FORMAT CODECS (DocumentFormat)
// ============================================================================

/// A format that turns text into a cursor of type [T].
///
/// Every accessor under `format` implements this, which is what lets
/// `Response.parse` take any of them without naming one:
///
/// ```dart
/// DocumentFormat<Json> reader = DocumentFormat.yaml;
/// final config = reader.parse(await File('config.yaml').readAsString());
/// ```
///
/// [parse] never throws. Text that is not this format gives the empty
/// cursor — the contract every reader in this library keeps, because the
/// caller asked for a document and the honest answer is that there is not
/// one.
abstract interface class DocumentFormat<T> {
  /// Decodes [text] into this format's cursor.
  T parse(String text);

  /// HTML markup codec.
  static DocumentFormat<Markup> get html => const HtmlFormat();

  /// JSON document cursor codec.
  static DocumentFormat<Json> get json => const JsonFormat();

  /// YAML document cursor codec.
  static DocumentFormat<Json> get yaml => const YamlFormat();

  /// TOML document cursor codec.
  static DocumentFormat<Json> get toml => const TomlFormat();

  /// CSV cursor codec.
  static DocumentFormat<Csv> get csv => const CsvFormat();

  /// Robots.txt codec.
  static DocumentFormat<Robots> get robots => const RobotsFormat();

  /// Sitemap XML codec.
  static DocumentFormat<List<Uri>> get sitemap => const SitemapFormat();
}
