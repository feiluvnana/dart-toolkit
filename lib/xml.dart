/// # XML
///
/// `XmlDocument`, an in-house parser with an XPath 1.0 subset for `$`, and the XML bridges on
/// `http.Response`, `Uri` and `String`.
///
/// {@category Formats}
library;

import 'package:http/http.dart' as http;

import 'core.dart';
import 'http.dart';

part 'src/xml/dom.dart';
part 'src/xml/parser.dart';
part 'src/xml/xml_document.dart';
