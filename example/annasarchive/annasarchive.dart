// Books: find a book on Anna's Archive and download it, in a terminal app.
//
//   dart run example/annasarchive/annasarchive.dart
//
// The site checks for a real browser, so searches run through Chrome. Its domains move:
// ANNAS_ARCHIVE=https://… points at a working mirror; BOOKS_DIR changes where books land.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/process.dart';
import 'package:dart_toolkit/tui.dart';

// ---- The app ------------------------------------------------------------------------------

const orange = TuiColor.rgb(217, 119, 87);
const bold = CellStyle(bold: true);
const muted = CellStyle(dim: true);
String sizeText(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String about(Book book) => [?book.author, ...book.details].join(' · ');

enum Action {
  download('Download', 'into ~/Downloads; downloading it again resumes'),
  open('Open its page', 'in your browser'),
  copy('Copy its link', '');

  const Action(this.label, this.help);
  final String label;
  final String help;
}

sealed class Screen {
  const Screen();
}

final class Welcome extends Screen {
  const Welcome();
}

final class Searching extends Screen {
  final String query;
  final Screen back;

  const Searching(this.query, this.back);
}

final class Found extends Screen {
  final String query;
  final String? total;
  final int page;
  final bool more;
  final bool loading;

  const Found(this.query, {this.total, this.page = 1, this.more = false, this.loading = false});

  Found withLoading(bool loading) => Found(query, total: total, page: page, more: more, loading: loading);
}

final class Detail extends Screen {
  final Found back;
  final Book book;

  const Detail(this.back, this.book);
}

sealed class Message {
  const Message();
}

final class Connected extends Message {
  const Connected();
}

final class Unreachable extends Message {
  final Object error;

  const Unreachable(this.error);
}

final class Arrived extends Message {
  final int search;
  final String query;
  final int page;
  final SearchPage result;

  const Arrived(this.search, this.query, this.page, this.result);
}

final class SearchFailed extends Message {
  final int search;
  final Object error;

  const SearchFailed(this.search, this.error);
}

final class Notice extends Message {
  final String text;
  final bool ok;

  const Notice(this.text, {this.ok = true});
}

Future<void> main() => Tui.run(BooksApp().run);

final class BooksApp {
  final archive = AnnasArchive();
  late final downloads = Downloads(archive);
  var input = FieldState();
  var results = <Book>[];
  var selected = 0;
  var action = 0;
  var latestSearch = 0;
  var connected = false;
  Notice? notice;
  Screen screen = const Welcome();

  Future<void> run(Term term) async {
    term.defer(archive.close);
    term.defer(downloads.close);
    term.listen(downloads.changes);
    archive.connect().then((_) => term.post(const Connected()), onError: (Object e) => term.post(Unreachable(e)));
    while (true) {
      term.draw(draw);
      final event = await term.poll(timeout: const Duration(milliseconds: 100)); // the spinner ticks
      if (event != null && !update(term, event)) return;
    }
  }

  /// One event; false ends the app.
  bool update(Term term, TuiEvent event) {
    switch (event) {
      case Post(:final message):
        _receive(message);
      case KeyPress(name: 'd', ctrl: true) || Interrupt():
        return false;
      case KeyPress(name: 'enter'):
        _enter(term);
      case KeyPress(name: 'esc'):
        _back();
      case KeyPress(name: 'up'):
        _move(term, -1);
      case KeyPress(name: 'down'):
        _move(term, 1);
      default:
        if (input.handle(event)) notice = null;
    }
    return true;
  }

  void draw(Canvas ui) {
    final shown = downloads.latest.values.toList();
    final rows = shown.skip(max(0, shown.length - 3)).toList();
    final fixed = 2 + rows.length + (notice == null ? 0 : 1) + 3 + 1;
    ui.split(
      [
        (c) => c.text(" ✻ Books · Anna's Archive", fg: orange, style: bold),
        _body,
        (c) {
          for (final p in rows) {
            _downloadRow(c, p);
          }
        },
        _notice,
        (c) => c.box(build: (b) => b.field(input, focused: true)),
        _footer,
      ],
      vert: true,
      flex: [2, max(1, ui.bounds.h - fixed), rows.length, notice == null ? 0 : 1, 3, 1],
    );
  }

  void _body(Canvas c) {
    switch (screen) {
      case Welcome():
        _welcome(c);
      case Searching(:final query):
        c.spinner(
          connected ? 'Searching for "$query"…  esc to cancel' : "Passing the site's browser check…  esc to cancel",
          fg: orange,
        );
      case final Found found:
        _found(c, found);
      case Detail(:final book):
        _detail(c, book);
    }
  }

  void _welcome(Canvas c) {
    c.text(" ✻ Welcome to Books!", fg: orange, style: bold);
    c.text("Find a book on Anna's Archive by its name, then download it.", style: muted);
    c.text(connected ? "● connected to $site" : "○ connecting to $site…", style: muted);
    c.text('How it works:', style: muted);
    c.text('  1. Type a title, author or ISBN and press Enter');
    c.text('  2. ↑↓ walk the results, Enter opens a book');
    c.text('  3. Its menu downloads it into ~/Downloads, opens its page or copies its link');
    c.text('  4. A download you quit resumes when you download it again');
  }

  void _found(Canvas c, Found found) {
    if (results.isEmpty) {
      c.text(' No books for "${found.query}". Try fewer words.', style: muted);
      return;
    }
    final shown = '${results.length} shown${found.total == null ? '' : ' of ${found.total}'}';
    c.text(' Results for "${found.query}" · $shown', style: bold);
    if (found.loading) c.spinner('Loading more…', fg: orange);
    c.list([for (final (i, b) in results.indexed) '${i + 1}. ${b.title}  ${about(b)}'], selected: selected);
  }

  void _detail(Canvas c, Book book) {
    c.box(
      title: ' ${selected + 1} of ${results.length} ',
      build: (b) {
        b.text(book.title, fg: orange, style: bold);
        if (book.author case final author?) b.text('by $author');
        if (book.publisher case final publisher?) b.text(publisher, style: muted);
        b.text('');
        b.list([for (final a in Action.values) '${a.label.padRight(16)}${a.help}'], selected: action);
        if (downloads.latest[book] case final p?) _downloadRow(b, p);
        if (book.description case final description?) b.text(description, style: muted);
      },
    );
  }

  void _downloadRow(Canvas c, Progress p) {
    final title = p.book.title;
    switch (p) {
      case Queued():
        c.text('… waiting: $title');
      case Finding():
        c.spinner('Finding a server for $title', fg: orange);
      case Receiving(:final bytes):
        c.text('⬇ $title  ${sizeText(bytes)}', fg: orange);
      case Saved(:final file):
        final home = io.Platform.environment['HOME'] ?? io.Platform.environment['USERPROFILE'] ?? '';
        final path = home.isEmpty ? file.path : file.path.replaceFirst(home, '~');
        c.text('✓ $title → $path', fg: TuiColor.green);
      case Failed(:final error):
        c.text('✗ $title: $error', fg: TuiColor.red);
    }
  }

  void _notice(Canvas c) {
    if (notice case final n?) {
      c.text(' ${n.ok ? '✓' : '✗'} ${n.text}', fg: n.ok ? TuiColor.green : TuiColor.red);
    }
  }

  void _footer(Canvas c) {
    final hints = switch (screen) {
      Welcome() => 'type a name · enter search · ctrl+c quit',
      Searching() => 'esc cancel',
      Found() when results.isNotEmpty => '↑↓ move · enter open · type to search again',
      Found() => 'type a new search',
      Detail() => '↑↓ choose · enter run · esc back',
    };
    final status = switch (screen) {
      Found(:final page) when results.isNotEmpty => 'page $page · ${selected + 1}/${results.length}',
      _ when connected => '● connected',
      _ => '○ connecting',
    };
    c.text('  $hints  $status', style: muted);
  }

  void _receive(Object? message) {
    switch (message) {
      case Connected():
        connected = true;
      case Unreachable(:final error):
        notice = Notice("Could not reach Anna's Archive: $error", ok: false);
      case final Notice n:
        notice = n;
      case final SearchFailed failed when failed.search == latestSearch:
        notice = Notice('${failed.error}', ok: false);
        switch (screen) {
          case Searching(:final back):
            screen = back;
          case Found(:final query, :final total, :final page, :final more):
            screen = Found(query, total: total, page: page, more: more);
          default:
            break;
        }
      case final Arrived arrived when arrived.search == latestSearch:
        _showResults(arrived);
      default:
        break;
    }
  }

  void _showResults(Arrived arrived) {
    connected = true;
    if (arrived.page == 1) {
      results = arrived.result.books;
      selected = 0;
    } else {
      results = [...results, ...arrived.result.books];
    }
    final found = Found(arrived.query, total: arrived.result.total, page: arrived.page, more: arrived.result.more);
    switch (screen) {
      case Detail(:final book):
        screen = Detail(found, book);
      default:
        screen = found;
    }
  }

  void _newSearch(Term term, String query) {
    input = FieldState();
    _search(term, query, 1);
    screen = Searching(query, screen is Searching ? (screen as Searching).back : screen);
  }

  void _loadMoreNearTheEnd(Term term, Found found) {
    final nearTheEnd = selected >= results.length - 3;
    if (!found.more || found.loading || !nearTheEnd) return;
    _search(term, found.query, found.page + 1);
    screen = found.withLoading(true);
  }

  void _search(Term term, String query, int page) {
    final search = ++latestSearch;
    archive
        .search(query, page: page)
        .then(
          (result) => term.post(Arrived(search, query, page, result)),
          onError: (Object e) => term.post(SearchFailed(search, e)),
        );
  }

  void _openBook(Found found, Book book) {
    action = 0;
    screen = Detail(found, book);
  }

  void _back() {
    if (input.text.isNotEmpty) {
      input = FieldState();
      return;
    }
    switch (screen) {
      case Searching(:final back):
        latestSearch++;
        screen = back;
      case Detail(:final back):
        screen = back;
      default:
        break;
    }
  }

  void _enter(Term term) {
    final query = input.text.trim();
    if (query.isNotEmpty) {
      _newSearch(term, query);
      return;
    }
    switch (screen) {
      case final Found found when results.isNotEmpty:
        var at = selected;
        if (at < 0) at = 0;
        if (at >= results.length) at = results.length - 1;
        _openBook(found, results[at]);
      case Detail(:final book):
        _act(term, book);
      default:
        break;
    }
  }

  void _move(Term term, int dir) {
    switch (screen) {
      case final Found found:
        if (results.isEmpty) return;
        selected += dir;
        if (selected < 0) selected = 0;
        if (selected >= results.length) selected = results.length - 1;
        _loadMoreNearTheEnd(term, found);
      case Detail():
        action += dir;
        if (action < 0) action = 0;
        if (action >= Action.values.length) action = Action.values.length - 1;
      default:
        break;
    }
  }

  void _act(Term term, Book book) {
    switch (Action.values[action]) {
      case Action.download:
        downloads.add(book);
        notice = const Notice('Downloading into ~/Downloads; downloading it again resumes');
      case Action.open:
        _tell(term, openUrl(book.page), 'Opened in your browser', 'Could not open ${book.page}');
      case Action.copy:
        _tell(term, copy(book.page), 'Copied the link', 'No clipboard tool (pbcopy, clip, wl-copy or xclip)');
    }
  }

  void _tell(Term term, Future<bool> done, String success, String failure) {
    done.then(
      (ok) => term.post(ok ? Notice(success) : Notice(failure, ok: false)),
      onError: (Object _) => term.post(Notice(failure, ok: false)),
    );
  }
}

Future<bool> openUrl(String url) => io.Platform.isMacOS
    ? Process('open', [url]).check()
    : io.Platform.isWindows
    ? Process('cmd', ['/c', 'start', '', url]).check()
    : Process('xdg-open', [url]).check();

Future<bool> copy(String text) async {
  Future<bool> tool(String cmd, List<String> args) =>
      Process(cmd, args, input: text).check().catchError((Object _) => false);
  if (io.Platform.isMacOS) return tool('pbcopy', []);
  if (io.Platform.isWindows) return tool('clip', []);
  return await tool('wl-copy', []) || await tool('xclip', ['-selection', 'clipboard']);
}

// ---- Anna's Archive, through a real browser -----------------------------------------------

/// The site. Its domains move: `ANNAS_ARCHIVE=https://…` points at a mirror that works.
final site = io.Platform.environment['ANNAS_ARCHIVE'] ?? 'https://annas-archive.gl';

/// Titles of the browser-check pages a protected site shows before the real one.
final checking = RegExp(r'DDoS-Guard|Just a moment|Checking your browser|Attention Required', caseSensitive: false);

/// A server error page's title: `502 Bad Gateway`.
final serverError = RegExp(r'^\s*([45]\d\d)\b');

final totalCount = RegExp(r'\(([^ ]+) total\)');
final symbols = RegExp(r'[^\w\s()\[\].,-]');

final class Book {
  const Book(this.title, this.page, {this.author, this.publisher, this.description, this.details = const []});
  final String title;
  final String page;
  final String? author;
  final String? publisher;
  final String? description;
  final List<String> details;
  String get id => Uri.parse(page).pathSegments.last;
  @override
  bool operator ==(Object other) => other is Book && other.page == page;
  @override
  int get hashCode => page.hashCode;
  @override
  String toString() => title;
}

typedef SearchPage = ({List<Book> books, String? total, bool more});

/// Anna's Archive through a real browser: the site checks for one before it serves pages.
final class AnnasArchive {
  final _chrome = Chrome();
  Page? _page;

  Future<void> connect() => _open('$site/');

  Future<SearchPage> search(String query, {int page = 1}) async {
    final url = Uri.parse('$site/search').replace(queryParameters: {'q': query, if (page > 1) 'page': '$page'});
    final results = await _open('$url');
    return (
      books: [
        for (final link in results.all('.js-aarecord-list-outer a.js-vim-focus'))
          if (closest(link, '.border-b') case final row?) _book(link, row),
      ],
      total: results.all('div.text-gray-500').map((e) => totalCount.firstMatch(e.text)?[1]).nonNulls.firstOrNull,
      more: results.find('a.js-pagination-next-page') != null,
    );
  }

  /// A direct file link from the first partner server that has one.
  Future<String> fileOf(Book book) async {
    for (final server in [8, 9, 10, 0, 1, 2, 3, 4, 5, 6, 7]) {
      try {
        final page = await _open('$site/slow_download/${book.id}/0/$server');
        for (final a in page.all('a[href^="http"]')) {
          if (a.text.contains('Download now')) return a.attr('href')!;
        }
      } on Exception {
        continue;
      }
    }
    throw const MissingException('partner server with this file now: try again later, or open its page');
  }

  Future<void> close() => _chrome.close();

  /// [url] rendered in the one reused tab, once the browser check has passed. A server
  /// error is retried twice; a parked domain (no Anna's Archive markup) fails at once.
  Future<Doc> _open(String url) async {
    for (var attempt = 1; ; attempt++) {
      try {
        if (_page case final page?) {
          await page.navigate(url, timeout: const Duration(seconds: 60));
        } else {
          _page = await _chrome.open(url, timeout: const Duration(seconds: 60));
        }
        return await _rendered(_page!, url);
      } on MissingException {
        rethrow;
      } on Exception {
        if (attempt == 3) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  /// The page once it is the real one: a browser check is waited out (60 s at most), a server
  /// error page throws, and a page without the site's markup is a parked domain.
  Future<Doc> _rendered(Page page, String url) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      final title = await page.title();
      if (serverError.firstMatch(title)?[1] case final code?) {
        throw HttpException('$title from $url', uri: Uri.parse(url), status: int.parse(code));
      }
      if (!checking.hasMatch(title)) {
        final doc = await page.html();
        if (doc.find('a[href^="/search"], form[action*="search"]') == null) {
          throw MissingException(
            "Anna's Archive at $site (the domain answers, but not with the site): "
            'set ANNAS_ARCHIVE to a working mirror',
          );
        }
        return doc;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException("The site's browser check did not pass within 60 s", const Duration(seconds: 60));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
}

Book _book(Element link, Element row) => Book(
  _decoded(link.text),
  '$site${link.attr('href')}',
  author: _labelled(row, 'mdi--user-edit'),
  publisher: _labelled(row, 'mdi--company'),
  description: _optional(row.find('div.text-gray-600.mt-2')),
  details: _details(row.find('div.font-semibold.text-sm')),
);

String? _labelled(Element row, String icon) => row
    .all('a[href^="/search"]')
    .where((link) => link.find('span[class*="$icon"]') != null)
    .map((link) => _decoded(link.text))
    .firstOrNull;

String? _optional(Element? found) => found == null || found.text.trim().isEmpty ? null : _decoded(found.text);

List<String> _details(Element? line) => [
  if (line != null)
    for (final part in line.text.split('·'))
      if (!part.contains('/'))
        if (part.replaceAll(symbols, '').trim() case final detail when detail.isNotEmpty && detail != 'Save') detail,
];

String _decoded(String text) => Html.parse(text).text;

/// The nearest ancestor-or-self of [el] matching [css].
Element? closest(Element el, String css) {
  for (Element? at = el; at != null; at = at.parent) {
    if (at.matches(css)) return at;
  }
  return null;
}

// ---- Downloads ----------------------------------------------------------------------------

/// Where books land: $BOOKS_DIR, else ~/Downloads.
final downloadsFolder = Dir(
  io.Platform.environment['BOOKS_DIR'] ??
      '${io.Platform.environment['HOME'] ?? io.Platform.environment['USERPROFILE']}/Downloads',
);

final bookFormats = 'epub pdf mobi azw3 fb2 djvu cbz cbr txt doc docx rtf zip rar'.split(' ').toSet();

File savePath(Book book) {
  final format = book.details.map((d) => d.toLowerCase()).where(bookFormats.contains).firstOrNull ?? 'bin';
  final name = [book.title, ?book.author].join(' - ');
  return downloadsFolder.file('${safeName(name)}.$format');
}

String safeName(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Where one download stands.
sealed class Progress {
  const Progress(this.book);
  final Book book;
}

final class Queued extends Progress {
  const Queued(super.book);
}

final class Finding extends Progress {
  const Finding(super.book);
}

final class Receiving extends Progress {
  const Receiving(super.book, this.bytes);
  final int bytes;
}

final class Saved extends Progress {
  const Saved(super.book, this.file);
  final File file;
}

final class Failed extends Progress {
  const Failed(super.book, this.error);
  final Object error;
}

/// Two downloads at a time. Each streams into `<name>.part` and resumes one an earlier run
/// left; the finished file is moved into place.
final class Downloads {
  Downloads(this.archive);
  final AnnasArchive archive;
  final _changes = StreamController<Progress>.broadcast();
  final _queue = <Book>[];
  final latest = <Book, Progress>{};
  var _running = 0;

  Stream<Progress> get changes => _changes.stream;

  void add(Book book) {
    if (latest[book] case Queued() || Finding() || Receiving()) return;
    _queue.add(book);
    _emit(Queued(book));
    _next();
  }

  void _next() {
    while (_running < 2 && _queue.isNotEmpty) {
      final book = _queue.removeAt(0);
      _running++;
      _fetch(book).whenComplete(() {
        _running--;
        _next();
      });
    }
  }

  Future<void> _fetch(Book book) async {
    try {
      _emit(Finding(book));
      final url = await archive.fileOf(book);
      final to = savePath(book);
      final part = File('${to.path}.part');
      await to.parent.make();
      var shown = DateTime.now();
      void progress(int bytes) {
        if (DateTime.now().difference(shown) < const Duration(milliseconds: 200)) return;
        shown = DateTime.now();
        _emit(Receiving(book, bytes));
      }

      try {
        await Http.get(url, retry: 3).pipe(part, resume: true, onProgress: progress);
      } on HttpException catch (e) {
        if (e.status != 200) rethrow;
        // The server can't resume: start the file over.
        await part.drop();
        await Http.get(url, retry: 3).pipe(part, onProgress: progress);
      }
      _emit(Saved(book, await part.move(to)));
    } catch (e) {
      _emit(Failed(book, e));
    }
  }

  void _emit(Progress p) {
    latest[p.book] = p;
    if (!_changes.isClosed) _changes.add(p);
  }

  Future<void> close() => _changes.close();
}
