part of '../../formats.dart';

/// The ways into `formats`: a string parsed as each format it knows.
///
/// {@category Formats}
extension StringFormatsExtensions on String {
  /// This string parsed as JSON.
  JsonDocument get json => JsonDocument.parse(this);

  /// This YAML text as a document: block and flow mappings and sequences, plain and quoted
  /// scalars (over several lines too), `|` and `>` blocks, anchors, aliases and `<<` merge
  /// keys, comments. A key defined twice is an error.
  /// Numbers, booleans and null are themselves; dates and times stay text; `!!str` keeps a
  /// scalar text and any other tag is ignored.
  ///
  /// A stream of several documents reads as its first; [YamlDocument.documents] has them all.
  ///
  /// Throws [FormatException] with a line number on bad syntax.
  YamlDocument get yaml => YamlDocument._(_YamlParser(this).parse());

  /// This TOML text as a document: tables and arrays of tables become nested objects and
  /// arrays, dotted keys nest, strings of all four kinds decode, numbers and booleans are
  /// themselves, dates and times stay text.
  ///
  /// Covers TOML 1.0 as scripts use it, checked by `test/formats_test.dart` rather than
  /// against the specification's own suite. A table defined twice, an inline table or a static
  /// array extended afterwards, and `[[a]]` on a key that is not an array of tables are errors.
  ///
  /// Throws [FormatException] with a line number on bad syntax.
  JsonDocument get toml => JsonDocument(_TomlParser(this).parse());

  /// This INI text as a document: one object per `[section]`, keys before any section at the
  /// root. `;` and `#` start comments; `key = value` and `key: value` both work; quoted values
  /// lose their quotes; a line indented under a key continues its value.
  ///
  /// Dots nest: `a.b = 1` and `[server.tls]` are tables inside tables. A key that cannot nest
  /// — `x.y.z` after `x.y` is already a value, or `x.y` after it is already a table, as Java
  /// properties files write them — stays whole in its section, so `log4j.appender.A1` and
  /// `log4j.appender.A1.layout` both read back. A quoted part of a section name is one name,
  /// dots and all: `["www.example.com"]`, and git's `[remote "origin"]` is `remote.origin`.
  JsonDocument get ini => JsonDocument(_parseIni(this));

  /// This string parsed as HTML. It has no address, so its [Elements.links] stay as written
  /// unless it has a `<base href>`; `res.html` knows the page's.
  HtmlDocument get html => HtmlDocument.parse(this);

  /// This string parsed as XML.
  XmlDocument get xml => XmlDocument.parse(this);
}
