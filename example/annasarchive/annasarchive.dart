import 'dart:io';
import 'dart:math';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/process.dart';
import 'package:dart_toolkit/tui.dart';

import 'fetch.dart';
import 'search.dart';

/// Books: Anna's Archive in the terminal, run with no arguments. Type a name and press Enter;
/// ↑↓ walk the results, Enter opens a book, and its menu downloads it into ~/Downloads, opens
/// its page or copies its link. Downloads are detached jobs: they carry on after the app ends,
/// and the next start shows them.
Future<void> main(List<String> args) => Cli(
  "Finds and downloads books from Anna's Archive, in a terminal app.",
  pools: [downloads],
  handler: (ctx) async {
    final app = Books();
    ctx.defer(app.archive.close);
    await app.run();
  },
).run(args);

const _orange = Style(fg: Color.rgb(217, 119, 87));
const _bold = Style(bold: true);
const _muted = Style(dim: true);
const _green = Style(fg: Color.green);
const _red = Style(fg: Color.red);

/// What the app shows.
sealed class Screen {
  const Screen();
}

final class Welcome extends Screen {
  const Welcome();
}

/// A first page on its way; Esc goes [back].
final class Searching extends Screen {
  final String query;
  final Screen back;

  const Searching(this.query, this.back);
}

/// The results so far ([Books.books]): [page] pages of them, a next one [loading].
final class Found extends Screen {
  final String query;
  final String? total;
  final int page;
  final bool more, loading;

  const Found(this.query, {this.total, this.page = 1, this.more = false, this.loading = false});

  Found next({required bool loading}) => Found(query, total: total, page: page, more: more, loading: loading);
}

/// A book and its menu ([Books.actions], the cursor [Books.action]).
final class Detail extends Screen {
  final Found back;
  final Book book;

  const Detail(this.back, this.book);
}

/// What a book's menu can offer.
enum Action {
  download('Download', 'into ~/Downloads, even after you quit'),
  pause('Pause', 'its download'),
  resume('Resume', 'its download'),
  stop('Stop', 'its download; downloading it again carries on'),
  open('Open its page', 'in your browser'),
  copy('Copy its link', '');

  final String label, help;

  const Action(this.label, this.help);
}

/// What finished in the background.
sealed class Message {
  const Message();
}

final class Ready extends Message {
  const Ready();
}

/// Search [id]'s page [page] of [query].
final class Arrived extends Message {
  final int id, page;
  final String query;
  final Results results;

  const Arrived(this.id, this.query, this.page, this.results);
}

/// Search [id] failed; `0` is the warm-up.
final class Missed extends Message {
  final int id;
  final Object error;

  const Missed(this.id, this.error);
}

final class Notice extends Message {
  final String text;
  final bool ok;

  const Notice(this.text, {this.ok = true});
}

/// A download moved on.
final class Moved extends Message {
  final Job<Book, Path> job;

  const Moved(this.job);
}

final class Books extends TuiApp<Screen, Message> {
  final archive = AnnasArchive();
  final input = Field(prompt: '> ', placeholder: "Search a book's title, author or ISBN");
  var books = <Book>[];
  var cursor = 0, offset = 0;

  /// The cursor in a book's menu.
  var action = 0;

  /// The downloads this run started, or found unfinished: the panel's, finished ones included.
  final _shown = <String>{};

  /// Each download's progress as it is drawn: its rate needs the statuses heard so far.
  final _tallies = <String, Tally>{};

  /// The latest search's id: anything that arrives for another is stale.
  var search = 0;
  var ready = false;
  Notice? notice;

  /// The rows of results the last frame fitted.
  var _visible = 1;

  Books()
    : super(
        const Welcome(),
        theme: const TuiTheme(
          palette: Palette(accent: _orange, focused: _orange, pointer: '❯'),
        ),
      );

  @override
  void init() {
    send(archive.warm().then<Message>((_) => const Ready(), onError: (Object e, StackTrace _) => Missed(0, e)));
    listen(downloads.changes.map(Moved.new));
  }

  /// What [book]'s menu offers: a download, or what can be done to the one under way.
  List<Action> actions(Book book) {
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

  // ---------------------------------------------------------------- update

  @override
  Screen update(Screen s, TuiEvent<Message> e) {
    if (e case Sent(:final message)) return _receive(s, message);
    if (e is KeyPress || e is Char) notice = null;
    switch (e) {
      case const KeyPress('d', ctrl: true):
        Tui.quit(s);
      case KeyPress.enter when input.text.trim().isNotEmpty:
        return _search(s, input.text.trim());
      case KeyPress.enter:
        return switch (s) {
          Found() when books.isNotEmpty => (() {
            action = 0;
            return Detail(s, books[cursor]);
          })(),
          Detail(:final book) => _run(s, book),
          _ => s,
        };
      case KeyPress.esc:
        return _back(s);
      case KeyPress.up || KeyPress.down when s is Detail:
        action = (action + (e == KeyPress.up ? -1 : 1)) % actions(s.book).length;
      case KeyPress.up || KeyPress.down || KeyPress.pageUp || KeyPress.pageDown when s is Found && books.isNotEmpty:
        final by = switch (e) {
          KeyPress.up => -1,
          KeyPress.down => 1,
          KeyPress.pageUp => -_visible,
          _ => _visible,
        };
        cursor = (cursor + by).clamp(0, books.length - 1);
        return _more(s);
      default:
    }
    return s;
  }

  /// [next] in place of the results, the cursor on the first.
  void _show(List<Book> next) {
    books = next;
    cursor = offset = 0;
  }

  Screen _receive(Screen s, Message m) {
    switch (m) {
      case Ready():
        ready = true;
      case Notice():
        notice = m;
      case Moved(:final job):
        if (!job.status.isFinal) _shown.add(job.id); // the next frame draws it
      case Missed(id: 0, :final error):
        notice = Notice("Could not reach Anna's Archive: $error", ok: false);
      case Missed(:final id, :final error) when id == search:
        notice = Notice('$error', ok: false);
        return switch (s) {
          Searching(:final back) => back,
          Found() => s.next(loading: false),
          _ => s,
        };
      case Arrived(:final id, :final query, :final page, :final results) when id == search:
        ready = true;
        if (page == 1) {
          _show(results.books);
        } else {
          books = [...books, ...results.books];
        }
        final found = Found(query, total: results.total, page: page, more: results.more);
        return s is Detail ? Detail(found, s.book) : found;
      default:
    }
    return s;
  }

  /// Searches [query] afresh, or for its next [page].
  Screen _search(Screen s, String query, {int page = 1}) {
    input.text = '';
    final id = ++search;
    send(
      archive
          .search(query, page: page)
          .then<Message>((r) => Arrived(id, query, page, r), onError: (Object e, StackTrace _) => Missed(id, e)),
    );
    return page > 1 && s is Found ? s.next(loading: true) : Searching(query, s is Searching ? s.back : s);
  }

  /// The next page, once the cursor nears the end of what is loaded.
  Screen _more(Found s) =>
      s.more && !s.loading && cursor >= books.length - 3 ? _search(s, s.query, page: s.page + 1) : s;

  Screen _back(Screen s) {
    if (input.text.isNotEmpty) {
      input.text = '';
      return s;
    }
    if (s is Searching) search++;
    return switch (s) {
      Searching(:final back) => back,
      Detail(:final back) => back,
      _ => s,
    };
  }

  // ---------------------------------------------------------------- a book's menu

  Screen _run(Screen s, Book book) {
    final menu = actions(book);
    final job = downloads.job(book);
    switch (menu[action.clamp(0, menu.length - 1)]) {
      case Action.download:
        _shown.add(downloads.add(book, detached: true).id);
        notice = const Notice('Downloading: it carries on if you quit');
      case Action.pause:
        job?.pause();
      case Action.resume:
        job?.resume();
      case Action.stop:
        job?.remove();
        notice = const Notice('Stopped: downloading it again carries on from there');
      case Action.open:
        final opener = Platform.isMacOS ? 'open' : (Platform.isWindows ? 'explorer' : 'xdg-open');
        _tell(Shell.run(opener, args: ['${book.page}']).isOk, 'Opened in your browser', 'Could not open ${book.page}');
      case Action.copy:
        _copy('${book.page}');
    }
    action = action.clamp(0, actions(book).length - 1);
    return s;
  }

  void _copy(String text) {
    Future<bool> via(String tool) => Shell.run(tool, text: text).isOk.catchError((Object _) => false);
    final copied = Platform.isMacOS
        ? via('pbcopy')
        : Platform.isWindows
        ? via('clip')
        : via('wl-copy').then((ok) async => ok || await via('xclip -selection clipboard'));
    _tell(copied, 'Copied the link', 'No clipboard tool (pbcopy, clip, wl-copy or xclip)');
  }

  void _tell(Future<bool> done, String ok, String failed) => send(
    done.then<Message>(
      (yes) => yes ? Notice(ok) : Notice(failed, ok: false),
      onError: (Object _) => Notice(failed, ok: false),
    ),
  );

  // ---------------------------------------------------------------- view

  @override
  Widget view(Screen s) => VStack([
    Label.spans([const Span(' ✻ ', _orange), const Span('Books', _bold), const Span(" · Anna's Archive", _muted)]),
    Label(''),
    _body(s).flex(),
    ..._panel(),
    if (notice case final n?) Label(' ${n.ok ? '✓' : '✗'} ${n.text}', style: n.ok ? _green : _red),
    Box(input),
    _footer(s),
  ]);

  Widget _body(Screen s) => switch (s) {
    Welcome() => _welcome(),
    Searching(:final query) => Spin(
      ready ? 'Searching for "$query"…  esc to cancel' : "Passing the site's browser check…  esc to cancel",
    ),
    Found() => _found(s),
    Detail(:final book) => _detail(book),
  };

  Widget _welcome() => VStack([
    HStack([
      Box(
        VStack([
          Label.spans([const Span('✻ ', _orange), const Span('Welcome to Books!', _bold)]),
          Label(''),
          Label("Find a book on Anna's Archive by its name, then download it.", style: _muted),
          Label(ready ? '● connected to $site' : '○ connecting to $site…', style: ready ? _green : _muted),
        ]),
      ).themed(const TuiTheme(palette: Palette(borderStyle: _orange))),
      Label('').flex(),
    ]),
    Label(''),
    Label(' How it works:', style: _muted),
    Label('  1. Type a title, author or ISBN and press Enter'),
    Label('  2. ↑↓ walk the results, Enter opens a book'),
    Label('  3. Its menu downloads it into ~/Downloads, opens its page or copies its link'),
    Label('  4. Downloads carry on after you quit; the next start shows them'),
  ]);

  Widget _found(Found s) {
    if (books.isEmpty) return Label(' No books for "${s.query}". Try fewer words.', style: _muted);
    return VStack([
      Label.spans([
        const Span(' Results for '),
        Span('"${s.query}"', _bold),
        Span(' · ${books.length} shown${s.total == null ? '' : ' of ${s.total}'}', _muted),
      ]),
      Label(''),
      Paint(_list).flex(),
      if (s.loading) const Spin('Loading more…'),
    ]);
  }

  /// The results, three rows each, the cursor's kept in view, and a scrollbar.
  void _list(Canvas c) {
    const rows = 3;
    _visible = max(1, c.height ~/ rows);
    if (cursor < offset) offset = cursor;
    if (cursor >= offset + _visible) offset = cursor - _visible + 1;
    for (var i = 0; i < _visible && offset + i < books.length; i++) {
      c.area(0, i * rows, c.width - 1, rows).draw(_row(offset + i));
    }
    if (books.length > _visible) {
      final thumb = max(1, c.height * _visible ~/ books.length);
      final top = (c.height - thumb) * offset ~/ max(1, books.length - _visible);
      for (var y = 0; y < c.height; y++) {
        final on = y >= top && y < top + thumb;
        c.text(c.width - 1, y, on ? '┃' : '│', on ? _orange : _muted);
      }
    }
  }

  Widget _row(int n) {
    final b = books[n], on = n == cursor;
    return Label.spans([
      Span(on ? ' ❯ ' : '   ', _orange),
      Span('${n + 1}.'.padRight(5), _muted),
      Span(b.title, on ? _orange + _bold : _bold),
      Span('\n${' ' * 8}'),
      Span([?b.author, ...b.info].join(' · '), _muted),
    ], wrap: false);
  }

  Widget _detail(Book b) => Box(
    VStack([
      Label(b.title, style: _orange + _bold),
      if (b.author case final a?) Label('by $a'),
      if (b.publisher case final p?) Label(p, style: _muted),
      Label(''),
      Label(b.info.join(' · ')),
      Label(''),
      for (final (i, a) in actions(b).indexed)
        Label.spans([
          Span(i == action ? ' ❯ ' : '   ', _orange),
          Span(a.label.padRight(16), i == action ? _orange + _bold : Style.none),
          Span(a.help, _muted),
        ], wrap: false),
      if (downloads.job(b) case final job?) ...[Label(''), _download(job)],
      Label(''),
      if (b.description case final d?) Label(d, style: _muted),
    ]),
    title: ' ${cursor + 1} of ${books.length} ',
  );

  /// The downloads worth a row: the last three this run started or found unfinished.
  List<Widget> _panel() {
    final jobs = [
      for (final job in downloads.jobs)
        if (_shown.contains(job.id)) job,
    ];
    return [for (final job in jobs.skip(max(0, jobs.length - 3))) _download(job)];
  }

  /// [job]'s progress, heard from its start; a new one once a resumed job runs again.
  Tally _tally(Job<Book, Path> job) => switch (_tallies[job.id]) {
    final tally? when !tally.isOver => tally,
    _ => _tallies[job.id] = Tally.task(job),
  };

  /// A download's row: waiting, a server sought, the bar, paused, or where it landed.
  Widget _download(Job<Book, Path> job) {
    final title = job.item.title;
    return switch (job.status) {
      Failed(:final error) => Label(' ✗ $title: $error', style: _red, wrap: false),
      Done(:final value) => Label(' ✓ $title → ${_home(value)}', style: _green, wrap: false),
      Stopped() => Label(' ■ $title, stopped', style: _muted, wrap: false),
      Paused() => Label(' ⏸ $title, paused${_at(job)}', style: _muted, wrap: false),
      Waiting() => Spin('Waiting to download $title…'),
      Running(step: 'finding a server') => Spin('Finding a server for $title…'),
      _ => HStack([
        Label(' ⬇ $title', wrap: false).flex(),
        Board(
          _tally(job),
          log: 0,
          task: (v) =>
              Label(' ${v.bar(18)} ${'${v.percent ?? '--'}%'.padLeft(4)} ${v.pace} ', style: _orange, wrap: false),
        ).fixed(40),
      ]),
    };
  }

  /// ` at 42%`: how far a paused download had got.
  String _at(Job<Book, Path> job) => switch (_tallies[job.id]?.latest) {
    TallyItem(:final received, total: final all?) when all > 0 => ' at ${received * 100 ~/ all}%',
    _ => '',
  };

  String _home(Path p) => p.replaceFirst('${Path.home}', '~');

  Widget _footer(Screen s) {
    final hints = switch (s) {
      Welcome() => 'type a name · enter search · ctrl+c quit',
      Searching() => 'esc cancel',
      Found() when books.isNotEmpty => '↑↓ move · enter open · type to search again',
      Found() => 'type a new search',
      Detail() => '↑↓ choose · enter run · esc back',
    };
    final right = switch (s) {
      Found(:final page) when books.isNotEmpty => 'page $page · ${cursor + 1}/${books.length}',
      _ => ready ? '● connected' : '○ connecting',
    };
    return HStack([Label('  $hints', style: _muted, wrap: false).flex(), Label('$right ', style: _muted)]);
  }
}
