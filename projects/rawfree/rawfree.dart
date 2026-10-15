// Search manga on rawfree, pick a series and download chapters.
//
//   dart run projects/rawfree/rawfree.dart [query]
//
// Type a title and press enter to search; enter again opens the selected
// series. In the chapter list, enter downloads a chapter and `a` downloads all
// of them. Chapters go to downloads/<series>/<chapter>/ next to this script,
// one at a time. The
// keys for each screen are shown at the bottom.
library;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/tui.dart';

import 'downloads.dart';
import 'site.dart';

final class Paged<T> {
  Paged(this._fetch);
  final Future<Slice<T>> Function(int page) _fetch;
  final pick = Pick<T>();
  var page = 0, more = true;

  Future<void> next(String what) async {
    final r = await Console.spin('$what (page ${page + 1})…', _fetch(page + 1));
    page++;
    more = r.more;
    pick.addAll(r.items);
  }
}

sealed class View {}

final class Search extends View {
  Search(String text) : query = Field(text: text);
  final Field query;
  Paged<Hit>? hits;
  var last = '';
}

final class Series extends View {
  Series(this.back, this.hit)
    : chapters = Paged((p) async {
        final r = await resolveChapters(hit.url, page: p);
        await Future.wait([
          for (final ch in r.items) Job(hit, ch).marker.exists().then((done) => done ? queue.onDisk.add(ch.url) : null),
        ]);
        return r;
      });
  final Search back;
  final Hit hit;
  final Paged<Chapter> chapters;
}

Future<void> main(List<String> args) async {
  await Tui.run<View>(Search(args.join(' ').trim()), screen);
  queue.stop();
}

Screen screen(View view, App<View> app) {
  switch (view) {
    case Search s:
      return Screen(
        title: 'rawfree',
        (r) {
          final [body, foot] = r.rows([0, 3]);
          body.list(s.hits?.pick ?? Pick<Hit>(), (h) => h.title, empty: 'type a title, press enter');
          foot.box('search').input(s.query, hint: 'manga title');
        },
        keys: {
          'enter': ('search', () => onEnter(s, app)),
          if (s.hits?.more ?? false) 'ctrl+n': ('more', () => s.hits!.next('loading results')),
          'escape': ('quit', app.quit),
        },
      );
    case Series c:
      final pick = c.chapters.pick, q = queue, sel = pick.selected();
      final waiting = q.where(JobStatus.queued).length + q.where(JobStatus.paused).length;
      final failed = q.where(JobStatus.failed).toList();
      return Screen(
        title: c.hit.title,
        status: [
          if (q.paused) '⏸ paused',
          if (waiting > 0) '$waiting queued',
          if (failed.isNotEmpty) '${failed.length} failed',
        ].join(' · '),
        (r) {
          final [body, foot] = r.rows([0, q.jobs.isEmpty && q.lines.isEmpty ? 0 : 8]);
          body.list(pick, (ch) => '${q.icon(ch)} ${ch.title}', empty: 'no chapters');
          final log = foot.box('downloads').scroll(q.scroll);
          for (final j in q.where(JobStatus.active)) {
            log.bar(j.done, j.total, label: '⇣ ${j.chapter.title}');
          }
          for (final line in q.lines) {
            log.write('$line\n');
          }
        },
        keys: {
          if (sel != null) 'enter': ('download', () => q.add(c.hit, [sel])),
          'a': ('all', () => queueAll(c)),
          if (sel != null && q.jobs.containsKey(sel.url)) 'x': ('remove', () => q.remove(sel)),
          if (q.jobs.isNotEmpty) 'p': (q.paused ? 'resume' : 'pause', q.pause),
          if (failed.isNotEmpty) 'r': ('retry', () => q.add(c.hit, [for (final j in failed) j.chapter])),
          if (c.chapters.more) 'm': ('older', () => c.chapters.next('loading chapters')),
          'o': ('browser', () => Shell.open(c.hit.url)),
          'escape': ('back', () => app.go(c.back)),
          'q': ('quit', app.quit),
        },
      );
  }
}

// Enter on a new query searches; enter again opens the selected series.
Future<void> onEnter(Search s, App<View> app) async {
  final q = s.query.text().trim();
  if (q.isEmpty) return;
  final hit = s.hits?.pick.selected();
  if (q == s.last && hit != null) {
    final c = Series(s, hit);
    app.go(c);
    await c.chapters.next('loading chapters');
    return;
  }
  s.last = q;
  final seen = <String>{};
  s.hits = Paged((p) async {
    final r = await searchManga(q, page: p);
    return (items: r.items.where((h) => seen.add(h.url)).toList(), more: r.more);
  });
  await s.hits!.next('searching "$q"');
}

Future<void> queueAll(Series c) async {
  while (c.chapters.more) {
    await c.chapters.next('loading chapters');
  }
  queue.add(c.hit, [
    for (final ch in c.chapters.pick.items())
      if (!queue.onDisk.contains(ch.url)) ch,
  ]);
}
