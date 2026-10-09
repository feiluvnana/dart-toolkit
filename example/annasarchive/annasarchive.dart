import 'dart:io';
import 'dart:math';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/process.dart';
import 'package:dart_toolkit/tui.dart';

import 'fetch.dart';
import 'search.dart';

Future<void> main(List<String> args) => Cli(
  "Finds and downloads books from Anna's Archive.",
  pools: [downloads],
  handler: (ctx) async {
    final app = BooksApp();
    ctx.defer(app.archive.close);
    await app.run();
  },
).run(args);

const orange = Style(fg: Color.rgb(217, 119, 87));
const bold = Style(bold: true);
const muted = Style(dim: true);
const green = Style(fg: Color.green);
const red = Style(fg: Color.red);

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

enum Action {
  download('Download', 'into ~/Downloads, even after you quit'),
  pause('Pause', 'its download'),
  resume('Resume', 'its download'),
  stop('Stop', 'its download; downloading it again carries on'),
  open('Open its page', 'in your browser'),
  copy('Copy its link', '');

  final String label;
  final String help;

  const Action(this.label, this.help);
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

final class DownloadMoved extends Message {
  final Job<Book, Path> job;

  const DownloadMoved(this.job);
}

final class BooksApp extends TuiApp<Screen, Message> {
  final archive = AnnasArchive();
  final input = Field(prompt: '> ', placeholder: "Search a book's title, author or ISBN");
  final results = Choice<Book>([]);
  final menu = Choice<Action>([]);
  final shownDownloads = <String>{};
  final tallies = <String, Tally>{};
  var latestSearch = 0;
  var connected = false;
  Notice? notice;

  BooksApp()
    : super(
        const Welcome(),
        theme: const TuiTheme(
          palette: Palette(accent: orange, focused: orange, pointer: '❯'),
        ),
      );

  @override
  void init() {
    focus(input);
    send(
      archive.connect().then<Message>(
        (_) => const Connected(),
        onError: (Object error, StackTrace _) => Unreachable(error),
      ),
    );
    listen(downloads.changes.map(DownloadMoved.new));
  }

  List<Action> actionsFor(Book book) {
    final status = downloads.job(book)?.status;
    return [
      if (status == null || status is Done || status is Stopped) Action.download,
      if (status is Waiting || status is Running) Action.pause,
      if (status is Paused || status is Failed) Action.resume,
      if (status is Waiting || status is Running || status is Paused) Action.stop,
      Action.open,
      Action.copy,
    ];
  }

  @override
  Screen update(Screen screen, TuiEvent<Message> event) {
    final next = _next(screen, event);
    if (next is Detail) menu.items = actionsFor(next.book);
    return next;
  }

  Screen _next(Screen screen, TuiEvent<Message> event) {
    if (event case Sent(:final message)) return _receive(screen, message);
    if (event is KeyPress || event is Char) notice = null;
    final query = input.text.trim();
    return switch ((screen, event)) {
      (_, const KeyPress('d', ctrl: true)) => Tui.quit(screen),
      (_, KeyPress.enter) when query.isNotEmpty => _newSearch(screen, query),
      (final Found found, KeyPress.enter) when results.value != null => _openBook(found, results.value!),
      (Detail(:final book), KeyPress.enter) => _act(screen, book),
      (_, KeyPress.esc) => _back(screen),
      (Detail(), _) when menu.handle(event) => screen,
      (final Found found, _) when results.handle(event) => _loadMoreNearTheEnd(found),
      _ => screen,
    };
  }

  Screen _receive(Screen screen, Message message) {
    switch (message) {
      case Connected():
        connected = true;
      case Unreachable(:final error):
        notice = Notice("Could not reach Anna's Archive: $error", ok: false);
      case Notice():
        notice = message;
      case DownloadMoved(:final job) when !job.status.isFinal:
        shownDownloads.add(job.id);
      case SearchFailed(:final search, :final error) when search == latestSearch:
        notice = Notice('$error', ok: false);
        return switch (screen) {
          Searching(:final back) => back,
          Found() => screen.withLoading(false),
          _ => screen,
        };
      case Arrived(:final search) when search == latestSearch:
        return _showResults(screen, message);
      default:
    }
    return screen;
  }

  Screen _showResults(Screen screen, Arrived arrived) {
    connected = true;
    final (:books, :total, :more) = arrived.result;
    if (arrived.page == 1) {
      results.items = books;
      results.index = 0;
    } else {
      results.items = [...results.items, ...books];
    }
    final found = Found(arrived.query, total: total, page: arrived.page, more: more);
    return screen is Detail ? Detail(found, screen.book) : found;
  }

  Screen _newSearch(Screen screen, String query) {
    input.text = '';
    _search(query, 1);
    return Searching(query, screen is Searching ? screen.back : screen);
  }

  Screen _loadMoreNearTheEnd(Found found) {
    final nearTheEnd = results.index >= results.items.length - 3;
    if (!found.more || found.loading || !nearTheEnd) return found;
    _search(found.query, found.page + 1);
    return found.withLoading(true);
  }

  void _search(String query, int page) {
    final search = ++latestSearch;
    send(
      archive
          .search(query, page: page)
          .then<Message>(
            (result) => Arrived(search, query, page, result),
            onError: (Object error, StackTrace _) => SearchFailed(search, error),
          ),
    );
  }

  Screen _openBook(Found found, Book book) {
    menu.index = 0;
    return Detail(found, book);
  }

  Screen _back(Screen screen) {
    if (input.text.isNotEmpty) {
      input.text = '';
      return screen;
    }
    switch (screen) {
      case Searching(:final back):
        latestSearch++;
        return back;
      case Detail(:final back):
        return back;
      default:
        return screen;
    }
  }

  Screen _act(Screen screen, Book book) {
    final job = downloads.job(book);
    switch (menu.value) {
      case Action.download:
        shownDownloads.add(downloads.add(book, detached: true).id);
        notice = const Notice('Downloading: it carries on if you quit');
      case Action.pause:
        job?.pause();
      case Action.resume:
        job?.resume();
      case Action.stop:
        job?.remove();
        notice = const Notice('Stopped: downloading it again carries on from there');
      case Action.open:
        _openInBrowser(book.page);
      case Action.copy:
        _copy('${book.page}');
      case null:
    }
    return screen;
  }

  void _openInBrowser(Uri page) {
    final opener = Platform.isMacOS ? 'open' : (Platform.isWindows ? 'explorer' : 'xdg-open');
    _tell(Shell.run(opener, args: ['$page']).isOk, 'Opened in your browser', 'Could not open $page');
  }

  void _copy(String text) {
    Future<bool> copyWith(String tool) => Shell.run(tool, text: text).isOk.catchError((Object _) => false);
    final copied = Platform.isMacOS
        ? copyWith('pbcopy')
        : Platform.isWindows
        ? copyWith('clip')
        : copyWith('wl-copy').then((ok) async => ok || await copyWith('xclip -selection clipboard'));
    _tell(copied, 'Copied the link', 'No clipboard tool (pbcopy, clip, wl-copy or xclip)');
  }

  void _tell(Future<bool> done, String success, String failure) => send(
    done.then<Message>(
      (ok) => ok ? Notice(success) : Notice(failure, ok: false),
      onError: (Object _) => Notice(failure, ok: false),
    ),
  );

  @override
  Widget view(Screen screen) => VStack([
    Label.spans([const Span(' ✻ ', orange), const Span('Books', bold), const Span(" · Anna's Archive", muted)]),
    Label(''),
    _body(screen).flex(),
    ..._downloadsPanel(),
    if (notice case final notice?) Label(' ${notice.ok ? '✓' : '✗'} ${notice.text}', style: notice.ok ? green : red),
    Box(input),
    _footer(screen),
  ]);

  Widget _body(Screen screen) => switch (screen) {
    Welcome() => _welcome(),
    Searching(:final query) when connected => Spin('Searching for "$query"…  esc to cancel'),
    Searching() => const Spin("Passing the site's browser check…  esc to cancel"),
    Found() => _resultsView(screen),
    Detail(:final book) => _bookView(book),
  };

  Widget _welcome() => VStack([
    HStack([
      Box(
        VStack([
          Label.spans([const Span('✻ ', orange), const Span('Welcome to Books!', bold)]),
          Label(''),
          Label("Find a book on Anna's Archive by its name, then download it.", style: muted),
          if (connected) Label('● connected to $site', style: green) else Label('○ connecting to $site…', style: muted),
        ]),
      ).themed(const TuiTheme(palette: Palette(borderStyle: orange))),
      Label('').flex(),
    ]),
    Label(''),
    Label(' How it works:', style: muted),
    Label('  1. Type a title, author or ISBN and press Enter'),
    Label('  2. ↑↓ walk the results, Enter opens a book'),
    Label('  3. Its menu downloads it into ~/Downloads, opens its page or copies its link'),
    Label('  4. Downloads carry on after you quit; the next start shows them'),
  ]);

  Widget _resultsView(Found found) {
    if (results.items.isEmpty) return Label(' No books for "${found.query}". Try fewer words.', style: muted);
    final shown = '${results.items.length} shown${found.total == null ? '' : ' of ${found.total}'}';
    return VStack([
      Label.spans([const Span(' Results for '), Span('"${found.query}"', bold), Span(' · $shown', muted)]),
      Label(''),
      Menu(results, item: _resultRow).flex(),
      if (found.loading) const Spin('Loading more…'),
    ]);
  }

  Widget _resultRow(ItemView<Book> row) {
    final book = row.value;
    final about = [?book.author, ...book.details].join(' · ');
    return Label.spans([
      Span(row.isSelected ? ' ❯ ' : '   ', orange),
      Span('${row.index + 1}.'.padRight(5), muted),
      Span(book.title, row.isSelected ? orange + bold : bold),
      Span('\n        $about\n', muted),
    ], wrap: false);
  }

  Widget _bookView(Book book) => Box(
    VStack([
      Label(book.title, style: orange + bold),
      if (book.author case final author?) Label('by $author'),
      if (book.publisher case final publisher?) Label(publisher, style: muted),
      Label(''),
      Label(book.details.join(' · ')),
      Label(''),
      Menu(menu, item: _actionRow),
      if (downloads.job(book) case final job?) ...[Label(''), _downloadRow(job)],
      if (book.description case final description?) ...[Label(''), Label(description, style: muted)],
    ]),
    title: ' ${results.index + 1} of ${results.items.length} ',
  );

  Widget _actionRow(ItemView<Action> row) => Label.spans([
    Span(row.isSelected ? ' ❯ ' : '   ', orange),
    Span(row.value.label.padRight(16), row.isSelected ? orange + bold : Style.none),
    Span(row.value.help, muted),
  ], wrap: false);

  List<Widget> _downloadsPanel() {
    final jobs = downloads.jobs.where((job) => shownDownloads.contains(job.id)).toList();
    return [for (final job in jobs.skip(max(0, jobs.length - 3))) _downloadRow(job)];
  }

  Widget _downloadRow(Job<Book, Path> job) {
    final title = job.item.title;
    return switch (job.status) {
      Done(:final value) => Label(' ✓ $title → ${value.replaceFirst('${Path.home}', '~')}', style: green, wrap: false),
      Failed(:final error) => Label(' ✗ $title: $error', style: red, wrap: false),
      Stopped() => Label(' ■ $title, stopped', style: muted, wrap: false),
      Paused() => Label(' ⏸ $title, paused', style: muted, wrap: false),
      Waiting() => Spin('Waiting to download $title…'),
      Running(step: 'finding a server') => Spin('Finding a server for $title…'),
      _ => HStack([Label(' ⬇ $title', wrap: false).flex(), Board(_tally(job), log: 0, task: _progress).fixed(40)]),
    };
  }

  Tally _tally(Job<Book, Path> job) {
    final tally = tallies[job.id];
    if (tally != null && !tally.isOver) return tally;
    return tallies[job.id] = Tally.task(job);
  }

  Widget _progress(TaskView view) {
    final percent = '${view.percent ?? '--'}%'.padLeft(4);
    return Label(' ${view.bar(18)} $percent ${view.pace} ', style: orange, wrap: false);
  }

  Widget _footer(Screen screen) {
    final hints = switch (screen) {
      Welcome() => 'type a name · enter search · ctrl+c quit',
      Searching() => 'esc cancel',
      Found() when results.items.isNotEmpty => '↑↓ move · enter open · type to search again',
      Found() => 'type a new search',
      Detail() => '↑↓ choose · enter run · esc back',
    };
    final status = switch (screen) {
      Found(:final page) when results.items.isNotEmpty => 'page $page · ${results.index + 1}/${results.items.length}',
      _ when connected => '● connected',
      _ => '○ connecting',
    };
    return HStack([Label('  $hints', style: muted, wrap: false).flex(), Label('$status ', style: muted)]);
  }
}
