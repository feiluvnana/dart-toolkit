/// The markup tree `html.dart` and `xml.dart` share: [Html], [Xml], [Element] and the other
/// nodes, CSS `\$` and XPath `\$x` queries, and [Selection].
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../collection.dart';
import 'collection/formats_bridge.dart';
import 'message.dart';

part 'formats/html/dom.dart';
part 'formats/html/entities.dart';
part 'formats/html/parser.dart';
part 'formats/html/selector.dart';
part 'formats/markup_internals.dart';
part 'formats/queries.dart';
part 'formats/xml/dom.dart';
part 'formats/xml/parser.dart';
part 'formats/xpath.dart';
