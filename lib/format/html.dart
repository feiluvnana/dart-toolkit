/// # HTML (`format.html.*`)
///
/// The format codec, spelled exactly like [JsonAccessor], [YamlAccessor] and
/// [TomlAccessor]: `parse`, `read`, `format`. HTML was the format this library
/// started with, which is why it spent four releases living in `net` as a `$`
/// bolted to the side of a response — the one format that never got Rule 1
/// applied to it. It is a format like the others, and it reads like them now.
///
/// The [Markup] *cursor* the readers return is exported from `util`, because
/// it is a pure value and a type `net` hands back through [Codec] cannot live
/// under `format`.
///
/// The jQuery `$` survives as an opt-in import, for scripts that want it:
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
/// import 'package:dart_toolkit/html.dart';
///
/// $(markup).find('.track').texts;
/// markup.$('.track').texts;
/// ```
library;

import 'package:html/parser.dart' as html_parser;

import '../util/codec.dart';
import '../util/markup.dart';
import 'format.dart';

// ============================================================================
// HTML (format.html.*)
// ============================================================================

/// Entry point for HTML, reachable as `format.html`.
///
/// ```dart
/// final page = format.html.parse(res.body);
/// final cached = await format.html.read('fixtures/product.html');
/// io.write('out.html', format.html.format(page));
/// ```
///
/// Writing a document straight to disk is `io.write`; [format] is the string
/// half, for when the markup is going somewhere that is not a file.
class HtmlAccessor with FileCodec<Markup> implements Codec<Markup> {
  /// Creates the accessor. Prefer the shared `format.html` instance.
  const HtmlAccessor();

  /// Parses [text] into a [Markup] cursor.
  ///
  /// There is no such thing as markup that is not HTML — the parser recovers
  /// from anything — so the empty cursor here means an empty document rather
  /// than a failure, matching how a missing path reads for the other codecs.
  @override
  Markup parse(String text) => Markup.of(html_parser.parse(text));

  /// Parses [text] into a [Markup] cursor ready for [Markup.xpath].
  ///
  /// The same document; the difference is which query language the callable
  /// shorthand runs. A cursor from [parse] answers [Markup.xpath] too, so
  /// this only matters for `page('//h1')`.
  Markup query(String text) =>
      Markup.of(html_parser.parse(text), isXPath: true);

  /// Parses [text] as a document fragment, without the `<html><body>` wrapper
  /// the parser otherwise adds.
  ///
  /// For markup that is a piece of a page — a row out of a template, a chunk
  /// from a JSON field — where [parse]'s rooting would hand back the body
  /// rather than the piece.
  Markup fragment(String text) =>
      Markup(html_parser.parseFragment(text).children.toList());

  /// Renders [markup] back to HTML text.
  ///
  /// The outer HTML of every element in the cursor, concatenated — so a round
  /// trip through [parse] and back is the document, and a round trip through
  /// `find` and back is the matches.
  String format(Markup markup) => markup.outers.join();
}

/// Parses [markup] into a queryable [Markup] cursor.
///
/// The jQuery entry point, an alias of `format.html.parse`. Opt-in via
/// `package:dart_toolkit/html.dart`, because `$` in every script's global
/// scope is a cost the default surface should not charge.
///
/// ```dart
/// $(markup).find('.track').texts;
/// markup.$('.track').texts;
/// ```
Markup $(String markup, [String? selector]) {
  final q = const HtmlAccessor().parse(markup);
  return selector != null ? q.find(selector) : q;
}

/// Parses [markup] into a [Markup] cursor for XPath queries.
///
/// An alias of `format.html.query`, on the same opt-in terms as [$].
Markup $xpath(String markup, [String? query]) {
  final q = const HtmlAccessor().query(markup);
  return query != null ? q.xpath(query) : q;
}

/// Query helpers on a raw HTML string.
extension QuerySelectorOnHtmlString on String {
  /// jQuery selector accessor for this markup string.
  Markup get $ => const HtmlAccessor().parse(this);

  /// XPath selector accessor for this markup string.
  Markup get $xpath => const HtmlAccessor().query(this);
}
