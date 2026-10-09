import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';

import 'search.dart';

final downloadsFolder = Env.get<Path>('BOOKS_DIR', or: Path.home / 'Downloads');

final downloads = Pool(FetchBook.new, concurrency: 2, store: Store.app('books') / 'downloads');

final bookFormats = 'epub pdf mobi azw3 fb2 djvu cbz cbr txt doc docx rtf zip rar'.split(' ').toSet();

Path savePath(Book book) {
  final format = book.details.map((detail) => detail.toLowerCase()).where(bookFormats.contains).firstOrNull ?? 'bin';
  final name = [book.title, ?book.author].join(' - ');
  return downloadsFolder / '${name.filename}.$format';
}

final class FetchBook extends Worker<Book, Path> {
  late final AnnasArchive archive;

  @override
  Future<void> init(Work setup) async {
    archive = AnnasArchive();
    setup.defer(archive.close);
  }

  @override
  Future<Path> run(Book book, Work work) async {
    work.step('finding a server');
    final file = await archive.fileOf(book);
    return file.download(to: savePath(book));
  }

  @override
  Serializer<Book> get item => Book.serializer;
}
