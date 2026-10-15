import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';

const instagram = 'https://www.instagram.com';
const defaultAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
final sessionFile = Fs.scriptDir().file('.session');

void onRateLimit(Duration wait) =>
    Console.log('reached the Instagram rate limit, waiting ${wait.human()} before the next request');

// Instaloader's limits: 75 calls per 11 minutes, except the post feed which
// gets 200.
final apiRate = Rate(75, 11.minutes, pause: 3.seconds, onWait: onRateLimit);
final feedRate = Rate(200, 11.minutes, pause: 3.seconds, onWait: onRateLimit);

final web = Http.client(
  base: instagram,
  rate: apiRate,
  check: true,
  headers: {
    'user-agent': defaultAgent,
    'accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
    'accept-language': 'en-US,en;q=0.9',
    'sec-fetch-dest': 'document',
    'sec-fetch-mode': 'navigate',
    'sec-fetch-site': 'none',
  },
);

// Images and videos come from the CDN, which has no rate limit.
final cdn = Http.client(headers: {'user-agent': defaultAgent, 'referer': '$instagram/'}, retries: 3, resume: true);

class Session {
  Session(this.cookies, this.agent);
  final Cookies cookies;
  final String agent;
}

Client apiClient(Session session) => Http.client(
  base: instagram,
  rate: apiRate,
  check: true,
  cookies: session.cookies,
  // Without the csrftoken echoed as a header, Instagram treats you as a bot.
  csrf: (cookie: 'csrftoken', header: 'x-csrftoken'),
  headers: {
    'user-agent': session.agent,
    'accept': '*/*',
    'accept-language': 'en-US,en;q=0.9',
    'x-ig-app-id': '936619743392459',
    'x-requested-with': 'XMLHttpRequest',
    'sec-fetch-site': 'same-origin',
  },
);

class Profile {
  Profile(this.id, this.username, this.posts, this.highlights);
  final String id;
  final String username;
  final List<Json> posts; // first 12 only
  final List<({String id, String title})> highlights;
}

// The public profile page has the user's data embedded as JSON, split over
// several script tags.
Future<Profile> loadProfile(String username) async {
  final page = await web.get('/$username/').html();
  final merged = <String, Object?>{};
  for (final part in page.json().$('**.xig_user_by_username')) {
    merged.addAll(part.asMap<Object?>());
  }
  final user = Json.of(merged);
  final id = user.$('pk|id').text();
  if (id == null) throw Exception('User not found: "$username".');

  final posts = user.$('polaris_ordered_timeline_connection.edges.*.node').toList();
  final highlights = [
    for (final node in user.$('lox_highlights_connection.edges.*.node'))
      (id: node.$('id').or('').replaceFirst('highlight:', ''), title: node.$('title').or('highlight')),
  ];
  return Profile(id, user.$('username').or(username), posts, highlights);
}

// One page (12 posts) of the profile grid, and the cursor for the next page.
Future<({List<Json> posts, String? next})> fetchPosts(Client api, String user, String? cursor) async {
  final response = await readJson(
    api.post(
      '/graphql/query',
      headers: {'referer': '$instagram/$user/'},
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
  final hasNext = feed.$('page_info.has_next_page').or(false);
  return (posts: feed.$('edges.*.node').toList(), next: hasNext ? feed.$('page_info.end_cursor').text() : null);
}

// reelId is a user id for their current stories, or "highlight:<id>".
Future<List<Json>> fetchReel(Client api, String reelId, String user) async {
  final response = await readJson(
    api.get('/api/v1/feed/reels_media/', query: {'reel_ids': reelId}, headers: {'referer': '$instagram/$user/'}),
  );
  return [for (final reel in response.$('reels')) ...reel.$('items')];
}

// When Instagram wants something from you (log in again, verify the account)
// it redirects API calls to an HTML page instead of answering them.
Future<Json> readJson(Future<Response> request) async {
  final response = await request;
  final url = response.url();
  if (url.contains('/accounts/login')) {
    await response.close();
    throw Exception('Instagram logged you out: copy a fresh .session from your browser.');
  }
  if (url.contains('/challenge/') || url.contains('/accounts/')) {
    await response.close();
    throw Exception(
      'Instagram wants you to verify the account. Do it in the browser or the app, then run again.\n$url',
    );
  }
  return response.json();
}

// .session is a cookies.txt export plus a "user-agent: ..." line.
Future<Session?> loadSession() async {
  final text = await sessionFile.text(or: '');
  final cookies = Cookies.parse(text);
  if (cookies['sessionid'] == null) return null;
  final agent = RegExp(r'^user-agent:(.*)$', multiLine: true, caseSensitive: false).firstMatch(text)?[1]?.trim();
  if (agent == null) {
    Console.log('warning: .session has no user-agent line, so requests use a different browser than your login');
  }
  return Session(cookies, agent ?? defaultAgent);
}
