// Twitter/X extractor for MediaLoader.
library;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/utils.dart';

import '../engine.dart';

const _web = 'https://x.com';
const _bearer =
    'Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';

final class TwitterExtractor extends Extractor {
  @override
  final code = 'twt';

  @override
  final name = 'Twitter';

  @override
  final site = _web;

  @override
  final kinds = const [Kind.posts, Kind.profiles];

  @override
  final loginCookies = const {'auth_token'};

  @override
  late final apiRate = rate(100, 15.minutes);
  late final mediaRate = rate(150, 15.minutes);

  static final _url = RegExp(
    r'^(?:https?://)?(?:www\.|mobile\.)?(?:(?:[fv]x)?twitter|(?:fix(?:up|v))?x)\.com/([^/?#]+)(?:/status/(\d+))?',
  );

  @override
  bool matches(String input) {
    final s = input.trim();
    if (_url.hasMatch(s)) return true;
    if (s.toLowerCase().startsWith('twt:')) return true;
    return false;
  }

  @override
  Target parse(String input) {
    var s = input.trim();
    if (s.toLowerCase().startsWith('twt:')) {
      s = s.substring(4).trim();
    }
    for (final re in [r'[?&]screen_name=([^&#]+)', r'[?&]user_id=(\d+)', r'/i/user/(\d+)']) {
      if (RegExp(re).firstMatch(s) case final m?) return Target(code, m[1]!);
    }
    final m = _url.firstMatch(s);
    if (m == null) {
      final sanitized = s.replaceAll('@', '');
      return Target(code, sanitized);
    }
    if (const {
      'home',
      'explore',
      'notifications',
      'messages',
      'settings',
      'i',
      'intent',
      'search',
    }.contains(m[1]!.toLowerCase())) {
      throw FormatException('"$input" is not a Twitter profile or tweet.');
    }
    return Target(code, m[1]!, post: m[2]);
  }

  @override
  Client client(Cookies jar) => Http.client(
    base: _web,
    rate: apiRate,
    cookies: jar,
    csrf: (cookie: 'ct0', header: 'x-csrf-token'),
    login: const ['/i/flow/login', '/account/access'],
    headers: {
      ...HttpUtils.api,
      'authorization': _bearer,
      'x-twitter-active-user': 'yes',
      'x-twitter-auth-type': 'OAuth2Session',
      'x-twitter-client-language': 'en',
    },
  );

  @override
  Future<void> extract(JobCtx ctx) async {
    if (ctx.target.post case final tweetId?) {
      await _extractSingleTweet(ctx, tweetId);
      return;
    }

    final prof = await _fetchProfile(ctx.api, ctx.target.user);
    ctx.userId = prof.id;
    ctx.userName = prof.name;
    ctx.avatarUrl = prof.avatar;

    ctx.db.recordTarget(platform: code, user: prof.name, id: prof.id, displayName: prof.name, avatarUrl: prof.avatar);

    if (ctx.wants(Kind.profiles)) {
      if (prof.avatar != null) {
        ctx.profileAsset(prof.avatar);
      }
      if (prof.banner != null) {
        final size = Uri.parse(prof.banner!).pathSegments.reversed.skip(1).firstOrNull ?? '';
        ctx.profileAsset(prof.banner, id: 'banner_${Fs.sanitize(size)}');
      }
    }

    if (ctx.wants(Kind.posts)) {
      try {
        await _extractTimeline(ctx, prof);
      } catch (e) {
        ctx.phase(Kind.posts, 'unavailable: ${explain(e)}', done: true);
        ctx.log('posts unavailable: ${explain(e)}');
      }
    }
  }

  Future<void> _extractSingleTweet(JobCtx ctx, String tweetId) async {
    ctx.phase(Kind.posts, 'fetching tweet $tweetId');
    final t = await _fetchTweet(ctx.api, tweetId);
    final owner = t.$('core.user_results.result.core.screen_name|core.user_results.result.legacy.screen_name').text();
    if (owner != null) ctx.userName = owner;

    final postTime = _tweetTime(t);
    ctx.db.recordPost(
      platform: code,
      user: owner ?? ctx.target.user,
      postId: tweetId,
      postedAt: postTime,
      caption: t
          .$(
            'note_tweet.note_tweet_results.result.text|legacy.full_text|legacy.retweeted_status_result.result.legacy.full_text',
          )
          .text(),
    );

    final assets = _tweetAssets(ctx, t, ctx.folder(Kind.posts));
    await ctx.enqueue(assets);
    ctx.phase(Kind.posts, '1 tweet enqueued', done: true);
  }

  Future<void> _extractTimeline(JobCtx ctx, _Profile prof) async {
    var cursor = ctx.options.all ? ctx.cursor(Kind.posts) : null;
    ctx.phase(Kind.posts, cursor == null ? 'fetching tweets' : 'resuming tweets from cursor');

    var pageCount = 0;
    var tweetCount = 0;

    while (true) {
      final page = await _fetchMediaTimeline(ctx.api, prof.id, cursor);
      if (page.items.isEmpty) break;
      pageCount++;

      final newAssets = <MediaAsset>[];
      var duplicatesInPage = 0;

      for (final t in page.items) {
        final id = _tweetId(t);
        final postTime = _tweetTime(t);

        if (!ctx.options.all && ctx.db.isPostSeen(code, prof.name, id)) {
          duplicatesInPage++;
          continue;
        }

        final assets = _tweetAssets(ctx, t, ctx.folder(Kind.posts));
        newAssets.addAll(assets);
        tweetCount++;

        ctx.db.recordPost(platform: code, user: prof.name, postId: id, postedAt: postTime, itemCount: assets.length);
      }

      if (newAssets.isNotEmpty) {
        await ctx.enqueue(newAssets);
      }

      if (page.next == null || (!ctx.options.all && duplicatesInPage == page.items.length)) {
        break;
      }

      cursor = page.next;
      if (cursor != null) {
        ctx.saveCursor(Kind.posts, cursor);
      }
      ctx.phase(Kind.posts, '$tweetCount tweets ($pageCount pages)');
    }

    ctx.phase(Kind.posts, '$tweetCount tweets discovered', done: true);
  }

  List<MediaAsset> _tweetAssets(JobCtx ctx, Json tweet, Dir dir) {
    final id = _tweetId(tweet);
    final at = _tweetTime(tweet);
    final month = dir / at.format('yyyy-MM');
    final out = <MediaAsset>[];

    final mediaList = _mediaOf(tweet);
    for (final (i, m) in mediaList.indexed) {
      final name = '${id}_${i + 1}';
      final type = m.$('type').text();
      if (type == 'video' || type == 'animated_gif') {
        final mp4s = Json.of([
          for (final v in m.$('video_info.variants'))
            if (v.$('content_type').text() == 'video/mp4') v,
        ]);
        if (mp4s.max((v) => v.$('bitrate').or(0)).$('url').text() case final url?) {
          out.add(
            MediaAsset(
              id: '$name.mp4',
              platform: code,
              user: ctx.userName ?? ctx.target.user,
              category: Kind.posts,
              to: month.file('$name.mp4'),
              url: url,
              at: at,
              sourcePostId: id,
            ),
          );
        }
      } else if (m.$('media_url_https').text() case final url?) {
        final ext = Uri.parse(url).path.split('.').lastOrNull ?? 'jpg';
        out.add(
          MediaAsset(
            id: '$name.$ext',
            platform: code,
            user: ctx.userName ?? ctx.target.user,
            category: Kind.posts,
            to: month.file('$name.$ext'),
            url: '$url?name=orig',
            at: at,
            sourcePostId: id,
          ),
        );
      }
    }

    final caption = tweet
        .$(
          'note_tweet.note_tweet_results.result.text|legacy.full_text|legacy.retweeted_status_result.result.legacy.full_text',
        )
        .text();
    if (out.isNotEmpty && caption != null && caption.trim().isNotEmpty) {
      out.add(
        MediaAsset(
          id: '$id.txt',
          platform: code,
          user: ctx.userName ?? ctx.target.user,
          category: Kind.posts,
          to: month.file('$id.txt'),
          text: caption,
          at: at,
          sourcePostId: id,
        ),
      );
    }

    return out;
  }

  // ── API calls ────────────────────────────────────────────────────────────

  Future<_Profile> _fetchProfile(Client api, String name) async {
    if (RegExp(r'^\d+$').hasMatch(name)) {
      final res = await api.get('/i/user/$name');
      await res.close();
      final seg = Uri.parse(res.url()).pathSegments.where((s) => s.isNotEmpty).lastOrNull;
      if (seg != null && seg != 'user' && !RegExp(r'^\d+$').hasMatch(seg)) name = seg;
    }
    final response = await api
        .get(
          '/i/api/graphql/ck5KkZ8t5cOmoLssopN99Q/UserByScreenName',
          query: {
            'variables': {'screen_name': name, 'withSafetyModeUserFields': true},
            'features': _features,
            'fieldToggles': {'withAuxiliaryUserLabels': true},
          },
        )
        .json();
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

  Future<_FeedPage> _fetchMediaTimeline(Client api, String userId, String? cursor) async {
    final response = await api
        .get(
          '/i/api/graphql/jCRhbOzdgOHp6u9H4g2tEg/UserMedia',
          query: {
            'variables': {
              'userId': userId,
              'count': 20,
              'cursor': ?cursor,
              'includePromotedContent': false,
              'withClientEventToken': false,
              'withBirdwatchNotes': false,
              'withVoice': true,
            },
            'features': _features,
            'fieldToggles': {'withArticlePlainText': false},
          },
        )
        .json();
    final timeline = response.$('data.user.result.timeline.timeline|data.user.result.timeline_v2.timeline');
    final tweets = [for (final t in timeline.$('**.tweet_results.result')) _unwrap(t)];
    final next = timeline.$('**').where((n) => n.$('cursorType').text() == 'Bottom').firstOrNull?.$('value').text();
    return (items: tweets, next: tweets.isEmpty ? null : next);
  }

  Future<Json> _fetchTweet(Client api, String id) async {
    final response = await api
        .get(
          '/i/api/graphql/2ICDjqPd81tulZcYrtpTuQ/TweetResultByRestId',
          query: {
            'variables': {'tweetId': id, 'withCommunity': false, 'includePromotedContent': false, 'withVoice': false},
            'features': _features,
          },
        )
        .json();
    final t = _unwrap(response.$('data.tweetResult.result'));
    return t.isEmpty ? throw Exception('tweet not found: $id') : t;
  }

  Json _unwrap(Json t) => t.$('tweet').isEmpty ? t : t.$('tweet');

  String _tweetId(Json tweet) => tweet.$('rest_id|legacy.id_str').or('tweet');

  DateTime _tweetTime(Json tweet) {
    final id = BigInt.tryParse(_tweetId(tweet));
    return id == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch((id >> 22).toInt() + 1288834974657);
  }

  Json _mediaOf(Json tweet) => tweet.$(
    'legacy.extended_entities.media|legacy.retweeted_status_result.result.legacy.extended_entities.media'
    '|legacy.retweeted_status_result.result.tweet.legacy.extended_entities.media',
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

typedef _Profile = ({String id, String name, String? avatar, String? banner});
typedef _FeedPage = ({List<Json> items, String? next});
