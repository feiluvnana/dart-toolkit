import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';

import 'search.dart';

/// Where downloads land: `$BOOKS_DIR`, else `~/Downloads`.
final Path downloadsDir = Env.get<Path>('BOOKS_DIR', or: Path.home / 'Downloads');

/// The downloads: detached jobs, so they carry on after the app ends, and the next start shows
/// them.
final downloads = Pool(FetchBook.new, concurrency: 2, store: Store.app('books') / 'downloads');

/// The formats a book's file can be in, as its details name them.
final _formats = 'epub pdf mobi azw3 fb2 djvu cbz cbr txt doc docx rtf zip rar'.split(' ').toSet();

/// Where [book] is saved: `~/Downloads/<title> - <author>.<format>`.
Path target(Book book) {
  final ext = book.info.map((i) => i.toLowerCase()).where(_formats.contains).firstOrNull ?? 'bin';
  return downloadsDir / '${[book.title, ?book.author].join(' - ').filename}.$ext';
}

/// Downloads a book: a partner server that has it, then its file into [downloadsDir].
final class FetchBook extends Worker<Book, Path> {
  late final AnnasArchive site;

  @override
  Future<void> init(Work setup) async {
    site = AnnasArchive();
    setup.defer(site.close);
  }

  @override
  Future<Path> run(Book book, Work work) async {
    work.step('finding a server');
    final link = await site.fileOf(book);
    return link.download(to: target(book));
  }

  @override
  Serializer<Book> get item => Book.serializer;
}
