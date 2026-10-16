// What a run is doing, drawn as a full-screen dashboard while it runs.
library;

import 'dart:async';
import 'dart:io' show exitCode, stdout;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/tui.dart';

// The one board of this run: every module reports into it.
final board = Board();

final class Board {
  final started = DateTime.now();
  final users = <User>[];
  final usersScroll = Scroll(follow: false), transfersScroll = Scroll(follow: false), log = Scroll();
  final apis = <Client>[]; // the platform clients: counted, and closed when the run ends
  final meter = Meter(); // every CDN byte
  String? pause; // why a platform's calls are on hold
  Timer? _pauseTimer;
  var done = false, crashed = false, failuresOnly = false, retrying = 0, active = 0; // active: files downloading
  final failures = <Failure>[]; // what r retries
  bool get finished => done && retrying == 0;
  int get requests => apis.fold(0, (n, c) => n + c.sent());
  Part get total => Part.total(users.expand((u) => u.parts.values));

  // A platform's calls are on hold for [wait]: say why until then.
  void holdPause(String why, Duration wait, {required String platform}) {
    pause = '[$platform] $why';
    note(why, platform: platform);
    _pauseTimer?.cancel();
    _pauseTimer = Timer(wait, () => pause = null);
  }

  // The timer must not outlive the run.
  void clearPause() {
    _pauseTimer?.cancel();
    pause = null;
  }

  // A failure to report now and retry on r.
  void fail(String line, Future<void> Function() retry, {String? platform}) {
    failures.add((line: line, retry: retry));
    note(line, platform: platform, failed: true);
  }

  // Every failure again; one that fails again comes back to [failures].
  Future<void> retryAll() async {
    final all = [...failures];
    failures.clear();
    if (all.isEmpty) return;
    note('retrying ${all.length} ${all.length == 1 ? 'failure' : 'failures'}');
    retrying += all.length;
    await Future.wait([for (final f in all) f.retry().whenComplete(() => retrying--)]);
  }

  User user(String name, {required String platform}) {
    final u = User(name, platform);
    users.add(u);
    return u;
  }

  // A line in the run's log (Console's: the log pane, or printed without a terminal).
  void note(String line, {String? platform, bool failed = false}) =>
      Console.log('${platform == null ? '' : '[$platform] '}$line', failed: failed);
}

typedef Failure = ({String line, Future<void> Function() retry});

final class User {
  User(this.name, this.platform);
  String name;
  final String platform;
  String? id, error;
  final parts = <String, Part>{}; // by folder: posts, stories, …
  final changes = <String>[];
  bool get busy => error == null && parts.values.any((p) => p.busy || p.done < p.queued);
}

// One folder of a user: what its explorer is doing and what it downloaded.
final class Part {
  Part(this.name);
  final String name;
  String phase = 'waiting', note = '';
  bool busy = true; // still listing
  var queued = 0, added = 0, had = 0, failed = 0, stored = 0;
  final meter = Meter(); // this folder's downloads, as they arrive
  int get bytes => stored + meter.done();

  // [parts] added up: a user's, or every user's.
  static Part total(Iterable<Part> parts) => Part('all')
    ..queued = parts.fold(0, (n, p) => n + p.queued)
    ..added = parts.fold(0, (n, p) => n + p.added)
    ..had = parts.fold(0, (n, p) => n + p.had)
    ..failed = parts.fold(0, (n, p) => n + p.failed)
    ..stored = parts.fold(0, (n, p) => n + p.bytes);
  int get done => added + had + failed;
  bool get finished => !busy && done >= queued && failed == 0;
  String get counts => '$added new · $had had${failed > 0 ? ' · $failed failed' : ''} · ${bytes.size()}';
}

// Runs [work] under the dashboard until q, then calls [close] (so downloads
// stop and nothing keeps the process alive) and prints the summary. Without
// a terminal, Console prints the log and the bars as they go, and failures
// are retried once.
// Sets exitCode: 1 when something failed, 130 when quit before the end.
Future<void> watch(Future<void> Function() work, {required Future<void> Function() close}) async {
  if (!stdout.hasTerminal) {
    try {
      await work();
      await board.retryAll();
    } finally {
      board.clearPause();
      await close();
      summary();
    }
    if (board.failures.isNotEmpty) exitCode = 1;
    return;
  }
  try {
    await Tui.run(board, accent: Color.orange, (b, app) {
      return Screen(
        draw,
        title: title(b),
        status: b.finished ? 'done: press q to leave' : (b.retrying > 0 ? 'retrying ${b.retrying}…' : b.pause),
        keys: {
          'show': (
            '',
            () => work()
                .then(
                  (_) {},
                  onError: (Object e, _) {
                    b.crashed = true;
                    b.note('✗ $e', failed: true);
                  },
                )
                .whenComplete(() => b.done = true),
          ),
          'l': ('save log', () async => app.status('✓ log saved: ${await saveLog()}')),
          'f': (b.failuresOnly ? 'all lines' : 'failures only', () => b.failuresOnly = !b.failuresOnly),
          if (b.failures.isNotEmpty) 'r': ('retry ${b.failures.length} failed', b.retryAll),
          'q escape': (
            'quit',
            () async {
              if (b.finished || await Console.confirm('Stop downloading? The next run continues from here.')) {
                app.quit();
              }
            },
          ),
        },
      );
    });
  } finally {
    board.clearPause();
    await close();
  }
  summary();
  exitCode = !board.finished ? 130 : (board.failures.isNotEmpty || board.crashed ? 1 : 0);
}

// Each platform's tag colour: the known ones fixed, a new one the next
// free colour, so a TikTok or Bluesky added later needs nothing here.
const _fixed = {'ins': Color.magenta, 'twt': Color.cyan, 'fbk': Color.blue};
const _spare = [Color.green, Color.yellow, Color.red, Color.white];
final _picked = <String, Color>{};
Color platformColor(String code) =>
    _fixed[code] ?? _picked.putIfAbsent(code, () => _spare[_picked.length % _spare.length]);

// medialoader [ins] · 2 users · 140/400 files · 31 new · 2 failed · 120.4 MB · 3.1 MB/s · 9 API calls · 1 min 12 s
String title(Board b) => switch (b.total) {
  final t => [
    [
      'medialoader',
      if (b.users.isNotEmpty) '[${{for (final u in b.users) u.platform}.join(',')}]',
    ].join(' '),
    '${b.users.length} ${b.users.length == 1 ? 'user' : 'users'}',
    '${t.done}/${t.queued} files',
    '${t.added} new',
    if (t.failed > 0) '${t.failed} failed',
    t.bytes.size(),
    '${b.meter.rate().size()}/s',
    '${b.requests} API calls',
    DateTime.now().difference(b.started).human(),
    if (b.finished) 'done',
  ].join(' · '),
};

void draw(Region r) {
  final b = board;
  final [top, bottom] = r.rows([0, (r.height() / 3).round().clamp(5, 14)]);
  final [left, right] = top.cols([0, (top.width() * 0.4).round()]);
  users(left.box('users', color: border).scroll(b.usersScroll), b);
  final t = b.total, waiting = t.queued - t.done - b.active;
  // Every file in flight: Console bars, one row each.
  right
      .box('downloading: ${b.active}, ${waiting < 0 ? 0 : waiting} waiting', color: border)
      .scroll(b.transfersScroll)
      .bars(color: flow);
  // f shows only failures and rate limits, and back.
  bottom
      .box(b.failuresOnly ? 'log: failures & rate limits only' : 'log', color: border)
      .scroll(b.log)
      .log(only: b.failuresOnly ? (l) => l.failed || l.text.toLowerCase().contains('rate limit') : null, failures: bad);
}

// `[ins] ` in the platform's colour, then the row continues.
void tag(Region r, String? platform) {
  if (platform != null) r.write('[$platform] ', inline: true, color: platformColor(platform), style: {.bold});
}

// Per user a header, then per folder its bar and a line of what its
// explorer is doing and the counts; a folder done without failures is one row.
void users(Region r, Board b) {
  final lines = <void Function(Region)>[
    if (b.users.isEmpty) (r) => r.spin('looking up users', color: busy, style: {.bold}),
    // Every user together: one bar over all files, and the bytes so far.
    if (b.users.length > 1)
      (r) {
        r.write('all'.padRight(13), inline: true, style: {.bold});
        final t = b.total;
        r.bar(Meter()..update(t.done, t.queued), color: t.failed > 0 ? bad : flow);
      },
    if (b.users.length > 1) (r) {},
    for (final u in b.users) ...[
      (r) {
        tag(r, u.platform);
        r.write('@${u.name}  ', inline: true, color: handle, style: {.bold});
        switch (u) {
          case User(:final error?):
            r.write('✗ $error', color: bad, style: {.bold});
          case User(id: null):
            r.spin('looking up profile', color: busy, style: {.bold});
          case User(:final id):
            final t = Part.total(u.parts.values);
            r.write('($id)  ', inline: true, style: {.dim});
            u.busy
                ? r.write('working · ${t.added} new · ${t.bytes.size()}', color: busy)
                : r.write('✓ done · ${t.added} new · ${t.bytes.size()}', color: good);
        }
      },
      for (final p in u.parts.values) ...[
        (r) {
          r.write('  ${p.name}'.padRight(13), inline: true, style: {.bold});
          p.finished
              ? r.write('✓ ${p.counts} · ${p.note}', color: good)
              : r.bar(Meter()..update(p.done, p.queued), color: p.failed > 0 ? bad : flow);
        },
        if (!p.finished)
          (r) {
            r.write('    ', inline: true);
            p.busy
                ? r.spin('${p.counts} · ${p.phase}', color: busy)
                : r.write('✓ ${p.counts} · ${p.note}', color: p.failed > 0 ? bad : good);
          },
      ],
      for (final c in u.changes) (r) => r.write('  changed: $c', color: warn),
      (r) {},
    ],
  ];
  r.lines(lines.length, (row, i) => lines[i](row));
}

// Each file in flight: who and where, then its bytes and speed.
// The palette: borders gray, platform tags unique, progress green,
// working/waits yellow, failures red, usernames white.
const border = Color.gray, handle = Color.white, busy = Color.yellow, flow = Color.green, good = Color.green;
const bad = Color.red, warn = Color.yellow;

// The run's log so far into .medialoader.log next to the script; returns its path.
Future<String> saveLog() async {
  final file = Fs.scriptDir().file('.medialoader.log');
  await (Console.logged() > file);
  return file.path();
}

// After the dashboard: a table per user, what changed and what failed.
void summary() {
  for (final u in board.users) {
    Console.table(
      [
        for (final p in u.parts.values)
          [p.name, p.added, p.had, if (p.failed > 0) p.failed else null, p.bytes.size(), p.note],
      ],
      header: ['[${u.platform}] @${u.name}', 'new', 'had', 'failed', 'size', ''],
    );
    if (u.error != null) Console.log('  ✗ ${u.error}');
    for (final c in u.changes) {
      Console.log('  changed: $c');
    }
  }
  for (final f in board.failures) {
    Console.log('  ${f.line}');
  }
}
