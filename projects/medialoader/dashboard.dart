// What a run is doing, drawn as a full-screen dashboard while it runs.
// Import with `as dashboard`.
library;

import 'dart:async';
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
  var requests = 0;
  int get bytes => parts.fold(0, (n, p) => n + p.bytes);
  String? pause; // why Instagram calls are on hold
  Timer? _pauseTimer; // clears [pause]; cancelled on quit so it never keeps the process alive
  var done = false, failuresOnly = false, live = false;
  final failures = <Failure>[]; // what r retries
  var retrying = 0;
  bool get finished => done && retrying == 0;
  final _samples = ListQueue<(DateTime, int)>();
  var _transferred = 0;

  // Platform calls are on hold for [wait]: show why, then clear it. The
  // timer is cancelled on quit (see [clearPause]), so a run quit during a
  // rate-limit wait never keeps the process alive until it fires.
  void holdPause(String why, Duration wait, {String? platform}) {
    final plat = platform ?? _detectPlatform(why);
    final prefix = plat != null && plat.isNotEmpty && !why.startsWith('[$plat]') ? '[$plat] ' : '';
    pause = '$prefix$why';
    note(why, platform: plat);
    _pauseTimer?.cancel();
    _pauseTimer = Timer(wait, () => pause = null);
  }

  // Drop a pending pause wait: the timer must not outlive the run.
  void clearPause() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
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

  User user(String name, {String platform = ''}) {
    final u = User(name, platform: platform);
    users.add(u);
    return u;
  }

  // A line in the log; without a terminal, printed as it happens.
  void note(String line, {String? platform, bool failed = false}) {
    final plat = platform ?? _detectPlatform(line);
    events.add((at: DateTime.now(), line: line, platform: plat, failed: failed));
    if (!live) {
      final tag = plat != null && plat.isNotEmpty && !line.startsWith('[$plat]') ? '[$plat] ' : '';
      Console.log('$tag$line');
    }
  }

  static String? _detectPlatform(String line) {
    final lower = line.toLowerCase();
    if (lower.startsWith('[ins]') || lower.contains('instagram')) return 'ins';
    if (lower.startsWith('[twt]') || lower.contains('twitter')) return 'twt';
    if (lower.startsWith('[fbk]') || lower.contains('facebook')) return 'fbk';
    return null;
  }

  void count(int n) {
    _transferred += n;
    final now = DateTime.now();
    _samples.add((now, _transferred));
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

typedef Event = ({DateTime at, String line, String? platform, bool failed});
typedef Failure = ({String line, Future<void> Function() retry});

final class User {
  User(this.name, {this.platform = ''});
  String name;
  String platform;
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
  String? status;

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
      final result = await work();
      if (board.failures.isNotEmpty) exit(1);
      return result;
    } finally {
      board.clearPause();
      summary();
    }
  }
  late final Future<T> job;
  board.live = true;
  try {
    await Tui.run(board, accent: Color.orange, (b, app) {
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
              job
                  .then((_) {}, onError: (Object e, _) => b.note('✗ $e', failed: true))
                  .whenComplete(() => b.done = true);
            },
          ),
          'l': ('save log', () async => app.status('✓ log saved: ${await saveLog()} (${b.events.length} lines)')),
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
    // The TUI is gone from here on: no timer may keep the process alive
    // past it (the shell would wait with no prompt until Ctrl-C).
    board.live = false;
    board.clearPause();
  }
  summary();
  if (!board.finished) exit(130);
  try {
    await job;
  } catch (_) {}
  if (board.failures.isNotEmpty) exit(1);
  exit(0);
}

Color platformColor(String code) => switch (code.toLowerCase()) {
  'ins' || 'instagram' => Color.magenta,
  'twt' || 'twitter' => Color.cyan,
  'fbk' || 'facebook' => Color.blue,
  _ => Color.white,
};

// instaloader · 2 users · 140/400 files · 31 new · 2 failed · 120.4 MB · 3.1 MB/s · 1 min 12 s
String title(Board b) {
  final parts = b.parts.toList();
  int sum(int Function(Part p) f) => parts.fold(0, (n, p) => n + f(p));
  final plats = {for (final u in b.users) if (u.platform.isNotEmpty) u.platform}.toList();
  final platStr = plats.isNotEmpty ? ' [${plats.join(',')}]' : '';
  return [
    'medialoader$platStr',
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
  users(left.box('users', color: border).scroll(b.usersScroll), b);
  transfers(
    right
        .box(
          'downloading: ${b.transfers.length} of 8 lanes, ${max(0, b.queued - b.files - b.transfers.length)} waiting',
          color: border,
        )
        .scroll(b.transfersScroll),
    b,
  );
  // Clicking the log's header shows only failures and rate limits, and back.
  final head = b.failuresOnly
      ? 'log: failures & rate limits only (click for all)'
      : 'log (click for failures & rate limits only)';
  final toggle = {'click': ('', () => b.failuresOnly = !b.failuresOnly)};
  events(bottom.box(head, color: border, on: toggle).scroll(b.log), b);
}

// Per user a header, then per folder its bar and a line of what its
// explorer is doing and the counts; a folder done without failures is one
// row. A user still being looked up is one row.
void users(Region r, Board b) {
  final lines = <void Function(Region)>[
    if (b.users.isEmpty) (r) => r.spin('looking up users', color: busy, style: {.bold}),
    for (final u in b.users) ...[
      (r) {
        final plat = u.platform;
        final [tag, handleCol, status] = r.cols([
          plat.isNotEmpty ? 6 : 0,
          u.name.length + 3,
          0,
        ]);
        if (plat.isNotEmpty) tag.write('[$plat]', color: platformColor(plat), style: {.bold});
        handleCol.write('@${u.name}', color: handle, style: {.bold});
        switch (u) {
          case User(:final error?):
            status.write('✗ $error', color: bad, style: {.bold});
          case User(id: null):
            status.spin('looking up profile', color: busy, style: {.bold});
          case User(:final id):
            final idStr = id != null ? ' ($id)' : '';
            u.busy
                ? status.write('$idStr  working', color: busy)
                : status.write('$idStr  ✓ done', color: good);
        }
      },
      for (final p in u.parts.values) ...[
        (r) {
          final [label, rest] = r.cols([13, 0]);
          label.write('  ${p.name}', style: {.bold});
          p.finished
              ? rest.write('✓ ${p.counts} · ${p.note}', color: good)
              : rest.bar(p.done, p.queued, label: '${p.done}/${p.queued}', color: p.failed > 0 ? bad : flow);
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
    final plat = t.user.platform;
    final [tag, who, path] = rows[2 * i].cols([
      plat.isNotEmpty ? 6 : 0,
      t.user.name.length + 2,
      0,
    ]);
    if (plat.isNotEmpty) tag.write('[$plat]', color: platformColor(plat), style: {.bold});
    who.write('@${t.user.name}', color: handle, style: {.bold});
    path.write(t.path);
    final secs = DateTime.now().difference(t.since).inMilliseconds / 1000;
    final [bar, rate] = rows[2 * i + 1].cols([0, 14]);
    bar.bar(t.done, t.total, label: t.status != null ? ' ${t.status}' : ' ', bytes: true, color: flow);
    if (t.status != null) {
      rate.write(' ${t.status}', color: busy, style: {.bold});
    } else {
      rate.write(secs > 0 ? ' ${size((t.done / secs).round())}/s' : '', style: {.dim});
    }
  }
}

extension on Event {
  bool get isRateLimit {
    final lower = line.toLowerCase();
    return lower.contains('rate limit') || lower.contains('ratelimit') || lower.contains('rate-limit');
  }
}

// Failures red, changes and waits yellow, saved files plain.
void events(Region r, Board b) {
  final shown = [
    for (final e in b.events)
      if (!b.failuresOnly || e.failed || e.isRateLimit) e,
  ];
  r.lines(shown.length, (row, i) {
    final e = shown[i];
    final plat = e.platform;
    final [time, tag, line] = row.cols([
      10,
      plat != null && plat.isNotEmpty ? 6 : 0,
      0,
    ]);
    time.write(e.at.format('HH:mm:ss'), style: {.dim});
    if (plat != null && plat.isNotEmpty) {
      tag.write('[$plat]', color: platformColor(plat), style: {.bold});
    }
    var text = e.line;
    if (plat != null && text.startsWith('[$plat] ')) {
      text = text.substring(plat.length + 3);
    }
    line.write(
      text,
      color: e.failed ? bad : (text.contains(' changed: ') || e.isRateLimit ? warn : null),
      style: e.failed ? {.bold} : {},
    );
  });
}

// The palette: borders gray, platform tags unique, progress green,
// working/waits yellow, failures red, usernames white.
const border = Color.gray,
    handle = Color.white,
    busy = Color.yellow,
    flow = Color.green,
    good = Color.green,
    bad = Color.red,
    warn = Color.yellow;

// Every log line so far into .medialoader.log next to the script; returns
// its path.
Future<String> saveLog() async {
  final file = Fs.scriptDir().file('.medialoader.log');
  await file.write([
    for (final e in board.events)
      '${e.at.format('yyyy-MM-dd HH:mm:ss')}  ${e.platform != null && e.platform!.isNotEmpty ? '[${e.platform}] ' : ''}${e.line}\n'
  ].join());
  return file.path();
}

// After the dashboard: a table per user, what changed and what failed.
void summary() {
  for (final u in board.users) {
    final title = u.platform.isNotEmpty ? '[${u.platform}] @${u.name}' : '@${u.name}';
    Console.table(
      [
        for (final p in u.parts.values)
          [p.name, p.added, p.had, if (p.failed > 0) p.failed else null, size(p.bytes), p.note],
      ],
      header: [title, 'new', 'had', 'failed', 'size', ''],
    );
    final tag = u.platform.isNotEmpty ? '[${u.platform}] ' : '';
    if (u.error != null) Console.log('  ✗ $tag${u.error}');
    for (final c in u.changes) {
      Console.log('  changed: $tag$c');
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
