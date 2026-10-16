// Downloads profiles' media into downloads/<platform>/<user>/.
// Import with `as download`.
library;

import 'dart:convert';
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
import 'media.dart';
import 'platform.dart';

typedef Options = ({bool all, bool reset, bool dry, DateTime? since, int? image, int? video});
typedef Results = List<Outcome<Download, bool>>;

/// One page of a feed and the cursor of the next.
typedef Page = ({List<Json> items, String? next});

// Images and videos come from the CDNs: no rate limit, retries, resumes.
final cdn = Http.client(retries: 3, resume: true);

// Downloads each target's categories into [root]/<platform>/<user>/, all at
// once: every user's explorers feed one queue that downloads 8 files at a
// time. Asks, logs in and refuses before the dashboard opens.
Future<void> run(Map<Target, Set<String>> wants, Dir root, Options o) async {
  final apis = <Platform, Client>{};
  for (final p in {for (final t in wants.keys) t.platform}) {
    apis[p] = await p.login() ??
        (throw UsageException(
          '${p.name} downloads need a login: export ${p.site} cookies (and a "user-agent: …" line) '
          'into .${p.code}.session next to medialoader.dart.',
        ));
  }
  if (o.reset) {
    for (final MapEntry(key: t, value: cats) in wants.entries) {
      await wipe(root.dir(t.platform.code).dir(Fs.sanitize(t.user)), t.platform, cats, dry: o.dry);
    }
  }
  board.apis.addAll(apis.values);
  final q = Queue(o);
  await watch(
    () async {
      final added = await Future.wait([
        for (final MapEntry(key: t, value: cats) in wants.entries)
          Job(t, cats, apis[t.platform]!, root.dir(t.platform.code), q).run(),
      ]);
      Console.notify('medialoader: ${o.dry ? 'dry run' : 'done'}, ${added.fold(0, (a, b) => a + b)} new files');
    },
    close: () => Future.wait([for (final c in [...board.apis, cdn]) c.close()]),
  );
}

// Every user downloaded into [root] before (it has a .<code>.json), with the
// categories it has folders for.
Future<Map<Target, Set<String>>> discover(Dir root) async {
  final out = <Target, Set<String>>{};
  for (final p in platforms) {
    if (!await root.dir(p.code).exists()) continue;
    for (final d in await root.dir(p.code).list()) {
      if (d is! Dir || !await d.file('.${p.code}.json').exists()) continue;
      out[Target(p, d.name())] = {
        for (final c in p.categories)
          if (await d.dir(c.folder).exists()) c.name,
      };
    }
  }
  return out;
}

// Deletes [categories]' folders and cursors in [dir] after asking, so they
// download again. The index stays, so carousel numbers stay stable.
Future<void> wipe(Dir dir, Platform platform, Set<String> categories, {bool dry = false}) async {
  final folders = [
    for (final c in platform.categories)
      if (categories.contains(c.name) && await dir.dir(c.folder).exists()) c.folder,
  ];
  if (folders.isEmpty) return;
  if (dry) return Console.log('dry run: --reset would delete ${folders.join(', ')} of @${dir.name()}');
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

// One user's download: what its explorers share. A failed one is reported
// and retried on r.
final class Job {
  Job(this.target, this.cats, this.api, this.root, this.queue);
  final Target target;
  final Set<String> cats;
  final Client api;
  final Dir root;
  final Queue queue;
  late final u = board.user(target.user, platform: code);
  final batches = <Future<Results>>[];
  Dir? _dir;
  Index? _index;

  String get code => target.platform.code;
  Options get o => queue.o;
  Dir get dir => _dir!;
  Index get index => _index!;

  // Who this is, once the platform looked it up: its folder, index, and what
  // is on disk. Without [track] (one post) the index is read, never written.
  Future<void> open(String name, {String? id, bool track = true}) async {
    u
      ..name = name
      ..id = id ?? name;
    _dir = root.dir(Fs.sanitize(name));
    _index = await Index.load(dir, code, dry: o.dry || !track);
    final parts = [
      for (final c in target.platform.categories)
        if (cats.contains(c.name)) u.parts[c.folder] = Part(c.folder),
    ];
    await Future.wait([
      for (final p in parts)
        dir.dir(p.name).size().then((s) => p
          ..had = s.files
          ..queued = s.files
          ..bytes = s.bytes),
    ]);
  }

  bool wants(String category) => cats.contains(category);

  Part? part(String folder) => u.parts[folder];

  void phase(Part? p, String what, {bool done = false}) {
    if (p == null) return;
    done ? p.note = what : p.phase = what;
    p.busy = !done;
  }

  void log(Part? p, String line) {
    phase(p, line);
    board.note('@${u.name} ${p?.name}: $line', platform: code);
  }

  void changed(String change) {
    u.changes.add(change);
    board.note('@${u.name} changed: $change', platform: code);
  }

  // Whether something posted [at] is wanted (--since).
  bool keep(DateTime at) => o.since == null || !at.isBefore(o.since!);

  // A client for this job on its own [rate], counted and closed with the run.
  Client client(Rate rate) {
    final c = api.copy(rate: rate);
    board.apis.add(c);
    return c;
  }

  // A profile picture's first-seen day, its file-name prefix; [change] is noted when it is new.
  String seen(String id, String change) => index.profiles[id] ??= () {
    if (index.profiles.isNotEmpty) changed(change);
    return DateTime.now().format('yyyy-MM-dd');
  }();

  // Where a listing stopped: .<code>-cursor-<name>.
  File cursor(String name) => dir.file('.$code-cursor-$name');

  Future<Results> add(List<Download> files) {
    final batch = queue.add(this, files);
    batches.add(batch);
    return batch;
  }

  // Returns the new files.
  Future<int> run() async {
    if (cats.isEmpty) {
      board.note('@${target.user} has no matching categories, skipped', platform: code);
      return 0;
    }
    u.id = null; // on the board: looking up
    try {
      await target.platform.explore(this);
    } catch (e) {
      u.error = '${target.platform.explain(e)}';
      board.fail('✗ @${u.name}: ${u.error}', () async {
        u
          ..error = null
          ..parts.clear()
          ..changes.clear();
        batches.clear();
        await run();
      }, platform: code);
      return 0;
    } finally {
      await Future.wait(batches);
      await _index?.save();
    }
    if (u.changes.isNotEmpty) Console.notify('medialoader: @${u.name} changed: ${u.changes.join('; ')}');
    return [for (final b in await Future.wait(batches)) ...b].values().where((isNew) => isNew).length;
  }
}

// What the runs saw, to tell what changed (.<code>.json): when every post was
// last listed, the newest post, every post ever seen with its item ids in
// file-number order, the posts hidden/deleted now, every story and profile
// picture seen, and each highlight's items.
final class Index {
  Index(this.file, Json j, {this.dry = false})
    : checked = DateTime.fromMillisecondsSinceEpoch(j.$('checked').or(0)),
      newest = j.$('newest').or(0),
      posts = {
        for (final MapEntry(:key, :value) in j.$('posts').asMap<Json>().entries) key: value.asList<String>(),
        for (final code in j.$('codes')) code.or(''): <String>[], // the format before item ids
      },
      hidden = {...j.$('hidden').asList<String>()},
      stories = j.$('stories').asMap<int>(),
      profiles = j.$('profiles').asMap<String>(),
      highlights = {
        for (final MapEntry(:key, :value) in j.$('highlights').asMap<Json>().entries) key: {...value.asList<String>()},
      };

  final File file;
  final bool dry; // --dry-run: never written
  DateTime checked;
  int newest;
  Map<String, List<String>> posts;
  Set<String> hidden;
  Map<String, int> stories;
  Map<String, String> profiles;
  Map<String, Set<String>> highlights;

  static Future<Index> load(Dir dir, String code, {bool dry = false}) async {
    final file = dir.file('.$code.json');
    return Index(file, await file.json(or: Json.of({})), dry: dry);
  }

  Future<void> _saving = Future.value();

  Future<void> save() => dry ? _saving : _saving = _saving.then((_) => _write(), onError: (_) => _write());

  Future<void> _write() => file.write(
    Json.encode({
      'checked': checked.millisecondsSinceEpoch,
      'newest': newest,
      'posts': posts,
      'hidden': [...hidden],
      'stories': stories,
      'profiles': profiles,
      'highlights': {for (final e in highlights.entries) e.key: [...e.value]},
    }),
  );

}

// One download queue for every explorer: whatever is added downloads as soon
// as one of the 8 lanes is free. add() completes when that batch is done.
final class Queue {
  Queue(this.o);
  final Options o;
  final _lanes = Pool(limit: 8);

  Future<Results> add(Job j, List<Download> files) async {
    final missing = await Future.wait([for (final f in files) f.to.exists().then((e) => !e)]);
    for (final (i, f) in files.indexed) {
      if (missing[i]) _part(j, f).queued++;
    }
    return Pool.settle(files, (f) => _get(j, f), limit: max(files.length, 1));
  }

  Part _part(Job j, Download f) {
    final key = f.to.path(from: j.dir).split('/').first;
    return j.u.parts.putIfAbsent(key, () => Part(key));
  }

  Future<bool> _get(Job j, Download f) async {
    final part = _part(j, f), t = Transfer(j.u, part, f.to.path(from: j.dir));
    try {
      final isNew = await save(j, f, t);
      if (isNew) part.added++;
      return isNew;
    } catch (e) {
      part
        ..failed += 1
        ..bytes -= t.done;
      board.fail('✗ @${j.u.name} ${t.path}: $e', () async {
        part
          ..failed -= 1
          ..queued -= 1;
        await add(j, [f]);
      }, platform: j.code);
      rethrow;
    }
  }

  // Fetches (or writes) one file unless it is there; true when new.
  Future<bool> save(Job j, Download f, Transfer t) async {
    if (await f.to.exists()) return false;
    if (o.dry) {
      board.note('@${j.u.name} would save ${t.path}', platform: j.code);
      return true;
    }
    if (f.text case final text?) {
      await f.to.write(text);
      t.part.bytes += utf8.encode(text).length;
    } else {
      var how = '';
      try {
        await _lanes.run(() {
          board.transfers.add(t);
          return cdn.get(f.url!, headers: {'referer': '${j.target.platform.site}/'}) | board.speed | Pipe.tap(t.update) > f.to;
        });
        how = await _compress(f.to, t);
      } finally {
        board.transfers.remove(t);
      }
      board.note('@${j.u.name} ${t.path}  ${t.done.size()}$how', platform: j.code);
    }
    if (f.at case final at?) await f.to.touch(at);
    return true;
  }

  // Re-encodes [file] at --image-quality/--video-quality; says how it went.
  Future<String> _compress(File file, Transfer t) async {
    final video = const {'mp4', 'mov', 'webm', 'mkv'}.contains(file.path().split('.').last.toLowerCase());
    final quality = video ? o.video : o.image;
    if (quality == null) return '';
    t.status = 'compressing';
    try {
      final r = video
          ? await Video.compress(file.path(), quality: quality)
          : await Image.compress(file.path(), quality: quality);
      if (r == null) return ' (kept: compressing would not make it smaller)';
      final (before, after) = r;
      t.part.bytes += after - before;
      return ' (compressed from ${before.size()}, -${((before - after) * 100 / before).round()}%)';
    } on ToolkitException catch (e) {
      return ' (not compressed: ${e.message})';
    } finally {
      t.status = null;
    }
  }
}

// Lists a newest-first feed (Instagram posts, tweets) into [folder]: only
// what is newer than the files on disk, unless it is the first run, the
// weekly full check, or --all; continues where an interrupted run stopped
// (a cursor saved once each page's files are down); reports edited, hidden
// and reappearing posts.
Future<void> feed(
  Job j, {
  required String folder,
  required String noun,
  required Future<Page> Function(String? cursor) page,
  required String Function(Json item) id,
  required List<String> Function(Json item) items,
  required DateTime Function(Json item) time,
  required List<Download> Function(List<Json> page) files,
}) async {
  final part = j.part(folder), index = j.index;
  final known = {...index.posts.keys}, newest = index.newest;
  final check = known.isEmpty || DateTime.now().difference(index.checked) > 7.days;
  j.phase(part, check && !j.o.all ? 'listing every $noun (${known.isEmpty ? 'first run' : 'weekly check'})' : 'listing ${noun}s');
  final mark = j.cursor(folder);
  final resume = j.o.all ? '' : (await mark.text(or: '')).trim();
  final listed = <String, int>{};
  var pages = 0, saving = Future<void>.value(), ok = true;

  void track(Future<Results> batch, String? next) => saving = saving.then((_) async {
    ok = ok && (await batch).failures().isEmpty;
    if (!ok || j.o.dry) return;
    await (next == null ? mark.delete() : mark.write(next));
    await index.save();
  });

  // The page's files, noting carousels/threads whose items changed.
  List<Download> filesOf(List<Json> page) {
    for (final item in page) {
      final key = id(item), now = items(item), before = index.posts[key];
      if (before == null || before.isEmpty) {
        index.posts[key] = now;
        continue;
      }
      final added = [for (final i in now) if (!before.contains(i)) i];
      final hidden = before.where((i) => !now.contains(i)).length;
      if (added.isNotEmpty || hidden > 0) {
        j.changed('$noun $key edited: ${added.length} new, $hidden hidden (files kept)');
        index.posts[key] = [...before, ...added];
      }
    }
    return files(page);
  }

  // True when the end of the feed was reached.
  Future<bool> walk(String? cursor, {required bool tracked, required bool stop}) async {
    final none = Future<Results>.value(const []);
    for (;;) {
      final p = await page(cursor);
      final wanted = [for (final i in p.items) if (j.keep(time(i))) i];
      if (p.items.isEmpty || wanted.isEmpty) {
        if (tracked) track(none, null);
        return p.items.isEmpty;
      }
      final list = filesOf(wanted);
      pages++;
      if (stop && list.isNotEmpty && (await Future.wait(list.map((f) => f.to.exists()))).every((e) => e)) {
        if (tracked) track(none, null);
        return false;
      }
      listed.addAll({for (final i in p.items) id(i): time(i).millisecondsSinceEpoch ~/ 1000});
      j.log(part, 'page $pages: ${wanted.length} ${noun}s${dates(wanted, time)}, ${list.length} files');
      final batch = j.add(list);
      if (tracked) track(batch, p.next);
      if (p.next == null || p.next == cursor) {
        if (tracked) track(none, null);
        return true;
      }
      cursor = p.next;
    }
  }

  final bool complete;
  try {
    final full = j.o.all || check;
    if (resume.isEmpty) {
      complete = await walk(null, tracked: true, stop: !full);
    } else {
      await walk(null, tracked: false, stop: true);
      j.log(part, 'continuing where the last run stopped');
      complete = await walk(resume, tracked: true, stop: !full);
    }
  } finally {
    await saving;
  }
  index.newest = listed.values.fold(newest, max);
  if (complete && ok) index.checked = DateTime.now();
  if (complete && resume.isEmpty) {
    final seen = listed.keys.toSet();
    final shown = {
      ...index.hidden.intersection(seen),
      if (known.isNotEmpty)
        for (final MapEntry(:key, :value) in listed.entries)
          if (!known.contains(key) && value <= newest) key,
    };
    final gone = known.difference(seen).difference(index.hidden);
    if (gone.isNotEmpty) j.changed('${noun}s hidden or deleted (${gone.length}): ${gone.join(', ')}, files kept');
    if (shown.isNotEmpty) j.changed('${noun}s shown again (${shown.length}): ${shown.join(', ')}');
    index.hidden = known.difference(seen);
  }
  final newPages = pages - 1;
  j.phase(
    part,
    complete
        ? 'all $pages pages listed'
        : newPages <= 0
        ? 'no new ${noun}s'
        : '$newPages newest ${newPages == 1 ? 'page' : 'pages'} listed',
    done: true,
  );
}

// ", 2024-05-01 to 2024-04-18"
String dates(List<Json> items, DateTime Function(Json) time) {
  final (first, last) = (time(items.first).format('yyyy-MM-dd'), time(items.last).format('yyyy-MM-dd'));
  return ', ${first == last ? first : '$first to $last'}';
}
