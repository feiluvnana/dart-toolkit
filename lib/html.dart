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
/// const markup = '<table><tr><td>one</td></tr></table>';
/// final rows = $(markup, 'tr');       // parse and query in one call
/// final cells = markup.$('td');       // the same, from the string

/// ```
library;

export 'format/html.dart' show $, $xpath, QuerySelectorOnHtmlString;
