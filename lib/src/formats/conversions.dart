part of '../../formats.dart';

/// The ways into `formats`: a string parsed as each format it knows.
///
/// {@category Formats}
extension StringFormatsExtensions on String {
  /// This string parsed as JSON.
  JsonDocument get json => JsonDocument.parse(this);

  /// This YAML text as a document, with anchors, aliases and `<<` merges; a duplicate key is an
  /// error. Dates and times stay text; `!!str` keeps a scalar text and other tags are ignored.
  /// A multi-document stream reads as its first; [YamlDocument.documents] has them all.
  ///
  /// Throws [FormatException] with a line number on bad syntax.
  YamlDocument get yaml => YamlDocument._(_YamlParser(this).parse());

  /// This TOML 1.0 text as a document; dates and times stay text. Redefining a table, extending
  /// an inline table or static array, and `[[a]]` on a non-array-of-tables are errors.
  ///
  /// Throws [FormatException] with a line number on bad syntax.
  JsonDocument get toml => JsonDocument(_TomlParser(this).parse());

  /// This INI text as a document: one object per `[section]`, keys before any section at the
  /// root. `;`/`#` comments, `=` or `:`, quotes stripped, indented lines continue a value.
  ///
  /// Dots nest (`a.b = 1`, `[server.tls]`), except a key that cannot — Java properties'
  /// `log4j.appender.A1` beside `log4j.appender.A1.layout` — which stays whole. A quoted part of
  /// a section name is one name: `["www.example.com"]`; git's `[remote "origin"]` is
  /// `remote.origin`.
  JsonDocument get ini => JsonDocument(_parseIni(this));

  /// This string parsed as HTML. With no address, its [Elements.links] stay as written unless it
  /// has a `<base href>`; `res.html` knows the page's.
  HtmlDocument get html => HtmlDocument.parse(this);

  /// This string parsed as XML.
  XmlDocument get xml => XmlDocument.parse(this);
}

/// The front door for document parsing and reading across formats (JSON, YAML, TOML, INI, HTML, XML).
///
/// {@category Formats}
abstract final class Doc {
  /// The document in the file at [path] (a [String] or a `Path`), parsed by extension:
  /// `.json`, `.yaml`/`.yml`, `.toml`, `.ini`/`.cfg`/`.conf`.
  static Future<JsonDocument> read(Object path) => JsonDocument.read(path.toString());

  /// The table in the file at [path], read as [Table.read] does: `.json` (an array of objects),
  /// `.ndjson`/`.jsonl`, `.tsv`, and CSV for any other extension.
  static Future<Table> table(Object path, {String? separator}) => Table.read(path.toString(), separator: separator);

  /// Parses [text] as JSON.
  static JsonDocument json(String text) => JsonDocument.parse(text);

  /// Parses [text] as YAML.
  static YamlDocument yaml(String text) => text.yaml;

  /// Parses [text] as TOML.
  static JsonDocument toml(String text) => text.toml;

  /// Parses [text] as INI.
  static JsonDocument ini(String text) => text.ini;

  /// Parses [text] as HTML.
  static HtmlDocument html(String text) => HtmlDocument.parse(text);

  /// Parses [text] as XML.
  static XmlDocument xml(String text) => XmlDocument.parse(text);
}
