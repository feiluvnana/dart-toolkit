part of '../../markup.dart';

/// What `html.dart`'s parser and `xpath.dart` need from the tree, which they build and walk from
/// libraries of their own. Hidden from every topic import; not API.
abstract final class MarkupInternals {
  // ---- building, for the HTML parser

  /// An HTML element as the parser makes it: [attrs] already flat, names already interned.
  static Element element(String name, List<String> attrs) =>
      Element._parsed(name, attrs, name == 'base' ? Element._base : 0);

  /// [child] appended to [parent], which is the parser's own: nothing to detach, no edit to count.
  static void add(Element parent, Node child) {
    child
      .._parent = parent
      .._slot = parent._nodes.length;
    parent._nodes.add(child);
    if (_holdsBase(child)) _markBase(parent);
  }

  static int nameEnd(String src, int i) => _nameEnd(src, i);

  static int scanAttributes(
    String src,
    int i,
    List<String> into,
    Names names, {
    required bool html,
    required String Function(String value) decode,
  }) => _scanAttributes(src, i, into, names, html: html, decode: decode);

  static String decode(String text, (String?, int) Function(String text, int start) reference) =>
      _decodeReferences(text, reference);

  static (String?, int) numericReference(String text, int start, Map<int, int> windows1252) =>
      _numericReference(text, start, windows1252);

  static Map<String, String> get svgTags => _svgTags;
  static Map<String, String> get svgAttributes => _svgAttributes;
  static Set<String> get voidElements => _voidElements;
  static Set<String> get rawTextElements => _rawTextElements;

  static bool isSpace(int c) => _isSpace(c);
  static bool isAlpha(int c) => _isAlpha(c);
  static bool isAlnum(int c) => _isAlnum(c);
  static int toLower(int c) => _toLower(c);

  // ---- documents, for `Html`

  static Uri? url(Element root) => _urls[root];
  static void setUrl(Element root, Uri url) => _urls[root] = url;
  static Uri? base(Element root) => _baseOf(root);

  /// What a document's `$` finds: the root itself included.
  static Selection<Element> inDocument(Element root, String selector, {required bool fold}) =>
      Selection._(_Selector.parse(selector, fold: fold).inDocument(root), selector);

  // ---- walking, for XPath

  static List<Node> nodes(Element e) => e._nodes;
  static List<String> attrs(Element e) => e._attrs;
  static String? attr(Element e, String name) => e._attr(name);
  static Selection<N> selection<N extends Node>(List<N> nodes, String query) => Selection._(nodes, query);
  static bool eachBelow(Node n, bool Function(Node) visit) => _eachBelow(n, visit);
  static int indexIn(List<Node> siblings, Node n) => _indexIn(siblings, n);
  static Node rootOf(Node n) => _rootOf(n);
  static List<T> inOrder<T extends Node>(List<T> nodes) => _inOrder(nodes);
  static int documentOrder(Node x, Node y, Map<Node, int> roots) => _documentOrder(x, y, roots);

  /// The attribute [name] of [owner], as an XPath `@` step selects it.
  static Attribute attribute(String name, String value, Element owner) => Attribute._(name, value, owner);

  /// The document node above [root], where an absolute XPath starts.
  static Element document(Element root) => _Document(root);

  /// The root a document node holds, or `null` when [n] is not one.
  static Element? documentRoot(Node n) => n is _Document ? n.root : null;
}
