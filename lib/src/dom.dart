/// The tree `html` parses into: elements and text, nothing else (comments
/// and doctypes are dropped while parsing). Private to the toolkit.
library;

/// A node in the tree.
sealed class Node {
  /// The element holding this node; null at the top.
  Element? parent;

  /// Detach from the parent. A no-op at the top.
  void remove() {
    parent?.nodes.remove(this);
    parent = null;
  }

  /// A copy; [deep] copies the subtree too.
  Node clone(bool deep);
}

/// A run of text.
final class Text extends Node {
  Text(this.data);

  String data;

  @override
  Text clone(bool deep) => Text(data);
}

/// Where an element lives: the HTML vocabulary, or embedded SVG/MathML.
enum Space { html, svg, math }

/// An element: a name, attributes in source order, child nodes.
final class Element extends Node {
  Element(this.localName, [Map<String, String>? attributes, this.space = Space.html])
    : attributes = attributes ?? <String, String>{};

  /// The tag name: lower case for HTML, as the spec writes it for SVG
  /// (`foreignObject`).
  final String localName;

  final Space space;

  final Map<String, String> attributes;

  final nodes = <Node>[];

  /// The child elements.
  Iterable<Element> get children => nodes.whereType<Element>();

  /// Every descendant text joined (`textContent`).
  String get text {
    final out = StringBuffer();
    final stack = <Node>[this];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      switch (n) {
        case Text(:final data):
          out.write(data);
        case Element(:final nodes):
          for (var i = nodes.length - 1; i >= 0; i--) {
            stack.add(nodes[i]);
          }
      }
    }
    return out.toString();
  }

  void append(Node child) {
    child.parent = this;
    nodes.add(child);
  }

  void insertBefore(Node child, Node ref) {
    child.parent = this;
    nodes.insert(nodes.indexOf(ref), child);
  }

  @override
  Element clone(bool deep) {
    final copy = Element(localName, Map.of(attributes), space);
    if (!deep) return copy;
    // An explicit stack: a page nested 10,000 deep must not overflow.
    final stack = <(Element, Element)>[(this, copy)];
    while (stack.isNotEmpty) {
      final (from, to) = stack.removeLast();
      for (final n in from.nodes) {
        switch (n) {
          case Text():
            to.append(n.clone(false));
          case Element():
            final e = n.clone(false);
            to.append(e);
            stack.add((n, e));
        }
      }
    }
    return copy;
  }

  @override
  String toString() => '<$localName>';
}
