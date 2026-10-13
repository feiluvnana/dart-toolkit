/// rawfree TUI: search manga, open pages, download chapters.
///
/// No flags, no args — just run it:
/// ```sh
/// dart run example/rawfree.dart
/// ```
///
/// Keys (search view): type to edit · enter search/open · ↑↓ move ·
/// `ctrl+o` open in browser · `esc` quit.
/// Keys (chapters view): ↑↓ move · enter download chapter ·
/// `o` open series in browser · `b`/`esc` back.
/// `ctrl+c` quits from anywhere; while a download runs, quitting asks for a
/// second press.
///
/// Downloads go to `downloads/<series>/<chapter>/` as `001.jpg`, `002.jpg`,
/// … Network failures show a one-line status and the app keeps running.
///
/// Immediate mode: async work (search, chapters, downloads) mutates this
/// state from `.then` callbacks, and the next frame shows it.
library;

import 'dart:io' show StdoutException, exit, stderr;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/tui.dart';

const _base = 'https://rawfree.you';

const _headers = {
  'accept':
      'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'ja,en-US;q=0.9,en;q=0.8',
  'user-agent':
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
};

typedef Hit = Map<String, String?>; // title, url
typedef Chapter = ({String title, String url, int postId});

Future<void> main(List<String> argv) async {
  try {
    await Tui.run(_app);
  } on StdoutException {
    stderr.writeln('rawfree needs a terminal');
    exit(1);
  }
  // Searches and downloads still in flight would keep the process alive
  // after the screen is gone; quitting means quitting.
  exit(0);
}

Future<void> _app(Screen screen) async {
  final st = _State();
  while (!st.quit) {
    await screen.frame((r) => st.draw(screen, r));
  }
}

final class _State {
  var query = '';
  var searched = '';
  var hits = <Hit>[];
  var sel = 0;
  var searching = false;

  Hit? series;
  var chapters = <Chapter>[];
  var csel = 0;
  var loadingCh = false;

  var status = 'type a manga title, press enter';
  var statusErr = false;

  String? downloading;
  var dlDone = 0;
  var dlTotal = 0;

  var quit = false;
  var quitAsked = false;

  void draw(Screen s, Region r) {
    final [head, body, line, foot] = r.rows([1, 0, 1, 3]);
    head.write(
      series == null
          ? '✻ rawfree · ↑↓ enter · ctrl+o browser · esc quit'
          : '✻ rawfree · enter download · o browser · b back',
      color: 208,
    );
    var msg = status;
    if (downloading != null && dlTotal > 0) {
      msg = '↓ $downloading $dlDone/$dlTotal';
    }
    line.write(
      msg,
      color: statusErr ? 203 : (msg.startsWith('✓') ? 78 : 240),
    );
    if (s.pressed('ctrl+c')) _quit();
    if (series case final open?) {
      if (chapters.isEmpty) {
        body.write(loadingCh ? '  loading chapters…' : '  no chapters',
            color: 240);
      } else {
        csel = body.list([for (final c in chapters) c.title], csel);
      }
      foot
          .box(open['title'] ?? 'manga')
          .write('enter downloads the chapter', color: 240);
      if (s.pressed('enter') && chapters.isNotEmpty) {
        _download(chapters[csel]);
      }
      if (s.pressed('o')) _browse(open['url']!);
      if (s.pressed('b') || s.pressed('escape')) series = null;
    } else {
      query = foot.box('search').input(query);
      if (hits.isEmpty) {
        body.write(searching ? '  searching…' : '  no results yet',
            color: 240);
      } else {
        sel = body.list([for (final h in hits) h['title'] ?? ''], sel);
      }
      if (s.pressed('enter') && query.trim() != searched) {
        _search();
      } else if (s.pressed('enter') && hits.isNotEmpty) {
        _openSeries(hits[sel]);
      }
      if (s.pressed('ctrl+o') && hits.isNotEmpty) _browse(hits[sel]['url']!);
      if (s.pressed('escape')) _quit();
    }
  }

  void _quit() {
    if (downloading != null && !quitAsked) {
      quitAsked = true;
      statusErr = true;
      status = '$downloading is still downloading · press again to quit';
      return;
    }
    quit = true;
  }

  void _browse(String url) {
    Shell.open(url).then((_) {
      statusErr = false;
      status = 'opened in browser';
    }).catchError((Object e) {
      statusErr = true;
      status = '✗ ${_short(e)}';
    });
  }

  void _search() {
    final q = query.trim();
    if (q.isEmpty) return;
    searched = q;
    searching = true;
    statusErr = false;
    status = 'searching…';
    searchManga(q).then((found) {
      hits = found;
      sel = 0;
      searching = false;
      status = found.isEmpty ? 'no results' : '${found.length} result(s)';
    }).catchError((Object e) {
      searching = false;
      statusErr = true;
      status = '✗ ${_short(e)}';
    });
  }

  void _openSeries(Hit h) {
    series = h;
    chapters = [];
    csel = 0;
    loadingCh = true;
    statusErr = false;
    status = 'loading chapters…';
    resolveChapters(h['url']!).then((found) {
      chapters = found;
      loadingCh = false;
      status = '${found.length} chapter(s)';
    }).catchError((Object e) {
      loadingCh = false;
      statusErr = true;
      status = '✗ ${_short(e)}';
    });
  }

  void _download(Chapter c) {
    if (downloading != null) {
      status = 'already downloading…';
      return;
    }
    downloading = c.title;
    quitAsked = false;
    // Read now: the user may go back to the search before the images load.
    final dir = 'downloads/${_safe(series?['title'] ?? 'manga')}/${_safe(c.title)}';
    dlDone = 0;
    dlTotal = 0;
    statusErr = false;
    () async {
      try {
        final imgs = await chapterImages(c.postId);
        if (imgs.isEmpty) {
          statusErr = true;
          status = '✗ ${c.title}: no images found';
          downloading = null;
          return;
        }
        dlTotal = imgs.length;
        var failed = 0;
        for (final (i, u) in imgs.indexed) {
          dlDone = i + 1;
          final img = await Http.get(u,
              headers: {..._headers, 'referer': '$_base/'}, retries: 2);
          if (!img.ok()) {
            failed++;
            await img.close();
            continue;
          }
          final data = await img.bytes();
          // An expired signed URL serves a <1 KB stub.
          if (data.length < 1024) {
            failed++;
            continue;
          }
          // Numbered pages: the host answers `application/octet-stream`
          // and its URLs carry no extension, so `img.name()` is a bare id.
          final name =
              '${'${i + 1}'.padLeft(3, '0')}${_imgExt(data, img)}';
          await Fs.dir(dir).file(name).write(data);
        }
        status = '✓ ${c.title} ($dlTotal img) → $dir'
            '${failed > 0 ? ' · $failed failed, retry the chapter' : ''}';
      } catch (e) {
        statusErr = true;
        status = '✗ ${_short(e)}';
      }
      downloading = null;
    }();
  }
}

// --- rawfree API (JSON only, works where HTML is region-blocked) ---

Future<Json> _apiGet(String path) async {
  final res = await Http.get('$_base/wp-json/wp/v2/$path',
      headers: _headers, retries: 2);
  if (!res.ok()) {
    final text = await res.text();
    await res.close();
    throw StateError('HTTP ${res.status()}: $text');
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
    out.add({'title': title!.trim(), 'url': url});
  }

  final q = Uri.encodeQueryComponent(query);
  final tags =
      await _apiGet('tags?search=$q&per_page=$limit');
  for (final t in tags) {
    if (out.length >= limit) break;
    add(_htmlText(t.$('name').value<String>() ?? ''),
        t.$('link').value<String>());
  }
  final posts = await _apiGet(
      'posts?search=$q&per_page=$limit&_embed=wp:featuredmedia');
  for (final p in posts) {
    if (out.length >= limit) break;
    add(_titleOf(p), p.$('link').value<String>());
  }
  return out;
}

Future<int?> _seriesTag(List<int> ids) async {
  if (ids.isEmpty) return null;
  if (ids.length == 1) return ids.first;
  final tags =
      await _apiGet('tags?include=${ids.join(',')}&per_page=100');
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
  final segs =
      Uri.parse(pageUrl).pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) throw StateError('bad url');
  final sq = Uri.encodeQueryComponent(segs.last);
  final posts = await _apiGet('posts?slug=$sq&_fields=id,tags');
  for (final p in posts) {
    if (p.$('id').value<int>() == null) continue;
    final tagIds = p.$('tags').value<List<int>>() ?? [];
    final tagId = await _seriesTag(tagIds);
    if (tagId == null) throw StateError('no series tag');
    return _toChapters(await _apiGet(
        'posts?tags=$tagId&per_page=100&_fields=id,link,title'));
  }
  final tags = await _apiGet('tags?slug=$sq&_fields=id');
  for (final t in tags) {
    final tagId = t.$('id').value<int>();
    if (tagId == null) continue;
    return _toChapters(await _apiGet(
        'posts?tags=$tagId&per_page=100&_fields=id,link,title'));
  }
  throw StateError('not found');
}

/// Chapter page images via the theme's AJAX endpoint.
Future<List<String>> chapterImages(int postId) async {
  final out = <String>[];
  final seen = <String>{};
  var index = 0;
  for (var round = 0; round < 12; round++) {
    final decoded = await Http.post('$_base/wp-admin/admin-ajax.php', body: {
      'action': 'z_do_ajax',
      '_action': 'decode_images',
      'p': '$postId',
      'img_index': '$index',
      'content': '',
      'nonce': 'x',
    }).json();
    final mes = decoded.$('mes').value<String>() ?? '';
    if (mes.isNotEmpty) {
      for (final img in Html.parse(mes, baseUrl: '$_base/').$('img')) {
        final src = img.attr('src') ??
            img.attr('data-src') ??
            img.attr('data-original') ??
            img.attr('data-lazy-src');
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
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
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
