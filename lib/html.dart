/// # HTML
///
/// `HtmlDocument` and element queries, with CSS selectors, and the HTML bridges
/// on `http.Response` and `Uri` — they live with the parser they need.
///
/// {@category Formats}
library;

import 'http.dart';
import 'xpath.dart';

part 'src/html/dom.dart';
part 'src/html/entities.dart';
part 'src/html/html_document.dart';
part 'src/html/parser.dart';
part 'src/html/selector.dart';
