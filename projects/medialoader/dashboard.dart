// MediaLoader TUI Dashboard: renders decoupled lanes, deduplication stats,
// per-target category progress, and live event log.
library;

import 'dart:async';
import 'dart:io' show exitCode;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/tui.dart';
import 'package:dart_toolkit/utils.dart';

import 'db.dart';
import 'engine.dart';

/// The active dashboard instance.
Dashboard? activeDashboard;

final class Dashboard {
  Dashboard({
    required this.engine,
    required this.db,
  });

  final IngestionEngine engine;
  final MediaDb db;

  final usersScroll = Scroll(follow: false);
  final transfersScroll = Scroll(follow: false);

  final border = Color.rgb(100, 116, 139);
  final handle = Color.white;
  final busy = Color.rgb(251, 191, 36);
  final flow = Color.rgb(52, 211, 153);
  final good = Color.rgb(74, 222, 128);
  final bad = Color.rgb(248, 113, 113);
  final warn = Color.rgb(251, 146, 60);
  final accent = Color.rgb(251, 146, 60);
  final textDim = Color.rgb(148, 163, 184);

  static final _fixedColors = {
    'ins': Color.rgb(225, 48, 108),
    'twt': Color.rgb(29, 155, 240),
    'fbk': Color.rgb(24, 119, 242),
  };
  static final _spareColors = [
    Color.rgb(52, 211, 153),
    Color.rgb(251, 191, 36),
    Color.rgb(248, 113, 113),
    Color.rgb(248, 250, 252),
  ];
  final _pickedColors = <String, Color>{};

  Color platformColor(String code) =>
      _fixedColors[code] ?? _pickedColors.putIfAbsent(code, () => _spareColors[_pickedColors.length % _spareColors.length]);

  // Overall totals across all users
  ({int queued, int added, int had, int failed, int bytes}) get total {
    var q = 0, a = 0, h = 0, f = 0, b = 0;
    for (final u in engine.users) {
      for (final c in u.categories.values) {
        q += c.queued;
        a += c.added;
        h += c.had;
        f += c.failed;
        b += c.bytes;
      }
    }
    return (queued: q, added: a, had: h, failed: f, bytes: b);
  }

  String title() {
    final t = total;
    final platforms = {for (final u in engine.users) u.platform}.join(',');
    final elapsed = DateTime.now().difference(engine.started).human();
    final rate = engine.overallByteMeter.rate();
    final speed = rate > 0 ? '${rate.size()}/s' : '';
    final dedupeStr = engine.deduplicatedCount > 0 ? '${engine.deduplicatedCount} deduped · ' : '';

    return [
      'medialoader${platforms.isNotEmpty ? ' [$platforms]' : ''}',
      '${engine.users.length} ${engine.users.length == 1 ? 'user' : 'users'}',
      '${t.added + t.had + t.failed}/${t.queued} files',
      '${t.added} new',
      if (dedupeStr.isNotEmpty) dedupeStr.substring(0, dedupeStr.length - 3),
      if (t.failed > 0) '${t.failed} failed',
      t.bytes.size(),
      if (speed.isNotEmpty) speed,
      '${engine.requests} API calls',
      elapsed,
      if (engine.finished) 'done',
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  void draw(Region r) {
    // Decoupled bottom panel: 1 overall bar + lanes (up to 8)
    final bottomH = (r.height() >= 20) ? 11 : (r.height() * 0.5).round().clamp(6, 11);
    final [top, bottom] = r.rows([0, bottomH]);

    _drawUsers(top.box('targets (${engine.users.length})', color: border).scroll(usersScroll));
    _drawLanes(bottom);
  }

  void _drawUsers(Region r) {
    final t = total;
    final lines = <void Function(Region)>[
      if (engine.users.isEmpty) (r) => r.spin('discovering targets…', color: busy, style: {.bold}),
      if (engine.users.length > 1)
        (r) {
          final done = t.added + t.had + t.failed;
          engine.allUsersMeter.update(done, t.queued > 0 ? t.queued : null);
          r.bar(engine.allUsersMeter, label: 'all targets ($done/${t.queued})', color: accent);
        },
      for (final u in engine.users) ...[
        (r) {
          _drawTag(r, u.platform);
          r.write('@${u.name} ', inline: true, color: handle, style: {.bold});
          if (u.error != null) {
            r.write('✗ ${u.error}', color: bad, style: {.bold});
          } else if (u.id == null && u.categories.isEmpty) {
            r.spin('resolving profile', color: busy, style: {.bold});
          } else {
            var userAdded = 0, userBytes = 0;
            for (final c in u.categories.values) {
              userAdded += c.added;
              userBytes += c.bytes;
            }
            if (u.id != null && u.id != u.name) r.write('(${u.id}) ', inline: true, style: {.dim});
            u.busy
                ? r.write('working · $userAdded new · ${userBytes.size()}', color: busy)
                : r.write('✓ done · $userAdded new · ${userBytes.size()}', color: good);
          }
        },
        for (final c in u.categories.values)
          (r) {
            if (c.finished) {
              r.write('  ${c.name.padRight(12)}', inline: true, style: {.bold});
              final noteStr = c.note.isNotEmpty ? ' · ${c.note}' : '';
              r.write('✓ ${c.counts}$noteStr', color: good);
            } else {
              final lab = '  ${c.name.padRight(10)} ${c.busy ? '${c.counts} (${c.phase})' : c.counts}';
              c.itemMeter.update(c.done, c.queued > 0 ? c.queued : null);
              r.bar(c.itemMeter, label: lab, color: c.failed > 0 ? bad : flow);
            }
          },
        for (final ch in u.changes) (r) => r.write('    ↳ $ch', color: warn),
      ],
    ];

    r.lines(lines.length, (row, i) => lines[i](row));
  }

  void _drawLanes(Region r) {
    final t = total;
    final done = t.added + t.had + t.failed;
    final waiting = (t.queued - done - engine.activeDownloads - engine.activeTranscodes).clamp(0, 999999);
    final titleStr =
        'lanes: ${engine.activeDownloads} downloading · ${engine.activeTranscodes} transcoding/hashing · $waiting queued';
    final inner = r.box(titleStr, color: border).scroll(transfersScroll);

    engine.overallItemMeter.update(done, t.queued > 0 ? t.queued : null);
    final rate = engine.overallByteMeter.rate();
    final speed = rate > 0 ? ' · ${rate.size()}/s' : '';
    final dedupeStr = engine.deduplicatedCount > 0 ? ' · ${engine.deduplicatedCount} deduped' : '';
    final overallLabel = 'overall: $done/${t.queued} files (${t.added} new$dedupeStr) · ${t.bytes.size()}$speed';

    inner.lines(9, (row, i) {
      if (i == 0) {
        row.bar(engine.overallItemMeter, label: overallLabel, color: accent);
        return;
      }
      final laneIndex = i - 1;
      if (laneIndex >= engine.lanes.length) {
        row.write('#$i  — idle —', color: textDim, style: {Style.dim});
        return;
      }
      final lane = engine.lanes[laneIndex];
      if (lane.busy) {
        final tag = lane.platform != null ? '[${lane.platform}] ' : '';
        final user = lane.user != null ? '@${lane.user} ' : '';
        final normalized = (lane.file ?? '').replaceAll(r'\', '/');
        final file = normalized.isNotEmpty ? normalized.split('/').last : '';
        final shortFile = file;

        switch (lane.status) {
          case LaneStatus.transcoding:
            row.spin('#${lane.id} $tag$user$shortFile · transcoding', color: warn);
          case LaneStatus.hashing:
            row.spin('#${lane.id} $tag$user$shortFile · hashing (pHash)', color: warn);
          case LaneStatus.downloading:
            row.bar(lane.meter, label: '#${lane.id} $tag$user$shortFile', color: flow);
          case LaneStatus.idle:
            row.write('#${lane.id}  — idle —', color: textDim, style: {Style.dim});
        }
      } else {
        row.write('#${lane.id}  — idle —', color: textDim, style: {Style.dim});
      }
    });
  }

  void _drawTag(Region r, String? platform) {
    if (platform != null) {
      r.write('[$platform] ', inline: true, color: platformColor(platform), style: {.bold});
    }
  }

  /// Interactive execution wrapper.
  static Future<void> watch({
    required IngestionEngine engine,
    required MediaDb db,
    required Future<void> Function() work,
  }) async {
    final d = Dashboard(engine: engine, db: db);
    activeDashboard = d;
    try {
      await Tui.run(
        d,
        accent: d.accent,
        work: () async {
          await work();
          await engine.retryAll();
          engine.done = true;
        },
        (dash, app) => Screen(
          dash.draw,
          title: dash.title(),
          status: engine.finished
              ? 'done: press q to leave'
              : (engine.retrying > 0 ? 'retrying ${engine.retrying}…' : null),
          keys: {
            'l': ('log file', () => app.status('✓ log: ${engine.logFile.path}')),
            if (engine.failures.isNotEmpty) 'r': ('retry ${engine.failures.length} failed', engine.retryAll),
            'q escape': (
              'quit',
              () async {
                if (engine.finished || await Console.confirm('Stop downloading? The database preserves state.')) {
                  app.quit();
                }
              },
            ),
          },
        ),
      );
    } finally {
      d.summary();
    }
    exitCode = !engine.finished ? 130 : (engine.failures.isNotEmpty ? 1 : 0);
  }

  /// Print terminal summary upon completion.
  void summary() {
    Console.log('');
    for (final u in engine.users) {
      Console.table(
        [
          for (final c in u.categories.values)
            [c.name, c.added, c.had, if (c.failed > 0) c.failed else null, c.bytes.size(), c.note],
        ],
        header: ['[${u.platform}] @${u.name}', 'new', 'had', 'failed', 'size', ''],
      );
      if (u.error != null) Console.log('  ✗ ${u.error}');
      for (final ch in u.changes) {
        Console.log('  changed: $ch');
      }
    }
    for (final f in engine.failures) {
      Console.log('  ${f.line}');
    }

    final dbStats = db.stats();
    Console.log('');
    Console.log(
      'Database: ${dbStats.assets} tracked assets · ${dbStats.totalBytes.size()} · ${dbStats.uniqueHashes} unique pHashes · ${dbStats.users} targets',
    );
    Console.log('Log file: ${engine.logFile.path}');
  }
}
