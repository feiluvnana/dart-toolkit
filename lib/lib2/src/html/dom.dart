import 'selector.dart';

/// A node in the document tree.
sealed class Node {
  /// The parent element, if any.
  Element? parent;

  /// All text below this node, concatenated.
  String get text;
}

/// A run of text.
final class TextNode extends Node {
  String data;

  TextNode(this.data);

  @override
  String get text => data;

  @override
  String toString() => data;
}

/// An element with a [tag], [attrs] and [children].
final class Element extends Node {
  final String tag;
  final Map<String, String> attrs;
  final List<Node> children = [];

  Element(this.tag, [Map<String, String>? attrs]) : attrs = attrs ?? <String, String>{};

  /// The concatenated text of every descendant.
  @override
  String get text => children.map((c) => c.text).join();

  /// The inner HTML-like serialisation of the children.
  String get html => children.map((c) => c.toString()).join();

  /// One attribute, or [or] (default `null`).
  String? attr(String name, {String? or}) => attrs[name] ?? or;

  /// The `id` attribute.
  String? get id => attrs['id'];

  /// The `class` attribute.
  String? get className => attrs['class'];

  /// The class list.
  List<String> get classes => (attrs['class'] ?? '').split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toList();

  /// Appends [node] as the last child.
  void append(Node node) {
    node.parent = this;
    children.add(node);
  }

  /// Inserts [node] at [index].
  void insert(int index, Node node) {
    node.parent = this;
    children.insert(index, node);
  }

  /// Removes this element from its parent.
  void drop() {
    parent?.children.remove(this);
    parent = null;
  }

  /// The previous sibling element, if any.
  Element? get previousElement {
    final siblings = parent?.children;
    if (siblings == null) return null;
    for (var i = siblings.indexOf(this) - 1; i >= 0; i--) {
      if (siblings[i] is Element) return siblings[i] as Element;
    }
    return null;
  }

  /// The next sibling element, if any.
  Element? get nextElement {
    final siblings = parent?.children;
    if (siblings == null) return null;
    for (var i = siblings.indexOf(this) + 1; i < siblings.length; i++) {
      if (siblings[i] is Element) return siblings[i] as Element;
    }
    return null;
  }

  /// The element children.
  Iterable<Element> get elements => children.whereType<Element>();

  /// Every descendant element in document order.
  Iterable<Element> get descendants sync* {
    for (final child in children) {
      if (child is Element) {
        yield child;
        yield* child.descendants;
      }
    }
  }

  /// The first element matching [selector], searching this element then descendants.
  Element? find(String selector) {
    if (selectorMatches(this, selector)) return this;
    for (final el in descendants) {
      if (selectorMatches(el, selector)) return el;
    }
    return null;
  }

  /// Every element matching [selector], in document order.
  List<Element> all(String selector) => [
    if (selectorMatches(this, selector)) this,
    for (final el in descendants)
      if (selectorMatches(el, selector)) el,
  ];

  /// Whether this element matches [selector].
  bool matches(String selector) => selectorMatches(this, selector);

  @override
  String toString() {
    final sb = StringBuffer('<$tag');
    attrs.forEach((name, value) => sb.write(' $name="${_escapeAttr(value)}"'));
    sb.write('>');
    for (final child in children) {
      sb.write(child.toString());
    }
    sb.write('</$tag>');
    return sb.toString();
  }
}

String _escapeAttr(String v) => v.replaceAll('"', '&quot;');

/// A parsed document with a synthetic `#document` root.
final class Doc {
  final Element root;

  Doc(this.root);

  /// The first element in the document matching [selector].
  Element? find(String selector) => root.find(selector);

  /// Every element in the document matching [selector].
  List<Element> all(String selector) => root.all(selector);

  /// The document's whole text.
  String get text => root.text;

  /// The `html` element, if present.
  Element? get html => all('html').firstOrNull;

  /// The `head` element, if present.
  Element? get head => all('head').firstOrNull;

  /// The `body` element, if present.
  Element? get body => all('body').firstOrNull;

  @override
  String toString() => root.html;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
