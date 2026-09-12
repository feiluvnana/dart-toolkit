/// # Markup Cursors (`Markup`)
///
/// A read cursor over a parsed HTML tree, and the other half of the pair
/// [Json] belongs to: one cursor for documents made of maps and scalars, one
/// for documents made of elements.
///
/// It lives in `lib/src/` for the reason [Json] does — it is a pure value
/// that more than one domain hands back, belonging to none of them, and it
/// computes rather than touches anything. It was under `lib/util/` through
/// 5.4.0 without ever being reachable as `util.` anything. The *codec* that
/// builds one is `format.html`, beside `format.json`, `format.yaml` and
/// `format.toml`, because a format is knowledge from outside Dart.
///
/// Three doors produce the same cursor:
///
/// ```dart
/// res.parse(format.html);                 // a response
/// format.html.parse(body);                // a string
/// await format.html.read('page.html');    // a file
/// ```
///
/// Navigation comes in two spellings, for the two questions: [Markup.$]
/// runs a CSS selector across the tree, and [Markup.$xpath] runs an XPath
/// query. [Field] is the typed form of a single read, for the values a
/// scraper wants out with their types intact.
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import '../src/jquery.dart';
import '../util/text.dart';

const TextAccessor _text = TextAccessor();

// ============================================================================
// MARKUP CURSORS (Markup)
// ============================================================================

/// A chainable set of matched elements.
///
/// Reads never throw and never cast: a selector that matches nothing gives an
/// empty cursor, and every reader on it hands back `null` or an empty list —
/// the same contract [Json] and `Field.text` keep, because the caller asked
/// for a value and the honest answer is that there is not one.
///
/// ```dart
/// final page = res.parse(format.html);
///
/// page.$('h1').text;                     // String
/// page.$('a').attrs('href');             // Sequence<String>
/// page.$xpath('//table//td[2]').texts;   // Sequence<String>
/// page.all('.product', (row) => (
///   name: row.$('.name').text,
///   price: row.pick(Field.text('.price').when(util.text.number)),
/// ));                                    // Sequence<({String name, num? price})>
/// ```
class Markup {
  final List<Element> _elements;
  final bool _isXPath;
  final Document? _document;

  /// Wraps [elements] without copying.
  Markup([List<Element>? elements, bool isXPath = false, Document? document])
    : _elements = elements ?? const [],
      _isXPath = isXPath,
      _document = document;

  /// Roots a cursor on an already-parsed [document].
  ///
  /// The top-level elements of its body, falling back to the document root
  /// when the markup has no body children, so a full page reads as usefully
  /// as a fragment.
  ///
  /// Turning *text* into a document is `format.html.parse`: parsing is the
  /// codec's job, and rooting a cursor on the result is this one's.
  factory Markup.of(Document document, {bool isXPath = false}) {
    final children = document.body?.children;
    if (children != null && children.isNotEmpty) {
      return Markup(children.toList(), isXPath, document);
    }
    final root = document.documentElement ?? document.body;
    return Markup(root != null ? [root] : [], isXPath, document);
  }

  /// The parsed document underneath, or `null` for a cursor over loose
  /// elements.
  ///
  /// The escape hatch, the way [Json.raw] is: for the one call `package:html`
  /// can answer and this cannot.
  Document? get document => _document;

  /// The matched elements, as a [List].
  List<Element> get elements => _elements;

  /// The first matched element, or `null` when empty.
  Element? get element => _elements.firstOrNull;

  /// The matched elements as a standard Dart [List].
  List<Element> get elementList => _elements;

  /// How many elements matched.
  int get count => _elements.length;

  /// Whether nothing matched.
  ///
  /// No complement: `!q.empty` already says the other thing.
  bool get empty => _elements.isEmpty;

  /// Runs an XPath query across the current elements or document.
  ///
  /// The XPath twin of [$], named for the language it speaks. It was `xpath`
  /// through 6.0.0; see [$] for why both took the jQuery spelling.
  Markup $xpath(String query) {
    final elements = <Element>[];
    final seen = <Element>{};
    final nodes = _document != null ? [_document] : _elements;
    for (final node in nodes) {
      try {
        final xp = HtmlXPath.node(node);
        final result = xp.query(query);
        for (final xNode in result.nodes) {
          final domNode = xNode.node;
          if (domNode is Element && seen.add(domNode)) {
            elements.add(domNode);
          }
        }
      } catch (_) {}
    }
    return Markup(elements, true, null);
  }

  /// A single-element result at [index]; empty when out of range.
  ///
  /// Negative indices count from the end, so `at(-1)` is the last match.
  Markup at(int index) {
    final i = index < 0 ? _elements.length + index : index;
    if (i < 0 || i >= _elements.length) return Markup(null, _isXPath);
    return Markup([_elements[i]], _isXPath);
  }

  /// Everything matching [selector], with full jQuery syntax.
  ///
  /// On a cursor rooted on a document — which is what `format.html.parse`
  /// gives back — the search covers the whole page, so an element sitting at
  /// the top level of the body is found like any other. On a scoped cursor it
  /// covers the descendants of the current set, which is what makes the
  /// chained form mean what it reads as:
  ///
  /// ```dart
  /// page.$('.row').$('.name').texts;   // names inside rows, only
  /// ```
  ///
  /// The result is scoped even when this cursor was not, so the second call
  /// above cannot quietly search the page again.
  ///
  /// `page(selector)` was a second spelling of this through 4.0.0 — the
  /// release that made them one search kept both names for it. Worse, which
  /// selector *language* the callable spoke depended on hidden state: on a
  /// cursor from `format.html.query` it ran the string as XPath instead, so
  /// nothing at the call site said which of the two it was. This one is CSS
  /// and [$xpath] is XPath, and the two names say which.
  ///
  /// It was `find` through 6.0.0, with `$` an opt-in extension on `String`
  /// beside it. jQuery's `$` is what Rule 1 means by a subject arriving with
  /// its own vocabulary, and a *method* named `$` puts nothing in a script's
  /// global scope — which was the whole objection to the spelling. So the
  /// subject's own name won, and `find` went rather than standing beside it.
  /// The top-level `$(markup, selector)` is still opt-in, because that one
  /// really is a global.
  Markup $(String selector) =>
      Markup(JQuery.select(_document ?? _elements, selector), false);

  /// One [R] per match of [selector], each built from its own scope.
  ///
  /// This is how a repeated sub-object comes back typed. [build] receives the
  /// matched element as a [Markup] of its own, so the same readers work
  /// one level down and a Dart record carries the shape without a class:
  ///
  /// ```dart
  /// final variants = page.all('.variant', (row) => (
  ///   name: row.$('.name').text,
  ///   sku: row.attr('data-sku'),
  ///   price: row.pick(Field.text('.price').when(util.text.number)),
  /// ));
  /// // Sequence<({String name, String? sku, num? price})>
  /// ```
  ///
  /// Where `extract` hands back `Map<String, Object?>` and leaves every value
  /// to be cast, this keeps the type of each field all the way out.
  List<R> all<R>(String selector, R Function(Markup row) build) =>
      $(selector)
          ._elements
          .map((element) => build(Markup([element], false)))
          .toList();

  /// Reads a typed [field] from the first element of this set.
  ///
  /// Scoped, so a [Field] works at any depth — inside [all], inside [one], or
  /// straight off a page:
  ///
  /// ```dart
  /// final String? title = res.parse(format.html).pick(Field.text('h1'));
  /// ```
  T pick<T>(Field<T> field) => field.read(_root);

  /// Reads [schema] out of this set, expanding the string shorthand.
  ///
  /// Values are either the string form — `'h1'` for text, `'a@href'` for an
  /// attribute, `['li']` for every match, `['.row', {...}]` for a repeated
  /// sub-object — or a [Field], which says the same thing with a static type.
  ///
  /// ```dart
  /// final data = res.parse(format.html).extract({
  ///   'title': 'h1',
  ///   'price': '.price',
  ///   'link': 'a@href',
  ///   'tags': ['ul.tags > li'],
  ///   'items': ['.product', {'name': '.name', 'url': 'a@href'}],
  /// });
  /// ```
  ///
  /// Every value comes back `Object?`. [pick] is the typed form, one field at
  /// a time.
  Map<String, Object?> extract(Map<String, Object?> schema) =>
      Field._readAll(_root, schema);

  // The document's root when there is one, so a scoped read sees the same page
  // an unscoped one does. `_elements.first` is the body's *first child* on a
  // document-rooted set, which made the answer depend on page structure.
  Element get _root =>
      _document?.documentElement ??
      _document?.body ??
      _elements.firstOrNull ??
      Element.tag('html');

  /// The elements satisfying [test].
  Markup filter(bool Function(Element element) test) =>
      Markup(_elements.where(test).toList(), _isXPath);

  /// The elements that themselves match [selector].
  Markup matching(String selector) => filter((e) => _matches(e, selector));

  /// The direct children of the current set, optionally matching [selector].
  Markup children([String? selector]) => _collect(
    (element) => element.children.where(
      (child) => selector == null || _matches(child, selector),
    ),
  );

  /// The immediate parents of the current set, optionally matching [selector].
  Markup parent([String? selector]) => _collect((element) {
    final parent = element.parent;
    if (parent == null) return const [];
    if (selector != null && !_matches(parent, selector)) return const [];
    return [parent];
  });

  /// The nearest self-or-ancestor of each element matching [selector].
  Markup closest(String selector) => _collect((element) {
    for (
      Element? current = element;
      current != null;
      current = current.parent
    ) {
      if (_matches(current, selector)) return [current];
    }
    return const [];
  });

  /// The siblings of the current set, optionally matching [selector].
  Markup siblings([String? selector]) => _collect((element) {
    final parent = element.parent;
    if (parent == null) return const [];
    return parent.children.where(
      (sibling) =>
          sibling != element &&
          (selector == null || _matches(sibling, selector)),
    );
  });

  /// The immediately preceding sibling of each element.
  Markup prev([String? selector]) => _sibling(-1, selector);

  /// The immediately following sibling of each element.
  Markup next([String? selector]) => _sibling(1, selector);

  /// The text of every match, joined by a space.
  ///
  /// Read as a browser renders it: runs of whitespace collapse to one space.
  /// See [readable].
  String get text => [
    for (final e in _elements) readable(e),
  ].where((s) => s.isNotEmpty).join(' ');

  /// The text of each match, one entry per element, read as [text] reads it.
  List<String> get texts => _elements.map(readable).toList();

  /// [element]'s text as a reader sees it rather than as the source spells it.
  ///
  /// A page is indented, so the markup for one heading carries newlines and
  /// runs of spaces that a browser collapses to one space before it draws
  /// anything. Reporting the source formatting as content made
  /// `res.\$('h1').text` come back as `'Wireless\n        Keyboard'`, and every
  /// call site had to collapse it again by hand.
  ///
  /// Inside a `<pre>` or a `<textarea>` the whitespace *is* the content — that
  /// is what those elements mean — so there it is kept and only trimmed.
  ///
  /// This is the one place text is read, so `res.\$(...).text`, `res.extract`
  /// and `res.pick` cannot drift apart.
  static String readable(Element element) =>
      _preformatted(element) ? element.text.trim() : _text.clean(element.text);

  /// Whether [element] sits anywhere inside a `<pre>` or `<textarea>`.
  static bool _preformatted(Element element) {
    for (Element? node = element; node != null; node = node.parent) {
      final name = node.localName;
      if (name == 'pre' || name == 'textarea') return true;
    }
    return false;
  }

  /// The inner HTML of the first match, or `''` when empty.
  String get html => _elements.isEmpty ? '' : _elements.first.innerHtml;

  /// The outer HTML of the first match, or `''` when empty.
  String get outer => _elements.isEmpty ? '' : _elements.first.outerHtml;

  /// Attribute [name] on the first match, or `null`.
  ///
  /// `href` and `src` had members of their own through 4.0.0 — four of them
  /// with the plurals, and two more on the [Element] extension. Each was this
  /// call with a literal, which Rule 5 calls a bug in the API rather than a
  /// convenience: `page.$('a').attr('href')`. They also multiplied without
  /// covering anything, since the next attribute a script wants is
  /// `data-id` and there was never going to be a member for that.
  String? attr(String name) => _elements.firstOrNull?.attributes[name];

  /// Attribute [name] across every match, skipping elements without it.
  ///
  /// Shorter than the match count when some matches do not carry [name], so
  /// this cannot be zipped against [texts] — [all] is how a row's fields are
  /// read together.
  List<String> attrs(String name) => _elements
      .map((element) => element.attributes[name])
      .whereType<String>()
      .toList();

  /// The value of the first match, as a browser would submit it, or `null`.
  ///
  /// Defined as [QuerySelectorOnElement.value] on the first match, which is
  /// where the rules a control follows are written down. The plural was
  /// `values` through 6.1.0 and is `elements` with a `map`, like every other
  /// per-element read.
  String? get value => _elements.firstOrNull?.value;

  /// The text of every match split on `<br>` and newlines, markup stripped
  /// and entities decoded.
  ///
  /// Stripping the tags leaves the entities behind, so `&amp;` used to survive
  /// into what is documented as text. They are decoded here the way the parser
  /// would have decoded them.
  List<String> get lines => _elements
      .expand(
        (element) => element.innerHtml
            .split(RegExp(r'<br\s*/?>|\r?\n'))
            .map((s) => _decode(s.replaceAll(RegExp(r'<[^>]*>'), '')).trim())
            .where((s) => s.isNotEmpty),
      )
      .toList();

  /// [markup] with its HTML entities turned back into characters.
  static String _decode(String markup) {
    if (!markup.contains('&')) return markup;
    // Parsed rather than table-driven, so every named and numeric entity the
    // parser knows is handled rather than the five everyone remembers.
    return html_parser.parseFragment(markup).text ?? markup;
  }

  Markup _collect(Iterable<Element> Function(Element element) expand) {
    final seen = <Element>{};
    for (final element in _elements) {
      seen.addAll(expand(element));
    }
    return Markup(seen.toList(), _isXPath);
  }

  Markup _sibling(int offset, String? selector) => _collect((element) {
    final parent = element.parent;
    if (parent == null) return const [];
    final index = parent.children.indexOf(element);
    final target = index + offset;
    if (index == -1 || target < 0 || target >= parent.children.length) {
      return const [];
    }
    final sibling = parent.children[target];
    if (selector != null && !_matches(sibling, selector)) return const [];
    return [sibling];
  });

  static bool _matches(Element element, String selector) =>
      JQuery.matches(element, selector);

  @override
  String toString() =>
      'Markup(count: $count, texts: '
      '[${texts.take(3).join(', ')}'
      '${count > 3 ? '...' : ''}])';
}
// ============================================================================
// EXTENSIONS
// ============================================================================

/// Query helpers on a single [Element].
/// Bridges a `package:html` [Element] into this library's cursor.
///
/// For the one case that hands you an element rather than a [Markup] —
/// [Markup.document], or a library that parsed the page itself. `$` and
/// `$xpath` stood here too through 4.0.0, on the *default* surface, which
/// contradicted both `lib/html.dart`'s own doc comment and Rule 5's "the one
/// survivor is an opt-in import". They were also `query` under a second name:
/// with the callable shorthand gone, [Markup.\$xpath] answers on any cursor, so
/// there was nothing an XPath-flavoured one did differently.
extension QuerySelectorOnElement on Element {
  /// This element's value as a browser would submit it, or `null`.
  ///
  /// What that means depends on the control, which is the point:
  ///
  /// - `<textarea>` — its text.
  /// - `<select>` — the selected `<option>`'s value, or its text when the
  ///   option carries no `value`. With nothing marked `selected`, the first
  ///   option, the way a browser does.
  /// - a checkbox or radio — its value only when `checked`, and `null`
  ///   otherwise, so an unticked box reads as absent rather than as its label.
  /// - anything else — its `value` attribute.
  ///
  /// This is the element-level rule and [Markup.value] is the cursor reading
  /// it off the first match. It was the other way round through 6.1.0, with
  /// the rule on the cursor and this a second spelling of it.
  String? get value {
    switch (localName) {
      case 'textarea':
        return text;
      case 'select':
        final options = querySelectorAll('option');
        if (options.isEmpty) return null;
        final chosen = options.firstWhere(
          (option) => option.attributes.containsKey('selected'),
          // A select with nothing marked selected submits its first option.
          orElse: () => options.first,
        );
        return chosen.attributes['value'] ?? chosen.text;
      default:
        final type = attributes['type']?.toLowerCase();
        if (type == 'checkbox' || type == 'radio') {
          if (!attributes.containsKey('checked')) return null;
          // An unlabelled ticked box submits 'on', as HTML says it does.
          return attributes['value'] ?? 'on';
        }
        return attributes['value'];
    }
  }

  /// This element as a single-match [Markup].
  Markup get query => Markup([this]);
}

/// Query helpers on a parsed [Document].
/// Bridges a `package:html` [Document] into this library's cursor.
///
/// The same story as [QuerySelectorOnElement]: `$` and `$xpath` were here on
/// the default surface and are gone.
extension QuerySelectorOnDocument on Document {
  /// This document's root as a single-match [Markup].
  Markup get query {
    final root = documentElement ?? body;
    return Markup(root != null ? [root] : [], false, this);
  }
}
// ============================================================================
// TYPED EXTRACTION (Field)
// ============================================================================

/// One typed value to read out of a parsed page.
///
/// [Markup.extract] accepts these alongside the string shorthand, and
/// [Markup.pick] reads one without losing its type. Sealed, so every
/// extraction shape is a case the compiler knows about rather than a runtime
/// type test on `dynamic`.
///
/// ```dart
/// final page = res.parse(format.html);
/// final title = page.pick(Field.text('h1'));           // String?
/// final links = page.pick(Field.attrs('a', 'href'));   // List<String>
/// ```
sealed class Field<T> {
  const Field();

  /// The trimmed text of the first match of [selector], or `null`.
  static TextField text(String selector) => TextField(selector);

  /// Attribute [attribute] on the first match of [selector], or `null`.
  ///
  /// An empty [selector] reads the attribute off the root element itself.
  static AttrField attr(String selector, String attribute) =>
      AttrField(selector, attribute);

  /// The trimmed text of every match of [selector].
  static TextsField texts(String selector) => TextsField(selector);

  /// Attribute [attribute] across every match of [selector] that carries it.
  static AttrsField attrs(String selector, String attribute) =>
      AttrsField(selector, attribute);

  /// A nested object read from the same root.
  ///
  /// Named `nest` and not `map`, because [Field.map] is the combinator every
  /// other Dart type spells that way.
  static NestField nest(Map<String, Object?> schema) => NestField(schema);

  /// One object per match of [selector], each read with [schema].
  static ListField list(String selector, Map<String, Object?> schema) =>
      ListField(selector, schema);

  /// An arbitrary read, for anything the other cases do not cover.
  static CallField<R> fn<R>(R Function(Element element) read) =>
      CallField<R>(read);

  /// Reads this field out of [root].
  T read(Element root);

  /// This field with [convert] applied to whatever it read.
  ///
  /// Where [Field.fn] takes an element and does everything by hand, this takes
  /// a field that already works and adjusts its answer:
  ///
  /// ```dart
  /// final stock = Field.text('.stock').map((t) => t ?? 'unknown');
  /// final count = Field.texts('.row').map((rows) => rows.length);
  /// ```
  Field<R> map<R>(R Function(T value) convert) =>
      CallField<R>((root) => convert(read(root)));

  /// Reads [schema] out of [root], expanding the string shorthand.
  ///
  /// This is what [Markup.extract] runs, and what [NestField] and [ListField]
  /// use for their nested schemas.
  static Map<String, Object?> _readAll(
    Element? root,
    Map<String, Object?> schema,
  ) {
    final result = <String, Object?>{};
    if (root == null) return result;
    for (final entry in schema.entries) {
      result[entry.key] = Field.of(entry.value).read(root);
    }
    return result;
  }

  /// The [Field] a schema entry describes, expanding the string shorthand.
  ///
  /// `'h1'`, `'a@href'`, `['li']`, `['li@href']`, `['.row', {...}]` and a
  /// nested schema map all have a [Field] equivalent; anything else reads as
  /// `null`.
  static Field<Object?> of(Object? spec) {
    switch (spec) {
      case Field<Object?> field:
        return field;
      case String css:
        final at = css.indexOf('@');
        if (at == -1) return TextField(css);
        return AttrField(
          css.substring(0, at).trim(),
          css.substring(at + 1).trim(),
        );
      case Map<String, Object?> schema:
        return NestField(schema);
      case List<Object?> spec when spec.length == 1:
        final first = spec.first;
        if (first is! String) return const _NullField();
        final at = first.indexOf('@');
        if (at == -1) return TextsField(first);
        return AttrsField(
          first.substring(0, at).trim(),
          first.substring(at + 1).trim(),
        );
      case List<Object?> spec
          when spec.length == 2 &&
              spec[0] is String &&
              spec[1] is Map<String, Object?>:
        return ListField(spec[0]! as String, spec[1]! as Map<String, Object?>);
      default:
        return const _NullField();
    }
  }
}

/// The text of the first match, read as a browser renders it. See
/// [Field.text].
final class TextField extends Field<String?> {
  /// The CSS selector to read.
  final String selector;

  /// Creates a text field.
  const TextField(this.selector);

  @override
  String? read(Element root) {
    final target = selector.isEmpty ? root : root.querySelector(selector);
    // The one text reader, so `extract` and `find(...).text` never disagree
    // the text of an element is.
    return target == null ? null : Markup.readable(target);
  }
}

/// An attribute of the first match. See [Field.attr].
final class AttrField extends Field<String?> {
  /// The CSS selector to read; empty means the root element itself.
  final String selector;

  /// The attribute name, or `text` for the element's text.
  final String attribute;

  /// Creates an attribute field.
  const AttrField(this.selector, this.attribute);

  @override
  String? read(Element root) {
    final target = selector.isEmpty ? root : root.querySelector(selector);
    if (target == null) return null;
    return attribute == 'text'
        ? Markup.readable(target)
        : target.attributes[attribute];
  }
}

/// The text of every match, read as a browser renders it. See [Field.texts].
final class TextsField extends Field<List<String>> {
  /// The CSS selector to read.
  final String selector;

  /// Creates a repeated text field.
  const TextsField(this.selector);

  @override
  List<String> read(Element root) => [
    for (final el in root.querySelectorAll(selector)) Markup.readable(el),
  ];
}

/// An attribute across every match. See [Field.attrs].
final class AttrsField extends Field<List<String>> {
  /// The CSS selector to read; empty means the root element itself.
  final String selector;

  /// The attribute name, or `text` for each element's text.
  final String attribute;

  /// Creates a repeated attribute field.
  const AttrsField(this.selector, this.attribute);

  @override
  List<String> read(Element root) {
    final elements = selector.isEmpty
        ? [root]
        : root.querySelectorAll(selector);
    if (attribute == 'text') {
      // Through [Markup.readable], like every other text read here: the
      // plural form used to hand back the page's own indentation while the
      // singular one collapsed it.
      return [for (final el in elements) Markup.readable(el)];
    }
    return [for (final el in elements) ?el.attributes[attribute]];
  }
}

/// A nested object read from the same root. See [Field.nest].
final class NestField extends Field<Map<String, Object?>> {
  /// The schema of the nested object.
  final Map<String, Object?> schema;

  /// Creates a nested object field.
  const NestField(this.schema);

  @override
  Map<String, Object?> read(Element root) => Field._readAll(root, schema);
}

/// One object per match. See [Field.list].
final class ListField extends Field<List<Map<String, Object?>>> {
  /// The CSS selector matching each container element.
  final String selector;

  /// The schema applied to every container.
  final Map<String, Object?> schema;

  /// Creates a repeated object field.
  const ListField(this.selector, this.schema);

  @override
  List<Map<String, Object?>> read(Element root) => [
    for (final el in root.querySelectorAll(selector))
      Field._readAll(el, schema),
  ];
}

/// An arbitrary typed read. See [Field.fn].
final class CallField<T> extends Field<T> {
  final T Function(Element element) _read;

  /// Creates a field backed by [read].
  const CallField(this._read);

  @override
  T read(Element root) => _read(root);
}

final class _NullField extends Field<Object?> {
  const _NullField();

  @override
  Object? read(Element root) => null;
}

/// [Field.when], for the fields that may not find anything.
///
/// Most readers are nullable — [Field.text] and [Field.attr] both hand back
/// `null` for a selector that matched nothing — so the converter a caller
/// actually has is one that takes a value, not a `null`.
extension NullableField<T extends Object> on Field<T?> {
  /// [convert] applied to what this field read, only when it read something.
  ///
  /// ```dart
  /// final price = Field.text('.price').when(util.text.number);   // Field<num?>
  /// final qty = Field.text('.qty').when(int.tryParse);           // Field<int?>
  /// ```
  ///
  /// [Field.map] is the unconditional form, for a converter that has something
  /// to say about an absent value:
  ///
  /// ```dart
  /// final stock = Field.text('.stock').map((t) => t ?? 'unknown');
  /// ```
  Field<R?> when<R>(R? Function(T value) convert) => CallField<R?>((root) {
    final value = read(root);
    return value == null ? null : convert(value);
  });
}
