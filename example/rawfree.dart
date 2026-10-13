/// rawfree: search manga, browse chapters, queue downloads.
///
/// ```sh
/// dart run example/rawfree.dart
/// ```
///
/// Search: type, `enter` searches, `enter` again opens the series.
/// Series: `enter` queues a chapter, `a` queues every chapter not on disk.
/// `ctrl+d` shows the download queue from any view (`r` retries the missing
/// pages of a failed job, `delete` drops a queued one, `c` clears finished).
/// Pages land in `downloads/<series>/<chapter>/001.jpg`, …
library;

import 'dart:io' show HttpException, StdoutException, exit, stderr;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/tui.dart';

const _base = 'https://rawfree.you';

const _headers = {
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'ja,en-US;q=0.9,en;q=0.8',
  'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
};

typedef Hit = ({String title, String url});
typedef Chapter = ({String title, String url, int postId});

// --- UI ---

sealed class Page {}

final class Search extends Page {
  final query = Field();
  final hits = Pick<Hit>();
  var searched = '';
}

final class Series extends Page {
  Series(this.back, this.hit);
  final Search back;
  final Hit hit;
  final chapters = Pick<Chapter>();
  final onDisk = <String>{};
}

final class Queue extends Page {
  Queue(this.back);
  final Page back;
}

enum JobStatus { queued, active, done, failed }

final class Job {
  Job(this.series, this.chapter);
  final Hit series;
  final Chapter chapter;
  var status = JobStatus.queued, done = 0, total = 0;
  final missing = <int>[]; // page indexes to (re)fetch; empty = all
  String get dir => 'downloads/${_safe(series.title)}/${_safe(chapter.title)}';
}

final queue = Pick<Job>();
var _working = false;

Future<void> main() async {
  try {
    await Tui.run<Page>(Search(), _screen);
  } on StdoutException {
    stderr.writeln('rawfree needs a terminal');
    exit(1);
  }
  exit(0); // downloads still in flight end with the app
}

Screen _screen(Page page, App<Page> app) {
  final keys = <String, Bind>{
    'ctrl+d': ('queue', () => app.go(page is Queue ? page.back : Queue(page))),
    'ctrl+c': ('', () => _quit(app)),
  };
  return switch (page) {
    Search s => Screen(
      title: '✻ rawfree',
      (r) {
        final [body, foot] = r.rows([0, 3]);
        body.list(s.hits, (h) => h.title, empty: 'type a manga title, press enter');
        foot.box('search').input(s.query);
      },
      keys: {
        'enter': s.query.text().trim() != s.searched ? ('search', () => _search(s)) : ('open', () => _open(s, app)),
        'ctrl+o': ('browser', () => _browse(s.hits.selected()?.url, app)),
        'escape': ('quit', () => _quit(app)),
        ...keys,
      },
    ),
    Series c => Screen(
      title: '✻ ${c.hit.title}',
      (r) => r.list(c.chapters, (ch) => '${_mark(c, ch)} ${ch.title}', empty: 'no chapters'),
      keys: {
        'enter': ('queue', () => _enqueue(c, [?c.chapters.selected()], app)),
        'a': ('queue all', () => _enqueue(c, c.chapters.items(), app)),
        'o': ('browser', () => _browse(c.hit.url, app)),
        'b escape': ('back', () => app.go(c.back)),
        ...keys,
      },
    ),
    Queue q => Screen(
      title: '✻ downloads',
      (r) {
        final [body, foot] = r.rows([0, 1]);
        body.table(
          queue,
          (j) => [
            j.chapter.title,
            j.status == JobStatus.failed ? 'failed (${j.missing.length})' : j.status.name,
            '${j.done}/${j.total}',
          ],
          header: ['chapter', 'status', 'pages'],
          empty: 'nothing queued · enter on a chapter queues it',
        );
        if (_active() case final j?) foot.bar(j.done, j.total, label: '↓ ${j.chapter.title}');
      },
      keys: {
        if (queue.selected()?.status == JobStatus.failed) 'r': ('retry', () => _retry(queue.selected()!, app)),
        if (queue.selected()?.status == JobStatus.queued) 'delete': ('remove', () => _remove(queue.selected()!)),
        'c': (
          'clear done',
          () => queue.set([
            for (final j in queue.items())
              if (j.status != JobStatus.done) j,
          ]),
        ),
        'b escape': ('back', () => app.go(q.back)),
        ...keys,
      },
    ),
  };
}

Job? _active() => queue.items().where((j) => j.status == JobStatus.active).firstOrNull;
Job? _job(Chapter ch) => queue.items().where((j) => j.chapter.postId == ch.postId).firstOrNull;
int get _left => queue.items().where((j) => j.status.index < JobStatus.done.index).length;

String _mark(Series c, Chapter ch) => c.onDisk.contains(ch.title)
    ? '✓'
    : switch (_job(ch)?.status) {
        JobStatus.done => '✓',
        JobStatus.failed => '✗',
        null => ' ',
        _ => '⇣',
      };

Future<void> _search(Search s) async {
  s.searched = s.query.text().trim();
  if (s.searched.isEmpty) return;
  s.hits.set(await Console.spin('searching', () => searchManga(s.searched)));
}

Future<void> _open(Search s, App<Page> app) async {
  final hit = s.hits.selected();
  if (hit == null) return;
  final page = Series(s, hit);
  app.go(page);
  final chapters = await Console.spin('loading chapters', () => resolveChapters(hit.url));
  for (final ch in chapters) {
    if (await Fs.dir(Job(hit, ch).dir).exists()) page.onDisk.add(ch.title);
  }
  page.chapters.set(chapters);
}

Future<void> _browse(String? url, App<Page> app) async {
  if (url == null) return;
  await Shell.open(url);
  app.say('opened in browser');
}

Future<void> _quit(App<Page> app) async {
  if (_left == 0 || await Console.confirm('$_left downloads left. Quit?')) app.quit();
}

void _enqueue(Series c, List<Chapter> chapters, App<Page> app) {
  final add = [
    for (final ch in chapters)
      if (!c.onDisk.contains(ch.title) && _job(ch) == null) Job(c.hit, ch),
  ];
  queue.set([...queue.items(), ...add]);
  app.say('queued ${add.length} chapter(s)');
  _work(app);
}

void _retry(Job job, App<Page> app) {
  job.status = JobStatus.queued;
  _work(app);
}

void _remove(Job job) => queue.set([
  for (final j in queue.items())
    if (j != job) j,
]);

/// The worker: one chapter at a time, 4 pages in parallel; idles when the
/// queue has nothing queued.
Future<void> _work(App<Page> app) async {
  if (_working) return;
  _working = true;
  try {
    for (;;) {
      final job = queue.items().where((j) => j.status == JobStatus.queued).firstOrNull;
      if (job == null) break;
      job.status = JobStatus.active;
      try {
        await _fetch(job);
      } on Exception catch (e) {
        job.status = JobStatus.failed;
        app.say('✗ ${job.chapter.title}: ${_short(e)}');
      }
    }
  } finally {
    _working = false;
  }
}

Future<void> _fetch(Job job) async {
  final imgs = await chapterImages(job.chapter.postId);
  if (imgs.isEmpty) throw FormatException('no images found');
  final todo = job.missing.isEmpty ? [for (var i = 0; i < imgs.length; i++) i] : [...job.missing];
  job
    ..total = imgs.length
    ..done = imgs.length - todo.length;
  final finished = queue.items().where((j) => j.status.index >= JobStatus.done.index).length;
  final label = '⇣ ${finished + 1}/${queue.items().length} chapters · ↓ ${job.chapter.title}';
  final bar = Console.bar(imgs.length, label: label)..tick(job.done);
  final failed = <int>[];
  var next = 0;
  Future<void> lane() async {
    while (next < todo.length) {
      final i = todo[next++];
      if (await _page(job, i, imgs[i])) {
        job.done++;
      } else {
        failed.add(i);
      }
      bar.tick();
    }
  }

  try {
    await Future.wait([for (var k = 0; k < 4; k++) lane()]);
  } finally {
    await bar.close();
  }
  job.missing
    ..clear()
    ..addAll(failed..sort());
  job.status = failed.isEmpty ? JobStatus.done : JobStatus.failed;
}

/// One page; false when it failed (non-2xx, network, or a <1 KB stub).
Future<bool> _page(Job job, int i, String url) async {
  try {
    final img = await Http.get(url, headers: {..._headers, 'referer': '$_base/'}, retries: 2);
    final data = img.ok() ? await img.bytes() : const <int>[];
    if (!img.ok()) await img.close();
    if (data.length < 1024) return false; // error page or expired-URL stub
    await Fs.dir(job.dir).file('${'${i + 1}'.padLeft(3, '0')}${_imgExt(data, img)}').write(data);
    return true;
  } on Exception {
    return false;
  }
}

// --- rawfree API (JSON only, works where HTML is region-blocked) ---

Future<Json> _apiGet(String path) async {
  final res = await Http.get('$_base/wp-json/wp/v2/$path', headers: _headers, retries: 2);
  if (!res.ok()) {
    final text = await res.text();
    await res.close();
    throw HttpException('HTTP ${res.status()}: ${_short(text)}', uri: Uri.parse(res.url()));
  }
  return res.json();
}

String _titleOf(Json item) {
  final rendered = item.$('title.rendered').value<String>();
  if (rendered != null) return _htmlText(rendered);
  return _htmlText(item.$('title').value<String>() ?? '');
}

/// Strip tags / decode entities from a WP title or tag name.
///
/// WP `title.rendered` may hold entities or inline tags, while tag `name`s
/// are usually bare text with no tags at all. `Html.parse` only keeps
/// element nodes, so bare text parses to zero elements and `.text()` reads
/// `''`. Wrapping in a `<div>` keeps both cases as element content.
String _htmlText(String html) {
  if (html.trim().isEmpty) return '';
  return Html.parse('<div>$html</div>').text();
}

/// Series first, then chapters.
Future<List<Hit>> searchManga(String query, {int limit = 30}) async {
  final out = <Hit>[];
  final seen = <String>{};
  void add(String? title, String? url) {
    if (url == null || url.isEmpty) return;
    if (!seen.add(url)) return;
    if ((title ?? '').trim().isEmpty) return;
    out.add((title: title!.trim(), url: url));
  }

  final q = Uri.encodeQueryComponent(query);
  final tags = await _apiGet('tags?search=$q&per_page=$limit');
  for (final t in tags) {
    if (out.length >= limit) break;
    add(_htmlText(t.$('name').value<String>() ?? ''), t.$('link').value<String>());
  }
  final posts = await _apiGet('posts?search=$q&per_page=$limit&_embed=wp:featuredmedia');
  for (final p in posts) {
    if (out.length >= limit) break;
    add(_titleOf(p), p.$('link').value<String>());
  }
  return out;
}

Future<int?> _seriesTag(List<int> ids) async {
  if (ids.isEmpty) return null;
  if (ids.length == 1) return ids.first;
  final tags = await _apiGet('tags?include=${ids.join(',')}&per_page=100');
  var best = ids.first;
  var bestCount = -1;
  for (final t in tags) {
    final id = t.$('id').value<int>();
    final count = t.$('count').value<int>() ?? 0;
    if (id != null && count > bestCount) {
      best = id;
      bestCount = count;
    }
  }
  return best;
}

List<Chapter> _toChapters(Json list) {
  final out = <Chapter>[];
  for (final p in list) {
    final id = p.$('id').value<int>();
    final link = p.$('link').value<String>();
    final title = _titleOf(p).trim();
    if (id == null || link == null || title.isEmpty) continue;
    out.add((title: title, url: link, postId: id));
  }
  return out;
}

/// Chapters of the series behind a chapter or series URL, newest first.
Future<List<Chapter>> resolveChapters(String pageUrl) async {
  final segs = Uri.parse(pageUrl).pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) throw FormatException('bad url', pageUrl);
  final sq = Uri.encodeQueryComponent(segs.last);
  final posts = await _apiGet('posts?slug=$sq&_fields=id,tags');
  for (final p in posts) {
    if (p.$('id').value<int>() == null) continue;
    final tagIds = p.$('tags').value<List<int>>() ?? [];
    final tagId = await _seriesTag(tagIds);
    if (tagId == null) throw const FormatException('no series tag');
    return _toChapters(await _apiGet('posts?tags=$tagId&per_page=100&_fields=id,link,title'));
  }
  final tags = await _apiGet('tags?slug=$sq&_fields=id');
  for (final t in tags) {
    final tagId = t.$('id').value<int>();
    if (tagId == null) continue;
    return _toChapters(await _apiGet('posts?tags=$tagId&per_page=100&_fields=id,link,title'));
  }
  throw FormatException('series not found', pageUrl);
}

/// Chapter page images via the theme's AJAX endpoint.
Future<List<String>> chapterImages(int postId) async {
  final out = <String>[];
  final seen = <String>{};
  var index = 0;
  for (var round = 0; round < 12; round++) {
    final decoded = await Http.post(
      '$_base/wp-admin/admin-ajax.php',
      body: {
        'action': 'z_do_ajax',
        '_action': 'decode_images',
        'p': '$postId',
        'img_index': '$index',
        'content': '',
        'nonce': 'x',
      },
    ).json();
    final mes = decoded.$('mes').value<String>() ?? '';
    if (mes.isNotEmpty) {
      for (final img in Html.parse(mes, baseUrl: '$_base/').$('img')) {
        final src = img.attr('src') ?? img.attr('data-src') ?? img.attr('data-original') ?? img.attr('data-lazy-src');
        if (src == null || src.isEmpty || src.startsWith('data:')) continue;
        if (seen.add(src)) out.add(src);
      }
    }
    final going = decoded.$('going').value<int>() ?? 0;
    final next = decoded.$('img_index').value<int>() ?? index + 1;
    if (going != 1 || next <= index) break;
    index = next;
    final waitMs = decoded.$('next_timeout').value<int>() ?? 1000;
    await Future<void>.delayed(Duration(milliseconds: waitMs.clamp(0, 5000)));
  }
  return out;
}

/// File extension for a downloaded chapter image.
///
/// The image host answers `application/octet-stream` and its URLs carry no
/// extension, so `Response.name()` is a bare id (`kbipl910tmb8`). Sniff the
/// magic bytes, falling back to the content-type and then `.jpg` (what the
/// host serves), so pages land as `001.jpg`, `002.jpg`, … and open in any
/// viewer.
String _imgExt(List<int> bytes, Response res) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return '.jpg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return '.png';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return '.gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return '.webp';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return '.bmp';
  }
  switch (res.header('content-type')?.split(';').first.trim().toLowerCase()) {
    case 'image/jpeg':
      return '.jpg';
    case 'image/png':
      return '.png';
    case 'image/gif':
      return '.gif';
    case 'image/webp':
      return '.webp';
    case 'image/bmp':
      return '.bmp';
  }
  return '.jpg';
}

String _safe(String s) {
  final clean = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final cut = clean.length > 80 ? clean.substring(0, 80) : clean;
  return cut.isEmpty ? 'manga' : cut;
}

String _short(Object e) {
  final line = '$e'.split('\n').first.trim();
  return line.length > 100 ? '${line.substring(0, 100)}…' : line;
}
