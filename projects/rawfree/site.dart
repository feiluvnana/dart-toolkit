// rawfree.you is WordPress: chapters are posts, series are tags.
library;

import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';

const baseUrl = 'https://rawfree.you';

// The image CDN's certificate chain doesn't verify in Dart, hence `insecure`.
final site = Http.client(
  base: '$baseUrl/',
  headers: {
    'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'accept-language': 'ja,en-US;q=0.9,en;q=0.8',
    'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    'referer': '$baseUrl/',
  },
  insecure: ['pubg-img.si'],
);
final wpApi = site.copy(base: '$baseUrl/wp-json/wp/v2/', check: true);
final anilist = Http.client(headers: {'accept': 'application/json'}, timeout: 15.seconds, retries: 1, check: true);

typedef Hit = ({String title, String url});
typedef Chapter = ({String title, String url, int postId});
typedef Slice<T> = ({List<T> items, bool more});

// The site only knows Japanese titles, so an English or romaji query also
// searches the Japanese titles AniList has for it.
Future<Slice<Hit>> searchManga(String query, {int limit = 30, int page = 1}) async {
  limit = limit.clamp(1, 100);
  final terms = {query, ...await nativeTitles(query)};
  final results = await Future.wait([for (final t in terms) searchTerm(t, limit, page)]);
  final seen = <String>{};
  return (
    items: [for (final r in results) ...r.items].where((h) => seen.add(h.url)).take(limit).toList(),
    more: results.any((r) => r.more),
  );
}

Future<Slice<Hit>> searchTerm(String term, int limit, int page) async {
  final paging = {'search': term, 'per_page': limit, 'page': page};
  final [tags, posts] = await Future.wait([
    wpGet('tags', paging, page),
    wpGet('posts', {...paging, '_embed': 'wp:featuredmedia'}, page),
  ]);
  return (
    items: [
      for (final t in tags.json) (title: plainText(t.$('name').or('')), url: t.$('link').or('')),
      for (final p in posts.json) (title: titleOf(p), url: p.$('link').or('')),
    ].where((h) => h.url.isNotEmpty && h.title.isNotEmpty).take(limit).toList(),
    more: tags.more || posts.more,
  );
}

final nativeTitleCache = <String, Future<List<String>>>{};
Future<List<String>> nativeTitles(String query) => nativeTitleCache.putIfAbsent(query, () async {
  if (!RegExp('[A-Za-z0-9]').hasMatch(query)) return const []; // already Japanese
  try {
    final data = await anilist
        .post(
          'https://graphql.anilist.co',
          body: .json({
            'query': r'query ($q: String) { Page(perPage: 5) { media(search: $q, type: MANGA, sort: SEARCH_MATCH) { title { native } } } }',
            'variables': {'q': query},
          }),
        )
        .json();
    return {
      ...data.$('data.Page.media.*.title.native').asList<String>().map((s) => s.trim()).where((s) => s.isNotEmpty),
    }.take(3).toList();
  } catch (_) {
    return const [];
  }
});

// Works with either a series URL or a chapter URL. Newest chapters first.
Future<Slice<Chapter>> resolveChapters(String url, {int page = 1}) async {
  final slug = Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).lastOrNull;
  if (slug == null) throw ContentException('bad url', url);

  Future<Slice<Chapter>> chapters(int tag) async {
    final r = await wpGet('posts', {'tags': tag, 'per_page': 100, 'page': page, '_fields': 'id,link,title'}, page);
    return (
      items: [for (final p in r.json) (title: titleOf(p).trim(), url: p.$('link').or(''), postId: p.$('id').or(0))]
          .where((c) => c.postId != 0 && c.url.isNotEmpty && c.title.isNotEmpty)
          .toList(),
      more: r.more,
    );
  }

  for (final p in (await wpGet('posts', {'slug': slug, '_fields': 'id,tags'})).json) {
    final ids = p.$('tags').asList<int>();
    if (ids.isEmpty) throw const ContentException('no series tag');
    if (ids.length == 1) return chapters(ids.single);
    // With several tags, the series is the one with the most posts.
    final tags = (await wpGet('tags', {'include': ids.join(','), 'per_page': 100})).json;
    final best = tags.isEmpty ? null : tags.reduce((a, b) => b.$('count').or(0) > a.$('count').or(0) ? b : a);
    return chapters(best?.$('id').value<int>() ?? ids.first);
  }
  for (final t in (await wpGet('tags', {'slug': slug, '_fields': 'id'})).json) {
    if (t.$('id').value<int>() case final id?) return chapters(id);
  }
  throw ContentException('series not found', url);
}

// Image URLs in reading order, with null for pages the site doesn't serve.
//
// The post excerpt lists an id per page, and an AJAX endpoint turns the ids
// into CDN URLs. For older chapters it only serves the last page or two, so
// match by id and leave gaps, rather than quietly saving a short chapter.
// Some chapters are one merged image with no ids; then take what's served.
Future<List<String?>> chapterImages(int postId) async {
  final [ids, served] = await Future.wait([pageIds(postId), servedImages(postId)]);
  final byId = {for (final u in served) Uri.parse(u).pathSegments.lastOrNull ?? '': u};
  if (!ids.any(byId.containsKey)) return [...served, for (var i = served.length; i < ids.length; i++) null];
  return [for (final id in ids) byId[id]];
}

Future<List<String>> pageIds(int postId) async {
  final r = await wpGet('posts/$postId', {'_fields': 'excerpt'});
  final ids = plainText(r.json.$('excerpt.rendered').or('')).split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
  return ids.every(RegExp(r'^[a-z0-9]{8,16}$').hasMatch) ? ids.toList() : const [];
}

// The endpoint returns images in batches. Past the end it keeps answering
// with a bigger index and no images, so stop when a batch adds nothing.
Future<List<String>> servedImages(int postId) async {
  final out = <String>{};
  for (var index = 0, round = 0; round < 50; round++) {
    final r = await site
        .post(
          'wp-admin/admin-ajax.php',
          body: .form({'action': 'z_do_ajax', '_action': 'decode_images', 'p': postId, 'img_index': index}),
        )
        .json();
    final before = out.length;
    for (final img in Html.parse(r.$('mes').or(''), base: '$baseUrl/').$('img')) {
      final src = img.attr('src') ?? img.attr('data-src') ?? img.attr('data-original') ?? img.attr('data-lazy-src');
      if (src != null && src.isNotEmpty && !src.startsWith('data:')) out.add(src);
    }
    final next = r.$('img_index').or(index + 1);
    if (out.length == before || next <= index) break;
    index = next;
  }
  return out.toList();
}

Future<({Json json, bool more})> wpGet(String path, Map<String, Object?> query, [int page = 1]) async {
  final res = await wpApi.get(path, query: query);
  final pages = int.tryParse(res.header('x-wp-totalpages') ?? '') ?? 1;
  return (json: await res.json(), more: pages > page);
}

String titleOf(Json item) => plainText(item.$('title.rendered').value<String>() ?? item.$('title').or(''));

// WordPress titles contain HTML entities and tags.
String plainText(String html) => Html.parse(html).text();
