/// # Markup Cursors (`Markup`)
///
/// A read cursor over a parsed HTML tree, and the other half of the pair
/// [Json] belongs to: one cursor for documents made of maps and scalars, one
/// for documents made of elements.
///
/// It lives here, in `util`, for the reason [Json] does — it is a pure value
/// that more than one domain hands back, and it computes rather than touches
/// anything. The *codec* that builds one is `format.html`, beside
/// `format.json`, `format.yaml` and `format.toml`, because a format is
/// knowledge from outside Dart.
///
/// Three doors produce the same cursor:
///
/// ```dart
/// res.parse(format.html);                 // a response
/// format.html.parse(body);                // a string
/// await format.html.read('page.html');    // a file
/// ```
///
/// Navigation comes in two spellings, for the two questions: [Markup.find]
/// runs a jQuery selector across the tree, and [Markup.xpath] runs an XPath
/// query. [Field] is the typed form of a single read, for the values a
/// scraper wants out with their types intact.
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import '../src/jquery.dart';
import 'sequence.dart';
import 'text.dart';

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
/// page.find('h1').text;                          // String
/// page.find('a').attrs('href');                 // Sequence<String>
/// page.xpath('//table//td[2]').texts;            // Sequence<String>
/// page.all('.product', (row) => (
///   name: row.find('.name').text,
///   price: row.pick(Field.text('.price').when(util.text.number)),
/// ));                                   // Sequence<({String name, num? price})>
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

  /// Creates a [Markup] for XPath evaluation.
  Markup.xpath([List<Element>? elements, Document? document])
    : _elements = elements ?? const [],
      _isXPath = true,
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

  /// The matched elements, as a [Sequence].
  ///
  /// This used to be an `IterableMixin<Element>`, which put Dart's whole
  /// collection vocabulary next to this library's on every selector result.
  /// A [Markup] now *holds* a sequence instead of being one, so the
  /// element-level work has one spelling:
  ///
  /// ```dart
  /// page.find('tr').elements.keep((e) => e.classes.contains('live')).count();
  /// ```
  Sequence<Element> get elements => Sequence(_elements);

  /// How many elements matched.
  int get count => _elements.length;

  /// Whether nothing matched.
  ///
  /// No complement: `!q.empty` already says the other thing.
  bool get empty => _elements.isEmpty;

  /// The element at [index], or `null` when out of range.
  Element? operator [](int index) =>
      index >= 0 && index < _elements.length ? _elements[index] : null;

  /// Runs an XPath query across the current elements or document.
  Markup xpath(String query) {
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
    return Markup(elements, true, _document);
  }

  /// All string values (attributes or text nodes) matching the XPath [query].
  Sequence<String> xpathvalues(String query) {
    final results = <String>[];
    final nodes = _document != null ? [_document] : _elements;
    for (final node in nodes) {
      try {
        final xp = HtmlXPath.node(node);
        final result = xp.query(query);
        if (result.attrs.isNotEmpty) {
          for (final a in result.attrs) {
            if (a != null && a.isNotEmpty) results.add(a);
          }
        } else {
          for (final xNode in result.nodes) {
            final domNode = xNode.node;
            final t = domNode.text?.trim();
            if (t != null && t.isNotEmpty) results.add(t);
          }
        }
      } catch (_) {}
    }
    return Sequence(results);
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
  /// page.find('.row').find('.name').texts;   // names inside rows, only
  /// ```
  ///
  /// The result is scoped even when this cursor was not, so the second call
  /// above cannot quietly search the page again.
  ///
  /// `page(selector)` was a second spelling of this through 4.0.0 — the
  /// release that made them one search kept both names for it. Worse, which
  /// selector *language* the callable spoke depended on hidden state: on a
  /// cursor from `format.html.query` it ran the string as XPath instead, so
  /// nothing at the call site said which of the two it was. [find] and
  /// [xpath] each say so in their names. The jQuery spelling survives where
  /// Rule 5 already put it, behind `package:dart_toolkit/html.dart`.
  Markup find(String selector) =>
      Markup(JQuery.select(_document ?? _elements, selector), false);

  /// One [R] per match of [selector], each built from its own scope.
  ///
  /// This is how a repeated sub-object comes back typed. [build] receives the
  /// matched element as a [Markup] of its own, so the same readers work
  /// one level down and a Dart record carries the shape without a class:
  ///
  /// ```dart
  /// final variants = page.all('.variant', (row) => (
  ///   name: row.find('.name').text,
  ///   sku: row.attr('data-sku'),
  ///   price: row.pick(Field.text('.price').when(util.text.number)),
  /// ));
  /// // Sequence<({String name, String? sku, num? price})>
  /// ```
  ///
  /// Where `extract` hands back `Map<String, Object?>` and leaves every value
  /// to be cast, this keeps the type of each field all the way out.
  Sequence<R> all<R>(String selector, R Function(Markup row) build) =>
      Sequence([
        for (final element in find(selector)._elements)
          build(Markup([element], false)),
      ]);

  /// The first match of [selector], built from its own scope, or `null`.
  ///
  /// The singular of [all], for a section a page has at most one of.
  ///
  /// ```dart
  /// final seller = page.one('.seller', (s) => (
  ///   name: s.find('.name').text,
  ///   rating: s.pick(Field.text('.rating').when(util.text.number)),
  /// ));
  /// ```
  R? one<R>(String selector, R Function(Markup row) build) {
    final match = find(selector)._elements.firstOrNull;
    return match == null ? null : build(Markup([match], false));
  }

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
      Field.readAll(_root, schema);

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

  /// The elements that do *not* match [selector].
  Markup not(String selector) => filter((e) => !_matches(e, selector));

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
  Sequence<String> get texts =>
      Sequence([for (final e in _elements) readable(e)]);

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

  /// Inner HTML of every match.
  Sequence<String> get htmls => Sequence(_elements.map((e) => e.innerHtml));

  /// The outer HTML of the first match, or `''` when empty.
  String get outer => _elements.isEmpty ? '' : _elements.first.outerHtml;

  /// Outer HTML of every match.
  Sequence<String> get outers => Sequence(_elements.map((e) => e.outerHtml));

  /// Attribute [name] on the first match, or `null`.
  ///
  /// `href` and `src` had members of their own through 4.0.0 — four of them
  /// with the plurals, and two more on the [Element] extension. Each was this
  /// call with a literal, which Rule 5 calls a bug in the API rather than a
  /// convenience: `page.find('a').attr('href')`. They also multiplied without
  /// covering anything, since the next attribute a script wants is
  /// `data-id` and there was never going to be a member for that.
  String? attr(String name) => _elements.firstOrNull?.attributes[name];

  /// Attribute [name] across every match, skipping elements without it.
  ///
  /// Shorter than the match count when some matches do not carry [name], so
  /// this cannot be zipped against [texts] — [all] is how a row's fields are
  /// read together.
  Sequence<String> attrs(String name) => Sequence([
    for (final element in _elements)
      if (element.attributes[name] case final value?) value,
  ]);

  /// The value of the first match, as a browser would submit it, or `null`.
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
  String? get value =>
      _elements.isEmpty ? null : _elementValue(_elements.first);

  /// The value of every match that has one, on the same terms as [value].
  Sequence<String> get values => Sequence([
    for (final element in _elements)
      if (_elementValue(element) case final value?) value,
  ]);

  static String? _elementValue(Element element) {
    switch (element.localName) {
      case 'textarea':
        return element.text;
      case 'select':
        final options = element.querySelectorAll('option');
        if (options.isEmpty) return null;
        final chosen = options.firstWhere(
          (option) => option.attributes.containsKey('selected'),
          // A select with nothing marked selected submits its first option.
          orElse: () => options.first,
        );
        return chosen.attributes['value'] ?? chosen.text;
      default:
        final type = element.attributes['type']?.toLowerCase();
        if (type == 'checkbox' || type == 'radio') {
          if (!element.attributes.containsKey('checked')) return null;
          // An unlabelled ticked box submits 'on', as HTML says it does.
          return element.attributes['value'] ?? 'on';
        }
        return element.attributes['value'];
    }
  }

  /// The `data-[key]` attribute of the first match, falling back to [key].
  String? data(String key) {
    final element = _elements.firstOrNull;
    if (element == null) return null;
    return element.attributes['data-$key'] ?? element.attributes[key];
  }

  /// Every `data-*` attribute of the first match, keyed without the prefix.
  Map<String, String> get dataset {
    final element = _elements.firstOrNull;
    if (element == null) return const {};
    return {
      for (final entry in element.attributes.entries)
        if (entry.key.toString().startsWith('data-'))
          entry.key.toString().substring(5): entry.value,
    };
  }

  /// Whether any match carries [className].
  bool has(String className) =>
      _elements.any((e) => e.classes.contains(className));

  /// Calls [fn] for each match with its index.
  void each(void Function(Element element, int index) fn) {
    for (var i = 0; i < _elements.length; i++) {
      fn(_elements[i], i);
    }
  }

  /// The text of every match split on `<br>` and newlines, markup stripped
  /// and entities decoded.
  ///
  /// Stripping the tags leaves the entities behind, so `&amp;` used to survive
  /// into what is documented as text. They are decoded here the way the parser
  /// would have decoded them.
  Sequence<String> get lines => Sequence([
    for (final element in _elements)
      ...element.innerHtml
          .split(RegExp(r'<br\s*/?>|\r?\n'))
          .map((s) => _decode(s.replaceAll(RegExp(r'<[^>]*>'), '')).trim())
          .where((s) => s.isNotEmpty),
  ]);

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
      '[${texts.head(3).join(', ')}${count > 3 ? '...' : ''}])';
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
/// with the callable shorthand gone, [Markup.xpath] answers on any cursor, so
/// there was nothing an XPath-flavoured one did differently.
extension QuerySelectorOnElement on Element {
  /// This element's value as a browser would submit it, or `null`.
  ///
  /// Reads a `<textarea>`, a `<select>` and a checkbox the way
  /// [Markup.value] does, because it is the same answer.
  String? get value => query.value;

  /// Attribute [name], or `null`.
  String? attr(String name) => attributes[name];

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
  static Map<String, Object?> readAll(
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
    final elements =
        selector.isEmpty ? [root] : root.querySelectorAll(selector);
    if (attribute == 'text') {
      // Through [Markup.readable], like every other text read here: the
      // plural form used to hand back the page's own indentation while the
      // singular one collapsed it.
      return [for (final el in elements) Markup.readable(el)];
    }
    return [
      for (final el in elements)
        if (el.attributes[attribute] case final value?) value,
    ];
  }
}

/// A nested object read from the same root. See [Field.nest].
final class NestField extends Field<Map<String, Object?>> {
  /// The schema of the nested object.
  final Map<String, Object?> schema;

  /// Creates a nested object field.
  const NestField(this.schema);

  @override
  Map<String, Object?> read(Element root) => Field.readAll(root, schema);
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
    for (final el in root.querySelectorAll(selector)) Field.readAll(el, schema),
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
