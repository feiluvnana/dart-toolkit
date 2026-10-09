part of '../../markup.dart';

/// A parsed XML document: the same tree and queries as [Html], with [Element.syntax]
/// [Syntax.xml], so names keep case and prefix and an empty element serialises as `<tag/>`.
///
/// ```dart
/// final feed = await Xml.read('feed.xml');
/// feed.$x('//item/title').texts;
/// ```
///
/// {@category Formats}
final class Xml implements Markup, Saveable {
  /// The document element.
  @override
  final Element root;

  Xml._(this.root, {Uri? url}) {
    if (url != null) _urls[root] = url;
  }

  /// [text] parsed as XML; [url] is the document's address, which links resolve against (a
  /// feed's relative `<link>`). No document element is a [FormatException].
  static Xml parse(String text, {Uri? url}) => _parse(text, url, null);

  static Xml _parse(String text, Uri? url, String? where) => Xml._(parsedText('XML', where, text, _parseXml), url: url);

  /// The document saved at [path], its encoding sniffed: a byte-order mark, else the XML
  /// declaration's `encoding`, else UTF-8.
  static Future<Xml> read(String path) async {
    final bytes = await File(path).readAsBytes();
    return _parse(Response.bytes(bytes, 200, headers: const {'content-type': 'application/xml'}).text, null, path);
  }

  /// The address the document was parsed with, if any.
  @override
  Uri? get url => _urls[root];

  /// Every element matching CSS [selector], in document order. Names match case-sensitively;
  /// escape a prefix's colon, `$(r'media\:content')`, or use [$x].
  @override
  Selection<Element> $(String selector) =>
      Selection._(_Selector.parse(selector, fold: false).inDocument(root), selector);

  /// The document's text: see [Node.text].
  @override
  String get text => root.text;

  /// Every text node's text as it is in the markup.
  String get rawText => root.rawText;

  /// The document as XML text, with an XML declaration.
  String encode() => '<?xml version="1.0" encoding="UTF-8"?>\n${root.markup}\n';

  /// Writes [encode] to [to] as UTF-8, atomically, into a folder that exists; a file there is replaced
  /// unless [conflict] says otherwise.
  @override
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite}) =>
      FileBridge.save(to, conflict, 'Xml', () => [utf8.encode(encode())]);

  @override
  String toString() => 'Xml(${url ?? root.name})';
}

final _responseXml = Expando<Xml>();

/// A response's body read as XML.
///
/// {@category Formats}
extension XmlResponse on Response {
  /// The body as XML, whatever the status, with [url] as its address; a body that is not XML is
  /// a [FormatException] naming the URL.
  Xml get xml => _responseXml[this] ??= Xml._parse(text, url, '${url ?? 'the response'}');
}

/// A response on its way, read as XML.
///
/// {@category Formats}
extension XmlResponseFuture on Future<Response> {
  /// The body as XML, once the response is a 2xx; any other status is a [StatusException].
  Future<Xml> get xml => then((res) => res.isOk ? res.xml : throw StatusException(res));
}

/// Text read as XML.
///
/// {@category Formats}
extension XmlString on String {
  /// This text as XML, as [Xml.parse] reads it.
  Xml get xml => Xml.parse(this);
}
