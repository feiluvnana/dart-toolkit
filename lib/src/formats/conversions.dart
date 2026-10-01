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
  /// The document in the file at [path] (a [String] or [Path]), parsed by extension:
  /// `.json`, `.yaml`/`.yml`, `.toml`, `.ini`/`.cfg`/`.conf`.
  static Future<JsonDocument> read(Object path) => JsonDocument.read(path.toString());

  /// Parses [text] as JSON.
  static JsonDocument json(String text) => JsonDocument.parse(text);

  /// Parses [text] as JSON; see [json].
  static JsonDocument parseJson(String text) => json(text);

  /// Parses [text] as YAML.
  static YamlDocument yaml(String text) => text.yaml;

  /// Parses [text] as YAML; see [yaml].
  static YamlDocument parseYaml(String text) => yaml(text);

  /// Parses [text] as TOML.
  static JsonDocument toml(String text) => text.toml;

  /// Parses [text] as TOML; see [toml].
  static JsonDocument parseToml(String text) => toml(text);

  /// Parses [text] as INI.
  static JsonDocument ini(String text) => text.ini;

  /// Parses [text] as INI; see [ini].
  static JsonDocument parseIni(String text) => ini(text);

  /// Parses [text] as HTML.
  static HtmlDocument html(String text) => HtmlDocument.parse(text);

  /// Parses [text] as HTML; see [html].
  static HtmlDocument parseHtml(String text) => html(text);

  /// Parses [text] as XML.
  static XmlDocument xml(String text) => XmlDocument.parse(text);

  /// Parses [text] as XML; see [xml].
  static XmlDocument parseXml(String text) => xml(text);
}

/// An alias for [Doc] for full-name discoverability: `Document.read('config.yaml')`.
typedef Document = Doc;

/// Format reading helpers on [Path].
///
/// {@category Formats}
extension PathFormatsExtensions on Path {
  /// Reads and parses this file based on its extension (.json, .yaml, .toml, .ini).
  Future<JsonDocument> readDoc() => Doc.read(path);

  /// Reads and parses this file as JSON.
  Future<JsonDocument> readJson() async => JsonDocument.parse(await readText());

  /// Reads and parses this file as YAML.
  Future<YamlDocument> readYaml() async => (await readText()).yaml;

  /// Reads and parses this file as TOML.
  Future<JsonDocument> readToml() async => (await readText()).toml;

  /// Reads and parses this file as INI.
  Future<JsonDocument> readIni() async => (await readText()).ini;

  /// Reads and parses this file as HTML.
  Future<HtmlDocument> readHtml() async => HtmlDocument.parse(await readText());

  /// Reads and parses this file as XML.
  Future<XmlDocument> readXml() async => XmlDocument.parse(await readText());
}
