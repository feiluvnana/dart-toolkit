// The HTML bridges on `Response`, `Uri` and `String`; the tree itself is in `dom.dart`.

part of '../../html.dart';

final Expando<HtmlDocument> _htmlMemo = Expando<HtmlDocument>('htmlMemo');

/// HTML parsing on [Response].
///
/// {@category Formats}
extension ResponseHtmlExtensions on Response {
  /// The body parsed as HTML, once per response instance.
  HtmlDocument get html => _htmlMemo[this] ??= HtmlDocument.parse(text);
}

/// HTML fetching on [Uri].
///
/// {@category Formats}
extension UriHtmlExtensions on Uri {
  /// Fetches this URI and parses the response body as HTML.
  ///
  /// Throws [HttpException] unless the status is 2xx — an error page parses fine and
  /// then matches nothing. Use `get` with `isOk` to handle it yourself.
  Future<HtmlDocument> html({Map<String, String>? headers, Client? client}) async =>
      (await fetch(headers: headers, client: client)).html;
}

/// Parsing on [String].
///
/// {@category Formats}
extension StringHtmlExtensions on String {
  /// This string parsed as HTML.
  HtmlDocument get html => HtmlDocument.parse(this);
}

/// An HTML `<table>` as a [Table].
///
/// {@category Formats}
extension ElementTableExtensions on Element {
  /// This `<table>` (or the first one below this element) as rows of named columns: `<th>`
  /// texts name the columns, or `c1, c2, …` when there are none; each `<tr>` with `<td>` is a row.
  Table get table {
    final t = name == 'table' ? this : $('table').firstOrNull;
    if (t == null) return Table(const [], const []);
    final trs = t.$('tr').where((tr) => tr.parent?.name != 'table' || true).toList();
    var header = <String>[];
    final body = <List<String>>[];
    for (final tr in trs) {
      final ths = tr.$('th');
      final tds = tr.$('td');
      if (header.isEmpty && ths.isNotEmpty && tds.isEmpty) {
        header = [for (final th in ths) th.text.trim()];
      } else if (tds.isNotEmpty) {
        body.add([for (final td in tds) td.text.trim()]);
      }
    }
    final width = body.fold(header.length, (w, r) => r.length > w ? r.length : w);
    final columns = [
      for (var i = 0; i < width; i++) i < header.length && header[i].isNotEmpty ? header[i] : 'c${i + 1}',
    ];
    return Table(columns, [
      for (final r in body) {for (var i = 0; i < columns.length; i++) columns[i]: i < r.length ? r[i] : null},
    ]);
  }
}

/// {@category Formats}
extension ElementsTableExtensions on Elements {
  /// The first matched element's [ElementTableExtensions.table].
  Table get table => isEmpty ? Table(const [], const []) : first.table;
}
