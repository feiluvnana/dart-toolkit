/// [Html]: the HTML parser and its entity table, over the tree of `markup.dart`. What `html.dart`
/// exports, and [HtmlInternals], which `scrape.dart` reads.
library;

import 'dart:convert';
import 'dart:io';

import 'base.dart';
import 'markup.dart';
import 'message.dart';

part 'formats/html/entities.dart';
part 'formats/html/html.dart';
part 'formats/html/parser.dart';
