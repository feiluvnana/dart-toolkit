// Instagram's web API, as the website calls it: posts, stories, highlights
// and profile pictures.
library;

import 'dart:math';

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';

import '../feed.dart';
import '../job.dart';
import '../platform.dart';

const web = 'https://www.instagram.com';

final platform = Instagram();

final class Instagram extends Platform {
  @override
  final code = 'ins', name = 'Instagram', site = web;

  @override
  final kinds = const [Kind.posts, Kind.stories, Kind.highlights, Kind.profiles];

  @override
  final loginCookies = const {'sessionid'};

  // Instaloader's limits: 75 calls per 11 minutes, 200 for the post feed.
  late final apiRate = rate(75, 11.minutes, pause: 3.seconds), feedRate = rate(200, 11.minutes, pause: 3.seconds);

  @override
  bool matches(String input) => RegExp(r'^(?:https?://)?(?:www\.)?instagram\.com/').hasMatch(input.trim());

  @override
  Target parse(String input) {
    final s = input.trim();
    if (RegExp(r'instagram\.com/(?:[^/?#]+/)?(?:p|reels?|tv)/([^/?#]+)').firstMatch(s) case final m?) {
      return Target(this, m[1]!, post: m[1]);
    }
    final m = RegExp(r'instagram\.com/(?:stories/)?([^/?#]+)').firstMatch(s);
    if (m == null) return Target(this, username(s, name));
    if (const {
      'explore',
      'direct',
      'stories',
      'accounts',
      'developer',
      'about',
      'highlights',
    }.contains(m[1]!.toLowerCase())) {
      throw FormatException('"$input" is not an Instagram profile or post.');
    }
    return Target(this, m[1]!);
  }

  @override
  Client client(Cookies jar) => Http.client(
    base: web,
    rate: apiRate,
    check: true,
    cookies: jar,
    // Without the csrftoken echoed as a header, Instagram treats you as a bot.
    csrf: (cookie: 'csrftoken', header: 'x-csrftoken'),
    headers: {
      'accept': '*/*',
      'accept-language': 'en-US,en;q=0.9',
      'x-ig-app-id': '936619743392459',
      'x-requested-with': 'XMLHttpRequest',
      'sec-fetch-site': 'same-origin',
    },
  );

  @override
  Object explain(Object e) => switch (e) {
    HttpStatusException(status: final status && (401 || 403 || 429), :final method, :final url) =>
      'Instagram refused $method $url (HTTP $status): probably rate limited, try again in 15 minutes',
    _ => super.explain(e),
  };

  @override
  Future<void> explore(Job j) async {
    if (j.target.post case final code?) {
      final p = await post(j.api, code);
      await j.open(p.$('user.username').or(code), id: p.$('user.pk|user.id').text(), track: false);
      j.add(postFiles(p, j.folder(Kind.posts).dir(time(p).format('yyyy-MM')), j.index.posts[postCode(p)]));
      return j.phase(Kind.posts, '1 post', done: true);
    }
    final (profile: p, :first) = await profile(j.api, j.target.user);
    await j.open(p.name, id: p.id);
    late final feedApi = j.client(feedRate);
    await Future.wait([
      if (j.wants(Kind.profiles))
        Future(
          () => j.profiles([
            if (p.picture case final url?)
              (url: url, id: Fs.sanitize(Uri.parse(url).pathSegments.last), change: 'new profile picture', ext: ''),
          ]),
        ),
      if (j.wants(Kind.posts))
        feed(
          j,
          noun: 'post',
          // The profile lookup already read the first page.
          page: (cursor) => cursor == null && first != null ? Future.value(first) : posts(feedApi, p.name, cursor),
          id: postCode,
          items: postItems,
          time: time,
          files: (page) => [
            for (final x in page)
              ...postFiles(x, j.folder(Kind.posts).dir(time(x).format('yyyy-MM')), j.index.posts[postCode(x)]),
          ],
        ),
      if (j.wants(Kind.stories)) _stories(j, p),
      if (j.wants(Kind.highlights)) _highlights(j, p),
    ]);
  }

  Future<void> _stories(Job j, Profile p) async {
    j.phase(Kind.stories, 'fetching the stories up now');
    final items = [
      for (final r in await reels(j.api, [p.id], p.name)) ...r.items,
    ];
    for (final i in items) {
      j.index.stories[i.$('id').or('')] = i.$('taken_at').or(0);
    }
    j.add(storyFiles(items, (i) => j.folder(Kind.stories).dir(time(i).format('yyyy-MM'))));
    j.phase(Kind.stories, '${items.length} up now', done: true);
  }

  Future<void> _highlights(Job j, Profile p) async {
    final index = j.index;
    j.phase(Kind.highlights, 'listing highlights');
    final ids = await highlights(j.api, p);
    final now = <String, Set<String>>{};
    j.phase(Kind.highlights, 'fetching ${ids.length} highlights');
    await Future.wait([
      for (var i = 0; i < ids.length; i += 10)
        reels(j.api, ids.sublist(i, min(i + 10, ids.length)), p.name).then((reels) {
          for (final r in reels) {
            final title = r.title.isEmpty ? r.id : r.title;
            final items = {for (final item in r.items) item.$('id').or('')};
            if (index.highlights[title] case final before?) {
              final (added, removed) = (items.difference(before).length, before.difference(items).length);
              if (added + removed > 0) j.changed('highlight "$title": $added added, $removed removed');
            } else if (index.highlights.isNotEmpty) {
              j.changed('new highlight "$title"');
            }
            now[title] = items;
            j.add(storyFiles(r.items, (_) => j.folder(Kind.highlights).dir(Fs.sanitize(title))));
          }
          j.phase(Kind.highlights, 'fetched ${now.length} of ${ids.length} highlights');
        }),
    ]);
    for (final title in index.highlights.keys.where((t) => !now.containsKey(t))) {
      j.changed('highlight "$title" gone, files kept');
    }
    index.highlights = now;
    j.phase(Kind.highlights, '${ids.length} ${ids.length == 1 ? 'highlight' : 'highlights'}', done: true);
  }
}

// ── the API ──────────────────────────────────────────────────────────────

typedef Profile = ({String id, String name, String? picture});
typedef Reel = ({String id, String title, List<Json> items});

// A user id or name as a profile, and the first feed page when that is
// what carried it (one call instead of two), else the profile info.
Future<({Profile profile, Page? first})> profile(Client api, String name) async {
  Json u;
  Page? first;
  if (RegExp(r'^\d+$').hasMatch(name)) {
    u = (await json(api.get('/api/v1/users/$name/info/'))).$('user');
  } else {
    first = await posts(api, name, null);
    u = first.items.firstOrNull?.$('user') ?? Json.of(null);
    if (u.isEmpty) {
      u = (await json(api.get('/api/v1/users/web_profile_info/', query: {'username': name}))).$('data.user');
    }
  }
  return (
    profile: (
      id: u.$('pk|id').text() ?? (throw Exception('user not found: "$name"')),
      name: u.$('username').or(name),
      picture: u.$('hd_profile_pic_url_info.url|profile_pic_url_hd|profile_pic_url').text(),
    ),
    first: first,
  );
}

// One page (12 posts) of the profile grid.
Future<Page> posts(Client api, String user, String? cursor) async {
  final response = await json(
    api.post(
      '/graphql/query',
      headers: {'referer': '$web/$user/'},
      body: .form({
        'doc_id': '28975909992013618', // PolarisProfilePostsTabContentQuery
        'server_timestamps': true,
        'variables': Json.encode({
          'after': ?cursor,
          'data': {
            'count': 12,
            'include_reel_media_seen_timestamp': true,
            'include_relationship_info': true,
            'latest_besties_reel_media': true,
            'latest_reel_media': true,
          },
          'first': 12,
          'include_multi_captions': true,
          'username': user,
          '__relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider': true,
          '__relay_internal__pv__PolarisShortDramaEnabledrelayprovider': false,
          '__relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider': false,
        }),
      }),
    ),
  );
  final feed = response.$('data.xdt_api__v1__feed__user_timeline_graphql_connection');
  final more = feed.$('page_info.has_next_page').or(false);
  return (items: feed.$('edges.*.node').toList(), next: more ? feed.$('page_info.end_cursor').text() : null);
}

// One post by its shortcode: the first 11 characters are its media id in base 64.
Future<Json> post(Client api, String code) async {
  const digits = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final id = code
      .substring(0, min(11, code.length))
      .split('')
      .fold(BigInt.zero, (n, c) => n * BigInt.from(64) + BigInt.from(digits.indexOf(c)));
  final item = (await json(api.get('/api/v1/media/$id/info/'))).$('items.0');
  return item.isEmpty ? throw Exception('post not found: $code') : item;
}

// Every highlight as "highlight:<id>" (the profile page embeds few or none).
Future<List<String>> highlights(Client api, Profile p) async {
  final response = await json(
    api.get(
      '/graphql/query/',
      query: {
        'query_hash': 'd4d88dc1500312af6f937f7b804c68c3',
        'variables': Json.encode({'user_id': p.id, 'include_highlight_reels': true}),
      },
      headers: {'referer': '$web/${p.name}/'},
    ),
  );
  return [for (final id in response.$('data.user.edge_highlight_reels.edges.*.node.id')) 'highlight:${id.text()}'];
}

// Several reels in one call: a user id is their current stories,
// "highlight:<id>" one highlight.
Future<List<Reel>> reels(Client api, List<String> ids, String user) async {
  final response = await json(
    api.get('/api/v1/feed/reels_media/', query: {'reel_ids': ids}, headers: {'referer': '$web/$user/'}),
  );
  return [
    for (final r in response.$('reels_media'))
      (id: r.$('id').or(''), title: r.$('title').or(''), items: r.$('items').toList()),
  ];
}

// When Instagram wants something (log in again, verify the account) it
// redirects API calls to an HTML page instead of answering them.
Future<Json> json(Future<Response> request) async {
  final response = await request;
  final url = response.url();
  if (!url.contains('/accounts/') && !url.contains('/challenge/')) return response.json();
  await response.close();
  throw Exception(
    url.contains('/accounts/login')
        ? 'Instagram logged you out: copy a fresh .ins.session from your browser.'
        : 'Instagram wants you to verify the account. Do it in the browser or the app, then run again.\n$url',
  );
}

// ── posts and stories as files ───────────────────────────────────────────

// A post's shortcode: its file names and its index key.
String postCode(Json post) => Fs.sanitize(post.$('code|shortcode').text() ?? 'post');

// A post's item ids in order: its carousel's, or its own.
List<String> postItems(Json post) => [
  for (final item in children(post).isEmpty ? [post] : children(post)) item.$('pk|id').or(''),
];

List<Json> children(Json item) => [...item.$('carousel_media'), ...item.$('edge_sidecar_to_children.edges.*.node')];

// <code>_<n>.jpg and <code>.mp4 in [dir], with the caption as <code>.txt.
// [order] numbers a carousel's items by id (default: their position), so
// an edited album keeps its file names.
List<Download> postFiles(Json p, Dir dir, [List<String>? order]) {
  final out = files(p, postCode(p), dir, order).toList();
  final caption = p.$('caption.text|edge_media_to_caption.edges.0.node.text').text();
  return [
    ...out,
    if (caption != null && caption.trim().isNotEmpty && out.isNotEmpty)
      Download(dir.file('${postCode(p)}.txt'), text: caption, at: time(p)),
  ];
}

// Story items as <taken_at>_<id>.jpg/.mp4 in [dir]'s folder for each.
List<Download> storyFiles(List<Json> items, Dir Function(Json item) dir) => [
  for (final i in items) ...files(i, '${i.$('taken_at').or(0)}_${Fs.sanitize(i.$('id').or('item'))}', dir(i)),
];

// An item is a carousel of other items, a video, or an image.
Iterable<Download> files(Json item, String name, Dir dir, [List<String>? order]) sync* {
  final list = children(item);
  for (final (i, child) in list.indexed) {
    final at = order?.indexOf(child.$('pk|id').or('')) ?? -1;
    yield* files(child, '${name}_${(at < 0 ? i : at) + 1}', dir);
  }
  if (list.isNotEmpty) return;
  final video = largest(item.$('video_versions|video_resources')) ?? item.$('video_url').text();
  final image =
      largest(item.$('image_versions2.candidates')) ??
      largest(item.$('display_resources')) ??
      item.$('display_url|display_uri').text();
  if (video != null) {
    yield Download(dir.file('$name.mp4'), url: video, at: time(item));
  } else if (image != null && !image.contains('/null.jpg')) {
    yield Download(dir.file('$name.jpg'), url: image, at: time(item));
  }
}

// When an item was posted.
DateTime time(Json item) => DateTime.fromMillisecondsSinceEpoch(item.$('taken_at|taken_at_timestamp').or(0) * 1000);

// The API uses url/width, the data embedded in pages uses src/config_width.
String? largest(Json versions) => versions.max((v) => v.$('width|config_width').or(0)).$('url|src').text();
