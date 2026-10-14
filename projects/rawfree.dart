/// rawfree: search manga, pick a series, pick chapters, download.
///
/// ```sh
/// dart run projects/rawfree.dart [initial query]
/// ```
///
/// A full-screen app: type a title and press enter to search, enter again opens the series, then queue
/// chapters (or all) to download into `downloads/<series>/<chapter>/001.jpg`, one at a time with a bar.
/// Search: enter search/open, ctrl+n more results, tab list/input, esc quit. Chapters: enter queue,
/// a all (skips what is on disk), x remove from queue, p pause/resume, r retry failures, m older
/// chapters, o browser, esc back, q quit. Icons: ✓ on disk, ⇣ downloading, … queued, ⏸ paused, ✗ failed.
library;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/tui.dart';

// ---- data layer: WordPress REST + the theme's AJAX image endpoint ----

const _base = 'https://rawfree.you';
const _headers = {
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'ja,en-US;q=0.9,en;q=0.8',
  'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
};

/// CDN suffixes whose TLS chain Dart cannot verify; only these skip verification (public image bytes).
const _insecureHosts = ['pubg-img.si'];

typedef Hit = ({String title, String url});
typedef Chapter = ({String title, String url, int postId});
typedef Slice<T> = ({List<T> items, bool more});

enum JobStatus {
  queued('…'),
  active('⇣'),
  paused('⏸'),
  done('✓'),
  failed('✗');

  const JobStatus(this.icon);
  final String icon;
}

final class Job {
  Job(this.series, this.chapter);
  final Hit series;
  final Chapter chapter;
  var status = JobStatus.queued;
  var halt = false; // set to stop after the pages in flight
  var done = 0; // pages finished, for the bar
  int? total;
  final missing = <int>[]; // page indexes to refetch; empty = all
  String? error; // first page-level failure
  String get dir => 'downloads/${_safe(series.title)}/${_safe(chapter.title)}';

  /// Written (with the page count) only once every page is on disk, so a partial chapter is resumed.
  File get marker => Fs.dir(dir).file('.done');
}

/// Series first, then chapters, deduplicated by URL. The site index is Japanese-only, so a romaji/English
/// query is also searched under its native AniList titles. [page] is 1-based; `per_page` is capped at 100.
Future<Slice<Hit>> searchManga(String query, {int limit = 30, int page = 1}) async {
  limit = limit.clamp(1, 100);
  final terms = {query, ...await _nativeTitles(query)};
  final results = await Future.wait([for (final t in terms) _searchTerm(t, limit, page)]);
  final seen = <String>{};
  return (
    items: [for (final r in results) ...r.items].where((h) => seen.add(h.url)).take(limit).toList(),
    more: results.any((r) => r.more),
  );
}

Future<Slice<Hit>> _searchTerm(String term, int limit, int page) async {
  final q = Uri.encodeQueryComponent(term), paging = 'per_page=$limit&page=$page';
  final [tags, posts] = await Future.wait([
    _api('tags?search=$q&$paging', page),
    _api('posts?search=$q&$paging&_embed=wp:featuredmedia', page),
  ]);
  return (
    items: [
      for (final t in tags.json) (title: _text(t.$('name').or('')), url: t.$('link').or('')),
      for (final p in posts.json) (title: _title(p), url: p.$('link').or('')),
    ].where((h) => h.url.isNotEmpty && h.title.isNotEmpty).take(limit).toList(),
    more: tags.more || posts.more,
  );
}

/// Native titles for a romaji/English [query] from AniList; best effort, any failure yields none.
final _natives = <String, Future<List<String>>>{};
Future<List<String>> _nativeTitles(String query) => _natives.putIfAbsent(query, () async {
  if (!RegExp('[A-Za-z0-9]').hasMatch(query)) return const []; // already Japanese
  try {
    final data = await Http.post(
      'https://graphql.anilist.co',
      body: Body.json({
        'query': r'query ($q: String) { Page(perPage: 5) { media(search: $q, type: MANGA, sort: SEARCH_MATCH) { title { native } } } }',
        'variables': {'q': query},
      }),
      headers: {'accept': 'application/json'},
      timeout: const Duration(seconds: 15),
      retries: 1,
      check: true,
    ).json();
    return {
      ...data.$('data.Page.media.*.title.native').asList<String>().map((s) => s.trim()).where((s) => s.isNotEmpty),
    }.take(3).toList();
  } catch (_) {
    return const [];
  }
});

/// Chapters of the series behind a chapter or series URL, newest first, [page] of 100.
Future<Slice<Chapter>> resolveChapters(String url, {int page = 1}) async {
  final slug = Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).lastOrNull;
  if (slug == null) throw FormatException('bad url', url);
  final q = Uri.encodeQueryComponent(slug);

  Future<Slice<Chapter>> chapters(int tag) async {
    final r = await _api('posts?tags=$tag&per_page=100&page=$page&_fields=id,link,title', page);
    return (
      items: [for (final p in r.json) (title: _title(p).trim(), url: p.$('link').or(''), postId: p.$('id').or(0))]
          .where((c) => c.postId != 0 && c.url.isNotEmpty && c.title.isNotEmpty)
          .toList(),
      more: r.more,
    );
  }

  for (final p in (await _api('posts?slug=$q&_fields=id,tags')).json) {
    final ids = p.$('tags').asList<int>();
    if (ids.isEmpty) throw const FormatException('no series tag');
    if (ids.length == 1) return chapters(ids.single);
    // Several tags: the series tag is the one with the most posts.
    final tags = (await _api('tags?include=${ids.join(',')}&per_page=100')).json;
    return chapters(
      tags.fold((id: ids.first, count: -1), (best, t) {
        final count = t.$('count').or(0);
        return count > best.count ? (id: t.$('id').or(best.id), count: count) : best;
      }).id,
    );
  }
  for (final t in (await _api('tags?slug=$q&_fields=id')).json) {
    if (t.$('id').value<int>() case final id?) return chapters(id);
  }
  throw FormatException('series not found', url);
}

/// Chapter pages in reading order; null marks a page the site lists but does not serve.
///
/// The post excerpt lists one file id per page. The theme's AJAX endpoint turns ids into signed CDN URLs
/// (`…/d/<token>/<id>`), but for older chapters it only still serves the last page or two (the reader
/// page itself is cloaked outside Japan). Pages are matched to the list by id, so a withheld page is a
/// gap that fails the chapter instead of a silent short download; without ids in the URLs (one
/// `merged_1-15.jpg`) the served images are the pages.
Future<List<String?>> chapterImages(int postId) async {
  final [ids, served] = await Future.wait([_pageIds(postId), _served(postId)]);
  final byId = {for (final u in served) Uri.parse(u).pathSegments.lastOrNull ?? '': u};
  if (!ids.any(byId.containsKey)) return [...served, for (var i = served.length; i < ids.length; i++) null];
  return [for (final id in ids) byId[id]];
}

Future<List<String>> _pageIds(int postId) async {
  final r = await _api('posts/$postId?_fields=excerpt');
  final ids = _text(r.json.$('excerpt.rendered').or('')).split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
  return ids.every(RegExp(r'^[a-z0-9]{8,16}$').hasMatch) ? ids.toList() : const [];
}

/// What the endpoint serves, batch by batch from `img_index` until a round adds nothing (past the end
/// it answers `going:1` with an ever larger index and no images, forever).
Future<List<String>> _served(int postId) async {
  final out = <String>{};
  for (var index = 0, round = 0; round < 50; round++) {
    final r = await Http.post(
      '$_base/wp-admin/admin-ajax.php',
      body: Body.form({'action': 'z_do_ajax', '_action': 'decode_images', 'p': '$postId', 'img_index': '$index'}),
      retries: 2,
    ).json();
    final before = out.length;
    for (final img in Html.parse(r.$('mes').or(''), base: '$_base/').$('img')) {
      final src = img.attr('src') ?? img.attr('data-src') ?? img.attr('data-original') ?? img.attr('data-lazy-src');
      if (src != null && src.isNotEmpty && !src.startsWith('data:')) out.add(src);
    }
    final next = r.$('img_index').or(index + 1);
    if (out.length == before || next <= index) break;
    index = next;
  }
  return out.toList();
}

/// Download the pages of [job] into [Job.dir], four at a time, until done or [Job.halt]. Never throws:
/// the outcome is in [Job.status], [Job.missing] and [Job.error]; [Job.done] and [Job.total] drive a bar.
Future<void> fetchChapter(Job job) async {
  job
    ..status = JobStatus.active
    ..error = null
    ..done = 0
    ..total = null;
  try {
    final imgs = await chapterImages(job.chapter.postId);
    if (imgs.isEmpty) throw const FormatException('no images found');
    final todo = job.missing.isEmpty ? [for (var i = 0; i < imgs.length; i++) i] : [...job.missing];
    job
      ..total = imgs.length
      ..done = imgs.length - todo.length;
    final errors = await Pool.map(todo, (i) async {
      if (job.halt) return _halted;
      final url = imgs[i];
      final e = url == null ? 'p${i + 1} withheld by the site' : await _fetchPage(job, i, url);
      job.done++;
      return e;
    }, limit: 4);
    job.error = errors.nonNulls.where((e) => !identical(e, _halted)).firstOrNull;
    job.missing
      ..clear()
      ..addAll(
        [
          for (var k = 0; k < todo.length; k++)
            if (errors[k] != null) todo[k],
        ]..sort(),
      );
    if (job.missing.isEmpty) await job.marker.write('${imgs.length}');
    job.status = job.missing.isEmpty
        ? JobStatus.done
        : job.halt
        ? JobStatus.paused
        : JobStatus.failed;
  } catch (e) {
    job
      ..status = job.halt ? JobStatus.paused : JobStatus.failed
      ..error = _short(e);
  }
}

const _halted = 'halted';

/// One page: null on success, else a short reason (error status, network error, or a <1 KB stub).
Future<String?> _fetchPage(Job job, int i, String url) async {
  final n = i + 1;
  try {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final img = await Http.get(
      url,
      headers: {..._headers, 'referer': '$_base/'},
      retries: 2,
      insecure: _insecureHosts.any((s) => host == s || host.endsWith('.$s')),
    );
    if (!img.ok()) {
      await img.close();
      return 'HTTP ${img.status()} p$n';
    }
    final data = await img.bytes();
    if (data.length < 1024) return 'empty reply p$n';
    // The host serves application/octet-stream with extensionless URLs: sniff the bytes.
    await (Reader.of(data) > Fs.dir(job.dir).file('${'$n'.padLeft(3, '0')}.${Image.sniff(data) ?? 'jpg'}'));
    return null;
  } on Exception catch (e) {
    return 'p$n: ${_short(e)}';
  }
}

/// A WordPress GET: the parsed body and whether older pages remain (`X-WP-TotalPages`).
Future<({Json json, bool more})> _api(String path, [int page = 1]) async {
  final res = await Http.get('$_base/wp-json/wp/v2/$path', headers: _headers, retries: 2, check: true);
  final pages = int.tryParse(res.header('x-wp-totalpages') ?? '') ?? 1;
  return (json: await res.json(), more: pages > page);
}

String _title(Json item) => _text(item.$('title.rendered').value<String>() ?? item.$('title').or(''));

/// Entities and inline tags out of a WP title; the `<div>` keeps bare text as element content.
String _text(String html) => html.trim().isEmpty ? '' : Html.parse('<div>$html</div>').text();

String _safe(String s) {
  final clean = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return clean.isEmpty ? 'manga' : clean.substring(0, clean.length.clamp(0, 80));
}

String _short(Object e) {
  final line = '$e'.split('\n').first.trim();
  return line.length > 100 ? '${line.substring(0, 100)}…' : line;
}

// ---- the app ----

/// A list that loads page by page; the fetcher deduplicates.
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
          for (final ch in r.items)
            Job(hit, ch).marker.exists().then((done) => done ? _queue.onDisk.add(ch.url) : null),
        ]);
        return r;
      });
  final Search back;
  final Hit hit;
  final Paged<Chapter> chapters;
}

/// The download queue, shared by every series: one chapter at a time in the order added. Chapters can
/// be added while it runs, removed, and the whole queue paused (the active chapter stops after the
/// pages in flight and resumes with only its missing pages).
final class Queue {
  final jobs = <String, Job>{}; // by chapter url, in queue order
  final onDisk = <String>{}; // chapter urls with a `.done` marker
  final lines = <String>[];
  final scroll = Scroll();
  var paused = false, _running = false, _stopped = false;

  Iterable<Job> where(JobStatus s) => jobs.values.where((j) => j.status == s);

  /// The list icon of [ch]: its job's status, ✓ when on disk, else blank.
  String icon(Chapter ch) => jobs[ch.url]?.status.icon ?? (onDisk.contains(ch.url) ? '✓' : ' ');

  /// Queue [chapters]; failed or paused ones are requeued (for their missing pages), others are kept.
  void add(Hit series, Iterable<Chapter> chapters) {
    for (final ch in chapters) {
      final job = jobs.putIfAbsent(ch.url, () => Job(series, ch));
      if (job.status case JobStatus.failed || JobStatus.paused) job.status = JobStatus.queued;
    }
    _pump();
  }

  /// Drop [ch] from the queue; an active chapter stops after the pages in flight.
  void remove(Chapter ch) => jobs.remove(ch.url)?.halt = true;

  void pause() {
    paused = !paused;
    for (final j in where(JobStatus.active)) {
      j.halt = paused;
    }
    if (paused) return;
    for (final j in where(JobStatus.paused)) {
      j.status = JobStatus.queued;
    }
    _pump();
  }

  /// Quit: no new chapters or pages, and every request in flight is cancelled (the unfinished chapter
  /// has no `.done` marker, so the next run resumes it).
  void stop() {
    _stopped = true;
    for (final j in jobs.values) {
      j.halt = true;
    }
    Http.abort();
  }

  Future<void> _pump() async {
    if (_running || _stopped) return;
    _running = true;
    try {
      while (!paused && !_stopped) {
        final job = where(JobStatus.queued).firstOrNull;
        if (job == null) break;
        job.halt = false;
        await fetchChapter(job);
        if (jobs[job.chapter.url] != job) continue; // removed meanwhile
        switch (job.status) {
          case JobStatus.done:
            onDisk.add(job.chapter.url);
            jobs.remove(job.chapter.url);
            lines.add('✓ ${job.chapter.title} → ${job.dir}');
          case JobStatus.failed:
            final pages = job.missing.isEmpty ? '' : '${job.missing.length} pages failed, ';
            lines.add('✗ ${job.chapter.title}: $pages${job.error}');
          case JobStatus.paused when !paused: // resumed before it stopped
            job.status = JobStatus.queued;
          case _:
        }
      }
    } finally {
      _running = false;
    }
  }
}

final _queue = Queue();

Future<void> main(List<String> args) async {
  await Tui.run<View>(Search(args.join(' ').trim()), _screen);
  _queue.stop();
}

Screen _screen(View view, App<View> app) {
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
          'enter': ('search', () => _enter(s, app)),
          if (s.hits?.more ?? false) 'ctrl+n': ('more', () => s.hits!.next('loading results')),
          'escape': ('quit', app.quit),
        },
      );
    case Series c:
      final pick = c.chapters.pick, q = _queue, sel = pick.selected();
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
          'a': ('all', () => _all(c)),
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

/// Enter on a new query searches; on the same query it opens the selected series.
Future<void> _enter(Search s, App<View> app) async {
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
    return (
      items: [
        for (final h in r.items)
          if (seen.add(h.url)) h,
      ],
      more: r.more,
    );
  });
  await s.hits!.next('searching "$q"');
}

/// All chapters: pulls the remaining pages, queues what is not on disk.
Future<void> _all(Series c) async {
  while (c.chapters.more) {
    await c.chapters.next('loading chapters');
  }
  _queue.add(c.hit, [
    for (final ch in c.chapters.pick.items())
      if (!_queue.onDisk.contains(ch.url)) ch,
  ]);
}
