// MediaLoader TUI Dashboard: renders decoupled lanes, deduplication stats,
// per-target category progress, and live event log.
library;

import 'dart:async';
import 'dart:io' as io show ProcessInfo, exitCode;
import 'dart:math' as math;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/tui.dart';
import 'package:dart_toolkit/utils.dart';

import 'db.dart';
import 'engine.dart';

/// The active dashboard instance.
Dashboard? activeDashboard;

final class Dashboard {
  Dashboard({required this.engine, required this.db});

  final IngestionEngine engine;
  final MediaDb db;

  DateTime _lastStatsTime = DateTime.fromMillisecondsSinceEpoch(0);
  ({int assets, int totalBytes, int users, int uniqueHashes})? _cachedStats;

  ({int assets, int totalBytes, int users, int uniqueHashes}) get dbStats {
    final now = DateTime.now();
    if (_cachedStats == null || now.difference(_lastStatsTime) >= const Duration(seconds: 1)) {
      _lastStatsTime = now;
      _cachedStats = db.stats();
    }
    return _cachedStats!;
  }

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
      _fixedColors[code] ??
      _pickedColors.putIfAbsent(code, () => _spareColors[_pickedColors.length % _spareColors.length]);

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

    return [
      'medialoader${platforms.isNotEmpty ? ' [$platforms]' : ''}',
      '${engine.users.length} ${engine.users.length == 1 ? 'user' : 'users'}',
      '${t.added + t.had + t.failed}/${t.queued} files',
      '${t.added} new',
      if (engine.deduplicatedCount > 0) '${engine.deduplicatedCount} deduped',
      if (t.failed > 0) '${t.failed} failed',
      t.bytes.size(),
      if (speed.isNotEmpty) speed,
      '${engine.requests} API calls',
      elapsed,
      if (engine.finished) 'done',
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  void draw(Region r) {
    // Download panel height equals the number of rows drawn (1 overall bar + lanes + 2 border)
    final downloadH = engine.lanes.length + 3;
    final statusH = (r.height() >= 24) ? 5 : 4;
    final maxDownloadH = math.max(3, r.height() - statusH - 3);
    final lanesH = downloadH.clamp(3, maxDownloadH);
    final [top, downloadPanel, statusBar] = r.rows([0, lanesH, statusH]);

    _drawUsers(top.box('targets (${engine.users.length})', color: border).scroll(usersScroll));
    _drawLanes(downloadPanel);
    _drawStatus(statusBar);
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
    final waiting = engine.downloadWaiting + engine.transcodeWaiting;
    final titleStr =
        'lanes: ${engine.activeDownloads} downloading · ${engine.activeTranscodes} transcoding/hashing · $waiting queued';
    final inner = r.box(titleStr, color: border).scroll(transfersScroll);

    engine.overallItemMeter.update(done, t.queued > 0 ? t.queued : null);
    final rate = engine.overallByteMeter.rate();
    final speed = rate > 0 ? ' · ${rate.size()}/s' : '';
    final dedupeStr = engine.deduplicatedCount > 0 ? ' · ${engine.deduplicatedCount} deduped' : '';
    final overallLabel = 'overall: $done/${t.queued} files (${t.added} new$dedupeStr) · ${t.bytes.size()}$speed';

    inner.lines(engine.lanes.length + 1, (row, i) {
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

  void _drawStatus(Region r) {
    final inner = r.box('status', color: border);
    final t = total;
    final stats = dbStats;
    final ram = io.ProcessInfo.currentRss.size();
    final rate = engine.overallByteMeter.rate();
    final speed = rate > 0 ? '${rate.size()}/s' : 'idle';
    final waiting = engine.downloadWaiting + engine.transcodeWaiting;
    final logName = engine.logFile.path.replaceAll(r'\', '/').split('/').last;

    // Collect active platforms
    final platformSet = <String>{for (final u in engine.users) u.platform, ...engine.rateLimits.keys};
    if (platformSet.isEmpty) {
      for (final ext in extractors) {
        platformSet.add(ext.code);
      }
    }

    final h = inner.height();
    final lines = <void Function(Region)>[
      // Row 1: Rate limits, active pauses, RAM, live throughput, API calls
      (r) {
        r.write('rate limit: ', inline: true, style: {.bold});
        var first = true;
        for (final code in platformSet) {
          final pRate = engine.getRate(code);
          if (pRate == null) continue;
          if (!first) r.write('  ', inline: true);
          first = false;
          _drawTag(r, code);
          final wait = pRate.activeWait;
          if (wait != null && wait > Duration.zero) {
            r.write('${pRate.current}/${pRate.count} (${pRate.per.human()})', inline: true);
            r.write(' ⏸ wait ${wait.human()}', inline: true, color: warn, style: {.bold});
          } else {
            r.write('${pRate.current}/${pRate.count} (${pRate.per.human()})', inline: true, color: handle);
          }
        }
        r.write('  ·  ', inline: true, color: textDim);
        r.write('RAM: ', inline: true, style: {.bold});
        r.write(ram, inline: true, color: flow);
        r.write('  ·  speed: ', inline: true, style: {.bold});
        r.write(speed, inline: true, color: handle);
        r.write('  ·  ', inline: true, color: textDim);
        r.write('${engine.requests} API calls', inline: true, color: textDim);
      },

      if (h >= 3) ...[
        // Row 2: Workers concurrency, queue, in-flight assets, uptime
        (r) {
          r.write('workers: ', inline: true, style: {.bold});
          r.write('${engine.activeDownloads} dl, ${engine.activeTranscodes} trans', inline: true, color: handle);
          if (waiting > 0) {
            r.write(' ($waiting queued)', inline: true, color: busy);
          } else {
            r.write(' (0 queued)', inline: true, color: textDim);
          }
          final done = t.added + t.had + t.failed;
          r.write('  ·  tasks: $done/${t.queued} files', inline: true, color: textDim);
          final elapsed = DateTime.now().difference(engine.started).human();
          r.write('  ·  uptime: $elapsed', inline: true, color: textDim);
        },
        // Row 3: Database assets, storage bytes, deduplicated files, unique pHashes, log file
        (r) {
          r.write('database: ', inline: true, style: {.bold});
          r.write('${stats.assets} assets (${stats.totalBytes.size()})', inline: true, color: handle);
          r.write('  ·  deduped: ', inline: true, style: {.bold});
          r.write(
            '${engine.deduplicatedCount} [dedupe]',
            inline: true,
            color: engine.deduplicatedCount > 0 ? good : textDim,
          );
          r.write('  ·  unique pHashes: ${stats.uniqueHashes}', inline: true, color: textDim);
          r.write('  ·  log: $logName', inline: true, color: textDim);
        },
      ] else ...[
        // Row 2 for 2-row panel: Storage, database, workers, and log
        (r) {
          r.write('database: ', inline: true, style: {.bold});
          r.write('${stats.assets} assets (${stats.totalBytes.size()})', inline: true, color: handle);
          r.write('  ·  ', inline: true, color: textDim);
          r.write(
            '${engine.deduplicatedCount} deduped',
            inline: true,
            color: engine.deduplicatedCount > 0 ? good : textDim,
          );
          r.write(
            '  ·  workers: ${engine.activeDownloads} dl, ${engine.activeTranscodes} trans ($waiting queued)',
            inline: true,
            color: textDim,
          );
          r.write('  ·  log: $logName', inline: true, color: textDim);
        },
      ],
    ];

    inner.lines(lines.length, (row, i) => lines[i](row));
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
              : (engine.activePause ?? (engine.retrying > 0 ? 'retrying ${engine.retrying}…' : null)),
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
    io.exitCode = !engine.finished ? 130 : (engine.failures.isNotEmpty ? 1 : 0);
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
