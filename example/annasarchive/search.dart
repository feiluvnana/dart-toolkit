import 'package:dart_toolkit/chrome.dart';

const site = 'https://annas-archive.gl';

final totalCount = RegExp(r'\(([^ ]+) total\)');
final symbols = RegExp(r'[^\w\s()\[\].,-]');

final class Book {
  final String title;
  final Uri page;
  final String? author;
  final String? publisher;
  final String? description;
  final List<String> details;

  const Book(this.title, this.page, {this.author, this.publisher, this.description, this.details = const []});

  String get id => page.pathSegments.last;

  @override
  bool operator ==(Object other) => other is Book && other.page == page;

  @override
  int get hashCode => page.hashCode;

  @override
  String toString() => title;

  static final serializer = Serializer<Book>(
    encode: (book) => {
      'title': book.title,
      'page': '${book.page}',
      'author': book.author,
      'publisher': book.publisher,
      'description': book.description,
      'details': book.details,
    },
    decode: (json) {
      final book = json! as Map<String, Object?>;
      return Book(
        book['title']! as String,
        Uri.parse(book['page']! as String),
        author: book['author'] as String?,
        publisher: book['publisher'] as String?,
        description: book['description'] as String?,
        details: [for (final detail in book['details']! as List<Object?>) '$detail'],
      );
    },
  );
}

typedef SearchPage = ({List<Book> books, String? total, bool more});

final class AnnasArchive {
  Future<Chrome>? _chrome;
  Future<Html>? _homePage;

  Future<Chrome> get _browser => _chrome ??= Chrome.launch(
    block: Resource.heavy,
    render: Render(wait: Wait.dom, challenge: 60.s, timeout: 60.s),
  );

  Future<void> connect() async {
    try {
      await (_homePage ??= _open('$site/'.url));
    } catch (_) {
      _homePage = null;
      rethrow;
    }
  }

  Future<SearchPage> search(String query, {int page = 1}) async {
    await connect();
    final results = await _open('$site/search'.url.withQuery({'q': query, 'page': page > 1 ? page : null}));
    return (
      books: [
        for (final link in results.$('.js-aarecord-list-outer a.js-vim-focus'))
          if (link.closest('.border-b') case final row?) _book(link, row),
      ],
      total: results.$('div.text-gray-500').texts.map((text) => totalCount.firstMatch(text)?[1]).nonNulls.firstOrNull,
      more: results.$('a.js-pagination-next-page').isNotEmpty,
    );
  }

  Future<Uri> fileOf(Book book) async {
    await connect();
    for (final server in [8, 9, 10, 0, 1, 2, 3, 4, 5, 6, 7]) {
      try {
        final page = await _open('$site/slow_download/${book.id}/0/$server'.url);
        final links = page.$('a[href^="http"]').where((link) => link.text.contains('Download now'));
        if (links.isNotEmpty) return links.first.link;
      } on Exception {
        continue;
      }
    }
    throw MissingException('partner server with this file now: try again later, or open its page');
  }

  Future<void> close() async => (await _chrome)?.close();

  Future<Html> _open(Uri url) async => Http.scope(client: await _browser, retry: Retry(3), () => url.get().html);
}

Book _book(Element link, Element row) => Book(
  _decoded(link.text),
  '$site${link.attr('href')}'.url,
  author: _labelled(row, 'mdi--user-edit'),
  publisher: _labelled(row, 'mdi--company'),
  description: _optional(row.$('div.text-gray-600.mt-2')),
  details: _details(row.$('div.font-semibold.text-sm')),
);

String? _labelled(Element row, String icon) => row
    .$('a[href^="/search"]')
    .where((link) => link.$('span[class*="$icon"]').isNotEmpty)
    .map((link) => _decoded(link.text))
    .firstOrNull;

String? _optional(Selection found) {
  if (found.isEmpty || found.text.trim().isEmpty) return null;
  return _decoded(found.text);
}

List<String> _details(Selection line) => [
  if (line.isNotEmpty)
    for (final part in line.text.split('·'))
      if (!part.contains('/'))
        if (part.replaceAll(symbols, '').trim() case final detail when detail.isNotEmpty && detail != 'Save') detail,
];

String _decoded(String text) => text.html.text;
