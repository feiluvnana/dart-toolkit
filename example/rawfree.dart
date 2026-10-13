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
///
/// Downloads go to `downloads/<series>/<chapter>/`. Network failures show a
/// one-line status and the app keeps running.
library;

import 'dart:io' show Platform, Process, stderr;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
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

enum _View { search, chapters }

Future<void> main(List<String> argv) async {
  try {
    await Tui.run((screen) => _app(screen));
  } catch (e) {
    stderr.writeln('tui needs a terminal: $e');
  }
}

Future<void> _app(Screen screen) async {
  final st = _State();
  while (!st.quit) {
    await screen.frame((r) => st.frame(screen, r));
  }
}

final class _State {
  _View view = _View.search;
  String query = '';
  bool dirty = true;
  List<Hit> hits = [];
  int sel = 0;
  int scroll = 0;
  bool searching = false;

  String? seriesTitle;
  String? seriesUrl;
  List<Chapter> chapters = [];
  int csel = 0;
  int cscroll = 0;
  bool loadingCh = false;

  String status = 'type a manga title, press enter';
  bool statusErr = false;

  String? downloading;
  int dlDone = 0;
  int dlTotal = 0;

  bool quit = false;

  void frame(Screen s, Region r) {
    _input(s);
    _draw(s, r);
  }

  void _input(Screen s) {
    if (s.pressed('ctrl+c')) {
      quit = true;
      return;
    }
    if (view == _View.search) {
      final typed = s.typed();
      if (typed.isNotEmpty) {
        query += typed;
        dirty = true;
      }
      if (s.pressed('backspace') && query.isNotEmpty) {
        final runes = query.runes.toList()..removeLast();
        query = String.fromCharCodes(runes);
        dirty = true;
      }
      if (s.pressed('up')) {
        sel = (sel - 1 + hits.length).clamp(0, hits.isEmpty ? 0 : hits.length - 1);
      }
      if (s.pressed('down')) {
        sel = (sel + 1).clamp(0, hits.isEmpty ? 0 : hits.length - 1);
      }
      if (s.pressed('enter')) {
        if (dirty && query.trim().isNotEmpty) {
          _search();
        } else if (hits.isNotEmpty) {
          _openSeries(hits[sel.clamp(0, hits.length - 1)]);
        }
      }
      // NB: plain `o` would also fire while typing, so browser is ctrl+o here.
      if (s.pressed('ctrl+o')) {
        final i = sel.clamp(0, hits.length - 1);
        if (hits.isNotEmpty) _browse(hits[i]['url']!);
      }
      if (s.pressed('escape')) quit = true;
    } else {
      if (s.pressed('up')) {
        csel = (csel - 1 + chapters.length)
            .clamp(0, chapters.isEmpty ? 0 : chapters.length - 1);
      }
      if (s.pressed('down')) {
        csel = (csel + 1)
            .clamp(0, chapters.isEmpty ? 0 : chapters.length - 1);
      }
      if (s.pressed('enter') && chapters.isNotEmpty) {
        _download(chapters[csel.clamp(0, chapters.length - 1)]);
      }
      if (s.pressed('o') && seriesUrl != null) _browse(seriesUrl!);
      if (s.pressed('b') || s.pressed('escape')) view = _View.search;
    }
  }

  void _draw(Screen s, Region r) {
    final hint = view == _View.search
        ? '↑↓ move · enter open · ctrl+o browser · esc quit'
        : 'enter download · o browser · b back';
    // NB: split rows first: cols() consumes its region's cursor, so a
    // header built with cols() on `r` would leave nothing below it.
    final [top, rest] = r.rows([1, 0]);
    final [head, tail] = top.cols([11, 0]);
    head.write('✻ rawfree', color: 208, bold: true);
    tail.write(hint, color: 240);
    final [list, statusRow, bottom] = rest.rows([0, 1, 3]);
    // Keep the cursor on screen: the list owns everything but the
    // header (1), status (1) and input box (3) rows.
    final visible = (s.height() - 5).clamp(1, 1 << 30);

    if (view == _View.search) {
      while (sel < scroll) {
        scroll--;
      }
      while (sel >= scroll + visible) {
        scroll++;
      }
      _drawList(list, hits.map((h) => h['title'] ?? '').toList(), sel,
          scroll, empty: searching ? '  searching…' : '  no results yet');
    } else {
      while (csel < cscroll) {
        cscroll--;
      }
      while (csel >= cscroll + visible) {
        cscroll++;
      }
      _drawList(list, chapters.map((c) => c.title).toList(), csel, cscroll,
          empty: loadingCh ? '  loading chapters…' : '  no chapters');
    }

    var msg = status;
    if (downloading != null && dlTotal > 0) {
      msg = '↓ $downloading $dlDone/$dlTotal';
    }
    statusRow.write(
      msg,
      color: statusErr ? 203 : (msg.startsWith('✓') ? 78 : 240),
    );

    final box = bottom.box(view == _View.search ? 'search' : (seriesTitle ?? 'manga'));
    if (view == _View.search) {
      box.write('> $query▌', bold: true);
    } else {
      box.write('enter downloads the chapter as images · o opens the page',
          color: 240);
    }
  }

  void _drawList(
    Region list,
    List<String> rows,
    int cur,
    int sc, {
    required String empty,
  }) {
    if (rows.isEmpty) {
      list.write(empty, color: 240);
      return;
    }
    for (var i = sc; i < rows.length; i++) {
      final mark = i == cur ? '❯ ' : '  ';
      list.write('$mark${rows[i]}', bold: i == cur, color: i == cur ? 81 : null);
    }
  }

  void _search() {
    final q = query.trim();
    searching = true;
    statusErr = false;
    status = 'searching…';
    searchManga(q).then((found) {
      hits = found;
      sel = 0;
      scroll = 0;
      searching = false;
      dirty = false;
      status = found.isEmpty ? 'no results' : '${found.length} result(s)';
    }).catchError((Object e) {
      searching = false;
      statusErr = true;
      status = '✗ ${_short(e)}';
    });
  }

  void _openSeries(Hit h) {
    seriesTitle = h['title'];
    seriesUrl = h['url'];
    view = _View.chapters;
    chapters = [];
    csel = 0;
    cscroll = 0;
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
    dlDone = 0;
    dlTotal = 0;
    statusErr = false;
    () async {
      try {
        final imgs = await chapterImages(c.postId);
        dlTotal = imgs.length;
        final dir = 'downloads/${_safe(seriesTitle ?? 'manga')}/${_safe(c.title)}';
        var i = 0;
        var tiny = 0;
        for (final u in imgs) {
          i++;
          dlDone = i;
          final res = await Http.get(u, headers: {
            ..._headers,
            'referer': '$_base/',
          });
          if (res.status() < 200 || res.status() >= 300) {
            await res.close();
            tiny++;
            continue;
          }
          final tail = Uri.parse(u).pathSegments.lastOrNull ?? 'img';
          final name = '${'$i'.padLeft(3, '0')}_$tail';
          final bytes = await res.bytes();
          if (bytes.length < 1024) tiny++; // expired signed URL stub
          await Fs.file('$dir/$name').write(bytes);
        }
        status = '✓ ${c.title} ($dlTotal img) → $dir'
            '${tiny > 0 ? ' · $tiny failed, retry the chapter' : ''}';
      } catch (e) {
        statusErr = true;
        status = '✗ ${_short(e)}';
      }
      downloading = null;
    }();
  }

  void _browse(String url) {
    try {
      final done = Platform.isMacOS
          ? Process.run('open', [url])
          : Platform.isLinux
              ? Process.run('xdg-open', [url])
              : Process.run('start', [url, ''], runInShell: true);
      done.then((_) {}).catchError((Object _) {});
      statusErr = false;
      status = 'opened in browser';
    } catch (e) {
      statusErr = true;
      status = '✗ ${_short(e)}';
    }
  }
}

// --- rawfree API (JSON only, works where HTML is region-blocked) ---

Future<Json> _apiGet(String url) async {
  final res = await Http.get(url, headers: _headers);
  if (res.status() < 200 || res.status() >= 300) {
    await res.close();
    throw StateError('HTTP ${res.status()}');
  }
  return res.json();
}

Future<Json> _postForm(String url, Map<String, String> fields) async {
  var current = url;
  final headers = {
    'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
    'x-requested-with': 'XMLHttpRequest',
    'referer': '$_base/',
    'user-agent': _headers['user-agent']!,
  };
  for (var hop = 0; hop < 4; hop++) {
    final res = await Http.post(
      current,
      body: Uri(queryParameters: fields).query,
      headers: headers,
    );
    if (const {301, 302, 303, 307, 308}.contains(res.status())) {
      final loc = res.header('location');
      await res.close();
      if (loc == null || loc.isEmpty) throw StateError('redirect loop');
      current = Uri.parse(current).resolve(loc).toString();
      continue;
    }
    if (res.status() < 200 || res.status() >= 300) {
      await res.close();
      throw StateError('HTTP ${res.status()}');
    }
    return res.json();
  }
  throw StateError('too many redirects');
}

String _unescape(String s) {
  var out = s
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      );
  const entities = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    '#039': "'",
    'nbsp': ' ',
    'ndash': '–',
    'mdash': '—',
    'lsquo': '‘',
    'rsquo': '’',
    'ldquo': '“',
    'rdquo': '”',
    'hellip': '…',
  };
  return out.replaceAllMapped(
    RegExp(r'&([a-zA-Z#0-9]+);'),
    (m) => entities[m.group(1)] ?? m.group(0)!,
  );
}

String _titleOf(Json item) {
  final nested = item.$('title.rendered').value<String>();
  if (nested != null) return _unescape(nested);
  return _unescape(item.$('title').value<String>() ?? '');
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
  final tags = await _apiGet('$_base/wp-json/wp/v2/tags?search=$q&per_page=$limit');
  for (final t in tags) {
    if (out.length >= limit) break;
    add(_unescape(t.$('name').value<String>() ?? ''), t.$('link').value<String>());
  }
  final posts = await _apiGet(
      '$_base/wp-json/wp/v2/posts?search=$q&per_page=$limit&_embed=wp:featuredmedia');
  for (final p in posts) {
    if (out.length >= limit) break;
    add(_titleOf(p), p.$('link').value<String>());
  }
  return out;
}

Future<int?> _seriesTag(List<int> ids) async {
  if (ids.isEmpty) return null;
  if (ids.length == 1) return ids.first;
  final tags = await _apiGet(
      '$_base/wp-json/wp/v2/tags?include=${ids.join(',')}&per_page=100');
  var best = ids.first;
  var bestCount = -1;
  for (final t in tags) {
    final id = t.$('id').value<num>()?.toInt();
    final count = t.$('count').value<num>()?.toInt() ?? 0;
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
    final id = p.$('id').value<num>()?.toInt();
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
  final posts = await _apiGet('$_base/wp-json/wp/v2/posts?slug=$sq&_fields=id,tags');
  for (final p in posts) {
    if (p.$('id').value<num>() == null) continue;
    final tagIds = [
      for (final t in p.$('tags')) t.value<num>()?.toInt(),
    ].whereType<int>().toList();
    final tagId = await _seriesTag(tagIds);
    if (tagId == null) throw StateError('no series tag');
    return _toChapters(await _apiGet(
        '$_base/wp-json/wp/v2/posts?tags=$tagId&per_page=100&_fields=id,link,title'));
  }
  final tags = await _apiGet('$_base/wp-json/wp/v2/tags?slug=$sq&_fields=id');
  for (final t in tags) {
    final tagId = t.$('id').value<num>()?.toInt();
    if (tagId == null) continue;
    return _toChapters(await _apiGet(
        '$_base/wp-json/wp/v2/posts?tags=$tagId&per_page=100&_fields=id,link,title'));
  }
  throw StateError('not found');
}

/// Chapter page images via the theme's AJAX endpoint.
Future<List<String>> chapterImages(int postId) async {
  final out = <String>[];
  final seen = <String>{};
  var index = 0;
  for (var round = 0; round < 12; round++) {
    final decoded = await _postForm('$_base/wp-admin/admin-ajax.php', {
      'action': 'z_do_ajax',
      '_action': 'decode_images',
      'p': '$postId',
      'img_index': '$index',
      'content': '',
      'nonce': 'x',
    });
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
    final going = decoded.$('going').value<num>()?.toInt() ?? 0;
    final next = decoded.$('img_index').value<num>()?.toInt() ?? index + 1;
    if (going != 1 || next <= index) break;
    index = next;
    final waitMs = decoded.$('next_timeout').value<num>()?.toInt() ?? 1000;
    await Future<void>.delayed(Duration(milliseconds: waitMs.clamp(0, 5000)));
  }
  return out;
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
