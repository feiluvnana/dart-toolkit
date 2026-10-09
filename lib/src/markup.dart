/// The markup tree `html.dart`, `xml.dart` and `xpath.dart` share: [Element] and the other
/// nodes, [Selection], [Markup], CSS `\$` queries, and [Xml] with its parser. The HTML parser
/// and XPath are libraries of their own, reaching the tree through [MarkupInternals].
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'base.dart';
import 'collection/formats_bridge.dart';
import 'message.dart';

part 'formats/markup/dom.dart';
part 'formats/markup/internals.dart';
part 'formats/markup/scan.dart';
part 'formats/markup/selector.dart';
part 'formats/queries.dart';
part 'formats/xml/parser.dart';
part 'formats/xml/xml.dart';
