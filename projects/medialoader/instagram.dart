// Instagram's web API, as the website calls it. Import with `as instagram`.
library;

import 'dart:math';

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';

import 'dashboard.dart';
import 'download.dart';
import 'media.dart' as media;
import 'platform.dart';

const web = 'https://www.instagram.com';

// Instaloader's limits: 75 calls per 11 minutes, 200 for the post feed.
Rate rate(int calls) => Rate(
  calls,
  11.minutes,
  pause: 3.seconds,
  onWait: (w) => board.holdPause('Instagram rate limit: waiting ${w.human()}', w, platform: 'ins'),
);
final apiRate = rate(75), feedRate = rate(200);

typedef Profile = ({String id, String name, String? picture});
typedef Reel = ({String id, String title, List<Json> items});

// A user id or name as a profile: the first feed page carries it (one call),
// else the profile info.
Future<Profile> profile(Client api, String name) async {
  final Json u;
  if (RegExp(r'^\d+$').hasMatch(name)) {
    u = (await json(api.get('/api/v1/users/$name/info/'))).$('user');
  } else {
    u = (await posts(api, name, null)).items.firstOrNull?.$('user') ??
        (await json(api.get('/api/v1/users/web_profile_info/', query: {'username': name}))).$('data.user');
  }
  return (
    id: u.$('pk|id').text() ?? (throw Exception('user not found: "$name"')),
    name: u.$('username').or(name),
    picture: u.$('hd_profile_pic_url_info.url|profile_pic_url_hd|profile_pic_url').text(),
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
    for (final r in response.$('reels_media')) (id: r.$('id').or(''), title: r.$('title').or(''), items: r.$('items').toList()),
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

final platform = Instagram();

final class Instagram implements Platform {
  @override
  final code = 'ins', name = 'instagram', site = web;

  @override
  final categories = const [Category('post'), Category('story', 'stories'), Category('highlight'), Category('profile')];

  @override
  bool matches(String input) => RegExp(r'^(?:https?://)?(?:www\.)?instagram\.com/').hasMatch(input.trim());

  @override
  Target parse(String input) {
    final s = input.trim();
    if (RegExp(r'instagram\.com/(?:[^/?#]+/)?(?:p|reels?|tv)/([^/?#]+)').firstMatch(s) case final m?) {
      return Target(this, m[1]!, post: m[1]);
    }
    final m = RegExp(r'instagram\.com/(?:stories/)?([^/?#]+)').firstMatch(s);
    if (m == null) return Target(this, username(s, 'Instagram'));
    if (const {'explore', 'direct', 'stories', 'accounts', 'developer', 'about', 'highlights'}.contains(m[1]!.toLowerCase())) {
      throw FormatException('"$input" is not an Instagram profile or post.');
    }
    return Target(this, m[1]!);
  }

  // The logged-in client from .ins.session (a cookies.txt export plus a
  // "user-agent: ..." line), or null.
  @override
  Future<Client?> login() async {
    final jar = await Cookies.load(Fs.scriptDir().file('.ins.session'));
    if (jar['sessionid'] == null) return null;
    return Http.client(
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
  }

  @override
  Object explain(Object e) => switch (e) {
    HttpStatusException(status: 404, :final url) => 'not found: $url',
    HttpStatusException(status: final status && (401 || 403 || 429), :final method, :final url) =>
      'Instagram refused $method $url (HTTP $status): probably rate limited, try again in 15 minutes',
    _ => e,
  };

  @override
  Future<void> explore(Job j) async {
    if (j.target.post case final code?) {
      final p = await post(j.api, code);
      await j.open(p.$('user.username').or(code), id: p.$('user.pk|user.id').text(), track: false);
      j.add(media.post(p, j.dir.dir('posts').dir(media.time(p).format('yyyy-MM')), j.index.posts[media.code(p)]));
      return j.phase(j.part('posts'), '1 post', done: true);
    }
    final p = await profile(j.api, j.target.user);
    await j.open(p.name, id: p.id);
    late final feedApi = j.client(feedRate);
    await Future.wait([
      if (j.wants('profile')) _profile(j, p),
      if (j.wants('post'))
        feed(
          j,
          folder: 'posts',
          noun: 'post',
          page: (cursor) => posts(feedApi, p.name, cursor),
          id: media.code,
          items: media.items,
          time: media.time,
          files: (page) => media.posts(page, j.dir.dir('posts'), order: j.index.posts),
        ),
      if (j.wants('story')) _stories(j, p),
      if (j.wants('highlight')) _highlights(j, p),
    ]);
  }

  Future<void> _profile(Job j, Profile p) async {
    if (p.picture case final url?) {
      final id = Fs.sanitize(Uri.parse(url).pathSegments.last);
      j.add([media.Download(j.dir.dir('profiles').file('${j.seen(id, 'new profile picture')}_$id'), url: url)]);
    }
    j.phase(j.part('profiles'), '${j.index.profiles.length} seen', done: true);
  }

  Future<void> _stories(Job j, Profile p) async {
    final part = j.part('stories');
    j.phase(part, 'fetching the stories up now');
    final items = [for (final r in await reels(j.api, [p.id], p.name)) ...r.items];
    for (final i in items) {
      j.index.stories[i.$('id').or('')] = i.$('taken_at').or(0);
    }
    j.add(media.stories(items, j.dir.dir('stories'), monthly: true));
    j.phase(part, '${items.length} up now', done: true);
  }

  Future<void> _highlights(Job j, Profile p) async {
    final part = j.part('highlights'), index = j.index;
    j.phase(part, 'listing highlights');
    final ids = await highlights(j.api, p);
    final now = <String, Set<String>>{};
    j.phase(part, 'fetching ${ids.length} highlights');
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
            j.add(media.stories(r.items, j.dir.dir('highlights').dir(Fs.sanitize(title))));
          }
          j.phase(part, 'fetched ${now.length} of ${ids.length} highlights');
        }),
    ]);
    for (final title in index.highlights.keys.where((t) => !now.containsKey(t))) {
      j.changed('highlight "$title" gone, files kept');
    }
    index.highlights = now;
    j.phase(part, '${ids.length} ${ids.length == 1 ? 'highlight' : 'highlights'}', done: true);
  }
}
