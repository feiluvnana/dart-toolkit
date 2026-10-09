part of '../../markup.dart';

/// Which markup an [Element] came from, and so how it serialises: HTML keeps void and
/// raw-text elements, XML closes everything, empty ones as `<e/>`.
///
/// {@category Formats}
enum Syntax { html, xml }

/// A node in a parsed tree: an [Element], a [Text], or an [Attribute] selected by an XPath `@`
/// step.
///
/// {@category Formats}
sealed class Node {
  /// The element containing this node, or `null` at the root.
  Element? get parent => _parent;
  Element? _parent;

  /// The text as a reader sees it: every run of whitespace one space, trimmed; for an HTML
  /// element, what is below it but `<script>`, `<style>`, `<title>` and the rest a page never
  /// shows. CSS `:contains()` and XPath compare this. An attribute's is its value.
  String get text;

  /// The text as it is in the markup: every text node below, whitespace and all.
  String get rawText;

  /// This node serialised back to the markup it came from.
  String get markup;

  /// Takes this node out of its tree (an attribute off its element); nothing when it has no
  /// parent. It can be appended elsewhere.
  void detach() {
    final p = _parent;
    if (p == null) return;
    if (this case final Attribute a) {
      p.attributes.remove(a.name);
    } else {
      if (_holdsBase(this)) _edits++;
      p._nodes.remove(this);
    }
    _parent = null;
  }

  /// Puts [other] where this node is in its parent's children, detaching this one.
  void replace(Node other) {
    final p = _parent;
    if (p == null) return;
    if (this is Attribute || other is Attribute) {
      throw ArgumentError.value(other, 'other', 'Invalid replacement: an attribute is not a child');
    }
    if (identical(other, this)) return;
    // Detached first: an earlier sibling's removal would shift this node's index.
    other.detach();
    final index = p._nodes.indexOf(this);
    if (index != -1) {
      if (_holdsBase(this) || _holdsBase(other)) _edits++;
      other._parent = p;
      p._nodes[index] = other;
      _parent = null;
    }
  }

  @override
  String toString() => markup;
}

/// A run of text, decoded: `&amp;` is already `&`.
///
/// {@category Formats}
final class Text extends Node {
  /// The text as it is in the markup.
  final String data;

  Text(this.data);

  @override
  String get text => _collapsed(data);

  @override
  String get rawText => data;

  @override
  String get markup {
    final sb = StringBuffer();
    _writeEscaped(sb, data, attribute: false, xml: parent?.syntax == Syntax.xml);
    return sb.toString();
  }
}

/// An attribute, as an XPath `@name` step selects it.
///
/// {@category Formats}
final class Attribute extends Node {
  final String name;
  final String value;

  Attribute._(this.name, this.value, Element owner) {
    _parent = owner;
  }

  @override
  String get text => value;

  @override
  String get rawText => value;

  @override
  String get markup {
    final sb = StringBuffer('$name="');
    _writeEscaped(sb, value, attribute: true, xml: parent?.syntax == Syntax.xml);
    return (sb..write('"')).toString();
  }

  /// Equal when they name the same attribute on the same element: XPath mints a new instance
  /// per step, and a node-set must de-duplicate and sort them as one node.
  @override
  bool operator ==(Object other) => other is Attribute && other.name == name && identical(other.parent, parent);

  @override
  int get hashCode => Object.hash(identityHashCode(parent), name);
}

/// An element: a [name], its [attributes], and the [nodes] inside it. HTML names arrive
/// lowercased, XML ones as written; [syntax] decides serialisation and CSS case folding.
///
/// {@category Formats}
class Element extends Node {
  /// The tag name: `div` for HTML, as written for XML (`media:content`).
  final String name;

  /// Attributes by name, values decoded; a valueless attribute is `''`.
  final Map<String, String> attributes;

  /// Child nodes in document order.
  List<Node> get nodes => UnmodifiableListView(_nodes);
  final List<Node> _nodes = [];

  /// Which markup this element came from.
  final Syntax syntax;

  /// Index in the parent's [nodes], checked before searching, so sibling walks stay linear.
  int _slot = 0;

  Element(this.name, [Map<String, String>? attributes, this.syntax = Syntax.html])
    : attributes = name == 'base' ? _BaseAttributes(attributes ?? {}) : attributes ?? {} {
    if (name == 'base') _baseElements++;
  }

  /// Child elements, skipping text.
  Selection<Element> get children => Selection._(_nodes.whereType<Element>().toList(), '> *');

  /// The name without its namespace prefix: `content` for `media:content`.
  String get local => name.contains(':') ? name.substring(name.indexOf(':') + 1) : name;

  /// The namespace prefix, or `null`.
  String? get prefix => name.contains(':') ? name.substring(0, name.indexOf(':')) : null;

  /// The `id` attribute, or `null`.
  String? get id => attributes['id'];

  /// Attribute [name]; when it is absent, [or], else a [MissingException] naming it and the tag.
  String attr(String name, {String? or}) =>
      attributes[name] ?? or ?? (throw MissingException('attribute "$name"', where: '<${this.name}>'));

  /// The top of this element's tree, whose `<base href>` its links resolve against.
  Element get _root => _rootOf(this) as Element;

  /// The best image URL here: a lazy-load `data-*` attribute, then the densest `srcset` entry,
  /// then `src`, then [link], skipping placeholder pixels; for any element but an `<img>` (a
  /// `<picture>`, a card) the first `<img>` or `<source>` inside that has one comes first. A
  /// [MissingException] naming the tag when there is none.
  Uri get imageLink => _imageLinkIn(_baseOf(_root)) ?? (throw MissingException('image link', where: '<$name>'));

  /// [imageLink] against [base], found once by the caller rather than per candidate.
  Uri? _imageLinkIn(Uri? base) {
    final tag = name.toLowerCase();
    if (tag != 'img' && tag != 'source') {
      for (final c in _Selector.parse('img, source', fold: syntax == Syntax.html).from(this)) {
        if (c._imageLinkIn(base) case final u?) return u;
      }
    }
    Uri? usable(String? raw) => raw == null || raw.trim().isEmpty
        ? null
        : switch (_resolve(raw, base)) {
            final u? when !_isPlaceholder(u) => u,
            _ => null,
          };
    for (final a in const [
      'data-original',
      'data-src',
      'data-lazy-src',
      'data-lazy',
      'data-zoom-image',
      'data-highres',
    ]) {
      if (usable(attributes[a]) case final u?) return u;
    }
    return usable(_bestSrcset(attributes['srcset'])) ?? usable(attributes['src']) ?? _linkIn(base);
  }

  /// This element's `href`, `src`, or the address a script navigates to (a `javascript:` href,
  /// an `onclick`), resolved against its document's base; a [MissingException] naming the tag
  /// when there is none. An `href` that is not a URL is a [FormatException] carrying it: the
  /// value is there, so the document is broken, not the link absent.
  Uri get link {
    final raw = _rawLink;
    if (raw == null) throw MissingException('link (href, src or onclick)', where: '<$name>');
    return _resolve(raw, _baseOf(_root)) ?? (throw FormatException('Invalid HTML: <$name> href is not a URL', raw));
  }

  /// The link as written: `href`, then `src`, unless it is a script, then the address a script
  /// navigates to.
  String? get _rawLink {
    final href = attributes['href'] ?? attributes['src'];
    if (href != null && !_isScript(href)) return href;
    return _extractUrlFromOnclick(href) ?? _extractUrlFromOnclick(attributes['onclick']);
  }

  /// [link] as `null` instead of a throw, for a bulk read that skips what is not a link.
  Uri? _linkIn(Uri? base) => switch (_rawLink) {
    final href? => _resolve(href, base),
    null => null,
  };

  /// Appends [node] to this element's children, detaching it from where it was.
  void append(Node node) => _insert(node, _nodes.length);

  void _insert(Node node, int at) {
    if (node is Attribute) throw ArgumentError.value(node, 'node', 'Invalid child: an attribute');
    node.detach();
    if (_holdsBase(node)) _edits++;
    node._parent = this;
    _nodes.insert(at.clamp(0, _nodes.length), node);
  }

  /// Removes all child nodes from this element.
  void clear() {
    for (final node in _nodes) {
      if (_holdsBase(node)) _edits++;
      node._parent = null;
    }
    _nodes.clear();
  }

  /// The nearest ancestor, or this element itself, matching CSS [selector]; `null` when none
  /// does. Walking up is navigation, not a reading, like [next].
  Element? closest(String selector) {
    final parsed = _Selector.parse(selector, fold: syntax == Syntax.html);
    for (Element? e = this; e != null; e = e.parent) {
      if (parsed.matches(e)) return e;
    }
    return null;
  }

  /// The ancestors from the parent upward, nearest first.
  Iterable<Element> get ancestors sync* {
    for (var p = parent; p != null; p = p.parent) {
      yield p;
    }
  }

  /// Every descendant matching CSS [selector], in document order. HTML names fold to
  /// lowercase; for an XML prefix escape the colon, `r'media\:content'`.
  ///
  /// A leading combinator reads from this element, as in `:has()`: `> li.x` is its children,
  /// `+ dd` the next sibling, `~ p` the later ones; in `> a, b` the `b` is a descendant.
  Selection<Element> $(String selector) =>
      Selection._(_Selector.parse(selector, fold: syntax == Syntax.html).from(this), selector);

  /// The nodes XPath [expression] selects from this element: `//a/@href`,
  /// `//tr[td[2]="FLAC"]/td[1]/a`, `//h2[contains(., "Tracks")]/following-sibling::table[1]`.
  Selection<Node> $x(String expression) => _xpath([this], expression);

  @override
  String get text {
    if (_nodes case [final Text t]) return _collapsed(t.data);
    final out = _Folded();
    _foldText(this, out);
    return out.toString();
  }

  @override
  String get rawText {
    // One text child is most elements that have text at all, and needs no buffer.
    if (_nodes case [final Text t]) return t.data;
    final sb = StringBuffer();
    _eachBelow(this, (m) {
      if (m is Text) sb.write(m.data);
      return false;
    });
    return sb.toString();
  }

  /// The text as it reads on the page, trimmed, blank lines dropped: lines break at `<br>`,
  /// newlines and block elements (`p`, `div`, `li`, `tr`…), cells in a row are tab-separated,
  /// and what a page never shows (`head`, `script`, `style`, `title`, `template`, `noscript`)
  /// is skipped.
  List<String> get lines {
    final out = <String>[];
    final current = StringBuffer();

    void flush() {
      final line = current.toString().replaceAll(' ', ' ').trim();
      if (line.isNotEmpty) out.add(line);
      current.clear();
    }

    final open = <Element>[this];
    final at = <int>[0];
    while (open.isNotEmpty) {
      final e = open.last;
      final i = at.last;
      if (i == e._nodes.length) {
        open.removeLast();
        at.removeLast();
        if (_blockElements.contains(e.name)) flush();
        continue;
      }
      at[at.length - 1] = i + 1;
      switch (e._nodes[i]) {
        case final Text t:
          final data = t.data;
          var from = 0;
          for (var nl = data.indexOf('\n'); nl != -1; nl = data.indexOf('\n', from)) {
            current.write(data.substring(from, nl));
            flush();
            from = nl + 1;
          }
          current.write(from == 0 ? data : data.substring(from));
        case final Element child:
          final name = child.name;
          if (name == 'br') {
            flush();
          } else if (!_hiddenElements.contains(name)) {
            if (_blockElements.contains(name)) {
              flush();
            } else if ((name == 'td' || name == 'th') && current.isNotEmpty) {
              current.write('\t');
            }
            open.add(child);
            at.add(0);
          }
        default:
      }
    }
    flush();
    return out;
  }

  @override
  String get markup {
    final sb = StringBuffer();
    _serialize(this, sb);
    return sb.toString();
  }

  /// The form fields within this element (or this element itself) that carry form data,
  /// mapped by name to their values ([String] or [List<String>] for repeated names or multi-selects).
  ///
  /// Omitted: unnamed, disabled (as `:disabled` matches: own attribute, a disabled fieldset or
  /// optgroup), `submit`/`button`/`reset`/`image`/`file` controls, unchecked checkboxes/radios.
  Map<String, Object> get fields {
    final raw = <String, List<String>>{};
    void add(String name, String value) => (raw[name] ??= <String>[]).add(value);
    final isControl = const {'input', 'textarea', 'select', 'button'}.contains(name.toLowerCase());
    final inputs = [
      if (isControl && _disabled(this) == false) this,
      ...$('input:enabled, textarea:enabled, select:enabled, button:enabled'),
    ];
    for (final input in inputs) {
      final name = input.attributes['name'];
      if (name == null || name.isEmpty) continue;
      switch (input.name.toLowerCase()) {
        case 'textarea':
          add(name, input.rawText);
        case 'input':
          final type = (input.attributes['type'] ?? 'text').toLowerCase();
          if (const {'submit', 'button', 'reset', 'image', 'file'}.contains(type)) {
            continue;
          } else if (type == 'checkbox' || type == 'radio') {
            if (input.attributes.containsKey('checked')) add(name, input.attributes['value'] ?? 'on');
          } else {
            add(name, input.attributes['value'] ?? '');
          }
        case 'select':
          final options = input.$('option:enabled').toList();
          final list =
              input.attributes.containsKey('multiple') || (int.tryParse(input.attributes['size'] ?? '') ?? 1) > 1;
          final chosen = list
              ? options.where((o) => o.attributes.containsKey('selected'))
              : [
                  options.where((o) => o.attributes.containsKey('selected')).firstOrNull ?? options.firstOrNull,
                ].whereType<Element>();
          for (final o in chosen) {
            add(name, o.attributes['value'] ?? o.text);
          }
        default:
      }
    }
    return <String, Object>{
      for (final MapEntry(:key, :value) in raw.entries)
        if (value.length == 1) key: value.first else key: value,
    };
  }

  /// The [Request] a browser sends when this form is submitted, or, for a submit button
  /// (`<button>`, `<input type=submit|image>`), when it is pressed: the form's `method` (the
  /// button's `formmethod`; anything but POST is a GET), its `action` (`formaction`) resolved
  /// against the page (none is the page itself), and [fields] with the pressed button's own
  /// name and value. A GET carries the fields as the query, replacing the action's (no fields,
  /// no `?`); a POST as a form body.
  ///
  /// A relative action on a page parsed without its address (`Html.parse(text, url: …)`) is a
  /// [MissingException], as is anything but a form or a submit button in one.
  ///
  /// ```dart
  /// final req = form.$('button[value=next]').first.submission;  // as that button submits it
  /// ```
  Request get submission {
    final tag = name.toLowerCase();
    final type = (attributes['type'] ?? (tag == 'button' ? 'submit' : 'text')).toLowerCase();
    final button = (tag == 'button' || tag == 'input') && (type == 'submit' || type == 'image');
    // A button names its form by `form="id"`, else sits inside it.
    final form = switch ((tag, attributes['form'])) {
      ('form', _) => this,
      (_, final id?) when button => _root.$('form').where((f) => f.id == id).firstOrNull,
      _ => button ? closest('form') : null,
    };
    if (form == null) throw MissingException('form', where: '<$name>');
    final values = <String, Object>{...form.fields};
    void add(String key, String value) => values[key] = switch (values[key]) {
      null => value,
      final String one => [one, value],
      final List<String> many => [...many, value],
      final other => other,
    };
    if (attributes['name'] case final pressed? when button && pressed.isNotEmpty) {
      // An image button sends where it was clicked; a script's click is at its corner.
      if (type == 'image') {
        add('$pressed.x', '0');
        add('$pressed.y', '0');
      } else {
        add(pressed, attributes['value'] ?? '');
      }
    }
    final method = ((button ? attributes['formmethod'] : null) ?? form.attributes['method'] ?? 'GET').trim();
    final action = ((button ? attributes['formaction'] : null) ?? form.attributes['action'] ?? '').trim();
    final target = Uri.tryParse(action) ?? (throw FormatException('Invalid HTML: form action "$action" is not a URL'));
    final base = _baseOf(form._root);
    final Uri url;
    if (target.hasScheme) {
      url = target;
    } else if (base != null) {
      url = base.resolveUri(target);
    } else {
      throw MissingException('page address', where: '<form action="$action"> (parse the page with url:)');
    }
    if (method.toUpperCase() == 'POST') return Request('POST', url, form: values);
    if (values.isEmpty) return Request('GET', _withoutQuery(url));
    // Form-encoded as a browser writes it: `q=` for an empty field, `+` for a space.
    String pair(String k, String v) => '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(v)}';
    final query = [
      for (final MapEntry(:key, :value) in values.entries)
        if (value is List<String>) ...value.map((v) => pair(key, v)) else pair(key, '$value'),
    ].join('&');
    return Request('GET', url.replace(query: query));
  }

  /// This `<table>` (or the first one below this element) as rows of named columns; a
  /// [MissingException] when there is none.
  ///
  /// The header is the first all-`<th>` row or the first `<thead>` row; an unnamed column is
  /// `c1, c2, …` and a repeated name gets a suffix (`Price_2`). `colspan` and `rowspan` repeat
  /// a cell's text into every column and row it covers.
  Table get table {
    final t = name == 'table' ? this : $('table').firstOrNull;
    if (t == null) throw MissingException('<table>', where: '<$name>');
    List<String>? header;
    final body = <List<String?>>[];
    // Cells a rowspan carries down: column → (text, rows still to fill).
    final carried = <int, (String, int)>{};
    for (final tr in _within(t, const {'tr'}, const {'table'})) {
      final cells = _within(tr, const {'th', 'td'}, const {'table', 'tr'});
      if (cells.isEmpty) continue;
      if (header == null && (tr.parent?.name == 'thead' || cells.every((c) => c.name == 'th'))) {
        header = [
          for (final c in cells)
            for (var k = _span(c, 'colspan', 1000); k > 0; k--) c.text,
        ];
        continue;
      }
      if (!cells.any((c) => c.name == 'td')) continue;
      final row = <String?>[];
      void fill() {
        for (var c = carried[row.length]; c != null; c = carried[row.length]) {
          final (text, left) = c;
          left == 1 ? carried.remove(row.length) : carried[row.length] = (text, left - 1);
          row.add(text);
        }
      }

      for (final c in cells) {
        fill();
        final text = c.text;
        final down = _span(c, 'rowspan', 65534);
        for (var k = _span(c, 'colspan', 1000); k > 0; k--) {
          if (down > 1) carried[row.length] = (text, down - 1);
          row.add(text);
        }
      }
      // Cells carried past a short row's end keep their columns, with gaps between.
      for (var max = carried.keys.fold(-1, (m, k) => k > m ? k : m); row.length <= max;) {
        carried.containsKey(row.length) ? fill() : row.add(null);
      }
      body.add(row);
    }
    final names = header ?? const <String>[];
    final width = body.fold(names.length, (w, r) => r.length > w ? r.length : w);
    final seen = <String, int>{};
    final columns = <String>[];
    for (var i = 0; i < width; i++) {
      var name = i < names.length && names[i].isNotEmpty ? names[i] : 'c${i + 1}';
      final n = seen[name] = (seen[name] ?? 0) + 1;
      if (n > 1) {
        var k = n;
        while (seen.containsKey('${name}_$k')) {
          k++;
        }
        name = '${name}_$k';
        seen[name] = 1;
      }
      columns.add(name);
    }
    return Table(columns, [
      for (final r in body) {for (var i = 0; i < columns.length; i++) columns[i]: i < r.length ? r[i] : null},
    ]);
  }

  /// The next element sibling, or `null`.
  Element? get next => _sibling(1);

  /// The previous element sibling, or `null`.
  Element? get previous => _sibling(-1);

  Element? _sibling(int step) {
    final siblings = parent?._nodes;
    if (siblings == null) return null;
    if (_slot >= siblings.length || !identical(siblings[_slot], this)) _slot = siblings.indexOf(this);
    for (var i = _slot + step; i >= 0 && i < siblings.length; i += step) {
      if (siblings[i] case final Element e) return e;
    }
    return null;
  }
}

/// [u] with no query, and so no `?`.
Uri _withoutQuery(Uri u) => Uri(
  scheme: u.scheme,
  userInfo: u.userInfo,
  host: u.host,
  port: u.hasPort ? u.port : null,
  path: u.path,
  fragment: u.hasFragment ? u.fragment : null,
);

final _ws = RegExp(r'\s+');

/// The nodes a query matched, in document order: a CSS `$` gives elements, an XPath `$x` any
/// node. It is an [Iterable], and stays a selection through [where], [take] and [skip]; its
/// plurals ([texts], [attrs]) have one entry per match, so they line up.
///
/// ```dart
/// page.$('h2 a').texts;   page.$('a').attrs('href');   page.$('li').at(3).text;
/// page.$('table').first.table;   page.$x('//a/@href').links;
/// ```
///
/// {@category Formats}
final class Selection<N extends Node> extends Iterable<N> {
  final List<N> _nodes;

  /// The selector or expression, for the failure that names it.
  final String _query;

  Selection._(this._nodes, this._query);

  @override
  Iterator<N> get iterator => _nodes.iterator;

  @override
  int get length => _nodes.length;

  @override
  bool get isEmpty => _nodes.isEmpty;

  @override
  bool get isNotEmpty => _nodes.isNotEmpty;

  @override
  List<N> toList({bool growable = true}) => List.of(_nodes, growable: growable);

  MissingException _missing([int? at]) => MissingException(
    'match${at == null ? '' : ' $at'} for "$_query"${at == null ? '' : ' (${_nodes.length} matched)'}',
  );

  /// The first match; a [MissingException] naming the query when nothing matched
  /// (`firstOrNull` where nothing may match).
  @override
  N get first => _nodes.isEmpty ? throw _missing() : _nodes.first;

  /// The last match; a [MissingException] naming the query when nothing matched.
  @override
  N get last => _nodes.isEmpty ? throw _missing() : _nodes.last;

  /// The one match; a [MissingException] when nothing matched, a [FormatException] when more
  /// than one did.
  @override
  N get single => switch (_nodes.length) {
    0 => throw _missing(),
    1 => _nodes.first,
    final n => throw FormatException(
      'Invalid ${_nodes.first.parent?.syntax == Syntax.xml ? 'XML' : 'HTML'}: $n matches for "$_query", not one',
    ),
  };

  /// The match at [index] (negative from the end); a [MissingException] naming the query when
  /// there is none.
  N at(int index) {
    final i = index < 0 ? _nodes.length + index : index;
    return i >= 0 && i < _nodes.length ? _nodes[i] : throw _missing(index);
  }

  @override
  Selection<N> where(bool Function(N node) test) => Selection._(_nodes.where(test).toList(), _query);

  @override
  Selection<N> take(int count) => Selection._(_nodes.take(count).toList(), _query);

  @override
  Selection<N> skip(int count) => Selection._(_nodes.skip(count).toList(), _query);

  /// The first match's [Node.text]: `page.$('h1').text`. A [MissingException] naming the query
  /// when nothing matched.
  String get text => first.text;

  /// Every match's [Node.text].
  List<String> get texts => [for (final n in _nodes) n.text];

  /// Attribute [name] of the first match that has it: `page.$('meta[name=description]').attr('content')`.
  /// When none has it, [or], else a [MissingException] naming it and the query.
  String attr(String name, {String? or}) {
    for (final n in _nodes) {
      if (n is Element) {
        if (n.attributes[name] case final value?) return value;
      }
    }
    return or ?? (throw MissingException('attribute "$name"', where: '"$_query"'));
  }

  /// Every match's attribute [name], `null` where it has none (or is not an element).
  List<String?> attrs(String name) => [for (final n in _nodes) n is Element ? n.attributes[name] : null];

  /// Every match's link, resolved against its document's base address: an element's
  /// [Element.link], an attribute's value (`$x('//a/@href')`). What is not a link is skipped.
  List<Uri> get links => [for (final (n, base) in _withBase) ?_linkOf(n, base)];

  /// [n]'s link against [base]: an element's [Element.link], an attribute's value; `null` for
  /// anything else.
  static Uri? _linkOf(Node n, Uri? base) =>
      n is Element ? n._linkIn(base) : (n is Attribute && !_isScript(n.value) ? _resolve(n.value, base) : null);

  /// The first match's link, among those that have one (see [links]): `page.$('a.next').link`.
  /// A [MissingException] naming the query when none does.
  Uri get link {
    for (final (n, base) in _withBase) {
      if (_linkOf(n, base) case final u?) return u;
    }
    throw MissingException('link', where: '"$_query"');
  }

  /// Every match's [Element.imageLink]; one with none is skipped.
  List<Uri> get imageLinks => [for (final (n, base) in _withBase) ?(n is Element ? n._imageLinkIn(base) : null)];

  /// The first match's image link, among those that have one: a [MissingException] when none
  /// does.
  Uri get imageLink {
    for (final (n, base) in _withBase) {
      if (n is Element ? n._imageLinkIn(base) : null case final u?) return u;
    }
    throw MissingException('image link', where: '"$_query"');
  }

  /// Each match with its document's base address, looked up once per document, not per match.
  Iterable<(N, Uri?)> get _withBase sync* {
    Node? root;
    Uri? base;
    for (final n in _nodes) {
      final top = _rootOf(n is Attribute ? n.parent! : n);
      if (!identical(top, root)) (root, base) = (top, top is Element ? _baseOf(top) : null);
      yield (n, base);
    }
  }

  /// Every element each element match's [Element.$] finds, each once, in document order.
  Selection<Element> $(String selector) {
    final scopes = _nodes.whereType<Element>().toList();
    final s = _Selector.parse(selector, fold: scopes.firstOrNull?.syntax != Syntax.xml);
    final seen = <Element>{};
    final out = [
      for (final e in scopes)
        for (final m in s.from(e))
          if (seen.add(m)) m,
    ];
    // A descendant query from scopes in order finds in order; `> li` from nested ones does not.
    return Selection._(s.relative && scopes.length > 1 ? _inOrder(out) : out, selector);
  }

  /// The nodes XPath [expression] selects from each element match, each once, in document order.
  Selection<Node> $x(String expression) => _xpath(_nodes.whereType<Element>().toList(), expression);

  /// Takes every match out of its tree.
  void detach() {
    // Per parent at once, so taking out many siblings or nested matches stays linear.
    final byParent = <Element, Set<Node>>{};
    for (final n in _nodes) {
      final p = n._parent;
      if (p == null) continue;
      n is Attribute ? n.detach() : (byParent[p] ??= Set.identity()).add(n);
    }
    if (_baseElements > 0 && byParent.isNotEmpty) _edits++; // one bump for every base moved
    for (final MapEntry(key: p, value: gone) in byParent.entries) {
      p._nodes.removeWhere(gone.contains);
      for (final n in gone) {
        n._parent = null;
      }
    }
  }

  @override
  String toString() => 'Selection("$_query", ${_nodes.length})';
}

/// A parsed HTML document.
///
/// ```dart
/// final page = await url.get().html;
/// page.$('h2 a').texts;
/// await page.save('copy.html');
/// ```
///
/// {@category Formats}
final class Html implements Saveable {
  /// The `<html>` element. Parsing always makes one, with `<head>` and `<body>` inside.
  final Element root;

  /// The `<!DOCTYPE …>` as written, kept for [encode].
  final String? _doctype;

  Html._(this.root, this._doctype, {Uri? url}) {
    if (url != null) _urls[root] = url;
  }

  /// [text] parsed as a browser parses it: implied end tags, void and raw-text elements, SVG and
  /// MathML land where a browser puts them. Two repairs are not made: misnested formatting
  /// (`<b>1<p>2</b>3`) closes rather than being re-opened, and stray text in a `<table>` stays
  /// there. [url] is the page's address, which links resolve against.
  static Html parse(String text, {Uri? url}) {
    final (root, doctype) = _parseHtml(text);
    return Html._(root, doctype, url: url);
  }

  /// The page saved at [path], its charset sniffed as a browser sniffs it: a byte-order mark,
  /// else `<meta charset>`, else UTF-8.
  static Future<Html> read(String path) async =>
      parse(Response.bytes(await File(path).readAsBytes(), 200, headers: const {'content-type': 'text/html'}).text);

  /// The address the page was parsed with, if any.
  Uri? get url => _urls[root];

  /// What relative links resolve against: `<base href>` (resolved against [url]), else [url].
  Uri? get base => _baseOf(root);

  /// Every element matching CSS [selector], in document order.
  Selection<Element> $(String selector) => Selection._(_Selector.parse(selector).inDocument(root), selector);

  /// The nodes XPath [expression] selects, from the root: see [Element.$x].
  Selection<Node> $x(String expression) => _xpath([root], expression);

  /// The `<head>` element.
  Element get head => root._nodes.whereType<Element>().firstWhere((e) => e.name == 'head');

  /// The `<body>` element.
  Element get body => root._nodes.whereType<Element>().firstWhere((e) => e.name == 'body');

  /// The page's visible text: see [Node.text].
  String get text => root.text;

  /// Every text node's text as it is in the markup, the head's and scripts' included.
  String get rawText => root.rawText;

  /// Every link in the page (`a[href]`, `area[href]`, `link[href]`, `[src]`, a script's
  /// navigation), resolved against [base].
  List<Uri> get links => $('a[href], area[href], link[href], [src], [onclick]').links;

  /// The page's first image link (see [Element.imageLink]); a [MissingException] when it has
  /// none.
  Uri get imageLink {
    if (_images.imageLinks.firstOrNull case final u?) return u;
    throw const MissingException('image link', where: 'the page');
  }

  /// Every image link in the page, resolved against [base]: an `<img>`, a `<picture>` once,
  /// a lazy-loaded `data-src`.
  List<Uri> get imageLinks => _images.imageLinks;

  Selection<Element> get _images {
    final found = $('img, picture, [data-src], [data-original], [data-lazy-src]');
    return found.where((e) => !(e.name == 'img' && e.parent?.name == 'picture'));
  }

  /// The page as HTML text, its doctype first.
  String encode() => '${_doctype ?? ''}${root.markup}';

  /// Writes [encode] to [to] as UTF-8, atomically, into a folder that exists; a file there is replaced
  /// unless [conflict] says otherwise. A page that declares another charset gets a byte-order
  /// mark, which a browser believes over the `<meta>`.
  @override
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite}) => saveBytes(to, conflict, 'Html', () {
    final text = encode();
    final declared = $('meta[charset], meta[http-equiv]').any((m) {
      final charset = m.attributes['charset'] ?? _charsetIn(m.attributes['content']);
      return charset != null && !charset.trim().toLowerCase().startsWith('utf-8');
    });
    final bytes = utf8.encode(text);
    if (!declared) return bytes;
    return Uint8List(bytes.length + 3)
      ..setAll(0, const [0xef, 0xbb, 0xbf])
      ..setAll(3, bytes);
  });

  @override
  String toString() => 'Html(${url ?? 'parsed'})';
}

final _charsetParam = RegExp(r'charset\s*=\s*["\x27]?([^"\x27;\s]+)', caseSensitive: false);

String? _charsetIn(String? content) => content == null ? null : _charsetParam.firstMatch(content)?[1];

bool _isScript(String href) => href.trimLeft().toLowerCase().startsWith('javascript:');

final _onclickUrlRegExp = RegExp(
  r"""(?:(?:window\.|document\.)?location(?:\.href|\.assign|\.replace)?\s*(?:=|\()\s*|window\.open\s*\(\s*)['"]([^'"]+)['"]""",
  caseSensitive: false,
);

String? _extractUrlFromOnclick(String? onclick) =>
    onclick == null ? null : _onclickUrlRegExp.firstMatch(onclick)?.group(1);

bool _isPlaceholder(Uri uri) {
  final s = uri.toString().toLowerCase();
  return s.startsWith('data:image/') && (s.contains('r0lgod') || s.contains('base64,aaaa') || s.length < 120) ||
      s.endsWith('/blank.gif') ||
      s.endsWith('/pixel.gif') ||
      s.endsWith('/spacer.gif');
}

/// The URL of [srcSet]'s densest candidate: `w` widths count as is, `x` densities ×1000, and a
/// bare URL only when nothing else came first.
String? _bestSrcset(String? srcSet) {
  if (srcSet == null) return null;
  var top = -1.0;
  String? best;
  // As the HTML spec splits it: a URL runs to whitespace, so it may hold commas
  // (`w_800,c_scale`); its descriptors run to the next comma.
  final n = srcSet.length;
  var i = 0;
  while (i < n) {
    while (i < n && (_isSpace(srcSet.codeUnitAt(i)) || srcSet.codeUnitAt(i) == 0x2c)) {
      i++;
    }
    if (i >= n) break;
    final from = i;
    while (i < n && !_isSpace(srcSet.codeUnitAt(i))) {
      i++;
    }
    var to = i;
    final bare = srcSet.codeUnitAt(to - 1) == 0x2c; // `a.jpg, b.jpg 2x`: no descriptor
    while (to > from && srcSet.codeUnitAt(to - 1) == 0x2c) {
      to--;
    }
    final url = srcSet.substring(from, to);
    String? desc;
    if (!bare) {
      final d = i;
      while (i < n && srcSet.codeUnitAt(i) != 0x2c) {
        i++;
      }
      desc = srcSet.substring(d, i).trim().split(_ws).first.toLowerCase();
      if (desc.isEmpty) desc = null;
    }
    if (url.isEmpty) continue;
    final size = desc == null ? 1.0 : double.tryParse(desc.substring(0, desc.length - 1)) ?? 1.0;
    final density = switch (desc) {
      null => top < 0 ? 1.0 : -1.0,
      final d when d.endsWith('w') => size,
      final d when d.endsWith('x') => size * 1000.0,
      _ => 1.0,
    };
    if (density > top) (top, best) = (density, url);
  }
  return best;
}

/// [raw] trimmed and parsed, then resolved against [base] when there is one; `null` when not a URI.
Uri? _resolve(String raw, Uri? base) => switch (Uri.tryParse(raw.trim())) {
  final uri? when base != null => base.resolveUri(uri),
  final uri => uri,
};

/// Each document's address by root element, kept outside the tree so no element pays a field.
final _urls = Expando<Uri>('url');

/// Bumped by every edit that can move a `<base href>`: one that adds or takes away a `<base>`,
/// or a write to a `<base>`'s attributes. Other edits leave every cached base good, so reading
/// links while editing stays linear.
var _edits = 0;

/// `<base>` elements ever made: while there are none, no edit can move a base, and moving a
/// subtree need not search it.
var _baseElements = 0;

/// Whether [n] is or holds a `<base>`: only then can moving it change a document's base.
bool _holdsBase(Node n) =>
    _baseElements > 0 && n is Element && (n.name == 'base' || _eachBelow(n, (m) => m is Element && m.name == 'base'));

/// Each root's base and the [_edits] it was read at.
final _bases = Expando<(int, Uri?)>('base');

/// See [Html.base]: the first `<base href>` anywhere, as a browser reads it; found once per
/// root until a `<base>` changes.
Uri? _baseOf(Element root) => switch (_bases[root]) {
  (final at, final base) when at == _edits => base,
  _ => (_bases[root] = (_edits, _findBase(root))).$2,
};

/// A `<base>`'s attributes, which bump [_edits] on every write: its `href` is every link's.
final class _BaseAttributes extends MapBase<String, String> {
  final Map<String, String> _map;
  _BaseAttributes(this._map);

  @override
  String? operator [](Object? key) => _map[key];

  @override
  void operator []=(String key, String value) {
    _edits++;
    _map[key] = value;
  }

  @override
  String? remove(Object? key) {
    _edits++;
    return _map.remove(key);
  }

  @override
  void clear() {
    _edits++;
    _map.clear();
  }

  @override
  Iterable<String> get keys => _map.keys;

  @override
  int get length => _map.length;

  @override
  bool containsKey(Object? key) => _map.containsKey(key);
}

Uri? _findBase(Element root) {
  final url = _urls[root];
  String? href;
  _eachBelow(root, (e) => e is Element && e.name == 'base' && (href = e.attributes['href']) != null);
  final uri = href == null ? null : Uri.tryParse(href!.trim());
  if (uri == null) return url;
  return url == null ? uri : url.resolveUri(uri);
}

int _slotOf(Attribute a) {
  final p = a.parent;
  if (p == null) return -1;
  var i = 0;
  for (final k in p.attributes.keys) {
    if (k == a.name) return i;
    i++;
  }
  return -1;
}

/// [nodes] in document order, sorted only when they are not already.
List<T> _inOrder<T extends Node>(List<T> nodes) {
  if (nodes.length < 2) return nodes;
  final order = <Node, int>{};
  int key(Node n) {
    final e = n is Attribute ? n.parent! : n;
    final k = order[e];
    if (k != null) return k;
    final top = _rootOf(e);
    order[top] = order.length;
    _eachBelow(top, (m) {
      order[m] = order.length;
      return false;
    });
    return order[e] ?? -1;
  }

  var sorted = true;
  for (var i = 1; i < nodes.length && sorted; i++) {
    sorted = key(nodes[i - 1]) <= key(nodes[i]);
  }
  if (sorted) return nodes;
  return nodes..sort((x, y) {
    final c = key(x).compareTo(key(y));
    if (c != 0) return c;
    if (x is! Attribute) return y is Attribute ? -1 : 0;
    return y is! Attribute ? 1 : _slotOf(x).compareTo(_slotOf(y));
  });
}

/// How deep tree walks recurse before switching to an explicit stack: recursion is a third
/// faster, the stack survives documents nested 100 000 deep.
const _deep = 256;

/// The node at the top of [n]'s tree.
Node _rootOf(Node n) {
  for (var p = n.parent; p != null; p = p.parent) {
    n = p;
  }
  return n;
}

/// Visits the nodes below [n] in document order until [visit] returns true, and returns
/// whether it did; [depth] 1 is the children only.
bool _eachBelow(Node n, bool Function(Node) visit, {int depth = 1 << 30}) {
  final lists = <List<Node>>[];
  final at = <int>[];
  var list = n is Element ? n._nodes : const <Node>[];
  var i = 0;
  while (true) {
    if (i < list.length) {
      final m = list[i++];
      if (visit(m)) return true;
      if (m is Element && m._nodes.isNotEmpty && lists.length + 1 < depth) {
        lists.add(list);
        at.add(i);
        list = m._nodes;
        i = 0;
      }
    } else if (lists.isEmpty) {
      return false;
    } else {
      list = lists.removeLast();
      i = at.removeLast();
    }
  }
}

/// [root]'s visible text into [out], on a stack: an HTML element a page never shows is skipped,
/// and a block, a cell or a `<br>` keeps the words either side of it apart.
void _foldText(Element root, _Folded out) {
  final html = root.syntax == Syntax.html;
  final lists = <List<Node>>[];
  final at = <int>[];
  final blocks = <bool>[];
  var list = root._nodes;
  var i = 0;
  while (true) {
    if (i < list.length) {
      final n = list[i++];
      if (n is Text) {
        out.add(n.data);
      } else if (n is Element) {
        if (!html) {
          if (n._nodes.isNotEmpty) {
            lists.add(list);
            at.add(i);
            blocks.add(false);
            list = n._nodes;
            i = 0;
          }
          continue;
        }
        final name = n.name;
        if (_hiddenElements.contains(name)) continue;
        final apart = name == 'br' || name == 'td' || name == 'th' || _blockElements.contains(name);
        if (apart) out.space();
        if (n._nodes.isNotEmpty) {
          lists.add(list);
          at.add(i);
          blocks.add(apart);
          list = n._nodes;
          i = 0;
        }
      }
    } else if (lists.isEmpty) {
      return;
    } else {
      if (blocks.removeLast()) out.space();
      list = lists.removeLast();
      i = at.removeLast();
    }
  }
}

/// Elements [Element.lines] breaks a line around, and [Node.text] keeps apart.
const _blockElements = {
  'address', 'article', 'aside', 'blockquote', 'body', 'caption', 'center', 'dd', 'details', 'dialog', 'dir', //
  'div', 'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'header', 'hgroup', 'hr', 'html', 'legend', 'li', 'main', 'menu', 'nav', 'ol', 'option', 'p', 'pre', 'section',
  'summary', 'table', 'tbody', 'tfoot', 'thead', 'tr', 'ul',
};

/// Elements whose text a page never shows, which [Node.text] and [Element.lines] leave out.
const _hiddenElements = {'head', 'script', 'style', 'title', 'template', 'noscript'};

/// Writes [root] as markup into [sb], with an explicit stack so deep documents don't overflow.
void _serialize(Node root, StringBuffer sb) {
  if (root is! Element) {
    sb.write(root.markup);
    return;
  }
  if (!_writeStartTag(root, sb)) return;
  final open = <Element>[root];
  final at = <int>[0];
  while (open.isNotEmpty) {
    final e = open.last;
    final i = at.last;
    if (i == e._nodes.length) {
      sb
        ..write('</')
        ..write(e.name)
        ..write('>');
      open.removeLast();
      at.removeLast();
      continue;
    }
    at[at.length - 1] = i + 1;
    final n = e._nodes[i];
    if (n is Element) {
      if (_writeStartTag(n, sb)) {
        open.add(n);
        at.add(0);
      }
    } else if (n is Text) {
      _writeEscaped(sb, n.data, attribute: false, xml: e.syntax == Syntax.xml);
    }
  }
}

/// Writes [e]'s start tag, and returns whether its children and end tag are still to come:
/// not for a void element, an empty XML one, or a raw-text one, written whole here.
bool _writeStartTag(Element e, StringBuffer sb) {
  sb
    ..write('<')
    ..write(e.name);
  for (final MapEntry(:key, :value) in e.attributes.entries) {
    sb
      ..write(' ')
      ..write(key)
      ..write('="');
    _writeEscaped(sb, value, attribute: true, xml: e.syntax == Syntax.xml);
    sb.write('"');
  }
  if (e.syntax == Syntax.xml) {
    if (e._nodes.isNotEmpty) {
      sb.write('>');
      return true;
    }
    sb.write('/>');
    return false;
  }
  sb.write('>');
  if (e.name == 'pre' || e.name == 'textarea' || e.name == 'listing') {
    final first = e._nodes.firstOrNull;
    if (first is Text && first.data.startsWith('\n')) sb.write('\n');
  }
  if (_voidElements.contains(e.name)) return false;
  if (!_rawTextElements.contains(e.name)) return true;
  for (final n in e._nodes) {
    n is Text ? sb.write(n.data) : _serialize(n, sb);
  }
  sb
    ..write('</')
    ..write(e.name)
    ..write('>');
  return false;
}

/// Writes [s] with `&`, `<` and `>` escaped for a text node, or `&` and `"` for a
/// double-quoted attribute, copying the runs between them whole. XML also escapes a carriage
/// return, which its parser would read back as a newline.
void _writeEscaped(StringBuffer sb, String s, {required bool attribute, bool xml = false}) {
  var from = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final String? escape = switch (c) {
      0x26 => '&amp;',
      0x3c => '&lt;',
      0x3e when !attribute => '&gt;',
      0x22 when attribute => '&quot;',
      0x0a when attribute && xml => '&#10;',
      0x0d when xml => '&#13;',
      0x09 when attribute && xml => '&#9;',
      _ => null,
    };
    if (escape == null) continue;
    if (i > from) sb.write(s.substring(from, i));
    sb.write(escape);
    from = i + 1;
  }
  if (from == 0) {
    sb.write(s);
  } else if (from < s.length) {
    sb.write(s.substring(from));
  }
}

/// Elements below [root] named in [names], in document order, not entering one named in
/// [stop]: a nested table keeps its own rows, a row its own cells.
List<Element> _within(Element root, Set<String> names, Set<String> stop) {
  final out = <Element>[];
  final lists = <List<Node>>[];
  final at = <int>[];
  var list = root._nodes;
  var i = 0;
  while (true) {
    if (i < list.length) {
      final node = list[i++];
      if (node is! Element || stop.contains(node.name)) continue;
      if (names.contains(node.name)) {
        out.add(node);
      } else if (node._nodes.isNotEmpty) {
        lists.add(list);
        at.add(i);
        list = node._nodes;
        i = 0;
      }
    } else if (lists.isEmpty) {
      return out;
    } else {
      list = lists.removeLast();
      i = at.removeLast();
    }
  }
}

/// A cell's `colspan` or `rowspan`: 1 when absent or unreadable, at most [max].
int _span(Element cell, String name, int max) {
  final n = int.tryParse(cell.attributes[name]?.trim() ?? '') ?? 1;
  return n < 1 ? 1 : (n > max ? max : n);
}

final _responseHtml = Expando<Html>();

/// A response's body read as HTML.
///
/// {@category Formats}
extension HtmlResponse on Response {
  /// The body as HTML, whatever the status, with [url] as its address.
  Html get html => _responseHtml[this] ??= Html.parse(text, url: url);
}

/// A response on its way, read as HTML.
///
/// {@category Formats}
extension HtmlResponseFuture on Future<Response> {
  /// The body as HTML, once the response is a 2xx; any other status is a [StatusException].
  Future<Html> get html => then((res) => res.isOk ? res.html : throw StatusException(res));
}

/// Text read as HTML.
///
/// {@category Formats}
extension HtmlString on String {
  /// This text as HTML, as [Html.parse] reads it; its links stay as written unless it has a
  /// `<base href>`.
  Html get html => Html.parse(this);
}

const _controls = {'button', 'input', 'select', 'textarea', 'fieldset'};

/// Whether [e] is a disabled form control, as a browser decides: its own `disabled`, or a
/// `disabled` `<fieldset>` around it unless [e] sits in that fieldset's first `<legend>`; an
/// `<option>` is also disabled by a `disabled` `<optgroup>` around it. `null`: not a control.
bool? _disabled(Element e) {
  bool off(Element x) => x.attributes.containsKey('disabled');
  switch (e.name.toLowerCase()) {
    case 'option':
      final group = e.parent;
      return off(e) || (group != null && group.name.toLowerCase() == 'optgroup' && off(group));
    case 'optgroup':
      return off(e);
    case final name when !_controls.contains(name):
      return null;
  }
  if (off(e)) return true;
  var below = e;
  for (final a in e.ancestors) {
    if (a.name.toLowerCase() == 'fieldset' && off(a)) {
      final legend = a.children.where((c) => c.name.toLowerCase() == 'legend').firstOrNull;
      if (!identical(below, legend)) return true;
    }
    below = a;
  }
  return false;
}

/// [s] with every run of whitespace one space, trimmed; [s] itself when it has nothing to fold,
/// the common case, so no copy is made.
String _collapsed(String s) {
  final n = s.length;
  // The first place [s] is not already folded: a leading space, a run, a tab or newline.
  var i = 0;
  var space = true;
  for (; i < n; i++) {
    final c = s.codeUnitAt(i);
    if (c > 0x20 && c != 0xa0) {
      space = false;
    } else if (c == 0x20 && !space) {
      space = true;
    } else if (c == 0x20 || (c >= 0x09 && c <= 0x0d) || c == 0xa0) {
      break;
    } else {
      space = false;
    }
  }
  if (i == n) return space && n > 0 ? s.substring(0, n - 1) : s;
  final out = Uint16List(n);
  // What was clean so far, less a single space it ended on (it is the run's start).
  var j = space && i > 0 ? i - 1 : i;
  for (var k = 0; k < j; k++) {
    out[k] = s.codeUnitAt(k);
  }
  var pending = j > 0;
  for (; i < n; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x20 || (c >= 0x09 && c <= 0x0d) || c == 0xa0) {
      pending = j > 0;
    } else {
      if (pending) out[j++] = 0x20;
      pending = false;
      out[j++] = c;
    }
  }
  return String.fromCharCodes(out, 0, j);
}

/// Text with its whitespace folded as it is added: each run one space, none at either end.
final class _Folded {
  Uint16List _units = Uint16List(256);
  int _length = 0;
  bool _space = false;

  void add(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || (c >= 0x09 && c <= 0x0d) || c == 0xa0) {
        _space = _length > 0;
        continue;
      }
      if (_length + 2 > _units.length) {
        _units = Uint16List(_units.length * 2)..setRange(0, _length, _units);
      }
      if (_space) _units[_length++] = 0x20;
      _space = false;
      _units[_length++] = c;
    }
  }

  /// A break between words: a space before the next one, if anything came before.
  void space() => _space = _length > 0;

  @override
  String toString() => String.fromCharCodes(_units, 0, _length);
}
