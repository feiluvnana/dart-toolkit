// instaloader: grab all photos, reels, stories or highlights from a profile.
//
// ```sh
// dart run projects/instaloader.dart <username> [section] [--login]
// dart run projects/instaloader.dart natgeo photos
// dart run projects/instaloader.dart natgeo reels
// dart run projects/instaloader.dart natgeo stories --login
// dart run projects/instaloader.dart natgeo highlights --login
// ```
//
// Sections: `photos` (the default), `reels`, `stories`, `highlights`. Files
// land in `downloads/<user>/<section>/` (highlights grouped by tray title);
// reruns skip what is already on disk and resume what was cut off.
//
// Login: `--login` opens Chrome (profile in `.chrome/`); log in and the run
// continues by itself, with the session saved to `.session` and reused
// silently afterwards. Stories and highlights need it; photos and reels use
// it when present (every page, higher limits) and otherwise read the profile
// page anonymously (first grid page only).
//
// Rate limits: paced like the Python Instaloader (`RateController` in
// `instaloadercontext.py`): a random pause before every API call, at most 75
// calls per 11 min, and a 429 waits the window out before retrying. A 429
// means the IP is throttled: do not run parallel instances or the Instagram
// app meanwhile, and do not restart in a tight loop (a restart forgets the
// window and extends the ban).
library;

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/scrape.dart';

enum Section { photos, reels, stories, highlights }

const _ig = 'https://www.instagram.com';
const _agent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
final _session = Fs.file('.session');

final _user = Arg('username', 'Instagram username or profile URL.', required: true, parse: _username);
final _section = Arg('section', 'What to grab.', values: Section.values, or: Section.photos);
final _login = Flag('login', 'Log in with Chrome first (kept for next runs).');

/// Python Instaloader's `other` bucket: 75 calls per 11 min, ~1.5 s apart.
final _rate = Rate(
  75,
  11.minutes,
  pause: 3.seconds,
  onWait: (d) => Console.log('Instagram limit: waiting ${d.human()}; leave Instagram alone…'),
);

/// The anonymous profile page (like Python's `get_page_data`), which does
/// not trip the 429 that `web_profile_info` does.
final _web = Http.client(
  base: _ig,
  rate: _rate,
  check: true,
  headers: {
    'user-agent': _agent,
    'accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
    'accept-language': 'en-US,en;q=0.9',
    'sec-fetch-dest': 'document',
    'sec-fetch-mode': 'navigate',
    'sec-fetch-site': 'none',
  },
);

/// Media lives on the CDN, outside the API limits: parallel is fine.
final _cdn = Http.client(headers: {'user-agent': _agent, 'referer': '$_ig/'}, retries: 3, resume: true);

/// The logged-in API: the csrftoken cookie must ride along as a header too,
/// or even a valid sessionid is treated as a bot.
Client _api(Cookies session) => Http.client(
  base: _ig,
  rate: _rate,
  check: true,
  cookies: session,
  csrf: (cookie: 'csrftoken', header: 'x-csrftoken'),
  headers: {
    'user-agent': _agent,
    'accept': '*/*',
    'accept-language': 'en-US,en;q=0.9',
    'x-ig-app-id': '936619743392459',
    'x-requested-with': 'XMLHttpRequest',
    'sec-fetch-site': 'same-origin',
  },
);

Future<void> main(List<String> args) => Command(
  'instaloader',
  'Download all photos, reels, stories or highlights.',
  params: [_user, _section, _login],
  handler: _run,
).run(args);

String _username(String input) =>
    RegExp(r'^(?:.*instagram\.com/)?@?([A-Za-z0-9_.]+)').firstMatch(input.trim())?[1] ??
    (throw FormatException('expected a username or profile URL, got "$input"'));

Future<void> _run(Context c) async {
  final section = c(_section);
  final session = c(_login) ? await _logIn() : await _saved();
  if (session == null && (section == Section.stories || section == Section.highlights)) {
    throw const UsageException('Stories and highlights need a login: rerun with --login.');
  }
  try {
    await _grab(c(_user), section, session == null ? null : _api(session));
  } on HttpStatusException catch (e) {
    throw switch (e.status) {
      404 => Exception('User not found: "${c(_user)}".'),
      401 || 403 || 429 => Exception(
        'Instagram refused ${e.method} ${e.url} (HTTP ${e.status}): the IP is throttled. Wait ~15 min without '
        'retrying, then rerun (with --login, or from another network).',
      ),
      _ => e,
    };
  }
}

Future<void> _grab(String username, Section section, Client? api) async {
  final profile = await Console.spin('@$username', _profile(username));
  final user = profile.username;
  final dir = Fs.dir('downloads').dir(Fs.sanitize(user)).dir(section.name);
  final files = switch (section) {
    Section.photos || Section.reels => [
      for (final post in api == null ? profile.posts : await Console.spin('listing posts', _posts(api, user)))
        ..._files(post, dir, Fs.sanitize(post.$('code|shortcode').text() ?? 'post'), section),
    ],
    Section.stories => [
      for (final item in await _reel(api!, profile.id, user)) ..._files(item, dir, _stamp(item), section),
    ],
    Section.highlights => [
      for (final (:id, :title) in profile.highlights)
        for (final item in await _reel(api!, 'highlight:$id', user))
          ..._files(item, dir.dir(Fs.sanitize(title)), _stamp(item), section),
    ],
  };
  if (api == null) Console.log('@$user: first grid page only (rerun with --login for every post)');
  if (files.isEmpty) return Console.log('@$user: no ${section.name}');
  Console.log('@$user: ${files.length} ${section.name}');
  final bar = Console.bar(files.length, label: 'downloading');
  final done = await Pool.settle(files, (f) => _cdn.get(f.url) > f.to, onDone: bar.tick);
  for (final Failed(:item, :error) in done.failures()) {
    Console.log('✗ ${item.to.name()}: $error');
  }
  if (done.failures().isNotEmpty) Console.log('@$user: rerun to fetch fresh links for the failures');
  Console.notify('instaloader: @$user ${section.name} done');
}

// ---- instagram ----

/// Id, canonical name, highlight trays and the first grid page, from the
/// server-rendered profile page.
Future<({String id, String username, List<Json> posts, List<({String id, String title})> highlights})> _profile(
  String username,
) async {
  final parts = (await _web.get('/$username/').html()).json().$('**.xig_user_by_username');
  final user = Json.of({for (final part in parts) ...part.asMap<Object?>()});
  final id = user.$('pk|id').text() ?? (throw Exception('User not found: "$username".'));
  return (
    id: id,
    username: user.$('username').or(username),
    posts: user.$('polaris_ordered_timeline_connection.edges.*.node').toList(),
    highlights: [
      for (final node in user.$('lox_highlights_connection.edges.*.node'))
        (id: node.$('id').or('').replaceFirst('highlight:', ''), title: node.$('title').or('highlight')),
    ],
  );
}

/// Every post, 12 per GraphQL page (`PolarisProfilePostsTabContentQuery`).
Future<List<Json>> _posts(Client api, String user) => Scrape<String?, Json>(limit: 1)
    .run(
      [null],
      onItem: (v) async {
        final feed = await api
            .post(
              '/graphql/query',
              headers: {'referer': '$_ig/$user/'},
              body: .form({
                'doc_id': '28975909992013618',
                'server_timestamps': true,
                'variables': Json.encode({
                  'after': ?v.item,
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
            )
            .json()
            .$('data.xdt_api__v1__feed__user_timeline_graphql_connection');
        feed.$('edges.*.node').forEach(v.emit);
        if (feed.$('page_info.has_next_page').or(false)) v.add(feed.$('page_info.end_cursor').text());
      },
    )
    .toList();

/// The items of one reel: a user's live stories (their id) or a highlight
/// (`highlight:<id>`).
Future<List<Json>> _reel(Client api, String reelId, String user) async => [
  for (final reel
      in await api
          .get('/api/v1/feed/reels_media/', query: {'reel_ids': reelId}, headers: {'referer': '$_ig/$user/'})
          .json()
          .$('reels'))
    ...reel.$('items'),
];

// ---- media ----

/// The files one post or story item yields for [section]: each carousel
/// child, then the video (reels, stories) or the largest image (photos,
/// stories).
Iterable<({String url, File to})> _files(Json item, Dir dir, String stem, Section section) sync* {
  final children = [...item.$('carousel_media'), ...item.$('edge_sidecar_to_children.edges.*.node')];
  var n = 0;
  for (final child in children) {
    yield* _files(child, dir, '${stem}_${++n}', section);
  }
  if (children.isNotEmpty) return;
  final video = _widest(item.$('video_versions|video_resources')) ?? item.$('video_url').text();
  final image =
      _widest(item.$('image_versions2.candidates')) ??
      _widest(item.$('display_resources')) ??
      item.$('display_url|display_uri').text();
  if (video != null && section != Section.photos) {
    yield (url: video, to: dir.file('$stem.mp4'));
  } else if (video == null && image != null && section != Section.reels) {
    yield (url: image, to: dir.file('$stem.jpg'));
  }
}

/// The widest version's URL (API `url`/`width` or embedded `src`/`config_width`).
String? _widest(Json versions) => versions.max((v) => v.$('width|config_width').or(0)).$('url|src').text();

String _stamp(Json item) => '${item.$('taken_at').or(0)}_${Fs.sanitize(item.$('id').text() ?? 'item')}';

// ---- login ----

/// The `--login` session from an earlier run, or null.
Future<Cookies?> _saved() async {
  final session = Cookies.parse(await _session.text(or: ''));
  return session['sessionid'] == null ? null : session;
}

/// Log in by hand in Chrome; the run continues by itself once Instagram sets
/// `sessionid`, and the cookies are saved to `.session` for the next runs (a
/// headless cookie grab per run would be extra untracked requests from the
/// same IP, which is what trips the 429).
Future<Cookies> _logIn() async {
  final browser = await Console.spin('opening Chrome', Chrome.launch(headless: false, profile: '.chrome'));
  try {
    final page = await browser.open('$_ig/accounts/login/');
    await Console.spin('log in to Instagram in the Chrome window', page.cookie('sessionid', timeout: 5.minutes));
    final session = await page.cookies();
    await _session.write(session.encode());
    Console.log('session saved to ${_session.path()}');
    return session;
  } finally {
    await browser.close();
  }
}
