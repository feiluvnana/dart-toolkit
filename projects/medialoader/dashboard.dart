// What a run is doing, drawn as a full-screen dashboard while it runs.
// Import with `as dashboard`.
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
  final transfers = <Transfer>[]; // in flight, oldest first
  final events = <Event>[];
  final usersScroll = Scroll(follow: false), transfersScroll = Scroll(follow: false), log = Scroll();
  final apis = <Client>[]; // the platform clients: counted, and closed when the run ends
  final speed = Speed(); // every CDN byte
  String? pause; // why a platform's calls are on hold
  Timer? _pauseTimer;
  var done = false, failuresOnly = false, live = false, retrying = 0;
  final failures = <Failure>[]; // what r retries
  bool get finished => done && retrying == 0;
  int get requests => apis.fold(0, (n, c) => n + c.sent());
  Iterable<Part> get parts => users.expand((u) => u.parts.values);
  int sum(int Function(Part p) f) => parts.fold(0, (n, p) => n + f(p));

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

  // A line in the log; without a terminal, printed as it happens.
  void note(String line, {String? platform, bool failed = false}) {
    events.add((at: DateTime.now(), line: line, platform: platform, failed: failed));
    if (!live) Console.log('${platform == null ? '' : '[$platform] '}$line');
  }
}

typedef Event = ({DateTime at, String line, String? platform, bool failed});
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
  var queued = 0, added = 0, had = 0, failed = 0, bytes = 0;
  int get done => added + had + failed;
  bool get finished => !busy && done >= queued && failed == 0;
  String get counts => '$added new · $had had${failed > 0 ? ' · $failed failed' : ''} · ${bytes.size()}';
}

final class Transfer {
  Transfer(this.user, this.part, this.path);
  final User user;
  final Part part;
  final String path;
  final since = DateTime.now();
  var done = 0;
  int? total;
  String? status;

  void update(int done, int? total) {
    part.bytes += done - this.done;
    this.done = done;
    this.total = total;
  }
}

// Runs [work] under the dashboard until q, then calls [close] (so downloads
// stop and nothing keeps the process alive) and prints the summary. Without
// a terminal the log prints as it goes and failures are retried once.
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
  board.live = true;
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
                .then((_) {}, onError: (Object e, _) => b.note('✗ $e', failed: true))
                .whenComplete(() => b.done = true),
          ),
          'l': ('save log', () async => app.status('✓ log saved: ${await saveLog()} (${b.events.length} lines)')),
          if (b.failures.isNotEmpty) 'r': ('retry ${b.failures.length} failed', b.retryAll),
          'q escape': (
            'quit',
            () async {
              if (b.finished || await Console.confirm('Stop downloading? The next run continues from here.')) app.quit();
            },
          ),
        },
      );
    });
  } finally {
    board
      ..live = false
      ..clearPause();
    await close();
  }
  summary();
  exitCode = !board.finished ? 130 : (board.failures.isNotEmpty ? 1 : 0);
}

Color platformColor(String code) => switch (code) {
  'ins' => Color.magenta,
  'twt' => Color.cyan,
  'fbk' => Color.blue,
  _ => Color.white,
};

// medialoader [ins] · 2 users · 140/400 files · 31 new · 2 failed · 120.4 MB · 3.1 MB/s · 9 API calls · 1 min 12 s
String title(Board b) => [
  ['medialoader', if (b.users.isNotEmpty) '[${{for (final u in b.users) u.platform}.join(',')}]'].join(' '),
  '${b.users.length} ${b.users.length == 1 ? 'user' : 'users'}',
  '${b.sum((p) => p.done)}/${b.sum((p) => p.queued)} files',
  '${b.sum((p) => p.added)} new',
  if (b.sum((p) => p.failed) case final n when n > 0) '$n failed',
  b.sum((p) => p.bytes).size(),
  '${b.speed.rate().size()}/s',
  '${b.requests} API calls',
  DateTime.now().difference(b.started).human(),
  if (b.finished) 'done',
].join(' · ');

void draw(Region r) {
  final b = board;
  final [top, bottom] = r.rows([0, (r.height() / 3).round().clamp(5, 14)]);
  final [left, right] = top.cols([0, (top.width() * 0.4).round()]);
  users(left.box('users', color: border).scroll(b.usersScroll), b);
  final waiting = b.sum((p) => p.queued) - b.sum((p) => p.done) - b.transfers.length;
  transfers(
    right.box('downloading: ${b.transfers.length}, ${waiting < 0 ? 0 : waiting} waiting', color: border).scroll(b.transfersScroll),
    b,
  );
  // Clicking the log's header shows only failures and rate limits, and back.
  final head = b.failuresOnly ? 'log: failures & rate limits only (click for all)' : 'log (click for failures & rate limits only)';
  final toggle = {'click': ('', () => b.failuresOnly = !b.failuresOnly)};
  events(bottom.box(head, color: border, on: toggle).scroll(b.log), b);
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
            u.busy ? r.write('($id)  working', color: busy) : r.write('($id)  ✓ done', color: good);
        }
      },
      for (final p in u.parts.values) ...[
        (r) {
          r.write('  ${p.name}'.padRight(13), inline: true, style: {.bold});
          p.finished
              ? r.write('✓ ${p.counts} · ${p.note}', color: good)
              : r.bar(p.done, p.queued, color: p.failed > 0 ? bad : flow);
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
void transfers(Region r, Board b) {
  if (b.transfers.isEmpty) {
    r.write(b.finished ? 'nothing left' : 'waiting for files', style: {.dim});
    return;
  }
  r.lines(b.transfers.length * 2, (row, i) {
    final t = b.transfers[i ~/ 2];
    if (i.isEven) {
      tag(row, t.user.platform);
      row.write('@${t.user.name} ', inline: true, color: handle, style: {.bold}).write(t.path);
    } else if (t.status case final status?) {
      row.write('  $status', color: busy, style: {.bold});
    } else {
      row.bar(t.done, t.total, bytes: true, since: t.since, color: flow);
    }
  });
}

bool isRateLimit(Event e) => e.line.toLowerCase().contains('rate limit');

// Failures red, changes and waits yellow, saved files plain.
void events(Region r, Board b) {
  final shown = [
    for (final e in b.events)
      if (!b.failuresOnly || e.failed || isRateLimit(e)) e,
  ];
  r.lines(shown.length, (row, i) {
    final e = shown[i];
    row.write('${e.at.format('HH:mm:ss')}  ', inline: true, style: {.dim});
    tag(row, e.platform);
    row.write(
      e.line,
      color: e.failed ? bad : (e.line.contains(' changed: ') || isRateLimit(e) ? warn : null),
      style: e.failed ? {.bold} : {},
    );
  });
}

// The palette: borders gray, platform tags unique, progress green,
// working/waits yellow, failures red, usernames white.
const border = Color.gray, handle = Color.white, busy = Color.yellow, flow = Color.green, good = Color.green;
const bad = Color.red, warn = Color.yellow;

// Every log line so far into .medialoader.log next to the script; returns its path.
Future<String> saveLog() async {
  final file = Fs.scriptDir().file('.medialoader.log');
  await file.write([
    for (final e in board.events) '${e.at.format('yyyy-MM-dd HH:mm:ss')}  ${e.platform == null ? '' : '[${e.platform}] '}${e.line}\n',
  ].join());
  return file.path();
}

// After the dashboard: a table per user, what changed and what failed.
void summary() {
  for (final u in board.users) {
    Console.table(
      [
        for (final p in u.parts.values) [p.name, p.added, p.had, if (p.failed > 0) p.failed else null, p.bytes.size(), p.note],
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
