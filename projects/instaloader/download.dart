// Downloads a profile's photos, reels, stories and highlights. Import with
// `as download`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

import 'dashboard.dart';
import 'instagram.dart' as instagram;
import 'media.dart' as media;

enum Kind {
  photo,
  reel,
  story,
  highlight,
  profile,
  all;

  bool get login => this == story || this == highlight;
  String get folder => switch (this) {
    photo => 'photos',
    reel => 'reels',
    story => 'stories',
    highlight => 'highlights',
    profile => 'profiles',
    all => '',
  };
}

typedef Results = List<Outcome<media.Download, bool>>;

// Downloads [kinds] of every user into [root]/<user>/, all at once: each
// user's explorers (posts, stories, highlights) run concurrently and feed one
// queue that downloads 8 files at a time, reporting into the dashboard.
// Returns the new files. [reset] first deletes those folders of each user,
// after asking.
Future<int> run(
  List<String> names,
  Set<Kind> kinds,
  Client? api,
  Dir root, {
  bool all = false,
  bool reset = false,
}) async {
  if (reset) {
    for (final name in names) {
      await wipe(root.dir(Fs.sanitize(name.toLowerCase())), kinds);
    }
  }
  final q = Queue();
  final added = await Future.wait([for (final name in names) user(name, kinds, api, root, q, all: all)]);
  return added.fold<int>(0, (a, b) => a + b);
}

// Downloads one user; returns the new files.
// A user that fails (lookup, listing) is reported and retried from scratch on r.
Future<int> user(String name, Set<Kind> kinds, Client? api, Dir root, Queue q, {required bool all}) async {
  final u = board.user(name);
  Future<int> attempt() async {
    try {
      return await _user(u, kinds, api, root, q, all: all);
    } catch (e) {
      u.error = '${instagram.explain(e)}';
      board.fail('✗ @${u.name}: ${u.error}', () async {
        u
          ..error = null
          ..parts.clear()
          ..changes.clear();
        await attempt();
      });
      return 0;
    }
  }

  return attempt();
}

Future<int> _user(User u, Set<Kind> kinds, Client? api, Dir root, Queue q, {required bool all}) async {
  final p = await instagram.profile(u.name);
  u
    ..name = p.name
    ..id = p.id;
  final dir = root.dir(Fs.sanitize(p.name));
  final photos = kinds.contains(Kind.photo) ? dir.dir('photos') : null;
  final reels = kinds.contains(Kind.reel) ? dir.dir('reels') : null;
  final index = await Index.load(dir), batches = <Future<Results>>[];
  await index.save(); // from the start, so an interrupted run still leaves what it saw
  // A part per folder: photos, reels, stories, highlights, profiles.
  for (final k in Kind.values) {
    if (kinds.contains(k) && k != Kind.all) u.parts[k.folder] = Part(k.folder);
  }
  final feedParts = [?u.parts['photos'], ?u.parts['reels']];
  void changed(String change) {
    u.changes.add(change);
    board.note('@${p.name} changed: $change');
  }

  // What [parts]' explorer is doing now; [done] ends it with what it found.
  void phase(List<Part> parts, String what, {bool done = false}) {
    for (final part in parts) {
      done ? part.note = what : part.phase = what;
      part.busy = !done;
    }
  }

  Future<Results> add(List<media.Download> files) {
    final batch = q.add(u, dir, files);
    batches.add(batch);
    return batch;
  }

  Future<void> explorePosts() async {
    if (api == null) {
      phase(feedParts, 'not logged in: the latest 12 posts', done: true);
      add(media.posts(p.posts, photos: photos, reels: reels));
      return;
    }
    // A post that is hidden, archived or shown again sits among the old ones,
    // where a run that stops at the newest known page never looks; Instagram
    // gives no cheap count to notice it by. So once a week every post is
    // listed (only missing files download).
    final known = {...index.posts.keys}, newest = index.newest;
    final check = known.isEmpty || DateTime.now().difference(index.checked) > 7.days;
    phase(
      feedParts,
      check && !all ? 'listing every post (${known.isEmpty ? 'first run' : 'weekly check'})' : 'listing posts',
    );

    // Each listed post's items against the last run's: an edited album keeps
    // its numbers, new items take the next ones, and nothing is deleted.
    List<media.Download> files(List<Json> page) {
      for (final post in page) {
        final code = media.code(post), now = media.items(post), before = index.posts[code];
        if (before == null || before.isEmpty) {
          index.posts[code] = now;
          continue;
        }
        final added = [
          for (final id in now)
            if (!before.contains(id)) id,
        ];
        final hidden = before.where((id) => !now.contains(id)).length;
        if (added.isNotEmpty || hidden > 0) {
          changed('post $code edited: ${added.length} new, $hidden hidden (files kept)');
          index.posts[code] = [...before, ...added];
        }
      }
      return media.posts(page, photos: photos, reels: reels, order: index.posts);
    }

    void log(String line) {
      phase(feedParts, line);
      board.note('@${p.name} ${feedParts.map((part) => part.name).join('+')}: $line');
    }

    // Posts come newest first, so listing stops at the first page already
    // on disk, unless every post is listed (first run, weekly, --all).
    // .instaloader-cursor-* remembers where an interrupted listing stopped;
    // it only moves past a page once that page's files are saved, so
    // failures retry. A run continues from it after the new posts on top,
    // unless --all starts over, and stops as a fresh run would: at the first
    // page on disk, unless every post is due to be listed.
    final feed = api.copy(rate: instagram.feedRate), full = all || check;
    final mark = dir.file('.instaloader-cursor-${feedParts.map((part) => part.name).join('-')}');
    final resume = all ? '' : (await mark.text(or: '')).trim();
    final codes = <String, int>{}; // listed: their taken_at
    var pages = 0, saving = Future<void>.value(), ok = true;
    // In page order: once a page is saved, keep the cursor after it (none:
    // the listing is complete) and the index.
    void track(Future<Results> batch, String? next) => saving = saving.then((_) async {
      ok = ok && (await batch).failures().isEmpty;
      if (!ok) return;
      await (next == null ? mark.delete() : mark.write(next));
      await index.save();
    });

    // true when it reached the oldest post.
    Future<bool> walk(String? cursor, {required bool tracked, required bool stop}) async {
      do {
        final page = await instagram.posts(feed, p.name, cursor);
        final list = files(page.posts);
        pages++;
        if (stop && list.isNotEmpty && (await Future.wait(list.map((f) => f.to.exists()))).every((e) => e)) {
          if (tracked) track(Future.value(const []), null);
          return false;
        }
        codes.addAll({for (final post in page.posts) media.code(post): post.$('taken_at|taken_at_timestamp').or(0)});
        log('page $pages: ${dates(page.posts)}, ${list.length} files');
        final batch = add(list);
        if (tracked) track(batch, page.next);
        cursor = page.next;
      } while (cursor != null);
      return true;
    }

    // Even when listing fails, the pages already listed finish and save
    // their cursor, so the next run continues from there.
    final bool complete;
    try {
      if (resume.isEmpty) {
        complete = await walk(null, tracked: true, stop: !full);
      } else {
        await walk(null, tracked: false, stop: true);
        log('continuing where the last run stopped');
        complete = await walk(resume, tracked: true, stop: !full);
      }
    } finally {
      await saving;
    }
    index.newest = codes.values.fold(newest, max);
    // A full listing with failures stays due, so the next run lists past
    // every failed page again. Hidden and re-shown posts only show in a
    // listing from the top; one that resumed still counts as the full listing.
    if (complete && ok) index.checked = DateTime.now();
    if (complete && resume.isEmpty) {
      final listed = codes.keys.toSet();
      // Shown again: hidden last time, or unknown but older than the newest
      // post known (hidden before this index began).
      final shown = {
        ...index.hidden.intersection(listed),
        if (known.isNotEmpty)
          for (final MapEntry(:key, :value) in codes.entries)
            if (!known.contains(key) && value <= newest) key,
      };
      final gone = known.difference(listed).difference(index.hidden);
      if (gone.isNotEmpty) changed('posts hidden or deleted (${gone.length}): ${gone.join(', ')}, files kept');
      if (shown.isNotEmpty) changed('posts shown again (${shown.length}): ${shown.join(', ')}');
      index.hidden = known.difference(listed);
    }
    final newPages = pages - 1;
    final note = complete
        ? 'all $pages pages listed'
        : newPages == 0
        ? 'no new posts'
        : '$newPages newest ${newPages == 1 ? 'page' : 'pages'} listed';
    phase(feedParts, note, done: true);
  }

  Future<void> exploreStories() async {
    final part = [u.parts['stories']!];
    phase(part, 'fetching the stories up now');
    final items = [
      for (final r in await instagram.reels(api!, [p.id], p.name)) ...r.items,
    ];
    for (final i in items) {
      index.stories[i.$('id').or('')] = i.$('taken_at').or(0);
    }
    add(media.stories(items, dir.dir('stories'), daily: true));
    phase(part, '${items.length} up now', done: true);
  }

  Future<void> exploreHighlights() async {
    final part = [u.parts['highlights']!];
    phase(part, 'listing highlights');
    final ids = await instagram.highlights(api!, p);
    final now = <String, Set<String>>{};
    final known = index.highlights.isNotEmpty;
    phase(part, 'fetching ${ids.length} highlights');
    await Future.wait([
      for (var i = 0; i < ids.length; i += 10)
        instagram.reels(api, ids.sublist(i, min(i + 10, ids.length)), p.name).then((reels) {
          for (final r in reels) {
            final title = r.title.isEmpty ? r.id : r.title;
            final items = {for (final item in r.items) item.$('id').or('')};
            final before = index.highlights[title];
            if (before != null) {
              final (added, removed) = (items.difference(before).length, before.difference(items).length);
              if (added + removed > 0) changed('highlight "$title": $added added, $removed removed');
            } else if (known) {
              changed('new highlight "$title"');
            }
            now[title] = items;
            add(media.stories(r.items, dir.dir('highlights').dir(Fs.sanitize(title))));
          }
          phase(part, 'fetched ${now.length} of ${ids.length} highlights');
        }),
    ]);
    for (final title in index.highlights.keys.where((t) => !now.containsKey(t))) {
      changed('highlight "$title" gone, files kept');
    }
    index.highlights = now;
    phase(part, '${ids.length} ${ids.length == 1 ? 'highlight' : 'highlights'}', done: true);
  }

  // profiles/<first seen>_<picture>.jpg: the picture's file name changes
  // with the picture, so a new one is a new file.
  Future<void> exploreProfile() async {
    final part = [u.parts['profiles']!];
    phase(part, 'fetching the profile picture');
    final url = await instagram.picture(api, p);
    if (url == null) return phase(part, 'no profile picture', done: true);
    final id = Fs.sanitize(Uri.parse(url).pathSegments.last);
    if (!index.profiles.containsKey(id)) {
      if (index.profiles.isNotEmpty) changed('new profile picture');
      index.profiles[id] = DateTime.now().format('yyyy-MM-dd');
      await index.save(); // the file name holds that day: keep it before downloading
    }
    add([(to: dir.dir('profiles').file('${index.profiles[id]}_$id'), url: url, text: null)]);
    phase(part, '${index.profiles.length} seen${api == null ? ', 150px without a login' : ''}', done: true);
  }

  // Even when an explorer fails, what was queued finishes and the index is
  // saved before the user counts as failed (and r may start it over).
  try {
    await Future.wait([
      if (kinds.contains(Kind.profile)) exploreProfile(),
      if (photos != null || reels != null) explorePosts(),
      if (kinds.contains(Kind.story)) exploreStories(),
      if (kinds.contains(Kind.highlight)) exploreHighlights(),
    ]);
  } finally {
    await Future.wait(batches);
    await index.save();
  }
  final results = [for (final b in await Future.wait(batches)) ...b];
  if (u.changes.isNotEmpty) Console.notify('instaloader: @${p.name} changed: ${u.changes.join('; ')}');
  return results.values().where((isNew) => isNew).length;
}

// What the runs saw, to tell what changed (.instaloader.json): when every post was
// last listed, the newest post, every post ever seen with its item ids in
// file-number order, the posts hidden now, every story and
// profile picture seen, and each highlight's items.
class Index {
  Index(this.file, Json j)
    : checked = DateTime.fromMillisecondsSinceEpoch(j.$('checked').or(0)),
      newest = j.$('newest').or(0),
      posts = {
        for (final MapEntry(:key, :value) in j.$('posts').asMap<Object?>().entries)
          key: [for (final id in Json.of(value)) id.or('')],
        // The index before item ids: the order is taken from the next listing.
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
  DateTime checked; // the last listing of every post
  int newest; // taken_at of the newest post
  Map<String, List<String>> posts;
  Set<String> hidden;
  Map<String, int> stories; // every story seen, by id: its taken_at
  Map<String, String> profiles; // every profile picture seen: the day first seen
  Map<String, Set<String>> highlights;

  static Future<Index> load(Dir dir) async {
    final file = dir.file('.instaloader.json');
    return Index(file, Json.parse(await file.text(or: '{}')));
  }

  Future<void> _saving = Future.value();

  // One write at a time, each with the state as it is then.
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

// Deletes [kinds]' folders in [dir] after asking, so they download again from
// what is on Instagram now. The index stays, so album numbers stay stable.
Future<void> wipe(Dir dir, Set<Kind> kinds) async {
  final folders = [
    for (final k in kinds)
      if (await dir.dir(k.folder).exists()) k.folder,
  ];
  if (folders.isEmpty) return;
  final question =
      'Delete ${folders.join(', ')} of @${dir.name()} and download again? '
      'Expired stories and removed posts cannot be downloaded back.';
  if (!await Console.confirm(question)) throw Exception('--reset cancelled, nothing deleted.');
  for (final folder in folders) {
    await dir.dir(folder).delete();
  }
  for (final cursor in await dir.list(match: '.instaloader-cursor-*')) {
    await cursor.delete();
  }
}

// One download queue for every explorer: whatever is added downloads as soon
// as one of the 8 lanes is free. add() completes when that batch is done.
class Queue {
  var _free = 8;
  final _waiting = ListQueue<Completer<void>>();

  // Each file counts in its folder's part of [u] (its first folder in [dir]).
  Future<Results> add(User u, Dir dir, List<media.Download> files) {
    Part part(media.Download f) => u.parts[f.to.path(from: dir).split('/').first]!;
    for (final f in files) {
      part(f).queued++;
    }
    // A failed file leaves the counts on r and queues again.
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
      isNew ? part.added++ : part.had++;
      return isNew;
    } catch (e) {
      part.failed++;
      board.fail('✗ @${u.name} $path: ${instagram.explain(e)}', retry);
      rethrow;
    } finally {
      _waiting.isEmpty ? _free++ : _waiting.removeFirst().complete();
    }
  }

  // false when the file was already on disk, or in the folder above it (the
  // layout before day folders), from where it moves into place.
  Future<bool> save(media.Download f, Transfer t) async {
    if (await f.to.exists()) return false;
    final old = f.to.parent().parent().file(f.to.name());
    if (await old.exists()) {
      await old.move(f.to.path());
      return false;
    }
    if (f.text case final text?) {
      await f.to.write(text);
      return true;
    }
    board.transfers.add(t);
    try {
      await (instagram.cdn.get(f.url!) | Pipe.tap(t.update) > f.to);
    } finally {
      board.transfers.remove(t);
    }
    board.note('@${t.user.name} ${t.path}  ${size(t.done)}');
    return true;
  }
}

// "12 posts, 2024-05-01 to 2024-04-18"
String dates(List<Json> posts) {
  if (posts.isEmpty) return 'no posts';
  final (first, last) = (media.day(posts.first), media.day(posts.last));
  return '${posts.length} posts, ${first == last ? first : '$first to $last'}';
}
