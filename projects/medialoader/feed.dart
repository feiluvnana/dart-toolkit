// A newest-first feed (Instagram posts, tweets, and any future site's
// timeline) listed into its kind's folder.
library;

import 'dart:math';

import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

import 'job.dart';
import 'platform.dart';

// One page of a feed and the cursor of the next.
typedef Page = ({List<Json> items, String? next});

// Lists a feed of [kind]: only what is newer than the files on disk, unless
// it is the first run, the weekly full check, or --all; continues where an
// interrupted run stopped (a cursor saved once each page's files are
// down); reports edited, hidden and reappearing posts. [items] are a post's
// media ids in order (a carousel's), [files] a page's downloads.
Future<void> feed(
  Job j, {
  Kind kind = Kind.posts,
  required String noun,
  required Future<Page> Function(String? cursor) page,
  required String Function(Json item) id,
  required List<String> Function(Json item) items,
  required DateTime Function(Json item) time,
  required List<Download> Function(List<Json> page) files,
}) async {
  final index = j.index;
  final known = {...index.posts.keys}, newest = index.newest;
  final check = known.isEmpty || DateTime.now().difference(index.checked) > 7.days;
  j.phase(
    kind,
    check && !j.o.all ? 'listing every $noun (${known.isEmpty ? 'first run' : 'weekly check'})' : 'listing ${noun}s',
  );
  final mark = j.cursor(kind);
  final resume = j.o.all ? '' : (await mark.text(or: '')).trim();
  final listed = <String, int>{};
  var pages = 0, saving = Future<void>.value(), ok = true;

  // The cursor moves past a page only once all its files are down.
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
      final added = [
        for (final i in now)
          if (!before.contains(i)) i,
      ];
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
      final wanted = [
        for (final i in p.items)
          if (j.keep(time(i))) i,
      ];
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
      j.log(kind, 'page $pages: ${wanted.length} ${noun}s${_dates(wanted, time)}, ${list.length} files');
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
      j.log(kind, 'continuing where the last run stopped');
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
    kind,
    complete
        ? 'all $pages pages listed'
        : newPages <= 0
        ? 'no new ${noun}s'
        : '$newPages newest ${newPages == 1 ? 'page' : 'pages'} listed',
    done: true,
  );
}

// ", 2024-05-01 to 2024-04-18"
String _dates(List<Json> items, DateTime Function(Json) time) {
  final (first, last) = (time(items.first).format('yyyy-MM-dd'), time(items.last).format('yyyy-MM-dd'));
  return ', ${first == last ? first : '$first to $last'}';
}
