part of '../../html.dart';

/// A parsed HTML document.
///
/// ```dart
/// final page = await url.get().html;
/// page.$('h2 a').texts;
/// await page.save('copy.html');
/// ```
///
/// {@category Formats}
final class Html implements Markup, Saveable {
  /// The `<html>` element. Parsing always makes one, with `<head>` and `<body>` inside.
  @override
  final Element root;

  /// The `<!DOCTYPE …>` as written, kept for [encode].
  final String? _doctype;

  Html._(this.root, this._doctype, {Uri? url}) {
    if (url != null) MarkupInternals.setUrl(root, url);
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
  @override
  Uri? get url => MarkupInternals.url(root);

  /// What relative links resolve against: `<base href>` (resolved against [url]), else [url].
  Uri? get base => MarkupInternals.base(root);

  /// Every element matching CSS [selector], in document order.
  @override
  Selection<Element> $(String selector) => MarkupInternals.inDocument(root, selector, fold: true);

  /// The `<head>` element.
  Element get head => root.nodes.whereType<Element>().firstWhere((e) => e.name == 'head');

  /// The `<body>` element.
  Element get body => root.nodes.whereType<Element>().firstWhere((e) => e.name == 'body');

  /// The page's visible text: see [Node.text].
  @override
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
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite}) => FileBridge.save(to, conflict, 'Html', () {
    final declared = $('meta[charset], meta[http-equiv]').any((m) {
      final charset = m.attributes['charset'] ?? _charsetIn(m.attributes['content']);
      return charset != null && !charset.trim().toLowerCase().startsWith('utf-8');
    });
    return [
      if (declared) const [0xef, 0xbb, 0xbf],
      utf8.encode(encode()),
    ];
  });

  @override
  String toString() => 'Html(${url ?? 'parsed'})';
}

final _charsetParam = RegExp(r'charset\s*=\s*["\x27]?([^"\x27;\s]+)', caseSensitive: false);

String? _charsetIn(String? content) => content == null ? null : _charsetParam.firstMatch(content)?[1];

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

/// What `scrape.dart` needs from `html.dart`. Not API.
abstract final class HtmlInternals {
  /// [res]'s HTML if something has parsed it already, else `null`.
  static Html? parsed(Response res) => _responseHtml[res];
}
