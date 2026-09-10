/// Opt-in export for the top-level `$` and `$xpath` selectors.
///
/// `format.html.parse` is the name on the default surface; these are the
/// jQuery spelling of the same thing, kept off it because `$` in every
/// script's global scope is a cost not every script wants to pay.
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
/// import 'package:dart_toolkit/html.dart';
///
/// final page = $('<div>...</div>');
/// final rows = markup.$('table tr');
/// ```
library;

export 'format/html.dart' show $, $xpath, QuerySelectorOnHtmlString;
