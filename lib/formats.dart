/// # Formats
///
/// One module for every document: `JsonDocument` with JSONPath, and YAML, TOML and INI decoded
/// into it; `HtmlDocument` with CSS `\$` and XPath `\$x`; `XmlDocument` with XPath `\$`; the
/// `XPath` engine both share; YAML written back out. Parsers are the package's own, and the
/// module has no dependencies. The `http` bridges — `res.html`, `url.json()` — are in `http`.
///
/// ```dart
/// final pubspec = (await 'pubspec.yaml'.path.readText()).yaml;
/// final rows = doc.\$('table').table;
/// final links = page.\$x('//a/@href').texts;
/// ```
///
/// {@category Formats}
library;

import 'dart:convert';

import 'collection.dart';

part 'src/formats/html/dom.dart';
part 'src/formats/html/entities.dart';
part 'src/formats/html/parser.dart';
part 'src/formats/html/selector.dart';
part 'src/formats/ini.dart';
part 'src/formats/json/json_document.dart';
part 'src/formats/json/jsonpath.dart';
part 'src/formats/toml.dart';
part 'src/formats/xml/dom.dart';
part 'src/formats/xml/parser.dart';
part 'src/formats/xpath.dart';
part 'src/formats/yaml.dart';
