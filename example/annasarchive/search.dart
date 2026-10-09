import 'package:dart_toolkit/chrome.dart';

const site = 'https://annas-archive.gl';

/// One search result: a value, told apart by its [page].
final class Book {
  final String title;
  final String? author, publisher, description, file;
  final List<String> info;
  final Uri page;

  const Book(this.title, this.page, {this.author, this.publisher, this.info = const [], this.description, this.file});

  @override
  bool operator ==(Object other) => other is Book && other.page == page;

  @override
  int get hashCode => page.hashCode;

  @override
  String toString() => title;

  /// How a download keeps its book in the pool's store.
  static final serializer = Serializer<Book>(
    encode: (b) => [b.title, '${b.page}', b.author, b.publisher, b.info, b.description, b.file],
    decode: (json) {
      final [title, page, author, publisher, info, description, file] = json! as List<Object?>;
      return Book(
        title! as String,
        Uri.parse(page! as String),
        author: author as String?,
        publisher: publisher as String?,
        info: [for (final i in info! as List<Object?>) '$i'],
        description: description as String?,
        file: file as String?,
      );
    },
  );
}

/// A page of results: its books, the site's count (`500+`), and whether a next page exists.
typedef Results = ({List<Book> books, String? total, bool more});

/// Anna's Archive, searched in one Chrome kept for the session: the site sits behind
/// DDoS-Guard's browser check, passed once by [warm] and remembered by its cookie.
final class AnnasArchive {
  Future<Chrome>? _chrome;
  Future<void>? _warm;

  /// The results are in the served HTML: read at `DOMContentLoaded`, not after the ads load.
  Future<Chrome> get _browser => _chrome ??= Chrome.launch(
    block: Resource.heavy,
    render: Render(wait: Wait.dom, challenge: 60.s, timeout: 60.s),
  );

  /// Starts Chrome and passes the site's check, once: what every search waits on.
  /// A failure is not kept: the next search tries again.
  Future<void> warm() => _warm ??= _page('$site/'.url).then<void>(
    (_) {},
    onError: (Object e, StackTrace st) {
      _warm = null;
      Error.throwWithStackTrace(e, st);
    },
  );

  /// Page [page] of the results for [query].
  Future<Results> search(String query, {int page = 1}) async {
    await warm();
    final doc = await _page('$site/search'.url.withQuery({'q': query, 'page': page > 1 ? page : null}));
    return (
      books: _books(doc),
      total: doc.$('div.text-gray-500').texts.map((t) => _total.firstMatch(t)?[1]).nonNulls.firstOrNull,
      more: doc.$('a.js-pagination-next-page').isNotEmpty,
    );
  }

  /// Where [book]'s file can be fetched: the first partner server that names it, those without
  /// a waitlist (#9 to #11) first.
  Future<Uri> fileOf(Book book) async {
    await warm();
    final md5 = book.page.pathSegments.last;
    for (final server in [8, 9, 10, 0, 1, 2, 3, 4, 5, 6, 7]) {
      try {
        final doc = await _page('$site/slow_download/$md5/0/$server'.url);
        final link = doc.$('a[href^="http"]').where((a) => a.text.contains('Download now')).firstOrNull;
        if (link != null) return link.link;
      } catch (_) {} // a server that is down, full or gone: the next one
    }
    throw MissingException('partner server with this file now: try again later, or open its page');
  }

  Future<void> close() async => (await _chrome)?.close();

  /// [url] rendered; 5xx answers and dropped connections retried.
  Future<Html> _page(Uri url) async => Http.scope(client: await _browser, retry: Retry(3), () => url.get().html);
}

/// `Results 1-50 (500+ total)`: the total.
final _total = RegExp(r'\(([^ ]+) total\)');

List<Book> _books(Html doc) => [
  for (final title in doc.$('.js-aarecord-list-outer a.js-vim-focus'))
    if (title.closest('.border-b') case final row?)
      Book(
        _clean(title.text),
        '$site${title.attr('href')}'.url,
        author: _line(row, 'mdi--user-edit'),
        publisher: _line(row, 'mdi--company'),
        // `English [en] · EPUB · 2.2MB · 2022 · 📕 Book (fiction) · 🚀/lgli/lgrs · Save`
        info: [
          for (final part in (row.$('div.font-semibold.text-sm').firstOrNull?.text ?? '').split('·'))
            if (part.replaceAll(RegExp(r'[^\w\s()\[\].,-]'), '').trim() case final p
                when p.isNotEmpty && p != 'Save' && !part.contains('/'))
              p,
        ],
        description: _text(row.$('div.text-gray-600.mt-2').firstOrNull?.text),
        file: _text(row.$('div.font-mono').firstOrNull?.text),
      ),
];

String? _text(String? s) => s == null || s.trim().isEmpty ? null : _clean(s);

/// [s] trimmed, and decoded once more: the site escapes some titles twice (`&amp;quot;`).
String _clean(String s) => Html.decodeEntities(s).trim();

/// The text of [row]'s link marked with the [icon] class, or `null`.
String? _line(Element row, String icon) => row
    .$('a[href^="/search"]')
    .where((a) => a.$('span[class*="$icon"]').isNotEmpty)
    .map((a) => _clean(a.text))
    .firstOrNull;
