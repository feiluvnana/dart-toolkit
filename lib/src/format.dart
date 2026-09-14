/// # Format Codecs (`DocumentFormat`)
///
/// The seam between the domain that *fetches* bytes and the domain that
/// *understands* them. `net` has a body and something that reads bodies; it
/// never learns which format that something is. `format` has seven codecs and
/// no idea where the text came from.
///
/// It lives in `lib/src/` for the reason [Json] does: it is a pure value
/// both `net` and `format` need, and neither may depend on the other, so it
/// belongs to no domain. It sat under `lib/util/` through 5.4.0 without ever
/// being reachable as `util.` anything; it is exported from the package root
/// either way.
///
/// ```dart
/// res.html.$('h1').text;
/// res.parse(.json).at('data.items');
/// res.parse(.yaml).text('version');
/// ```
///
/// Implementing it is the whole contract for a new format: two methods, and
/// reading one off the disk comes free with it through [Path.read].
/// {@category Formats}
library;

import '../format/format.dart';
import 'csv.dart';
import 'json.dart';
import 'markup.dart';

// ============================================================================
// FORMAT CODECS (DocumentFormat)
// ============================================================================

/// A format: text in one direction, a cursor of type [T] in the other, and a
/// value of type [V] back to text.
///
/// Every codec under `format` implements this, which is what lets
/// [Response.parse] and [Path.read] take any of them without naming one — and
/// what makes the leading dot work, because the parameter type supplies the
/// prefix:
///
/// ```dart
/// res.parse(.yaml);                    // Json
/// await Path('config.yaml').read(.yaml);
/// await Path('out.csv').write(rows, as: .csv);
/// ```
///
/// [parse] never throws. Text that is not this format gives the empty
/// cursor — the contract every reader in this library keeps, because the
/// caller asked for a document and the honest answer is that there is not
/// one.
///
/// `T` is what reading gives you; `V` is what writing takes. They differ
/// wherever a format reads richer than it writes: `csv` parses to a [Csv]
/// cursor and writes from rows, `sitemap` parses to `List<Uri>` and writes
/// from any `Iterable<Uri>`.
abstract interface class DocumentFormat<T, V> {
  /// Decodes [text] into this format's cursor.
  T parse(String text);

  /// Renders [value] as this format's text.
  String format(V value);

  /// HTML markup codec.
  static DocumentFormat<Markup, Markup> get html => const HtmlFormat();

  /// JSON document cursor codec.
  static DocumentFormat<Json, Object?> get json => const JsonFormat();

  /// YAML document cursor codec.
  static DocumentFormat<Json, Object?> get yaml => const YamlFormat();

  /// TOML document cursor codec.
  static DocumentFormat<Json, Object?> get toml => const TomlFormat();

  /// CSV cursor codec.
  static DocumentFormat<Csv, Iterable<Map<String, Object?>>> get csv =>
      const CsvFormat();

  /// Robots.txt codec.
  static DocumentFormat<Robots, Robots> get robots => const RobotsFormat();

  /// Sitemap XML codec.
  static DocumentFormat<List<Uri>, Iterable<Uri>> get sitemap =>
      const SitemapFormat();
}
