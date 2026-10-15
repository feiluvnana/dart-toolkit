// Twitter's web API, as the website calls it. Import with `as twitter`.
library;

import 'dart:async';
import 'dart:math';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

import 'dashboard.dart';
import 'download.dart';
import 'media.dart' as media;
import 'platform.dart';

const site = 'https://x.com';
const agent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const bearer =
    'Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';

// Rate limits: 100 calls per 15 minutes, 150 for the user media timeline.
Rate rate(int calls) => Rate(
  calls,
  15.minutes,
  pause: 2.seconds,
  onWait: (w) => board.holdPause('Twitter rate limit: waiting ${w.human()}', w, platform: 'twt'),
);
final apiRate = rate(100), mediaRate = rate(150);

// CDN client with retries and resume.
final cdn = Http.client(headers: {'user-agent': agent, 'referer': '$site/'}, retries: 3, resume: true);

// The logged-in client from .twt.session (cookies.txt export plus a "user-agent: ..." line), or null.
Future<Client?> login() async {
  var file = Fs.scriptDir().file('.twt.session');
  if (!await file.exists()) {
    final cur = Fs.file('.twt.session');
    if (await cur.exists()) file = cur;
  }
  final text = await file.text(or: '');
  final cookies = Cookies.parse(text);
  if (cookies['auth_token'] == null) return null;
  final ua = RegExp(r'^user-agent:(.*)$', multiLine: true, caseSensitive: false).firstMatch(text)?[1]?.trim();
  if (ua == null) Console.log('warning: .twt.session has no user-agent line, so requests use default browser');
  final ct0 = cookies['ct0'] ?? '';
  return Http.client(
    base: site,
    rate: apiRate,
    check: true,
    cookies: cookies,
    headers: {
      'user-agent': ua ?? agent,
      'authorization': bearer,
      'x-csrf-token': ct0,
      'x-twitter-active-user': 'yes',
      'x-twitter-auth-type': 'OAuth2Session',
      'x-twitter-client-language': 'en',
      'accept': '*/*',
      'sec-fetch-site': 'same-origin',
    },
  );
}

typedef Profile = ({String id, String name, String nick, String? avatar, String? banner});

// Resolves a Twitter username into their user ID, avatar, and banner.
Future<Profile> profile(Client api, String name) async {
  board.requests++;
  var targetName = name;
  if (RegExp(r'^\d+$').hasMatch(name)) {
    try {
      final res = await api.get('/i/user/$name');
      final seg = Uri.parse(res.url()).pathSegments.where((s) => s.isNotEmpty).lastOrNull;
      if (seg != null && seg != 'user' && !RegExp(r'^\d+$').hasMatch(seg)) {
        targetName = seg;
      }
    } catch (_) {}
  }

  final query = {
    'variables': Json.encode({
      'screen_name': targetName,
      'withSafetyModeUserFields': true,
    }),
    'features': Json.encode({
      'hidden_profile_subscriptions_enabled': true,
      'rweb_tipjar_consumption_enabled': true,
      'responsive_web_graphql_exclude_directive_enabled': true,
      'verified_phone_label_enabled': false,
      'subscriptions_verification_info_is_identity_verified_enabled': true,
      'subscriptions_verification_info_verified_since_enabled': true,
      'highlights_tweets_tab_ui_enabled': true,
      'responsive_web_twitter_article_notes_tab_enabled': true,
      'creator_subscriptions_tweet_preview_api_enabled': true,
      'responsive_web_graphql_skip_user_profile_image_extensions_enabled': false,
      'responsive_web_graphql_timeline_navigation_enabled': true,
    }),
    'fieldToggles': Json.encode({
      'withAuxiliaryUserLabels': true,
    }),
  };

  final response = await json(api.get('/i/api/graphql/ck5KkZ8t5cOmoLssopN99Q/UserByScreenName', query: query));
  final user = response.$('data.user.result');
  if (user.isEmpty || user.$('__typename').text() == 'UserUnavailable') {
    throw Exception('Twitter user not found or unavailable: "$name".');
  }
  final id = user.$('rest_id').text() ?? (throw Exception('Could not get Twitter user id for "$name".'));
  final core = user.$('core');
  final legacy = user.$('legacy');
  final screenName = core.$('screen_name').text() ?? legacy.$('screen_name').text() ?? name;
  final nick = core.$('name').text() ?? legacy.$('name').text() ?? screenName;
  final avatarRaw = user.$('avatar.image_url').text() ?? legacy.$('profile_image_url_https').text() ?? core.$('avatar.image_url').text();
  final avatar = avatarRaw?.replaceAll('_normal.', '.');
  final bannerRaw = legacy.$('profile_banner_url').text() ?? user.$('legacy.profile_banner_url').text();
  final banner = bannerRaw != null ? '$bannerRaw/1500x500' : null;

  return (id: id, name: screenName, nick: nick, avatar: avatar, banner: banner);
}

// One page (up to 20 tweets) of the user's media timeline, and the cursor of the next.
Future<({List<Json> tweets, String? next})> mediaTimeline(Client api, String userId, String? cursor) async {
  board.requests++;
  final variables = {
    'userId': userId,
    'count': 20,
    'cursor': ?cursor,
    'includePromotedContent': false,
    'withClientEventToken': false,
    'withBirdwatchNotes': false,
    'withVoice': true,
  };
  final features = {
    'rweb_tipjar_consumption_enabled': true,
    'responsive_web_graphql_exclude_directive_enabled': true,
    'verified_phone_label_enabled': false,
    'creator_subscriptions_tweet_preview_api_enabled': true,
    'responsive_web_graphql_timeline_navigation_enabled': true,
    'responsive_web_graphql_skip_user_profile_image_extensions_enabled': false,
    'communities_web_enable_tweet_community_results_fetch': true,
    'c9s_tweet_anatomy_moderator_badge_enabled': true,
    'articles_preview_enabled': true,
    'responsive_web_edit_tweet_api_enabled': true,
    'graphql_is_translatable_rweb_tweet_is_translatable_enabled': true,
    'view_counts_everywhere_api_enabled': true,
    'longform_notetweets_consumption_enabled': true,
    'responsive_web_twitter_article_tweet_consumption_enabled': true,
    'freedom_of_speech_not_reach_fetch_enabled': true,
    'standardized_nudges_misinfo': true,
    'tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled': true,
    'longform_notetweets_rich_text_read_enabled': true,
    'longform_notetweets_inline_media_enabled': true,
    'responsive_web_enhance_cards_enabled': false,
  };
  final query = {
    'variables': Json.encode(variables),
    'features': Json.encode(features),
    'fieldToggles': Json.encode({'withArticlePlainText': false}),
  };

  final response = await json(api.get('/i/api/graphql/jCRhbOzdgOHp6u9H4g2tEg/UserMedia', query: query));
  var instructions = response.$('data.user.result.timeline.timeline.instructions');
  if (instructions.isEmpty) {
    instructions = response.$('data.user.result.timeline_v2.timeline.instructions');
  }

  final tweets = <Json>[];
  String? nextCursor;

  void addTweet(Json node) {
    var tweet = node.$('tweet_results.result');
    if (tweet.isEmpty) tweet = node.$('itemContent.tweet_results.result');
    if (tweet.isEmpty) return;
    if (tweet.$('tweet').isNotEmpty) tweet = tweet.$('tweet');
    tweets.add(tweet);
  }

  for (final instr in instructions) {
    final type = instr.$('type').text();
    if (type == 'TimelineAddEntries') {
      for (final entry in instr.$('entries')) {
        final entryId = entry.$('entryId').text() ?? '';
        final items = entry.$('content.items');
        if (items.isNotEmpty) {
          for (final item in items) {
            addTweet(item.$('item|itemContent'));
          }
        } else if (entryId.startsWith('tweet-')) {
          addTweet(entry.$('content'));
        } else if (entryId.startsWith('cursor-bottom-')) {
          nextCursor = entry.$('content.value').text() ?? entry.$('content.itemContent.value').text();
        }
      }
    } else if (type == 'TimelineAddToModule') {
      for (final item in instr.$('moduleItems')) {
        addTweet(item.$('item|itemContent'));
      }
    } else if (type == 'TimelineReplaceEntry') {
      final entry = instr.$('entry');
      final entryId = entry.$('entryId').text() ?? '';
      if (entryId.startsWith('cursor-bottom-')) {
        nextCursor = entry.$('content.value').text() ?? entry.$('content.itemContent.value').text();
      }
    }
  }

  return (tweets: tweets, next: tweets.isEmpty ? null : nextCursor);
}

String tweetId(Json tweet) => tweet.$('rest_id|legacy.id_str').text() ?? 'tweet';

String tweetMonth(Json tweet) {
  final id = tweetId(tweet);
  if (BigInt.tryParse(id) case final snowflake?) {
    final ms = (snowflake >> 22).toInt() + 1288834974657;
    return DateTime.fromMillisecondsSinceEpoch(ms).format('yyyy-MM');
  }
  return DateTime.now().format('yyyy-MM');
}

int tweetTimestamp(Json tweet) {
  final id = tweetId(tweet);
  if (BigInt.tryParse(id) case final snowflake?) {
    return ((snowflake >> 22).toInt() + 1288834974657) ~/ 1000;
  }
  return DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

List<String> tweetItems(Json tweet) {
  var media = tweet.$('legacy.extended_entities.media').toList();
  if (media.isEmpty) {
    media = tweet.$('legacy.retweeted_status_result.result.legacy.extended_entities.media').toList();
  }
  if (media.isEmpty) {
    media = tweet.$('legacy.retweeted_status_result.result.tweet.legacy.extended_entities.media').toList();
  }
  return [for (final m in media) m.$('id_str').text() ?? ''];
}

List<media.Download> tweetDownloads(
  List<Json> tweets, {
  Dir? postsDir,
  Dir? photos,
  Dir? videos,
  Map<String, List<String>> order = const {},
}) => [
  for (final t in tweets) ...singleTweetDownloads(t, postsDir ?? photos, postsDir ?? videos, order[tweetId(t)]),
];

List<media.Download> singleTweetDownloads(
  Json tweet,
  Dir? photos,
  Dir? videos, [
  List<String>? order,
]) {
  final id = tweetId(tweet);
  final month = tweetMonth(tweet);
  final pDir = photos?.dir(month);
  final vDir = videos?.dir(month);

  var mediaList = tweet.$('legacy.extended_entities.media').toList();
  if (mediaList.isEmpty) {
    mediaList = tweet.$('legacy.retweeted_status_result.result.legacy.extended_entities.media').toList();
  }
  if (mediaList.isEmpty) {
    mediaList = tweet.$('legacy.retweeted_status_result.result.tweet.legacy.extended_entities.media').toList();
  }
  final out = <media.Download>[];

  for (final (i, m) in mediaList.indexed) {
    final mediaId = m.$('id_str').text() ?? '';
    final at = order?.indexOf(mediaId) ?? -1;
    final num = (at < 0 ? i : at) + 1;
    final name = '${id}_$num';
    final type = m.$('type').text();

    if (type == 'video' || type == 'animated_gif') {
      if (vDir != null) {
        final variants = m.$('video_info.variants').toList();
        final mp4s = variants.where((v) => v.$('content_type').text() == 'video/mp4');
        if (mp4s.isNotEmpty) {
          final best = mp4s.reduce((a, b) => (a.$('bitrate').or(0)) > (b.$('bitrate').or(0)) ? a : b);
          if (best.$('url').text() case final url?) {
            out.add((to: vDir.file('$name.mp4'), url: url, text: null));
          }
        }
      }
    } else {
      if (pDir != null) {
        if (m.$('media_url_https').text() case final url?) {
          final origUrl = '$url?name=orig';
          final ext = url.split('.').lastOrNull?.split('?').firstOrNull ?? 'jpg';
          out.add((to: pDir.file('$name.$ext'), url: origUrl, text: null));
        }
      }
    }
  }

  final caption = tweet.$('legacy.full_text').text() ??
      tweet.$('note_tweet.note_tweet_results.result.text').text() ??
      tweet.$('legacy.retweeted_status_result.result.legacy.full_text').text();
  if (caption != null && caption.trim().isNotEmpty) {
    if (out.isNotEmpty) {
      for (final dir in {for (final f in out) f.to.parent().path()}) {
        out.add((to: Fs.dir(dir).file('$id.txt'), url: null, text: caption));
      }
    } else if (pDir != null || vDir != null) {
      final dir = pDir ?? vDir;
      out.add((to: dir!.file('$id.txt'), url: null, text: caption));
    }
  }

  return out;
}

Object explain(Object e) => switch (e) {
  HttpStatusException(status: 404, :final url) => 'user not found: $url',
  HttpStatusException(status: final status && (401 || 403), :final url) =>
    'Twitter refused (HTTP $status): your session in .twt.session may have expired or is invalid ($url)',
  HttpStatusException(status: 429, :final url) =>
    'Twitter rate limit reached (HTTP 429): try again in 15 minutes ($url)',
  _ => e,
};

Future<Json> json(Future<Response> request) async {
  board.requests++;
  final response = await request;
  final url = response.url();
  if (url.contains('/i/flow/login') || url.contains('/account/access')) {
    await response.close();
    throw Exception('Twitter logged you out: copy a fresh .twt.session from your browser.');
  }
  return response.json();
}

final platform = TwitterPlatform();

final class TwitterPlatform implements Platform {
  @override
  String get code => 'twt';

  @override
  String get name => 'twitter';

  @override
  List<Category> get categories => const [
    Category('tweet', folder: 'tweets', help: 'Tweets (photos and videos)'),
    Category('profile', folder: 'profiles', help: 'Profile avatar and banner'),
  ];

  @override
  bool matches(String input) =>
      RegExp(r'^(?:https?://)?(?:www\.|mobile\.)?(?:(?:[fv]x)?twitter|(?:fix(?:up|v))?x)\.com/').hasMatch(input.trim());

  @override
  String parseUser(String input) {
    final trimmed = input.trim();

    // 1. Explicit screen_name query param: ?screen_name=user
    if (RegExp(r'[?&]screen_name=([^&#]+)').firstMatch(trimmed) case final m?) {
      return m[1]!;
    }

    // 2. Explicit numeric user_id query param: ?user_id=123456
    if (RegExp(r'[?&]user_id=(\d+)').firstMatch(trimmed) case final m?) {
      return m[1]!;
    }

    // 3. /i/user/<id> route
    if (RegExp(r'/i/user/(\d+)').firstMatch(trimmed) case final m?) {
      return m[1]!;
    }

    // 4. URL path segment: https://x.com/<username> or https://twitter.com/<username>/status/...
    if (RegExp(r'^(?:https?://)?(?:www\.|mobile\.)?(?:(?:[fv]x)?twitter|(?:fix(?:up|v))?x)\.com/([^/?#]+)').firstMatch(trimmed) case final m?) {
      final seg = m[1]!;
      const nonProfile = {'home', 'explore', 'notifications', 'messages', 'settings', 'i', 'intent', 'search'};
      if (nonProfile.contains(seg.toLowerCase())) {
        throw FormatException('"$input" is not a Twitter user profile.');
      }
      return seg;
    }

    final handle = trimmed.replaceFirst(RegExp(r'^@'), '').split('?').first.split('/').first;
    if (handle.isEmpty) {
      throw FormatException('expected a Twitter username or profile URL, got "$input"');
    }
    return handle;
  }

  @override
  Future<Client?> login() => twitterLogin();

  @override
  Future<void> close(Client? api) async {
    await api?.close();
    await cdn.close();
  }

  @override
  Object explain(Object error) => twitterExplain(error);

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
      throw const UsageException('Twitter downloads require a login session: export cookies from x.com into .twt.session.');
    }

    final p = await profile(api, u.name);
    u
      ..name = p.name
      ..id = p.id;

    final legacyPosts = userDir.dir('posts');
    final tweetsDir = categories.contains('tweet') ? userDir.dir('tweets') : null;
    if (tweetsDir != null && await legacyPosts.exists() && !await tweetsDir.exists()) {
      await legacyPosts.move(tweetsDir.path());
    }
    final feedParts = [?u.parts['tweets']];

    Future<Results> add(List<media.Download> files) {
      final batch = queue.add(u, userDir, files);
      batches.add(batch);
      return batch;
    }

    Future<void> exploreMedia() async {
      final known = {...index.posts.keys}, newest = index.newest;
      final check = known.isEmpty || DateTime.now().difference(index.checked) > 7.days;
      phase(
        feedParts,
        check && !all ? 'listing every tweet (${known.isEmpty ? 'first run' : 'weekly check'})' : 'listing tweets',
      );

      List<media.Download> files(List<Json> page) {
        for (final tweet in page) {
          final id = tweetId(tweet), now = tweetItems(tweet), before = index.posts[id];
          if (before == null || before.isEmpty) {
            index.posts[id] = now;
            continue;
          }
          final added = [
            for (final item in now)
              if (!before.contains(item)) item,
          ];
          if (added.isNotEmpty) {
            changed('tweet $id updated: ${added.length} new items');
            index.posts[id] = [...before, ...added];
          }
        }
        return tweetDownloads(page, postsDir: tweetsDir, order: index.posts);
      }

      void log(String line) {
        phase(feedParts, line);
        board.note('@${p.name} ${feedParts.map((part) => part.name).join('+')}: $line', platform: 'twt');
      }

      final feed = api.copy(rate: mediaRate);
      final mark = userDir.file('.twt-cursor-${feedParts.map((part) => part.name).join('-')}');
      final resume = all ? '' : (await mark.text(or: '')).trim();
      final ids = <String, int>{};
      var pages = 0, saving = Future<void>.value(), ok = true;

      void track(Future<Results> batch, String? next) => saving = saving.then((_) async {
        ok = ok && (await batch).failures().isEmpty;
        if (!ok) return;
        await (next == null ? mark.delete() : mark.write(next));
        await index.save();
      });

      Future<bool> walk(String? cursor, {required bool tracked, required bool stop}) async {
        do {
          final page = await mediaTimeline(feed, p.id, cursor);
          if (page.tweets.isEmpty) {
            if (tracked) track(Future.value(const []), null);
            break;
          }
          final list = files(page.tweets);
          pages++;
          if (stop && list.isNotEmpty && (await Future.wait(list.map((f) => f.to.exists()))).every((e) => e)) {
            if (tracked) track(Future.value(const []), null);
            return false;
          }
          ids.addAll({for (final tweet in page.tweets) tweetId(tweet): tweetTimestamp(tweet)});
          log('page $pages: ${page.tweets.length} tweets, ${list.length} files');
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
          complete = await walk(null, tracked: true, stop: !(all || check));
        } else {
          await walk(null, tracked: false, stop: true);
          log('continuing where the last run stopped');
          complete = await walk(resume, tracked: true, stop: !(all || check));
        }
      } finally {
        await saving;
      }

      index.newest = ids.values.fold(newest, max);
      if (complete && ok) index.checked = DateTime.now();
      if (complete && resume.isEmpty) {
        final listed = ids.keys.toSet();
        final gone = known.difference(listed).difference(index.hidden);
        if (gone.isNotEmpty) changed('tweets removed (${gone.length}): ${gone.join(', ')}, files kept');
        index.hidden = known.difference(listed);
      }

      final newPages = pages - 1;
      final note = complete
          ? (pages == 0 ? 'no tweets' : 'all $pages pages listed')
          : newPages == 0
          ? 'no new tweets'
          : '$newPages newest ${newPages == 1 ? 'page' : 'pages'} listed';
      phase(feedParts, note, done: true);
    }

    Future<void> exploreProfile() async {
      final part = [?u.parts['profiles']];
      phase(part, 'fetching profile avatar and banner');
      final toAdd = <media.Download>[];
      if (p.avatar case final avatar?) {
        final rawId = Uri.parse(avatar).pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'avatar.jpg';
        final id = Fs.sanitize(rawId.split('?').first);
        if (!index.profiles.containsKey(id)) {
          if (index.profiles.isNotEmpty) changed('new profile avatar');
          index.profiles[id] = DateTime.now().format('yyyy-MM-dd');
          await index.save();
        }
        toAdd.add((to: userDir.dir('profiles').file('${index.profiles[id]}_$id'), url: avatar, text: null));
      }
      if (p.banner case final banner?) {
        final rawId = Uri.parse(banner).pathSegments.where((s) => s.isNotEmpty).toList().reversed.skip(1).firstOrNull ?? 'banner';
        final id = 'banner_${Fs.sanitize(rawId.split('?').first)}';
        if (!index.profiles.containsKey(id)) {
          if (index.profiles.isNotEmpty) changed('new profile banner');
          index.profiles[id] = DateTime.now().format('yyyy-MM-dd');
          await index.save();
        }
        toAdd.add((to: userDir.dir('profiles').file('${index.profiles[id]}_$id.jpg'), url: banner, text: null));
      }
      if (toAdd.isNotEmpty) add(toAdd);
      phase(part, '${toAdd.length} profile ${toAdd.length == 1 ? 'asset' : 'assets'}', done: true);
    }

    await Future.wait([
      if (categories.contains('profile')) exploreProfile(),
      if (tweetsDir != null) exploreMedia(),
    ]);
  }
}

Future<Client?> twitterLogin() => login();
Object twitterExplain(Object error) => explain(error);
