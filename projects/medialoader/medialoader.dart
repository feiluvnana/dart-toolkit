// MediaLoader CLI: High-performance, multi-platform media downloader with SQLite,
// perceptual hashing (pHash) deduplication, and decoupled download/transcoding concurrency.
library;

import 'dart:convert';
import 'dart:io' show exit, exitCode;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/utils.dart';

import 'dashboard.dart';
import 'db.dart';
import 'engine.dart';

final targetArgs = Rest<String>(
  'target',
  'Usernames with platform prefix (fbk:user, twt:user, ins:user) or full URLs.',
);
final outOpt = Opt<String?>(
  'out',
  'Destination directory for downloaded media, database, and logs (default: <script-dir>/downloads).',
  short: 'o',
);
final categoryOpt = Multi<Kind>(
  'category',
  'Media categories to download (posts, stories, highlights, photos, videos, albums, profiles).',
  values: Kind.values,
  or: Kind.values,
);
final sinceOpt = Opt<DateTime?>(
  'since',
  'Only what was posted on or after this date (2024-05-01, or 7d for a week ago).',
);
final compressFlag = Flag('compress', 'Compress media using recommended qualities (image 85, video 80).');
final allFlag = Flag('all', 'Scan from the beginning of the feed, ignoring stored cursors.', short: 'a');
final dryRunFlag = Flag('dry-run', 'List what would download; write nothing to disk or DB.', short: 'n');

final sharedOptions = <Param<Object?>>[outOpt, categoryOpt, sinceOpt, compressFlag, allFlag, dryRunFlag];

Dir resolveTargetDir(Context c) {
  final path = c(outOpt);
  return path != null ? Fs.dir(path) : Fs.scriptDir() / 'downloads';
}

Future<String> resolveDbPath(Dir root, String? customDbPath) async {
  if (customDbPath != null) return customDbPath;
  final standard = root.file('.medialoader.db');
  final legacy = root.file('.medialoader2.db');
  if (!await standard.exists() && await legacy.exists()) {
    await legacy.move(standard.path);
  }
  return standard.path;
}

LoaderOptions makeOptions(Context c) =>
    (all: c(allFlag), dry: c(dryRunFlag), compress: c(compressFlag), since: c(sinceOpt));

Future<void> main(List<String> args) async {
  await Command(
    'medialoader',
    'High-performance multi-platform media downloader with SQLite & perceptual deduplication.',
    version: '2.0.0',
    commands: [
      Command(
        'download',
        'Download profiles or single posts.',
        params: [...sharedOptions, targetArgs],
        handler: handleDownload,
      ),
      Command(
        'update',
        'Update every previously downloaded target with its known categories.',
        params: sharedOptions,
        handler: handleUpdate,
      ),
      Command('stats', 'Display statistics from the SQLite media database.', params: [outOpt], handler: handleStats),
      Command(
        'duplicate',
        'Check if an image matches any tracked asset by SHA-256 or pHash.',
        params: [outOpt, Rest<String>('file', 'Path to image file to check.', required: true)],
        handler: handleFindDuplicate,
      ),
      Command(
        'prune',
        'Clean up database records whose files have been removed from disk.',
        params: [outOpt],
        handler: handlePrune,
      ),
      Command(
        'export',
        'Export media asset records to JSON or CSV.',
        params: [
          outOpt,
          Opt<String>('format', 'Output format: json or csv.', or: 'json'),
          Opt<String?>('to', 'Output file path (default: stdout).'),
        ],
        handler: handleExport,
      ),
    ],
  ).run(args);
  exit(exitCode);
}

Future<void> handleDownload(Context c) async {
  final rawTargets = c(targetArgs);
  if (rawTargets.isEmpty) {
    throw UsageException('Please provide at least one target username (e.g. fbk:user, twt:user, ins:user) or URL.');
  }

  final targets = <Target>[];
  for (final raw in rawTargets) {
    try {
      targets.add(parseTarget(raw));
    } on FormatException catch (e) {
      throw UsageException(e.message);
    }
  }

  final chosenKinds = c(categoryOpt).toSet();
  final wants = <Target, Set<Kind>>{};
  for (final t in targets) {
    final ext = findExtractor(t.platformCode);
    final kinds = t.post != null ? {Kind.posts} : ext.kinds.where(chosenKinds.contains).toSet();
    if (kinds.isNotEmpty) {
      wants[t] = kinds;
    } else {
      Console.log('Skipping @${t.user}: platform ${ext.name} does not offer selected categories.');
    }
  }

  if (wants.isEmpty) {
    throw UsageException('No applicable categories selected for the given targets.');
  }

  final root = resolveTargetDir(c);
  await runLoader(targets: wants, root: root, options: makeOptions(c));
}

Future<void> handleUpdate(Context c) async {
  final root = resolveTargetDir(c);
  final wants = await discoverTargets(root);

  if (wants.isEmpty) {
    Console.log('medialoader: No previous downloads found in database or directory.');
    return;
  }

  await runLoader(targets: wants, root: root, options: makeOptions(c));
}

Future<void> handleStats(Context c) async {
  final root = resolveTargetDir(c);
  final dbPath = await resolveDbPath(root, null);

  if (!await Fs.file(dbPath).exists()) {
    Console.log('No database found at $dbPath');
    return;
  }

  final db = await MediaDb.open(dbPath);
  final stats = db.stats();
  db.close();

  Console.log('MediaLoader Database: $dbPath');
  Console.table(
    [
      ['Tracked Assets', stats.assets.toString()],
      ['Total Storage', stats.totalBytes.size()],
      ['Unique pHashes', stats.uniqueHashes.toString()],
      ['Monitored Targets', stats.users.toString()],
    ],
    header: ['Metric', 'Value'],
  );
}

Future<void> handleFindDuplicate(Context c) async {
  final files = c(Rest<String>('file', ''));
  if (files.isEmpty) {
    throw UsageException('Specify an image file to check.');
  }

  final targetFile = Fs.file(files.first);
  if (!await targetFile.exists()) {
    throw UsageException('File not found: ${targetFile.path}');
  }

  final root = resolveTargetDir(c);
  final dbPath = await resolveDbPath(root, null);
  final db = await MediaDb.open(dbPath);

  final sha256 = await targetFile.sha256();
  String? phash;
  try {
    phash = await (await targetFile.image()).phash();
  } catch (_) {}

  Console.log('Checking ${targetFile.name()}');
  Console.log('  SHA-256: $sha256');
  if (phash != null) Console.log('  pHash:   $phash');

  const threshold = 5;
  final match = db.findDuplicate(
    sha256: sha256,
    phash: phash,
    threshold: threshold,
    excludePath: targetFile.path.replaceAll(r'\', '/'),
  );
  db.close();

  if (match != null) {
    Console.log('  ✓ Duplicate found: $match');
  } else {
    Console.log('  No duplicates found within distance $threshold.');
  }
}

Future<void> handlePrune(Context c) async {
  final root = resolveTargetDir(c);
  final dbPath = await resolveDbPath(root, null);

  if (!await Fs.file(dbPath).exists()) {
    Console.log('No database found at $dbPath');
    return;
  }

  final db = await MediaDb.open(dbPath);
  final rows = db.select('SELECT file_path FROM assets;');
  var pruned = 0;

  for (final row in rows) {
    final filePath = row['file_path'] as String;
    final file = (filePath.contains(':') || filePath.startsWith('/') || filePath.startsWith(r'\'))
        ? Fs.file(filePath)
        : root.file(filePath);
    if (!await file.exists()) {
      db.execute('DELETE FROM assets WHERE file_path = ?;', [filePath]);
      pruned++;
    }
  }

  db.close();
  Console.log('Pruned $pruned missing asset records from database.');
}

Future<void> handleExport(Context c) async {
  final root = resolveTargetDir(c);
  final dbPath = await resolveDbPath(root, null);

  if (!await Fs.file(dbPath).exists()) {
    throw UsageException('No database found at $dbPath');
  }

  final db = await MediaDb.open(dbPath);
  final rows = db.select('SELECT * FROM assets ORDER BY created_at DESC;');
  db.close();

  final format = c(Opt<String>('format', '', or: 'json')).toLowerCase();
  final outPath = c(Opt<String?>('to', ''));

  final String content;
  if (format == 'csv') {
    final headers = ['id', 'platform', 'user', 'category', 'file_path', 'sha256', 'phash', 'file_size', 'status'];
    content = CsvUtils.encodeMaps(rows, columns: headers);
  } else {
    final records = [
      for (final row in rows) {for (final col in row.keys) col: row[col]},
    ];
    content = const JsonEncoder.withIndent('  ').convert(records);
  }

  if (outPath != null) {
    await Fs.file(outPath).write(content);
    Console.log('Exported ${rows.length} records to $outPath');
  } else {
    Console.log(content);
  }
}

/// Execute ingestion run for [targets] saving files into [root].
Future<void> runLoader({
  required Map<Target, Set<Kind>> targets,
  required Dir root,
  required LoaderOptions options,
}) async {
  final sessionDir = Fs.scriptDir();
  final dbPath = await resolveDbPath(root, null);
  final logFile = root.file('.medialoader.log');

  final db = await MediaDb.open(dbPath);
  final engine = IngestionEngine(db: db, options: options, logFile: logFile);
  await engine.migrateLegacyFiles(root);

  // 1. Resolve and authenticate extractors needed for target platforms
  final platformExtractors = <String, Extractor>{};
  final apis = <String, Client>{};

  for (final target in targets.keys) {
    final ext = platformExtractors.putIfAbsent(target.platformCode, () => findExtractor(target.platformCode));
    if (!apis.containsKey(ext.code)) {
      final client = await ext.login(sessionDir);
      if (client == null) {
        apis[ext.code] = ext.client(Cookies());
        Console.log(
          'Note: [${ext.code}] running without login session (.${ext.code}.session in ${sessionDir.path}). Some items may require auth.',
        );
      } else {
        apis[ext.code] = client;
      }
      engine.apis.add(apis[ext.code]!);
    }
  }

  // 2. Launch TUI Dashboard with Ingestion Engine
  try {
    await Dashboard.watch(
      engine: engine,
      db: db,
      work: () async {
        final jobs = <Future<void>>[];

        for (final MapEntry(key: target, value: kinds) in targets.entries) {
          final ext = platformExtractors[target.platformCode]!;
          final api = apis[ext.code]!;
          final platformRoot = root / ext.code;

          final ctx = JobCtx(
            target: target,
            kinds: kinds,
            api: api,
            root: platformRoot,
            options: options,
            db: db,
            engine: engine,
          );

          jobs.add(() async {
            await ctx.init();
            final userState = engine.getOrCreateUser(target.user, target.platformCode);
            try {
              await ext.extract(ctx);
            } catch (e) {
              userState.error = ext.explain(e);
              engine.log('✗ [@${target.user}] ${userState.error}', platform: target.platformCode, failed: true);
            }
          }());
        }

        await Future.wait(jobs);
        await engine.drain();
      },
    );
  } finally {
    await engine.close();
    db.close();
  }
}

/// Discover previously downloaded targets from database or directory structure.
Future<Map<Target, Set<Kind>>> discoverTargets(Dir root, {String? dbPath}) async {
  final out = <Target, Set<Kind>>{};
  final path = dbPath ?? await resolveDbPath(root, null);

  if (await Fs.file(path).exists()) {
    try {
      final db = await MediaDb.open(path);
      final rows = db.select('SELECT platform, user FROM targets;');
      for (final row in rows) {
        final platform = row['platform'] as String;
        final user = row['user'] as String;
        final ext = findExtractor(platform);
        out[Target(platform, user)] = ext.kinds.toSet();
      }
      db.close();
      if (out.isNotEmpty) return out;
    } catch (_) {}
  }

  // Fallback: scan disk folders
  for (final ext in extractors) {
    final pDir = root / ext.code;
    if (!await pDir.exists()) continue;
    for (final entity in await pDir.list()) {
      if (entity is Dir) {
        out[Target(ext.code, entity.name())] = ext.kinds.toSet();
      }
    }
  }

  return out;
}
