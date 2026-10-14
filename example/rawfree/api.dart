/// rawfree data layer: manga search, chapter resolve, page download.
///
/// Pure network + filesystem, no UI: progress flows out through [Job]
/// fields and the [fetchChapter] callbacks, consumed by the console flow
/// (`../rawfree.dart`).
library;

import 'dart:async';
import 'dart:io'
    show HttpClient, HttpClientRequest, HttpClientResponse, HttpException, HandshakeException, SocketException, TlsException, X509Certificate;
import 'dart:typed_data' show BytesBuilder;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/shell.dart';

const _base = 'https://rawfree.you';

const _headers = {
  'accept':
      'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'ja,en-US;q=0.9,en;q=0.8',
  'user-agent':
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
};

typedef Hit = ({String title, String url});
typedef Chapter = ({String title, String url, int postId});

/// One page of manga search results. [hasMore] is true when another [page]
/// exists, so callers can offer "load more" until it flips false.
typedef SearchPage = ({List<Hit> hits, bool hasMore});

/// One page of a series' chapters, newest first. See [SearchPage].
typedef ChapterPage = ({List<Chapter> chapters, bool hasMore});

enum JobStatus { queued, active, done, failed }

final class Job {
  Job(this.series, this.chapter);

  final Hit series;
  final Chapter chapter;
  var status = JobStatus.queued, done = 0, total = 0;

  /// Page indexes to (re)fetch; empty means all of them.
  final missing = <int>[];

  /// First page-level failure reason, if any (`HTTP 403`, `empty reply`,
  /// `network: …`). Unset on success.
  String? error;

  String get dir =>
      'downloads/${safeName(series.title)}/${safeName(chapter.title)}';
}

/// Series first, then chapters, deduplicated by URL.
///
/// The site index is Japanese-only, so a romaji/English query matches
/// nothing directly: it is bridged through AniList's title search, which
/// maps e.g. "aharen" to its native title, and every term is searched
/// (raw query first). Pure Japanese queries skip the bridge. WordPress
/// caps `per_page` at 100, so [limit] is clamped to 1–100. [page] is
/// 1-based; requesting past the last page throws [HttpException] (HTTP
/// 400), so only advance while the previous page's [hasMore] is true.
Future<SearchPage> searchManga(
  String query, {
  int limit = 30,
  int page = 1,
}) async {
  if (page < 1) throw ArgumentError.value(page, 'page', 'must be >= 1');
  limit = limit.clamp(1, 100);
  final terms = <String>[query];
  for (final native in await _nativeTitles(query)) {
    if (!terms.contains(native)) terms.add(native);
  }
  // Fetch every term concurrently, merge in term order with a global cap.
  final pages = await Future.wait(
    [for (final term in terms) _searchTerm(term, limit, page)],
  );
  final out = <Hit>[];
  final seen = <String>{};
  var totalPages = 1;
  for (final termPage in pages) {
    for (final hit in termPage.hits) {
      if (out.length >= limit) break;
      if (seen.add(hit.url)) out.add(hit);
    }
    if (termPage.totalPages > totalPages) totalPages = termPage.totalPages;
  }
  return (hits: out, hasMore: totalPages > page);
}

/// Tags then posts for a single search [term], so series rank above their
/// chapters.
Future<({List<Hit> hits, int totalPages})> _searchTerm(
  String term,
  int limit,
  int page,
) async {
  final q = Uri.encodeQueryComponent(term);
  final results = await Future.wait([
    _apiPage('tags?search=$q&per_page=$limit&page=$page'),
    _apiPage(
      'posts?search=$q&per_page=$limit&page=$page&_embed=wp:featuredmedia',
    ),
  ]);
  final tags = results[0];
  final posts = results[1];
  final out = <Hit>[];
  final seen = <String>{};
  void add(String? title, String? url) {
    if (url == null || url.isEmpty) return;
    if (!seen.add(url)) return;
    if ((title ?? '').trim().isEmpty) return;
    out.add((title: title!.trim(), url: url));
  }

  for (final t in tags.json) {
    if (out.length >= limit) break;
    add(
      _htmlText(t.$('name').value<String>() ?? ''),
      t.$('link').value<String>(),
    );
  }
  for (final p in posts.json) {
    if (out.length >= limit) break;
    add(_titleOf(p), p.$('link').value<String>());
  }
  return (
    hits: out,
    totalPages:
        tags.totalPages > posts.totalPages ? tags.totalPages : posts.totalPages,
  );
}

/// Native (Japanese) titles for a romaji/English [query] via AniList's
/// title search, best-effort: any failure (network, rate limit, no match)
/// yields no titles and the raw query results still stand. Results are
/// cached per query for the session, so paging and re-searches cost one
/// lookup.
final _nativeCache = <String, Future<List<String>>>{};

Future<List<String>> _nativeTitles(String query) =>
    _nativeCache.putIfAbsent(query, () async {
      // No ASCII letters/digits: already Japanese, the site matches it.
      if (!RegExp(r'[A-Za-z0-9]').hasMatch(query)) return const [];
      try {
        final res = await Http.post(
          'https://graphql.anilist.co',
          body: Body.json({
            'query':
                'query (\$q: String) { Page(perPage: 5) { media(search: \$q, type: MANGA, sort: SEARCH_MATCH) { title { native } } } }',
            'variables': {'q': query},
          }),
          headers: {'accept': 'application/json'},
          timeout: const Duration(seconds: 15),
          retries: 1,
        );
        if (!res.isSuccess()) {
          await res.close();
          return const [];
        }
        final data = await res.json();
        final out = <String>[];
        final seen = <String>{};
        for (final m in data.$('data.Page.media')) {
          final native = m.$('title.native').value<String>()?.trim() ?? '';
          if (native.isNotEmpty && seen.add(native)) out.add(native);
          if (out.length >= 3) break;
        }
        return out;
      } catch (_) {
        return const [];
      }
    });

/// Chapters of the series behind a chapter or series URL, newest first.
///
/// [page]/[perPage] paginate the chapter list ([perPage] clamped to 1–100,
/// [page] 1-based like [searchManga]); [ChapterPage.hasMore] tells whether
/// older chapters remain.
Future<ChapterPage> resolveChapters(
  String pageUrl, {
  int page = 1,
  int perPage = 100,
}) async {
  if (page < 1) throw ArgumentError.value(page, 'page', 'must be >= 1');
  perPage = perPage.clamp(1, 100);
  final segs =
      Uri.parse(pageUrl).pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) throw FormatException('bad url', pageUrl);
  final sq = Uri.encodeQueryComponent(segs.last);
  final posts = await _apiGet('posts?slug=$sq&_fields=id,tags');
  for (final p in posts) {
    if (p.$('id').value<int>() == null) continue;
    final tagIds = p.$('tags').listOf<int>() ?? [];
    final tagId = await _seriesTag(tagIds);
    if (tagId == null) throw const FormatException('no series tag');
    final chapters = await _apiPage(
      'posts?tags=$tagId&per_page=$perPage&page=$page&_fields=id,link,title',
    );
    return (
      chapters: _toChapters(chapters.json),
      hasMore: chapters.totalPages > page,
    );
  }
  final tags = await _apiGet('tags?slug=$sq&_fields=id');
  for (final t in tags) {
    final tagId = t.$('id').value<int>();
    if (tagId == null) continue;
    final chapters = await _apiPage(
      'posts?tags=$tagId&per_page=$perPage&page=$page&_fields=id,link,title',
    );
    return (
      chapters: _toChapters(chapters.json),
      hasMore: chapters.totalPages > page,
    );
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
      body: Body.form({
        'action': 'z_do_ajax',
        '_action': 'decode_images',
        'p': '$postId',
        'img_index': '$index',
        'content': '',
        'nonce': 'x',
      }),
    ).json();
    final mes = decoded.$('mes').value<String>() ?? '';
    if (mes.isNotEmpty) {
      for (final img in Html.parse(mes, baseUrl: '$_base/').$('img')) {
        final src =
            img.attr('src') ??
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

/// Download every page of [job] into [Job.dir], four pages at a time.
///
/// Sets [Job.total]/[Job.done] as it goes (plus [onTotal]/[onTick] for UIs
/// that want callbacks instead of polling), records failures in
/// [Job.missing], and leaves [Job.status] as done or failed. Throws only
/// when no images exist at all.
Future<void> fetchChapter(
  Job job, {
  void Function(int total)? onTotal,
  void Function()? onTick,
}) async {
  final imgs = await chapterImages(job.chapter.postId);
  if (imgs.isEmpty) throw FormatException('no images found');
  final todo =
      job.missing.isEmpty
          ? [for (var i = 0; i < imgs.length; i++) i]
          : [...job.missing];
  job
    ..total = imgs.length
    ..done = imgs.length - todo.length;
  onTotal?.call(imgs.length);
  for (var k = 0; k < job.done; k++) {
    onTick?.call();
  }
  final failed = <int>[];
  var next = 0;
  Future<void> lane() async {
    while (next < todo.length) {
      final i = todo[next++];
      final String? err = await _fetchPage(job, i, imgs[i]);
      if (err == null) {
        job.done++;
      } else {
        failed.add(i);
        job.error ??= err;
      }
      onTick?.call();
    }
  }

  await Future.wait([for (var k = 0; k < 4; k++) lane()]);
  job.missing
    ..clear()
    ..addAll(failed..sort());
  job.status = failed.isEmpty ? JobStatus.done : JobStatus.failed;
}

/// Open the series page in the desktop browser.
Future<void> openSeries(Hit hit) => Shell.openInDefaultApp(hit.url);

/// One page; null on success, else a short reason (non-2xx with status,
/// network error, or a <1 KB stub that is usually an error page or an
/// expired-URL placeholder).
Future<String?> _fetchPage(Job job, int i, String url) async {
  late final int status;
  late final List<int> data;
  late final String? contentType;
  try {
    final (int s, List<int> d, String? c) = await _getPage(url);
    status = s;
    data = d;
    contentType = c;
  } on Exception catch (e) {
    return 'p${i + 1}: ${shortError(e)}';
  }
  if (status < 200 || status > 299) return 'HTTP $status p${i + 1}';
  if (data.length < 1024) return 'empty reply p${i + 1}';
  await (Reader.of(data) >
      Fs.dir(job.dir).file(
        '${'${i + 1}'.padLeft(3, '0')}${_imgExt(data, contentType)}',
      ));
  return null;
}

/// Image bytes via the toolkit HTTP client, falling back to a scoped
/// insecure-TLS client when the host's chain is unverifiable (the image
/// CDN serves a chain Dart cannot build: `CERTIFICATE_VERIFY_FAILED`).
/// The fallback applies ONLY to [_insecureTlsSuffixes]; anything else
/// rethrows and fails the page with its reason.
Future<(int status, List<int> data, String? contentType)> _getPage(String url) async {
  try {
    final img = await Http.get(
      url,
      headers: {..._headers, 'referer': '$_base/'},
      retries: 2,
    );
    final bool ok = img.isSuccess();
    final int status = img.statusCode();
    final List<int> data = ok ? await img.bytes() : const <int>[];
    final String? contentType = img.header('content-type');
    if (!ok) await img.close();
    return (status, data, contentType);
  } on HandshakeException {
    if (!_insecureTls(url)) rethrow;
    return _getPageInsecure(url);
  } on TlsException {
    if (!_insecureTls(url)) rethrow;
    return _getPageInsecure(url);
  }
}

/// CDN suffixes whose TLS chain is known-unverifiable. Verification is
/// skipped only for these; image bytes are public content, so the residual
/// MITM risk is accepted and documented here, not silently.
const _insecureTlsSuffixes = <String>['pubg-img.si'];

bool _insecureTls(String url) {
  final String host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return host.isNotEmpty && _insecureTlsSuffixes.any((String s) => host == s || host.endsWith('.$s'));
}

/// Same GET over `dart:io`, skipping certificate verification. Retries
/// transient stalls like the toolkit client does.
Future<(int status, List<int> data, String? contentType)> _getPageInsecure(String url) async {
  final Uri uri = Uri.parse(url);
  Object? last;
  for (int attempt = 0; attempt < 3; attempt++) {
    final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      client.badCertificateCallback = (X509Certificate cert, String host, int port) =>
          _insecureTls('https://$host:$port');
      final HttpClientRequest req = await client.getUrl(uri).timeout(const Duration(seconds: 30));
      for (final MapEntry<String, String> h in <String, String>{..._headers, 'referer': '$_base/'}.entries) {
        req.headers.set(h.key, h.value);
      }
      final HttpClientResponse res = await req.close().timeout(const Duration(minutes: 2));
      final BytesBuilder out = BytesBuilder();
      await for (final List<int> chunk in res) {
        out.add(chunk);
      }
      return (res.statusCode, out.takeBytes(), res.headers.contentType?.mimeType);
    } on TimeoutException catch (e) {
      last = e;
    } on SocketException catch (e) {
      last = e;
    } on HttpException catch (e) {
      last = e;
    } finally {
      client.close(force: true);
    }
  }
  throw last ?? const HttpException('insecure fetch failed');
}

Future<Json> _apiGet(String path) async => (await _apiPage(path)).json;

/// Like [_apiGet], but also reports the `X-WP-TotalPages` response header
/// so callers can paginate without probing past the end.
Future<({Json json, int totalPages})> _apiPage(String path) async {
  final res = await Http.get(
    '$_base/wp-json/wp/v2/$path',
    headers: _headers,
    retries: 2,
  );
  if (!res.isSuccess()) {
    final text = await res.text();
    await res.close();
    throw HttpException('HTTP ${res.statusCode()}: ${shortError(text)}',
        uri: Uri.parse(res.finalUrl()));
  }
  final totalPages =
      int.tryParse(res.header('x-wp-totalpages') ?? '') ?? 1;
  final json = await res.json();
  return (json: json, totalPages: totalPages < 1 ? 1 : totalPages);
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

/// File extension for a downloaded chapter image.
///
/// The image host answers `application/octet-stream` and its URLs carry no
/// extension, so the name is a bare id (`kbipl910tmb8`). Sniff the
/// magic bytes, falling back to the content-type and then `.jpg` (what the
/// host serves), so pages land as `001.jpg`, `002.jpg`, … and open in any
/// viewer.
String _imgExt(List<int> bytes, String? contentType) {
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
  switch (contentType?.split(';').first.trim().toLowerCase()) {
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

String safeName(String s) {
  final clean = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final cut = clean.length > 80 ? clean.substring(0, 80) : clean;
  return cut.isEmpty ? 'manga' : cut;
}

String shortError(Object e) {
  final line = '$e'.split('\n').first.trim();
  return line.length > 100 ? '${line.substring(0, 100)}…' : line;
}
