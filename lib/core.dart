/// # Core Types & Documents
///
/// `Either`, string helpers, and the `JsonDocument` parser with JSONPath
/// selectors. No third-party dependencies — the `HtmlDocument` and
/// `XmlDocument` parsers live in their own libraries so a program that
/// parses JSON does not load an HTML and an XML parser to do it.
///
/// {@category Formats}
library;

import 'dart:async';

part 'src/core/either.dart';
part 'src/core/string_extensions.dart';
