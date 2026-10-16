// A newest-first feed (Instagram posts, tweets, and any future site's
// timeline) listed into its kind's folder.
library;

import 'dart:math';

import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

import 'job.dart';
import 'platform.dart';

// One page of a feed and the cursor of the next.
typedef Page = ({List<Json> items, String? next});

// Lists a feed of [kind] (http's Feed walks it): only what is newer than
// the files on disk, unless it is the first run, the weekly full check, or
// --all; continues where an interrupted run stopped; reports edited, hidden
// and reappearing posts. [items] are a post's media ids in order (a
// carousel's), [files] a page's downloads.
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
  final full = j.o.all || check; // list to the end, from the top
  j.phase(
    kind,
    check && !j.o.all ? 'listing every $noun (${known.isEmpty ? 'first run' : 'weekly check'})' : 'listing ${noun}s',
  );
  final mark = j.cursor(kind);
  final resumed = !full && !j.o.dry && (await mark.text(or: '')).trim().isNotEmpty;
  final listed = <String, int>{};
  var pages = 0, ok = true;

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

  final complete = await Feed(page, cursor: j.o.dry ? null : mark.path()).run(all: full, (p) async {
    final wanted = [
      for (final i in p.items())
        if (j.keep(time(i))) i,
    ];
    if (wanted.isEmpty) return p.stop(); // past --since
    final list = filesOf(wanted);
    // Listing only what is new: a page already down is where the new ones end.
    if (!full && list.isNotEmpty && (await Future.wait(list.map((f) => f.to.exists()))).every((e) => e)) {
      return p.stop();
    }
    pages++;
    listed.addAll({for (final i in p.items()) id(i): time(i).millisecondsSinceEpoch ~/ 1000});
    j.log(kind, 'page $pages: ${wanted.length} ${noun}s${_dates(wanted, time)}, ${list.length} files');
    p.add(
      j.add(list).then((r) async {
        final done = r.failures().isEmpty;
        if (done && !j.o.dry) await index.save();
        ok = ok && done;
        return done;
      }),
    );
  });
  index.newest = listed.values.fold(newest, max);
  if (complete && ok) index.checked = DateTime.now();
  if (complete && !resumed) {
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
  j.phase(
    kind,
    complete
        ? 'all $pages pages listed'
        : pages == 0
        ? 'no new ${noun}s'
        : '$pages newest ${pages == 1 ? 'page' : 'pages'} listed',
    done: true,
  );
}

// ", 2024-05-01 to 2024-04-18"
String _dates(List<Json> items, DateTime Function(Json) time) {
  final (first, last) = (time(items.first).format('yyyy-MM-dd'), time(items.last).format('yyyy-MM-dd'));
  return ', ${first == last ? first : '$first to $last'}';
}
