// High-throughput, decoupled download and processing engine for MediaLoader.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/utils.dart';
import 'package:dart_toolkit/video.dart';

import 'db.dart';
import 'platforms/facebook.dart';
import 'platforms/instagram.dart';
import 'platforms/twitter.dart';

/// Categories of media content.
enum Kind {
  posts,
  stories,
  highlights,
  photos,
  videos,
  albums,
  profiles;

  static Kind parse(String name) =>
      Kind.values.firstWhere((k) => k.name == name.toLowerCase(), orElse: () => throw FormatException('Unknown category: $name'));
}

/// Download target representation.
final class Target {
  const Target(this.platformCode, this.user, {this.post});

  final String platformCode;
  final String user;
  final String? post;

  @override
  bool operator ==(Object other) =>
      other is Target &&
      other.platformCode == platformCode &&
      other.user.toLowerCase() == user.toLowerCase() &&
      other.post == post;

  @override
  int get hashCode => Object.hash(platformCode, user.toLowerCase(), post);

  @override
  String toString() => '$platformCode:$user${post != null ? '/$post' : ''}';
}

/// Work unit representing a discovered media item.
final class MediaAsset {
  MediaAsset({
    required this.id,
    required this.platform,
    required this.user,
    required this.category,
    required this.to,
    this.url,
    this.text,
    this.at,
    this.sourcePostId,
  });

  final String id;
  final String platform;
  final String user;
  final Kind category;
  final File to;
  final String? url;
  final String? text;
  final DateTime? at;
  final String? sourcePostId;

  int? sizeOnDisk;
  String? sha256;
  String? phash;
}

enum LaneStatus { idle, downloading, transcoding, hashing }

/// Global loader configuration.
typedef LoaderOptions = ({
  bool all,
  bool dry,
  bool compress,
  DateTime? since,
});

/// UI representation of a concurrency lane.
final class WorkerLane {
  WorkerLane(this.id);
  final int id;
  bool busy = false;
  String? platform;
  String? user;
  String? file;
  LaneStatus status = LaneStatus.idle;
  Meter meter = Meter();

  void start({required String platform, required String user, required String file, required LaneStatus status}) {
    this.platform = platform;
    this.user = user;
    this.file = file;
    this.status = status;
    meter = Meter();
    busy = true;
  }

  void release() {
    busy = false;
    platform = null;
    user = null;
    file = null;
    status = LaneStatus.idle;
  }
}

/// Category download progress statistics.
final class CategoryStats {
  CategoryStats(this.name);
  final String name;
  String phase = 'waiting';
  String note = '';
  bool busy = true;
  int queued = 0;
  int added = 0;
  int had = 0;
  int failed = 0;
  int stored = 0;
  final byteMeter = Meter();
  final itemMeter = Meter();

  int get bytes => stored + byteMeter.done();
  int get done => added + had + failed;
  bool get finished => !busy && done >= queued && failed == 0;
  String get counts => '$added new · $had had${failed > 0 ? ' · $failed failed' : ''} · ${bytes.size()}';
}

/// Target state tracking in dashboard.
final class TargetState {
  TargetState(this.name, this.platform);
  final String name;
  final String platform;
  String? id;
  String? error;
  final categories = <String, CategoryStats>{};
  final changes = <String>[];

  CategoryStats category(String name) => categories.putIfAbsent(name, () => CategoryStats(name));

  bool get busy => error == null && categories.values.any((c) => c.busy || c.done < c.queued);
}

typedef FailureEntry = ({String line, Future<void> Function() retry});

/// Context provided to an extractor when discovering media for a target.
final class JobCtx {
  JobCtx({
    required this.target,
    required this.kinds,
    required this.api,
    required this.root,
    required this.options,
    required this.db,
    required this.engine,
  });

  final Target target;
  final Set<Kind> kinds;
  final Client api;
  final Dir root;
  final LoaderOptions options;
  final MediaDb db;
  final IngestionEngine engine;

  String? userId;
  String? userName;
  String? avatarUrl;

  Dir get targetDir => root.dir(Fs.sanitize(userName ?? target.user));
  Dir folder(Kind kind) => targetDir.dir(kind.name);

  bool wants(Kind kind) => kinds.contains(kind);

  void phase(Kind kind, String message, {bool done = false}) {
    engine.updatePhase(target.platformCode, target.user, kind, message, done: done);
  }

  void log(String message, {bool failed = false}) {
    engine.log(message, platform: target.platformCode, failed: failed);
  }

  void changed(String change) {
    engine.recordChange(target.platformCode, target.user, change);
  }

  Future<void> enqueue(List<MediaAsset> assets) => engine.enqueue(assets);

  String? cursor(Kind kind) => db.getCursor(platform: target.platformCode, user: target.user, category: kind);

  void saveCursor(Kind kind, String cursor) {
    if (!options.dry) {
      db.saveCursor(platform: target.platformCode, user: target.user, category: kind, cursor: cursor);
    }
  }

  void profileAsset(String? url, {String? id, String ext = '', String? change}) {
    if (url == null) return;
    id ??= Fs.sanitize(Uri.parse(url).pathSegments.last);
    final dateStr = DateTime.now().format('yyyy-MM-dd');
    final file = folder(Kind.profiles).file('${dateStr}_$id$ext');
    enqueue([
      MediaAsset(
        id: id,
        platform: target.platformCode,
        user: target.user,
        category: Kind.profiles,
        to: file,
        url: url,
        at: DateTime.now(),
      ),
    ]);
    if (change != null) changed(change);
    phase(Kind.profiles, 'profile asset updated', done: true);
  }
}

/// Pluggable media extractor base class.
abstract class Extractor {
  String get code;
  String get name;
  String get site;
  List<Kind> get kinds;

  bool matches(String input);
  Target parse(String input);

  Set<String> get loginCookies;
  Client client(Cookies jar);

  Future<void> extract(JobCtx ctx);

  Future<String?> refreshUrl(String assetId, String originalUrl) async => null;

  Future<Client?> login(Dir sessionDir) async {
    final jar = await sessionDir.file('.$code.session').cookies(or: Cookies());
    return loginCookies.any((c) => jar[c] != null) ? client(jar) : null;
  }

  Rate rate(int calls, Duration per, {Duration pause = const Duration(seconds: 2)}) =>
      Rate(calls, per, pause: pause);

  String explain(Object error) => switch (error) {
    HttpStatusException(status: 404, :final url) => 'not found: $url',
    HttpStatusException(status: final status && (401 || 403), :final url) =>
      '$name refused (HTTP $status): login in session may have expired ($url)',
    HttpStatusException(status: 429, :final url) => '$name rate limit (HTTP 429): please wait ($url)',
    SessionException(:final url) => '$name session expired: update session file ($url)',
    _ => error.toString(),
  };
}

/// Extractor registry.
final List<Extractor> extractors = [InstagramExtractor(), TwitterExtractor(), FacebookExtractor()];

/// Resolve the extractor responsible for [input] (handle, URL, or platform code).
Extractor findExtractor(String input) {
  final s = input.trim().toLowerCase();
  for (final ext in extractors) {
    if (ext.code == s) return ext;
  }
  for (final ext in extractors) {
    if (s.startsWith('${ext.code}:')) return ext;
  }
  for (final ext in extractors) {
    if (ext.matches(input.trim())) return ext;
  }
  throw FormatException(
    'Could not detect platform for "$input". Supported platform prefixes: ${extractors.map((e) => '${e.code}:').join(', ')}',
  );
}

/// Resolve the [Target] from an arbitrary input string or URL.
Target parseTarget(String input) {
  final s = input.trim();
  for (final ext in extractors) {
    if (s.toLowerCase().startsWith('${ext.code}:')) {
      return ext.parse(s);
    }
  }
  for (final ext in extractors) {
    if (ext.matches(s)) {
      return ext.parse(s);
    }
  }
  throw FormatException(
    'Could not detect platform for "$input". Please prefix with platform code (e.g. ins:$input, twt:$input, fbk:$input) or provide a full URL.',
  );
}

/// Decoupled download and transcoding ingestion engine.
final class IngestionEngine {
  IngestionEngine({
    required this.db,
    required this.options,
    File? logFile,
    int downloadLanes = 8,
    int transcodeLanes = 2,
  }) : logFile = logFile ?? Fs.scriptDir().dir('downloads').file('medialoader.log'),
       _downloadPool = Pool(limit: downloadLanes),
       _transcodePool = Pool(limit: transcodeLanes) {
    _idleLanes.addAll(lanes);
  }

  final MediaDb db;
  final LoaderOptions options;
  final File logFile;

  io.IOSink? _sink;
  io.IOSink get _logSink {
    if (_sink != null) return _sink!;
    final f = io.File(logFile.path);
    if (!f.parent.existsSync()) {
      f.parent.createSync(recursive: true);
    }
    return _sink = f.openWrite(mode: io.FileMode.append);
  }

  // Resumable HTTP client ensures partially downloaded .part files resume upon restart
  final Client cdn = Http.client(resume: true);

  final Pool _downloadPool;
  final Pool _transcodePool;

  final started = DateTime.now();
  final users = <TargetState>[];
  final apis = <Client>[];
  final overallByteMeter = Meter();
  final overallItemMeter = Meter();
  final allUsersMeter = Meter();

  final lanes = List.generate(8, (i) => WorkerLane(i + 1));
  final _idleLanes = <WorkerLane>[];

  final failures = <FailureEntry>[];
  var activeDownloads = 0;
  var activeTranscodes = 0;
  var deduplicatedCount = 0;
  var done = false;
  var retrying = 0;

  final _activeTasks = <Future<void>>{};
  static const _maxInFlight = 32;

  bool get finished => done && retrying == 0;
  int get requests => apis.fold(0, (n, c) => n + c.sent());

  TargetState getOrCreateUser(String name, String platform) {
    for (final u in users) {
      if (u.name == name && u.platform == platform) return u;
    }
    final u = TargetState(name, platform);
    users.add(u);
    return u;
  }

  void updatePhase(String platform, String user, Kind kind, String phase, {bool done = false}) {
    final u = getOrCreateUser(user, platform);
    final cat = u.categories.putIfAbsent(kind.name, () => CategoryStats(kind.name));
    if (done) {
      cat.note = phase;
      cat.busy = false;
    } else {
      cat.phase = phase;
      cat.busy = true;
    }
  }

  void recordChange(String platform, String user, String change) {
    final u = getOrCreateUser(user, platform);
    u.changes.add(change);
    log('[@$user] changed: $change', platform: platform);
  }

  void log(String line, {String? platform, bool failed = false}) {
    final tag = platform != null ? '[$platform] ' : '';
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final mark = failed ? '✗ ' : '';
    _logSink.writeln('$timeStr  $mark$tag$line');
  }

  WorkerLane _acquireLane(String platform, String user, String file, LaneStatus status) {
    final lane = _idleLanes.isNotEmpty ? _idleLanes.removeAt(0) : lanes.firstWhere((l) => !l.busy, orElse: () => lanes.first);
    lane.start(platform: platform, user: user, file: file, status: status);
    return lane;
  }

  void _releaseLane(WorkerLane lane) {
    lane.release();
    if (!_idleLanes.contains(lane)) _idleLanes.add(lane);
  }

  Future<void> enqueue(List<MediaAsset> assets) async {
    for (final a in assets) {
      while (_activeTasks.length >= _maxInFlight) {
        await Future.any(_activeTasks);
      }
      late final Future<void> fut;
      fut = _processAsset(a).whenComplete(() {
        _activeTasks.remove(fut);
      });
      _activeTasks.add(fut);
    }
  }

  Future<void> _processAsset(MediaAsset a) async {
    final relPath = a.to.path.replaceAll(r'\', '/');
    final u = getOrCreateUser(a.user, a.platform);
    final cat = u.categories.putIfAbsent(a.category.name, () => CategoryStats(a.category.name));
    cat.queued++;

    // 1. Check if older than since filter
    if (options.since != null && a.at != null && a.at!.isBefore(options.since!)) {
      cat.had++;
      return;
    }

    // 2. Check if already exists in DB or on disk (Clean Restart Guarantee)
    if (db.hasFile(relPath) || await a.to.exists()) {
      cat.had++;
      return;
    }

    if (options.dry) {
      log('[@${a.user}] would save ${a.to.name()}', platform: a.platform);
      cat.added++;
      return;
    }

    // 2. Download Phase (Network Pool with Resumable Transfers)
    final gotMeter = Meter();
    WorkerLane? lane;
    try {
      await _downloadPool.run(() async {
        activeDownloads++;
        lane = _acquireLane(a.platform, a.user, a.to.name(), LaneStatus.downloading);
        try {
          if (a.text case final text?) {
            await (Reader.of(utf8.encode(text)) & cat.byteMeter & gotMeter & lane!.meter > a.to);
          } else if (a.url case final url?) {
            await (cdn.get(url) & overallByteMeter & cat.byteMeter & gotMeter & lane!.meter > a.to);
          }
          if (a.at case final at?) await a.to.touch(at);
        } finally {
          _releaseLane(lane!);
          lane = null;
          activeDownloads--;
        }
      });
    } catch (e) {
      cat.stored -= gotMeter.done();
      if (e is InterruptedException) rethrow;
      cat.failed++;
      failures.add((
        line: '✗ [@${a.user}] ${a.to.name()}: $e',
        retry: () async {
          cat.failed--;
          cat.queued--;
          await _processAsset(a);
        },
      ));
      log('✗ [@${a.user}] ${a.to.name()}: $e', platform: a.platform, failed: true);
      return;
    }

    // 3. Post-Download: Hashing, Deduplication & Recording
    cat.added++;
    a.sizeOnDisk = await a.to.size();

    try {
      final h = HashUtils.sha256();
      await (a.to > h);
      a.sha256 = h.hex();
    } catch (_) {}

    final ext = a.to.name().split('.').last.toLowerCase();
    final isImage = const {'jpg', 'jpeg', 'png', 'webp'}.contains(ext);
    final isVideo = const {'mp4', 'mov', 'webm', 'mkv'}.contains(ext);

    if (isImage) {
      try {
        final img = await a.to.image();
        a.phash = await img.phash();
      } catch (_) {}
    }

    final duplicatePath = db.findDuplicate(sha256: a.sha256, phash: a.phash);
    if (duplicatePath != null && duplicatePath != relPath) {
      deduplicatedCount++;
      log('dedupe: ${a.to.name()} matches $duplicatePath', platform: a.platform);
    }

    db.recordAsset(
      id: a.id,
      platform: a.platform,
      user: a.user,
      category: a.category,
      filePath: relPath,
      postId: a.sourcePostId,
      url: a.url,
      sha256: a.sha256,
      phash: a.phash,
      fileSize: a.sizeOnDisk,
    );

    // 4. Transcoding Phase (CPU Pool, Bounded)
    if (options.compress) {
      final quality = isVideo ? 80 : 85;
      await _transcodePool.run(() async {
        activeTranscodes++;
        final transcodeLane = _acquireLane(a.platform, a.user, a.to.name(), LaneStatus.transcoding);
        try {
          final comp = await _compress(a.to.path, isVideo, quality, transcodeLane);
          log('[@${a.user}] ${a.to.name()}  $comp', platform: a.platform);
        } finally {
          _releaseLane(transcodeLane);
          activeTranscodes--;
        }
      });
    }
  }

  Future<String> _compress(String path, bool isVideo, int quality, WorkerLane lane) async {
    final size = (await Fs.file(path).size()).size();
    try {
      final c = isVideo
          ? await (Video.compress(path, quality: quality) & lane.meter)
          : await (Image.compress(path, quality: quality) & lane.meter);
      return c is Compressed ? c.text() : '$size (${c.text()})';
    } catch (e) {
      return '$size (compress skipped: $e)';
    }
  }

  Future<void> retryAll() async {
    if (failures.isEmpty) return;
    final toRetry = List<FailureEntry>.from(failures);
    failures.clear();
    retrying = toRetry.length;
    for (final f in toRetry) {
      try {
        await f.retry();
      } catch (_) {} finally {
        retrying--;
      }
    }
  }

  Future<void> drain() async {
    while (_activeTasks.isNotEmpty) {
      await Future.wait(_activeTasks.toList());
    }
  }

  Future<void> close() async {
    await cdn.close();
    for (final a in apis) {
      await a.close();
    }
    if (_sink != null) {
      await _sink!.flush();
      await _sink!.close();
      _sink = null;
    }
  }
}
