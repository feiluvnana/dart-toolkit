// Downloads a profile's media.
// Import with `as download`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/video.dart';

import 'dashboard.dart';
import 'media.dart' as media;
import 'platform.dart';

typedef Results = List<Outcome<media.Download, bool>>;

// Common CDN client for streaming images and videos.
const agent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
final cdn = Http.client(headers: {'user-agent': agent}, retries: 3, resume: true);

// Downloads [categories] of every target user into [root]/<user>/, all at once: each
// user's explorers run concurrently and feed one queue that downloads 8 files
// at a time, reporting into the dashboard. Returns the new files.
Future<int> run(
  List<Target> targets,
  Set<String> categories,
  Dir root, {
  bool all = false,
  bool reset = false,
  int? imageQuality,
  int? videoQuality,
}) {
  final wants = <Target, Set<String>>{};
  final isAll = categories.contains('all') || categories.isEmpty;
  for (final t in targets) {
    final supported = {for (final c in t.platform.categories) c.name};
    final matched = <String>{
      for (final c in t.platform.categories)
        if (categories.any(c.matches)) c.name,
    };
    final chosen = isAll ? supported : matched;
    wants[t] = chosen;
  }
  if (!isAll && wants.values.every((v) => v.isEmpty)) {
    throw UsageException(
      'None of the targets support category "${categories.join(', ')}". '
      'Supported categories: ${targets.map((t) => '${t.platform.code} (${t.platform.categories.map((c) => c.name).join(', ')})').toSet().join('; ')}',
    );
  }
  return runEach(
    wants,
    root,
    all: all,
    reset: reset,
    imageQuality: imageQuality,
    videoQuality: videoQuality,
  );
}

// Downloads each target with its own [categories] into [root]/<platform>/<user>/, all at once:
// every user's explorers run concurrently and feed one queue that downloads
// 8 files at a time. Returns the new files.
Future<int> runEach(
  Map<Target, Set<String>> wants,
  Dir root, {
  bool all = false,
  bool reset = false,
  int? imageQuality,
  int? videoQuality,
}) async {
  if (reset) {
    for (final MapEntry(:key, :value) in wants.entries) {
      final userDir = root.dir(key.platform.code).dir(Fs.sanitize(key.user.toLowerCase()));
      await wipe(userDir, key.platform, value);
    }
  }

  // Pre-authenticate sessions for platforms involved in this run; always force login
  final apis = <String, Client?>{};
  for (final target in wants.keys) {
    if (!apis.containsKey(target.platform.code)) {
      final client = await target.platform.login();
      if (client == null) {
        throw UsageException(
          '${target.platform.name} downloads require a login session: export cookies into .${target.platform.code}.session.',
        );
      }
      apis[target.platform.code] = client;
    }
  }

  try {
    final q = Queue(imageQuality: imageQuality, videoQuality: videoQuality);
    final added = await Future.wait([
      for (final MapEntry(:key, :value) in wants.entries)
        user(key, value, apis[key.platform.code], root.dir(key.platform.code), q, all: all),
    ]);
    return added.fold<int>(0, (a, b) => a + b);
  } finally {
    for (final MapEntry(:key, :value) in apis.entries) {
      final p = platforms.firstWhere((p) => p.code == key);
      await p.close(value);
    }
    await cdn.close();
  }
}

// Every user downloaded into [root] before, discovered via their .<code >.json
// index and existing category folders in [root]/<platform>/<user>/.
Future<Map<Target, Set<String>>> discover(Dir root) async {
  final out = <Target, Set<String>>{};
  if (!await root.exists()) return out;
  for (final p in platforms) {
    final platformDir = root.dir(p.code);
    if (!await platformDir.exists()) continue;
    for (final e in await platformDir.list()) {
      if (e is! Dir) continue;
      if (!await e.file('.${p.code}.json').exists()) continue;
      final cats = <String>{
        for (final c in p.categories)
          if (await e.dir(c.folder).exists() || (c.name == 'tweet' && await e.dir('posts').exists())) c.name,
      };
      if (cats.isEmpty) {
        board.note('@${e.name()} (${p.code}) has nothing downloaded yet, skipped', platform: p.code);
        continue;
      }
      out[Target(p, e.name())] = cats;
    }
  }
  return out;
}

// Downloads one user; returns the new files.
// A user that fails is reported and retried on 'r'.
Future<int> user(
  Target target,
  Set<String> categories,
  Client? api,
  Dir root,
  Queue q, {
  required bool all,
}) async {
  if (categories.isEmpty) {
    board.note('@${target.user} (${target.platform.code}) has no matching categories, skipped', platform: target.platform.code);
    return 0;
  }
  final u = board.user(target.user, platform: target.platform.code);
  Future<int> attempt() async {
    try {
      return await _user(target, u, categories, api, root, q, all: all);
    } catch (e) {
      u.error = '${target.platform.explain(e)}';
      board.fail('✗ @${u.name}: ${u.error}', () async {
        u
          ..error = null
          ..parts.clear()
          ..changes.clear();
        await attempt();
      }, platform: target.platform.code);
      return 0;
    }
  }

  return attempt();
}

Future<int> _user(
  Target target,
  User u,
  Set<String> categories,
  Client? api,
  Dir root,
  Queue q, {
  required bool all,
}) async {
  final p = target.platform;
  final dir = root.dir(Fs.sanitize(u.name));
  final index = await Index.load(dir, p.code);
  final batches = <Future<Results>>[];
  await index.save();

  for (final c in p.categories) {
    if (categories.contains(c.name)) u.parts[c.folder] = Part(c.folder);
  }
  await Future.wait([
    for (final c in p.categories)
      if (categories.contains(c.name))
        () async {
          final stats = await folderStats(dir.dir(c.folder));
          final part = u.parts[c.folder];
          if (part != null) {
            part.had = stats.files;
            part.queued = stats.files;
            part.bytes = stats.bytes;
          }
        }(),
  ]);

  void changed(String change) {
    u.changes.add(change);
    board.note('@${u.name} changed: $change', platform: p.code);
  }

  void phase(List<Part> parts, String what, {bool done = false}) {
    for (final part in parts) {
      done ? part.note = what : part.phase = what;
      part.busy = !done;
    }
  }

  try {
    await p.exploreUser(
      u: u,
      categories: categories,
      api: api,
      userDir: dir,
      index: index,
      queue: q,
      all: all,
      batches: batches,
      phase: phase,
      changed: changed,
    );
  } finally {
    await Future.wait(batches);
    await index.save();
  }
  final results = [for (final b in await Future.wait(batches)) ...b];
  if (u.changes.isNotEmpty) Console.notify('medialoader: @${u.name} changed: ${u.changes.join('; ')}');
  return results.values().where((isNew) => isNew).length;
}

// What the runs saw, to tell what changed (.<code >.json): when every post was
// last listed, the newest post, every post/tweet ever seen with its item ids in
// file-number order, the posts hidden/deleted now, every story and
// profile picture seen, and each highlight's items.
class Index {
  Index(this.file, Json j)
    : checked = DateTime.fromMillisecondsSinceEpoch(j.$('checked').or(0)),
      newest = j.$('newest').or(0),
      posts = {
        for (final MapEntry(:key, :value) in j.$('posts').asMap<Object?>().entries)
          key: [for (final id in Json.of(value)) id.or('')],
        for (final code in j.$('codes')) code.or(''): <String>[],
      },
      hidden = {for (final c in j.$('hidden')) c.or('')},
      stories = {for (final MapEntry(:key, :value) in j.$('stories').asMap<Object?>().entries) key: value as int},
      profiles = {for (final MapEntry(:key, :value) in j.$('profiles').asMap<Object?>().entries) key: '$value'},
      highlights = {
        for (final MapEntry(:key, :value) in j.$('highlights').asMap<Object?>().entries)
          key: {for (final id in Json.of(value)) id.or('')},
      };

  final File file;
  DateTime checked;
  int newest;
  Map<String, List<String>> posts;
  Set<String> hidden;
  Map<String, int> stories;
  Map<String, String> profiles;
  Map<String, Set<String>> highlights;

  static Future<Index> load(Dir dir, String platformCode) async {
    final file = dir.file('.$platformCode.json');
    return Index(file, Json.parse(await file.text(or: '{}')));
  }

  Future<void> _saving = Future.value();

  Future<void> save() => _saving = _saving.then((_) => _write(), onError: (_) => _write());

  Future<void> _write() => file.write(
    Json.encode({
      'checked': checked.millisecondsSinceEpoch,
      'newest': newest,
      'posts': posts,
      'hidden': [...hidden],
      'stories': stories,
      'profiles': profiles,
      'highlights': {
        for (final e in highlights.entries) e.key: [...e.value],
      },
    }),
  );
}

// Deletes [categories]' folders in [dir] after asking, so they download again.
// The index stays, so album/carousel numbers stay stable.
Future<void> wipe(Dir dir, Platform platform, Set<String> categories) async {
  final folders = [
    for (final c in platform.categories)
      if (categories.contains(c.name) && await dir.dir(c.folder).exists()) c.folder,
  ];
  if (folders.isEmpty) return;
  final question =
      'Delete ${folders.join(', ')} of @${dir.name()} and download again? '
      'Removed posts and expired stories cannot be downloaded back.';
  if (!await Console.confirm(question)) throw Exception('--reset cancelled, nothing deleted.');
  for (final folder in folders) {
    await dir.dir(folder).delete();
  }
  for (final cursor in await dir.list(match: '.${platform.code}-cursor-*')) {
    await cursor.delete();
  }
}

// One download queue for every explorer: whatever is added downloads as soon
// as one of the 8 lanes is free. add() completes when that batch is done.
class Queue {
  Queue({this.imageQuality, this.videoQuality});

  final int? imageQuality;
  final int? videoQuality;
  var _free = 8;
  final _waiting = ListQueue<Completer<void>>();

  Future<Results> add(User u, Dir dir, List<media.Download> files) async {
    Part part(media.Download f) {
      final key = f.to.path(from: dir).split('/').first;
      return u.parts.putIfAbsent(key, () => Part(key));
    }
    await Future.wait(files.map((f) async {
      if (!await f.to.exists()) {
        try {
          final old = f.to.parent().parent().file(f.to.name());
          if (await old.exists()) return;
        } catch (_) {}
        part(f).queued++;
      }
    }));
    Future<void> retry(media.Download f) async {
      part(f)
        ..failed -= 1
        ..queued -= 1;
      await add(u, dir, [f]);
    }

    return Pool.settle(
      files,
      (f) => _lane(u, part(f), f.to.path(from: dir), f, () => retry(f)),
      limit: max(files.length, 1),
    );
  }

  Future<bool> _lane(User u, Part part, String path, media.Download f, Future<void> Function() retry) async {
    if (_free > 0) {
      _free--;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    try {
      final isNew = await save(f, Transfer(u, part, path));
      if (isNew) part.added++;
      return isNew;
    } catch (e) {
      part.failed++;
      board.fail('✗ @${u.name} $path: $e', retry, platform: u.platform);
      rethrow;
    } finally {
      _waiting.isEmpty ? _free++ : _waiting.removeFirst().complete();
    }
  }

  Future<bool> save(media.Download f, Transfer t) async {
    if (await f.to.exists()) return false;
    final old = f.to.parent().parent().file(f.to.name());
    if (await old.exists()) {
      await old.move(f.to.path());
      return false;
    }
    if (f.text case final text?) {
      await f.to.write(text);
      t.part.bytes += utf8.encode(text).length;
      return true;
    }
    board.transfers.add(t);
    var originalSize = 0;
    try {
      await (cdn.get(f.url!) | Pipe.tap(t.update) > f.to);
      originalSize = t.done;
      if (imageQuality != null || videoQuality != null) {
        t.status = 'compressing';
        await _compress(f.to, t);
      }
    } finally {
      t.status = null;
      board.transfers.remove(t);
    }
    if (originalSize > 0 && t.done < originalSize) {
      final saved = originalSize - t.done;
      final pct = (saved * 100 / originalSize).round();
      board.note(
        '@${t.user.name} ${t.path}  ${size(t.done)} (compressed from ${size(originalSize)}, -$pct%)',
        platform: t.user.platform,
      );
    } else {
      board.note('@${t.user.name} ${t.path}  ${size(t.done)}', platform: t.user.platform);
    }
    return true;
  }

  Future<void> _compress(File file, Transfer t) async {
    try {
      final bytes = await file.bytes();
      if (bytes.isEmpty) return;

      final sniffedImg = Image.sniff(bytes);
      final ext = file.name().contains('.') ? file.name().split('.').last.toLowerCase() : '';
      final isImage = sniffedImg != null ||
          const {'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'tiff', 'ico'}.contains(ext);

      if (isImage && imageQuality != null) {
        final img = Image.decode(bytes);
        final ImageFormat targetFormat;
        if (ext == 'jpg' || ext == 'jpeg') {
          targetFormat = ImageFormat.jpg;
        } else if (ext == 'png') {
          targetFormat = ImageFormat.png;
        } else if (sniffedImg == ImageFormat.webp || sniffedImg == null) {
          targetFormat = ImageFormat.jpg;
        } else {
          targetFormat = sniffedImg;
        }
        await (img.encode(targetFormat, quality: imageQuality!) > file);
        final newSize = await file.size();
        final delta = newSize - t.done;
        t.done = newSize;
        t.part.bytes += delta;
        board.count(delta);
        return;
      }

      final sniffedVid = Video.sniff(bytes);
      final isVideo = sniffedVid != null || const {'mp4', 'webm', 'mkv', 'mov', 'avi'}.contains(ext);
      if (isVideo && videoQuality != null) {
        final video = await Video.decode(bytes);
        final VideoFormat targetFormat;
        if (ext == 'mp4') {
          targetFormat = VideoFormat.mp4;
        } else if (ext == 'webm') {
          targetFormat = VideoFormat.webm;
        } else if (ext == 'mov') {
          targetFormat = VideoFormat.mov;
        } else if (ext == 'mkv') {
          targetFormat = VideoFormat.mkv;
        } else if (ext == 'avi') {
          targetFormat = VideoFormat.avi;
        } else {
          targetFormat = sniffedVid ?? VideoFormat.mp4;
        }
        await (video.encode(targetFormat, quality: videoQuality!) > file);
        final newSize = await file.size();
        final delta = newSize - t.done;
        t.done = newSize;
        t.part.bytes += delta;
        board.count(delta);
        return;
      }
    } catch (e) {
      board.note('@${t.user.name} ${t.path} compression skipped: $e', platform: t.user.platform);
    }
  }
}

// Total file count and bytes of all non-temporary files in [dir].
Future<({int files, int bytes})> folderStats(Dir dir) async {
  if (!await dir.exists()) return (files: 0, bytes: 0);
  var files = 0, bytes = 0;
  try {
    await for (final entity in io.Directory(dir.path()).list(recursive: true, followLinks: false)) {
      if (entity is io.File) {
        final name = entity.path.split(RegExp(r'[/\\]')).last;
        if (name.startsWith('.') || name.endsWith('.tmp')) continue;
        files++;
        try {
          bytes += await entity.length();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return (files: files, bytes: bytes);
}

// "12 posts, 2024-05-01 to 2024-04-18"
String dates(List<Json> posts) {
  if (posts.isEmpty) return 'no posts';
  final (first, last) = (media.day(posts.first), media.day(posts.last));
  return '${posts.length} posts, ${first == last ? first : '$first to $last'}';
}
