// Twitter's web API, as the website calls it. Import with `as twitter`.
library;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';

import 'dashboard.dart';
import 'download.dart';
import 'media.dart';
import 'platform.dart';

const web = 'https://x.com';
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

typedef Profile = ({String id, String name, String? avatar, String? banner});

// A screen name (or user id) as their id, avatar, and banner.
Future<Profile> profile(Client api, String name) async {
  if (RegExp(r'^\d+$').hasMatch(name)) {
    // /i/user/<id> redirects to /<screen name>.
    final res = await api.get('/i/user/$name');
    await res.close();
    final seg = Uri.parse(res.url()).pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (seg != null && seg != 'user' && !RegExp(r'^\d+$').hasMatch(seg)) name = seg;
  }
  final response = await json(
    api.get(
      '/i/api/graphql/ck5KkZ8t5cOmoLssopN99Q/UserByScreenName',
      query: {
        'variables': Json.encode({'screen_name': name, 'withSafetyModeUserFields': true}),
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
        'fieldToggles': Json.encode({'withAuxiliaryUserLabels': true}),
      },
    ),
  );
  final user = response.$('data.user.result');
  if (user.isEmpty || user.$('__typename').text() == 'UserUnavailable') {
    throw Exception('user not found or unavailable: "$name"');
  }
  final banner = user.$('legacy.profile_banner_url').text();
  return (
    id: user.$('rest_id').text() ?? (throw Exception('no user id for "$name"')),
    name: user.$('core.screen_name|legacy.screen_name').or(name),
    avatar: user
        .$('avatar.image_url|legacy.profile_image_url_https|core.avatar.image_url')
        .text()
        ?.replaceAll('_normal.', '.'),
    banner: banner == null ? null : '$banner/1500x500',
  );
}

const _features = {
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

// One page (up to 20 tweets) of the user's media timeline.
Future<Page> mediaTimeline(Client api, String userId, String? cursor) async {
  final response = await json(
    api.get(
      '/i/api/graphql/jCRhbOzdgOHp6u9H4g2tEg/UserMedia',
      query: {
        'variables': Json.encode({
          'userId': userId,
          'count': 20,
          'cursor': ?cursor,
          'includePromotedContent': false,
          'withClientEventToken': false,
          'withBirdwatchNotes': false,
          'withVoice': true,
        }),
        'features': Json.encode(_features),
        'fieldToggles': Json.encode({'withArticlePlainText': false}),
      },
    ),
  );
  final timeline = response.$('data.user.result.timeline.timeline|data.user.result.timeline_v2.timeline');
  final tweets = [for (final t in timeline.$('**.tweet_results.result')) unwrap(t)];
  final next = timeline.$('**').where((n) => n.$('cursorType').text() == 'Bottom').firstOrNull?.$('value').text();
  return (items: tweets, next: tweets.isEmpty ? null : next);
}

// One tweet by id.
Future<Json> tweet(Client api, String id) async {
  final response = await json(
    api.get(
      '/i/api/graphql/2ICDjqPd81tulZcYrtpTuQ/TweetResultByRestId',
      query: {
        'variables': Json.encode({'tweetId': id, 'withCommunity': false, 'includePromotedContent': false, 'withVoice': false}),
        'features': Json.encode(_features),
      },
    ),
  );
  final t = unwrap(response.$('data.tweetResult.result'));
  return t.isEmpty ? throw Exception('tweet not found: $id') : t;
}

// A tweet with visibility results wraps the tweet.
Json unwrap(Json t) => t.$('tweet').isEmpty ? t : t.$('tweet');

String tweetId(Json tweet) => tweet.$('rest_id|legacy.id_str').or('tweet');

// When it was posted, from the id (a snowflake).
DateTime tweetTime(Json tweet) {
  final id = BigInt.tryParse(tweetId(tweet));
  return id == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch((id >> 22).toInt() + 1288834974657);
}

Json mediaOf(Json tweet) => tweet.$(
  'legacy.extended_entities.media|legacy.retweeted_status_result.result.legacy.extended_entities.media'
  '|legacy.retweeted_status_result.result.tweet.legacy.extended_entities.media',
);

List<String> tweetItems(Json tweet) => [for (final m in mediaOf(tweet)) m.$('id_str').or('')];

// tweets/<month>/<id>_<n>.jpg|mp4 and <id>.txt; [order] numbers the items by id.
List<Download> tweetFiles(Json tweet, Dir dir, [List<String>? order]) {
  final id = tweetId(tweet), at = tweetTime(tweet), month = dir.dir(at.format('yyyy-MM'));
  final out = <Download>[];
  for (final (i, m) in mediaOf(tweet).indexed) {
    final pos = order?.indexOf(m.$('id_str').or('')) ?? -1;
    final name = '${id}_${(pos < 0 ? i : pos) + 1}';
    if (const {'video', 'animated_gif'}.contains(m.$('type').text())) {
      final mp4s = Json.of([for (final v in m.$('video_info.variants')) if (v.$('content_type').text() == 'video/mp4') v]);
      if (mp4s.max((v) => v.$('bitrate').or(0)).$('url').text() case final url?) {
        out.add(Download(month.file('$name.mp4'), url: url, at: at));
      }
    } else if (m.$('media_url_https').text() case final url?) {
      out.add(Download(month.file('$name.${url.split('.').last}'), url: '$url?name=orig', at: at));
    }
  }
  final caption = tweet
      .$('note_tweet.note_tweet_results.result.text|legacy.full_text|legacy.retweeted_status_result.result.legacy.full_text')
      .text();
  return [...out, if (caption != null && caption.trim().isNotEmpty) Download(month.file('$id.txt'), text: caption, at: at)];
}

Future<Json> json(Future<Response> request) async {
  final response = await request;
  final url = response.url();
  if (url.contains('/i/flow/login') || url.contains('/account/access')) {
    await response.close();
    throw Exception('Twitter logged you out: copy a fresh .twt.session from your browser.');
  }
  return response.json();
}

final platform = Twitter();

final class Twitter implements Platform {
  @override
  final code = 'twt', name = 'twitter', site = web;

  @override
  final categories = const [Category('tweet'), Category('profile')];

  static final _url = RegExp(
    r'^(?:https?://)?(?:www\.|mobile\.)?(?:(?:[fv]x)?twitter|(?:fix(?:up|v))?x)\.com/([^/?#]+)(?:/status/(\d+))?',
  );

  @override
  bool matches(String input) => _url.hasMatch(input.trim());

  @override
  Target parse(String input) {
    final s = input.trim();
    for (final re in [r'[?&]screen_name=([^&#]+)', r'[?&]user_id=(\d+)', r'/i/user/(\d+)']) {
      if (RegExp(re).firstMatch(s) case final m?) return Target(this, m[1]!);
    }
    final m = _url.firstMatch(s);
    if (m == null) return Target(this, username(s, 'Twitter'));
    if (const {'home', 'explore', 'notifications', 'messages', 'settings', 'i', 'intent', 'search'}.contains(m[1]!.toLowerCase())) {
      throw FormatException('"$input" is not a Twitter profile or tweet.');
    }
    return Target(this, m[1]!, post: m[2]);
  }

  // The logged-in client from .twt.session (cookies.txt export plus a "user-agent: ..." line), or null.
  @override
  Future<Client?> login() async {
    final jar = await Cookies.load(Fs.scriptDir().file('.twt.session'));
    if (jar['auth_token'] == null) return null;
    return Http.client(
      base: web,
      rate: apiRate,
      check: true,
      cookies: jar,
      csrf: (cookie: 'ct0', header: 'x-csrf-token'),
      headers: {
        'authorization': bearer,
        'x-twitter-active-user': 'yes',
        'x-twitter-auth-type': 'OAuth2Session',
        'x-twitter-client-language': 'en',
        'accept': '*/*',
        'sec-fetch-site': 'same-origin',
      },
    );
  }

  @override
  Object explain(Object e) => switch (e) {
    HttpStatusException(status: 404, :final url) => 'not found: $url',
    HttpStatusException(status: final status && (401 || 403), :final url) =>
      'Twitter refused (HTTP $status): your session in .twt.session may have expired or is invalid ($url)',
    HttpStatusException(status: 429, :final url) => 'Twitter rate limit reached (HTTP 429): try again in 15 minutes ($url)',
    _ => e,
  };

  @override
  Future<void> explore(Job j) async {
    if (j.target.post case final id?) {
      final t = await tweet(j.api, id);
      final owner = t.$('core.user_results.result.core.screen_name|core.user_results.result.legacy.screen_name');
      await j.open(owner.or(j.target.user), track: false);
      j.add(tweetFiles(t, j.dir.dir('tweets'), j.index.posts[id]));
      return j.phase(j.part('tweets'), '1 tweet', done: true);
    }
    final p = await profile(j.api, j.target.user);
    await j.open(p.name, id: p.id);
    late final mediaApi = j.client(mediaRate);
    await Future.wait([
      if (j.wants('profile')) _profile(j, p),
      if (j.wants('tweet'))
        feed(
          j,
          folder: 'tweets',
          noun: 'tweet',
          page: (cursor) => mediaTimeline(mediaApi, p.id, cursor),
          id: tweetId,
          items: tweetItems,
          time: tweetTime,
          files: (page) => [for (final t in page) ...tweetFiles(t, j.dir.dir('tweets'), j.index.posts[tweetId(t)])],
        ),
    ]);
  }

  Future<void> _profile(Job j, Profile p) async {
    final files = [
      if (p.avatar case final url?) (url, Fs.sanitize(Uri.parse(url).pathSegments.last), 'new profile avatar', ''),
      if (p.banner case final url?)
        (url, 'banner_${Fs.sanitize(Uri.parse(url).pathSegments.reversed.skip(1).firstOrNull ?? '')}', 'new profile banner', '.jpg'),
    ];
    j.add([
      for (final (url, id, change, ext) in files) Download(j.dir.dir('profiles').file('${j.seen(id, change)}_$id$ext'), url: url),
    ]);
    j.phase(j.part('profiles'), '${files.length} profile ${files.length == 1 ? 'asset' : 'assets'}', done: true);
  }
}
