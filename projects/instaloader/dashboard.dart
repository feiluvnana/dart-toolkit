// What a run is doing, drawn as a full-screen dashboard while it runs.
// Import with `as dashboard`.
library;

import 'dart:collection';
import 'dart:io' show exit, stdout;
import 'dart:math' show max;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/tui.dart';

// The one board of this run: download.dart and instagram.dart report into it.
final board = Board();

final class Board {
  final started = DateTime.now();
  final users = <User>[];
  final transfers = <Transfer>[]; // in flight, oldest first
  final events = <Event>[];
  final usersScroll = Scroll(follow: false), transfersScroll = Scroll(follow: false), log = Scroll();
  var requests = 0, bytes = 0;
  String? pause; // why Instagram calls are on hold
  var done = false, failuresOnly = false, live = false;
  final failures = <Failure>[]; // what r retries
  var retrying = 0;
  bool get finished => done && retrying == 0;
  final _samples = ListQueue<(DateTime, int)>();

  // A failure to report now and retry on r.
  void fail(String line, Future<void> Function() retry) {
    failures.add((line: line, retry: retry));
    note(line, failed: true);
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

  User user(String name) {
    final u = User(name);
    users.add(u);
    return u;
  }

  // A line in the log; without a terminal, printed as it happens.
  void note(String line, {bool failed = false}) {
    events.add((at: DateTime.now(), line: line, failed: failed));
    if (!live) Console.log(line);
  }

  void count(int n) {
    bytes += n;
    final now = DateTime.now();
    _samples.add((now, bytes));
    while (_samples.length > 2 && now.difference(_samples.first.$1) > 5.seconds) {
      _samples.removeFirst();
    }
  }

  // Bytes per second over the last 5 seconds.
  double speed() {
    if (_samples.length < 2 || DateTime.now().difference(_samples.last.$1) > 5.seconds) return 0;
    final (t0, b0) = _samples.first;
    final (t1, b1) = _samples.last;
    final ms = t1.difference(t0).inMilliseconds;
    return ms == 0 ? 0 : (b1 - b0) * 1000 / ms;
  }

  Iterable<Part> get parts => users.expand((u) => u.parts.values);
  int get files => parts.fold(0, (n, p) => n + p.done);
  int get queued => parts.fold(0, (n, p) => n + p.queued);
}

typedef Event = ({DateTime at, String line, bool failed});
typedef Failure = ({String line, Future<void> Function() retry});

final class User {
  User(this.name);
  String name;
  String? id, error;
  final parts = <String, Part>{}; // by folder: photos, reels, …
  final changes = <String>[];
  bool get busy => error == null && parts.values.any((p) => p.busy || p.done < p.queued);
}

// One folder of a user: what its explorer is doing and what it downloaded.
final class Part {
  Part(this.name);
  final String name;
  String phase = 'waiting';
  bool busy = true; // still listing
  String note = '';
  var queued = 0, added = 0, had = 0, failed = 0, bytes = 0;
  int get done => added + had + failed;
  bool get finished => !busy && done >= queued && failed == 0;
  String get counts => '$added new · $had had${failed > 0 ? ' · $failed failed' : ''} · ${size(bytes)}';
}

final class Transfer {
  Transfer(this.user, this.part, this.path);
  final User user;
  final Part part;
  final String path;
  final since = DateTime.now();
  var done = 0;
  int? total;

  void update(int done, int? total) {
    board.count(done - this.done);
    part.bytes += done - this.done;
    this.done = done;
    this.total = total;
  }
}

// Runs [work] under the dashboard until the user quits (q), then prints the
// summary. Dragging selects text and copies it; the wheel or a scrollbar
// drag scrolls a panel. Without a terminal, the log prints as it goes. Quitting before
// the work is done stops it: finished pages keep their cursor, so the next
// run continues.
Future<T> watch<T>(Future<T> Function() work) async {
  if (!stdout.hasTerminal) {
    try {
      return await work();
    } finally {
      summary();
    }
  }
  late final Future<T> job;
  board.live = true;
  await Tui.run(board, accent: name, (b, app) {
    return Screen(
      title: title(b),
      status: b.finished
          ? 'done: press q to leave'
          : b.retrying > 0
          ? 'retrying ${b.retrying}…'
          : b.pause,
      draw,
      keys: {
        'show': (
          '',
          () {
            job = work();
            job.then((_) {}, onError: (Object e, _) => b.note('✗ $e', failed: true)).whenComplete(() => b.done = true);
          },
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
  board.live = false;
  summary();
  if (!board.finished) exit(130);
  final result = await job;
  if (board.failures.isNotEmpty) throw Exception('${board.failures.length} failed: run again to retry them.');
  return result;
}

// instaloader · 2 users · 140/400 files · 31 new · 2 failed · 120.4 MB · 3.1 MB/s · 1 min 12 s
String title(Board b) {
  final parts = b.parts.toList();
  int sum(int Function(Part p) f) => parts.fold(0, (n, p) => n + f(p));
  return [
    'instaloader',
    '${b.users.length} ${b.users.length == 1 ? 'user' : 'users'}',
    '${b.files}/${b.queued} files',
    '${sum((p) => p.added)} new',
    if (sum((p) => p.failed) case final n when n > 0) '$n failed',
    size(b.bytes),
    '${size(b.speed().round())}/s',
    '${b.requests} API calls',
    DateTime.now().difference(b.started).human(),
    if (b.finished) 'done',
  ].join(' · ');
}

void draw(Region r) {
  final b = board;
  final [top, bottom] = r.rows([0, (r.height() / 3).round().clamp(5, 14)]);
  final [left, right] = top.cols([0, (top.width() * 0.4).round()]);
  users(left.box('users', color: name).scroll(b.usersScroll), b);
  transfers(
    right
        .box(
          'downloading: ${b.transfers.length} of 8 lanes, ${max(0, b.queued - b.files - b.transfers.length)} waiting',
          color: flow,
        )
        .scroll(b.transfersScroll),
    b,
  );
  // Clicking the log's header shows only the failures, and back.
  final head = b.failuresOnly ? 'log: failures only (click for all)' : 'log (click for failures only)';
  final toggle = {'click': ('', () => b.failuresOnly = !b.failuresOnly)};
  events(bottom.box(head, color: Color.blue, on: toggle).scroll(b.log), b);
}

// Per user a header, then per folder its bar and a line of what its
// explorer is doing and the counts; a folder done without failures is one
// row. A user still being looked up is one row.
void users(Region r, Board b) {
  final lines = <void Function(Region)>[
    if (b.users.isEmpty) (r) => r.spin('looking up users', color: busy, style: {.bold}),
    for (final u in b.users) ...[
      (r) => switch (u) {
        User(:final error?) => r.write('@${u.name}  ✗ $error', color: bad, style: {.bold}),
        User(id: null) => r.spin('@${u.name}  looking up the profile', color: name, style: {.bold}),
        _ => r.write('@${u.name} (${u.id})  ${u.busy ? 'working' : '✓ done'}', color: name, style: {.bold}),
      },
      for (final p in u.parts.values) ...[
        (r) {
          final [label, rest] = r.cols([13, 0]);
          label.write('  ${p.name}', style: {.bold});
          p.finished
              ? rest.write('✓ ${p.counts} · ${p.note}', color: good)
              : rest.bar(p.done, p.queued, color: p.failed > 0 ? bad : flow);
        },
        if (!p.finished)
          (r) {
            final line = r.cols([4, 0]).last;
            p.busy
                ? line.spin('${p.counts} · ${p.phase}', color: busy)
                : line.write('✓ ${p.counts} · ${p.note}', color: p.failed > 0 ? bad : good);
          },
      ],
      for (final c in u.changes) (r) => r.write('  changed: $c', color: warn),
      if (u.id != null) (r) {},
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
  final rows = r.rows([
    for (final _ in b.transfers) ...[1, 1],
  ]);
  for (final (i, t) in b.transfers.indexed) {
    final [who, path] = rows[2 * i].cols([t.user.name.length + 2, 0]);
    who.write('@${t.user.name}', color: name, style: {.bold});
    path.write(t.path);
    final secs = DateTime.now().difference(t.since).inMilliseconds / 1000;
    final [bar, rate] = rows[2 * i + 1].cols([0, 12]);
    bar.bar(t.done, t.total, label: ' ', bytes: true, color: flow);
    rate.write(secs > 0 ? ' ${size((t.done / secs).round())}/s' : '', style: {.dim});
  }
}

// Failures red, changes and waits yellow, saved files plain.
void events(Region r, Board b) {
  final shown = [
    for (final e in b.events)
      if (e.failed || !b.failuresOnly) e,
  ];
  r.lines(shown.length, (row, i) {
    final e = shown[i];
    final [time, line] = row.cols([10, 0]);
    time.write(e.at.format('HH:mm:ss'), style: {.dim});
    line.write(
      e.line,
      color: e.failed ? bad : (e.line.contains(' changed: ') || e.line.contains('rate limit') ? warn : null),
      style: e.failed ? {.bold} : {},
    );
  });
}

// The palette: the accent (and user names) magenta, work in progress
// yellow, data flowing cyan, finished green, failures red.
const name = Color.magenta, busy = Color.yellow, flow = Color.cyan, good = Color.green, bad = Color.red;
const warn = Color.yellow;

// Every log line so far into .instaloader.log next to the script; returns
// its path.
Future<String> saveLog() async {
  final file = Fs.scriptDir().file('.instaloader.log');
  await file.write([for (final e in board.events) '${e.at.format('yyyy-MM-dd HH:mm:ss')}  ${e.line}\n'].join());
  return file.path();
}

// After the dashboard: a table per user, what changed and what failed.
void summary() {
  for (final u in board.users) {
    Console.table(
      [
        for (final p in u.parts.values)
          [p.name, p.added, p.had, if (p.failed > 0) p.failed else null, size(p.bytes), p.note],
      ],
      header: ['@${u.name}', 'new', 'had', 'failed', 'size', ''],
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

// "12.1 MB"
String size(int bytes) => switch (bytes) {
  < 1024 => '$bytes B',
  < 1024 * 1024 => '${(bytes / 1024).toStringAsFixed(1)} KB',
  < 1024 * 1024 * 1024 => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
  _ => '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB',
};
