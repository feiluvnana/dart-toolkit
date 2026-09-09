/// Opt-in export for top-level `$` and `$xpath` functions.
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
/// import 'package:dart_toolkit/selector.dart';
///
/// final query = $('<div>...</div>');
/// ```
library;

export 'net/selector.dart' show $, $xpath;
