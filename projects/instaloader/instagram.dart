// Instagram's web API, as the website calls it. Import with `as instagram`.
library;

import 'dart:async';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';

import 'dashboard.dart';

const site = 'https://www.instagram.com';
const agent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

// Instaloader's limits: 75 calls per 11 minutes, 200 for the post feed.
Rate rate(int calls) => Rate(
  calls,
  11.minutes,
  pause: 3.seconds,
  onWait: (w) {
    board.pause = 'Instagram rate limit: waiting ${w.human()}';
    board.note(board.pause!);
    Timer(w, () => board.pause = null);
  },
);
final apiRate = rate(75), feedRate = rate(200);

final web = Http.client(
  base: site,
  rate: apiRate,
  check: true,
  headers: {
    'user-agent': agent,
    'accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
    'accept-language': 'en-US,en;q=0.9',
    'sec-fetch-dest': 'document',
    'sec-fetch-mode': 'navigate',
    'sec-fetch-site': 'none',
  },
);

// Images and videos come from the CDN, which has no rate limit.
final cdn = Http.client(headers: {'user-agent': agent, 'referer': '$site/'}, retries: 3, resume: true);

// The logged-in client from .session (a cookies.txt export plus a
// "user-agent: ..." line), or null.
Future<Client?> login() async {
  final text = await Fs.scriptDir().file('.session').text(or: '');
  final cookies = Cookies.parse(text);
  if (cookies['sessionid'] == null) return null;
  final ua = RegExp(r'^user-agent:(.*)$', multiLine: true, caseSensitive: false).firstMatch(text)?[1]?.trim();
  if (ua == null) Console.log('warning: .session has no user-agent line, so requests use another browser');
  return Http.client(
    base: site,
    rate: apiRate,
    check: true,
    cookies: cookies,
    // Without the csrftoken echoed as a header, Instagram treats you as a bot.
    csrf: (cookie: 'csrftoken', header: 'x-csrftoken'),
    headers: {
      'user-agent': ua ?? agent,
      'accept': '*/*',
      'accept-language': 'en-US,en;q=0.9',
      'x-ig-app-id': '936619743392459',
      'x-requested-with': 'XMLHttpRequest',
      'sec-fetch-site': 'same-origin',
    },
  );
}

typedef Profile = ({String id, String name, String? picture, List<Json> posts}); // picture: 150px, posts: the first 12
typedef Reel = ({String id, String title, List<Json> items});

// The profile page embeds the user as JSON, split over several script tags.
Future<Profile> profile(String name) async {
  board.requests++;
  final page = await web.get('/$name/').html();
  final user = Json.of({for (final part in page.json().$('**.xig_user_by_username')) ...part.asMap<Object?>()});
  return (
    id: user.$('pk|id').text() ?? (throw Exception('User not found: "$name".')),
    name: user.$('username').or(name),
    picture: user.$('profile_pic_url').text(),
    posts: user.$('polaris_ordered_timeline_connection.edges.*.node').toList(),
  );
}

// One page (12 posts) of the profile grid, and the cursor of the next.
Future<({List<Json> posts, String? next})> posts(Client api, String user, String? cursor) async {
  final response = await json(
    api.post(
      '/graphql/query',
      headers: {'referer': '$site/$user/'},
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
  return (posts: feed.$('edges.*.node').toList(), next: more ? feed.$('page_info.end_cursor').text() : null);
}

// The profile picture at full size (the feed carries it), else 150px.
Future<String?> picture(Client? api, Profile p) async {
  if (api == null) return p.picture;
  final page = await posts(api.copy(rate: feedRate), p.name, null);
  return page.posts.firstOrNull?.$('user.hd_profile_pic_url_info.url').text() ?? p.picture;
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
      headers: {'referer': '$site/${p.name}/'},
    ),
  );
  return [for (final id in response.$('data.user.edge_highlight_reels.edges.*.node.id')) 'highlight:${id.text()}'];
}

// Several reels in one call: a user id is their current stories,
// "highlight:<id>" one highlight.
Future<List<Reel>> reels(Client api, List<String> ids, String user) async {
  final response = await json(
    api.get('/api/v1/feed/reels_media/', query: {'reel_ids': ids}, headers: {'referer': '$site/$user/'}),
  );
  return [
    for (final r in response.$('reels_media'))
      (id: r.$('id').or(''), title: r.$('title').or(''), items: r.$('items').toList()),
  ];
}

// What to tell the user about [e]: Instagram's refusals in plain words.
Object explain(Object e) => switch (e) {
  HttpStatusException(status: 404, :final url) => 'user not found: $url',
  HttpStatusException(status: final status && (401 || 403 || 429), :final method, :final url) =>
    'Instagram refused $method $url (HTTP $status): probably rate limited, try again in 15 minutes',
  _ => e,
};

// When Instagram wants something (log in again, verify the account) it
// redirects API calls to an HTML page instead of answering them.
Future<Json> json(Future<Response> request) async {
  board.requests++;
  final response = await request;
  final url = response.url();
  if (!url.contains('/accounts/') && !url.contains('/challenge/')) return response.json();
  await response.close();
  throw Exception(
    url.contains('/accounts/login')
        ? 'Instagram logged you out: copy a fresh .session from your browser.'
        : 'Instagram wants you to verify the account. Do it in the browser or the app, then run again.\n$url',
  );
}
