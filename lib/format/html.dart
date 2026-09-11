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
/// `Form` and [FormOnMarkup.form] live in `format/form.dart` and are part of
/// this accessor's family: finding a `<form>` and reading its controls is
/// reading HTML. Sending one is a socket, so the `Sending` extension is in
/// `net`.
///
/// The jQuery `$` survives as an opt-in import, for scripts that want it:
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
/// import 'package:dart_toolkit/html.dart';
///
/// // setup: const markup = '<li class="track">One</li>';
/// $(markup, '.track').texts;
/// $(markup).$('.track').texts;   // the same, spelled in two steps
/// ```
///
/// `markup.$('.track')` was an extension on `String` beside this through
/// 6.0.0 — a third door onto one operation, and the one that had to be an
/// extension because `String` is not ours. `format.html.$(markup, selector)`
/// is the member form and this is the global one; the extension went.
library;

import 'package:html/parser.dart' as html_parser;

import '../src/codec.dart';
import '../src/markup.dart';
import 'format.dart';

// ============================================================================
// HTML (format.html.*)
// ============================================================================

/// Entry point for HTML, reachable as `format.html`.
///
/// ```dart
/// final page = format.html.parse(res.body);
/// final cached = await format.html.read('fixtures/product.html');
/// io.write('out.html', format.html.format(page.$('.card')));
/// ```
///
/// `format.html.write(path, markup)` writes one to disk atomically; [format]
/// is the string half, for when the markup is going somewhere that is not a
/// file.
///
/// `parse(t).text` is the *correct* way to get a page's text: it is right
/// about entities, `<script>` bodies and malformed nesting, and it costs a
/// document. `util.text.tags(t)` is a regex over the string and costs nothing;
/// it is the one for a snippet, and the one to reach for when there are ten
/// thousand of them.
class HtmlAccessor with FileCodec<Markup, Markup> implements Codec<Markup> {
  /// Creates the accessor. Prefer the shared `format.html` instance.
  const HtmlAccessor();

  /// Parses [text] into a [Markup] cursor.
  ///
  /// There is no such thing as markup that is not HTML — the parser recovers
  /// from anything — so the empty cursor here means an empty document rather
  /// than a failure, matching how a missing path reads for the other codecs.
  @override
  Markup parse(String text) => Markup.of(html_parser.parse(text));

  /// Parses [text] as a document fragment, without the `<html><body>` wrapper
  /// the parser otherwise adds.
  ///
  /// For markup that is a piece of a page — a row out of a template, a chunk
  /// from a JSON field — where [parse]'s rooting would hand back the body
  /// rather than the piece.
  Markup fragment(String text) =>
      Markup(html_parser.parseFragment(text).children.toList());

  /// Parses [text] and runs the CSS [selector] over it, in one call.
  ///
  /// The two-step form is [parse] then [Markup.$]; this is the step a script
  /// actually writes, and it carries the jQuery name because that is the name
  /// for it:
  ///
  /// ```dart
  /// // setup: const markup = '<li class="track">One</li>';
  /// format.html.$(markup, '.track').texts;
  /// ```
  ///
  /// [selector] is required, which is what keeps this from being a second
  /// spelling of [parse]: one parses, the other parses *and* selects. The
  /// opt-in top-level `$(markup, [selector])` takes it optionally, because
  /// `$(html)` is idiomatic jQuery and that function is the jQuery door.
  Markup $(String text, String selector) => parse(text).$(selector);

  /// Parses [text] and runs the XPath [query] over it, in one call.
  ///
  /// The XPath twin of [$], on the same terms — see [Markup.$xpath].
  Markup $xpath(String text, String query) =>
      Markup.of(html_parser.parse(text), isXPath: true).$xpath(query);

  /// Renders [markup] back to HTML text.
  ///
  /// The outer HTML of every element in the cursor, concatenated — so a round
  /// trip through [parse] and back is the document, and a round trip through
  /// [Markup.$] and back is the matches.
  @override
  String format(Markup markup) =>
      markup.elements.transform(.map((e) => e.outerHtml)).collect(.join(''));
}

/// Parses [markup] into a queryable [Markup] cursor.
///
/// The jQuery entry point, an alias of `format.html.parse`. Opt-in via
/// `package:dart_toolkit/html.dart`, because `$` in every script's global
/// scope is a cost the default surface should not charge.
///
/// ```dart
/// // setup: const markup = '<li class="track">One</li>';
/// $(markup, '.track').texts;
/// $(markup).$('.track').texts;   // the same, spelled in two steps
/// ```
///
/// `markup.$('.track')` was an extension on `String` beside this through
/// 6.0.0 — a third door onto one operation, and the one that had to be an
/// extension because `String` is not ours. `format.html.$(markup, selector)`
/// is the member form and this is the global one; the extension went.
Markup $(String markup, [String? selector]) {
  final q = const HtmlAccessor().parse(markup);
  return selector != null ? q.$(selector) : q;
}

/// Parses [markup] into a [Markup] cursor for XPath queries.
///
/// The XPath twin of [$], on the same opt-in terms. It sets the flag itself,
/// because the flag only ever decided which language `$xpath` runs and there
/// was no way to observe it from the default surface — `format.html.query`
/// was a public member configuring one that is not public, and 6.0.0 deleted
/// it.
Markup $xpath(String markup, [String? query]) {
  final q = Markup.of(html_parser.parse(markup), isXPath: true);
  return query != null ? q.$xpath(query) : q;
}
