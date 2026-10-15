// Instagram's web API, as the website calls it. Import with `as instagram`.
library;

import 'dart:async';
import 'dart:math';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

import 'dashboard.dart';
import 'download.dart';
import 'media.dart' as media;
import 'platform.dart';

const site = 'https://www.instagram.com';
const agent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

// Instaloader's limits: 75 calls per 11 minutes, 200 for the post feed.
Rate rate(int calls) => Rate(
  calls,
  11.minutes,
  pause: 3.seconds,
  onWait: (w) => board.holdPause('Instagram rate limit: waiting ${w.human()}', w, platform: 'ins'),
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

// The logged-in client from .ins.session (a cookies.txt export plus a
// "user-agent: ..." line), or null.
Future<Client?> login() async {
  var file = Fs.scriptDir().file('.ins.session');
  if (!await file.exists()) {
    final cur = Fs.file('.ins.session');
    if (await cur.exists()) file = cur;
  }
  final text = await file.text(or: '');
  final cookies = Cookies.parse(text);
  if (cookies['sessionid'] == null) return null;
  final ua = RegExp(r'^user-agent:(.*)$', multiLine: true, caseSensitive: false).firstMatch(text)?[1]?.trim();
  if (ua == null) Console.log('warning: .ins.session has no user-agent line, so requests use another browser');
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

// Resolves an Instagram profile using authenticated API / GraphQL or web fallback.
Future<Profile> profile(Client? api, String name) async {
  board.requests++;
  if (api != null) {
    if (RegExp(r'^\d+$').hasMatch(name)) {
      try {
        final info = await json(api.get('/api/v1/users/$name/info/'));
        final u = info.$('user');
        final username = u.$('username').text();
        if (username != null) {
          final pic = u.$('hd_profile_pic_url_info.url').text() ?? u.$('profile_pic_url').text();
          return (id: name, name: username, picture: pic, posts: <Json>[]);
        }
      } catch (_) {}
    }

    try {
      final page = await posts(api, name, null);
      if (page.posts.isNotEmpty) {
        final u = page.posts.first.$('user');
        final id = u.$('pk|id').text();
        if (id != null) {
          final username = u.$('username').text() ?? name;
          final pic = u.$('hd_profile_pic_url_info.url').text() ?? u.$('profile_pic_url').text();
          return (id: id, name: username, picture: pic, posts: page.posts);
        }
      }
    } catch (_) {}

    final res = await api.get('/$name/');
    final html = await res.text();
    final profileId = RegExp(r'"profile_id":"(\d+)"').firstMatch(html)?[1] ??
        RegExp(r'"props":\{"id":"(\d+)"').firstMatch(html)?[1] ??
        RegExp(r'"target_id":"(\d+)"').firstMatch(html)?[1];
    if (profileId != null) {
      final pic = RegExp(r'<meta property="og:image" content="([^"]+)"').firstMatch(html)?[1]?.replaceAll('&amp;', '&');
      return (id: profileId, name: name, picture: pic, posts: <Json>[]);
    }
  }

  final res = await web.get('/$name/');
  final html = await res.text();
  final page = await res.html();
  final user = Json.of({for (final part in page.json().$('**.xig_user_by_username')) ...part.asMap<Object?>()});
  final id = user.$('pk|id').text() ??
      RegExp(r'"profile_id":"(\d+)"').firstMatch(html)?[1] ??
      RegExp(r'"props":\{"id":"(\d+)"').firstMatch(html)?[1] ??
      (throw Exception('User not found: "$name". If the user exists, log in with .ins.session (Instagram blocks anonymous access for some profiles).'));
  return (
    id: id,
    name: user.$('username').or(name),
    picture: user.$('profile_pic_url').text() ??
        RegExp(r'<meta property="og:image" content="([^"]+)"').firstMatch(html)?[1]?.replaceAll('&amp;', '&'),
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
  if (p.picture != null && !p.picture!.contains('s150x150')) return p.picture;
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
        ? 'Instagram logged you out: copy a fresh .ins.session from your browser.'
        : 'Instagram wants you to verify the account. Do it in the browser or the app, then run again.\n$url',
  );
}

final platform = InstagramPlatform();

final class InstagramPlatform implements Platform {
  @override
  String get code => 'ins';

  @override
  String get name => 'instagram';

  @override
  List<Category> get categories => const [
    Category('post', folder: 'posts', help: 'Posts (photos, reels, carousels)'),
    Category('story', folder: 'stories', help: 'Active stories'),
    Category('highlight', folder: 'highlights', help: 'Story highlights'),
    Category('profile', folder: 'profiles', help: 'Profile picture'),
  ];

  @override
  bool matches(String input) =>
      RegExp(r'^(?:https?://)?(?:www\.)?instagram\.com/').hasMatch(input.trim());

  @override
  String parseUser(String input) {
    final trimmed = input.trim();

    // Check for story URLs: https://www.instagram.com/stories/<username>/...
    if (RegExp(r'^(?:https?://)?(?:www\.)?instagram\.com/stories/([^/?#]+)').firstMatch(trimmed) case final m?) {
      final user = m[1]!;
      if (user != 'highlights') return user;
    }

    // Check for profile URLs: https://www.instagram.com/<username>
    if (RegExp(r'^(?:https?://)?(?:www\.)?instagram\.com/([^/?#]+)').firstMatch(trimmed) case final m?) {
      final seg = m[1]!;
      const nonProfile = {'p', 'reel', 'reels', 'tv', 'explore', 'direct', 'stories', 'accounts', 'developer', 'about'};
      if (nonProfile.contains(seg.toLowerCase())) {
        if (seg == 'p' || seg == 'reel' || seg == 'reels' || seg == 'tv') {
          throw FormatException('"$input" is a post URL, not a user profile. Please provide a username or profile URL.');
        }
        throw FormatException('"$input" is not an Instagram user profile.');
      }
      return seg;
    }

    final handle = trimmed.replaceFirst(RegExp(r'^@'), '').split('?').first.split('/').first;
    if (handle.isEmpty) {
      throw FormatException('expected an Instagram username or profile URL, got "$input"');
    }
    return handle;
  }

  @override
  Future<Client?> login() => instagramLogin();

  @override
  Future<void> close(Client? api) async {
    await api?.close();
    await web.close();
    await cdn.close();
  }

  @override
  Object explain(Object error) => instagramExplain(error);

  @override
  Future<void> exploreUser({
    required User u,
    required Set<String> categories,
    required Client? api,
    required Dir userDir,
    required Index index,
    required Queue queue,
    required bool all,
    required List<Future<Results>> batches,
    required void Function(List<Part> parts, String what, {bool done}) phase,
    required void Function(String change) changed,
  }) async {
    if (api == null) {
      throw const UsageException('Instagram downloads require a login session: export cookies from instagram.com into .ins.session.');
    }

    final p = await profile(api, u.name);
    u
      ..name = p.name
      ..id = p.id;

    final postsDir = categories.contains('post') ? userDir.dir('posts') : null;
    final feedParts = [?u.parts['posts']];

    Future<Results> add(List<media.Download> files) {
      final batch = queue.add(u, userDir, files);
      batches.add(batch);
      return batch;
    }

    Future<void> explorePosts() async {
      final known = {...index.posts.keys}, newest = index.newest;
      final check = known.isEmpty || DateTime.now().difference(index.checked) > 7.days;
      phase(
        feedParts,
        check && !all ? 'listing every post (${known.isEmpty ? 'first run' : 'weekly check'})' : 'listing posts',
      );

      List<media.Download> files(List<Json> page) {
        for (final post in page) {
          final code = media.code(post), now = media.items(post), before = index.posts[code];
          if (before == null || before.isEmpty) {
            index.posts[code] = now;
            continue;
          }
          final added = [
            for (final id in now)
              if (!before.contains(id)) id,
          ];
          final hidden = before.where((id) => !now.contains(id)).length;
          if (added.isNotEmpty || hidden > 0) {
            changed('post $code edited: ${added.length} new, $hidden hidden (files kept)');
            index.posts[code] = [...before, ...added];
          }
        }
        return media.posts(page, postsDir: postsDir, order: index.posts);
      }

      void log(String line) {
        phase(feedParts, line);
        board.note('@${p.name} ${feedParts.map((part) => part.name).join('+')}: $line', platform: 'ins');
      }

      final feed = api.copy(rate: feedRate), full = all || check;
      final mark = userDir.file('.ins-cursor-${feedParts.map((part) => part.name).join('-')}');
      final resume = all ? '' : (await mark.text(or: '')).trim();
      final codes = <String, int>{};
      var pages = 0, saving = Future<void>.value(), ok = true;

      void track(Future<Results> batch, String? next) => saving = saving.then((_) async {
        ok = ok && (await batch).failures().isEmpty;
        if (!ok) return;
        await (next == null ? mark.delete() : mark.write(next));
        await index.save();
      });

      Future<bool> walk(String? cursor, {required bool tracked, required bool stop}) async {
        do {
          final page = await posts(feed, p.name, cursor);
          if (page.posts.isEmpty) {
            if (tracked) track(Future.value(const []), null);
            break;
          }
          final list = files(page.posts);
          pages++;
          if (stop && list.isNotEmpty && (await Future.wait(list.map((f) => f.to.exists()))).every((e) => e)) {
            if (tracked) track(Future.value(const []), null);
            return false;
          }
          codes.addAll({for (final post in page.posts) media.code(post): post.$('taken_at|taken_at_timestamp').or(0)});
          log('page $pages: ${dates(page.posts)}, ${list.length} files');
          final batch = add(list);
          if (tracked) track(batch, page.next);
          if (page.next == null || page.next == cursor) {
            if (tracked) track(Future.value(const []), null);
            break;
          }
          cursor = page.next;
        } while (cursor != null);
        return true;
      }

      final bool complete;
      try {
        if (resume.isEmpty) {
          complete = await walk(null, tracked: true, stop: !full);
        } else {
          await walk(null, tracked: false, stop: true);
          log('continuing where the last run stopped');
          complete = await walk(resume, tracked: true, stop: !full);
        }
      } finally {
        await saving;
      }
      index.newest = codes.values.fold(newest, max);
      if (complete && ok) index.checked = DateTime.now();
      if (complete && resume.isEmpty) {
        final listed = codes.keys.toSet();
        final shown = {
          ...index.hidden.intersection(listed),
          if (known.isNotEmpty)
            for (final MapEntry(:key, :value) in codes.entries)
              if (!known.contains(key) && value <= newest) key,
        };
        final gone = known.difference(listed).difference(index.hidden);
        if (gone.isNotEmpty) changed('posts hidden or deleted (${gone.length}): ${gone.join(', ')}, files kept');
        if (shown.isNotEmpty) changed('posts shown again (${shown.length}): ${shown.join(', ')}');
        index.hidden = known.difference(listed);
      }
      final newPages = pages - 1;
      final note = complete
          ? 'all $pages pages listed'
          : newPages == 0
          ? 'no new posts'
          : '$newPages newest ${newPages == 1 ? 'page' : 'pages'} listed';
      phase(feedParts, note, done: true);
    }

    Future<void> exploreStories() async {
      final part = [?u.parts['stories']];
      phase(part, 'fetching the stories up now');
      final items = [
        for (final r in await reels(api, [p.id], p.name)) ...r.items,
      ];
      for (final i in items) {
        index.stories[i.$('id').or('')] = i.$('taken_at').or(0);
      }
      add(media.stories(items, userDir.dir('stories'), monthly: true));
      phase(part, '${items.length} up now', done: true);
    }

    Future<void> exploreHighlights() async {
      final part = [?u.parts['highlights']];
      phase(part, 'listing highlights');
      final ids = await highlights(api, p);
      final now = <String, Set<String>>{};
      final known = index.highlights.isNotEmpty;
      phase(part, 'fetching ${ids.length} highlights');
      await Future.wait([
        for (var i = 0; i < ids.length; i += 10)
          reels(api, ids.sublist(i, min(i + 10, ids.length)), p.name).then((List<Reel> reelsList) {
            for (final r in reelsList) {
              final title = r.title.isEmpty ? r.id : r.title;
              final items = {for (final item in r.items) item.$('id').or('')};
              final before = index.highlights[title];
              if (before != null) {
                final (added, removed) = (items.difference(before).length, before.difference(items).length);
                if (added + removed > 0) changed('highlight "$title": $added added, $removed removed');
              } else if (known) {
                changed('new highlight "$title"');
              }
              now[title] = items;
              add(media.stories(r.items, userDir.dir('highlights').dir(Fs.sanitize(title))));
            }
            phase(part, 'fetched ${now.length} of ${ids.length} highlights');
          }),
      ]);
      for (final title in index.highlights.keys.where((t) => !now.containsKey(t))) {
        changed('highlight "$title" gone, files kept');
      }
      index.highlights = now;
      phase(part, '${ids.length} ${ids.length == 1 ? 'highlight' : 'highlights'}', done: true);
    }

    Future<void> exploreProfile() async {
      final part = [?u.parts['profiles']];
      phase(part, 'fetching the profile picture');
      final url = await picture(api, p);
      if (url == null) return phase(part, 'no profile picture', done: true);
      final id = Fs.sanitize(Uri.parse(url).pathSegments.last);
      if (!index.profiles.containsKey(id)) {
        if (index.profiles.isNotEmpty) changed('new profile picture');
        index.profiles[id] = DateTime.now().format('yyyy-MM-dd');
        await index.save();
      }
      add([(to: userDir.dir('profiles').file('${index.profiles[id]}_$id'), url: url, text: null)]);
      phase(part, '${index.profiles.length} seen', done: true);
    }

    await Future.wait([
      if (categories.contains('profile')) exploreProfile(),
      if (postsDir != null) explorePosts(),
      if (categories.contains('story')) exploreStories(),
      if (categories.contains('highlight')) exploreHighlights(),
    ]);
  }
}

Future<Client?> instagramLogin() => login();
Object instagramExplain(Object error) => explain(error);
