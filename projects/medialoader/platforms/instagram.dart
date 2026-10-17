// Instagram extractor for MediaLoader.
library;

import 'dart:math';

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/utils.dart';

import '../engine.dart';

const _web = 'https://www.instagram.com';

final class InstagramExtractor extends Extractor {
  @override
  final code = 'ins';

  @override
  final name = 'Instagram';

  @override
  final site = _web;

  @override
  final kinds = const [Kind.posts, Kind.stories, Kind.highlights, Kind.profiles];

  @override
  final loginCookies = const {'sessionid'};

  late final apiRate = rate(75, 11.minutes, pause: 3.seconds);
  late final feedRate = rate(200, 11.minutes, pause: 3.seconds);

  @override
  bool matches(String input) {
    final s = input.trim();
    if (RegExp(r'^(?:https?://)?(?:www\.)?instagram\.com/').hasMatch(s)) return true;
    if (s.toLowerCase().startsWith('ins:')) return true;
    return false;
  }

  @override
  Target parse(String input) {
    var s = input.trim();
    if (s.toLowerCase().startsWith('ins:')) {
      s = s.substring(4).trim();
    }
    if (RegExp(r'instagram\.com/(?:[^/?#]+/)?(?:p|reels?|tv)/([^/?#]+)').firstMatch(s) case final m?) {
      return Target(code, m[1]!, post: m[1]);
    }
    final m = RegExp(r'instagram\.com/(?:stories/)?([^/?#]+)').firstMatch(s);
    if (m == null) {
      final sanitized = s.replaceAll('@', '');
      return Target(code, sanitized);
    }
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
    return Target(code, m[1]!);
  }

  @override
  Client client(Cookies jar) => Http.client(
    base: _web,
    rate: apiRate,
    cookies: jar,
    csrf: (cookie: 'csrftoken', header: 'x-csrftoken'),
    login: const ['/accounts/login', '/challenge/'],
    headers: {...HttpUtils.api, 'x-ig-app-id': '936619743392459', 'x-requested-with': 'XMLHttpRequest'},
  );

  @override
  Future<void> extract(JobCtx ctx) async {
    if (ctx.target.post case final postCode?) {
      await _extractSinglePost(ctx, postCode);
      return;
    }

    final (profile: prof, :first) = await _fetchProfile(ctx.api, ctx.target.user);
    ctx.userId = prof.id;
    ctx.userName = prof.name;
    ctx.avatarUrl = prof.picture;

    ctx.db.recordTarget(platform: code, user: prof.name, displayName: prof.name);

    if (ctx.wants(Kind.profiles) && prof.picture != null) {
      ctx.profileAsset(prof.picture, id: 'avatar');
    }

    final tasks = <Future<void>>[];
    Future<void> safeRun(Kind kind, Future<void> Function() run) async {
      try {
        await run();
      } catch (e) {
        ctx.phase(kind, 'unavailable: ${explain(e)}', done: true);
        ctx.log('${kind.name} unavailable: ${explain(e)}');
      }
    }

    if (ctx.wants(Kind.posts)) {
      tasks.add(safeRun(Kind.posts, () => _extractPosts(ctx, prof, first)));
    }
    if (ctx.wants(Kind.stories)) {
      tasks.add(safeRun(Kind.stories, () => _extractStories(ctx, prof)));
    }
    if (ctx.wants(Kind.highlights)) {
      tasks.add(safeRun(Kind.highlights, () => _extractHighlights(ctx, prof)));
    }

    await Future.wait(tasks);
  }

  Future<void> _extractSinglePost(JobCtx ctx, String code) async {
    ctx.phase(Kind.posts, 'fetching post $code');
    final p = await _fetchPost(ctx.api, code);
    final user = p.$('user.username').text() ?? ctx.target.user;
    ctx.userName = user;
    final postTime = _time(p);
    final postDir = ctx.folder(Kind.posts).dir(postTime.format('yyyy-MM'));

    final assets = _postAssets(ctx, p, postDir, code);
    await ctx.enqueue(assets);
    ctx.phase(Kind.posts, '1 post enqueued', done: true);
  }

  Future<void> _extractPosts(JobCtx ctx, _Profile prof, _FeedPage? first) async {
    final user = prof.name;
    var cursor = ctx.options.all ? null : ctx.cursor(Kind.posts);
    ctx.phase(Kind.posts, cursor == null ? 'fetching posts' : 'resuming posts from cursor');

    var pageCount = 0;
    var postCount = 0;

    while (true) {
      final _FeedPage page;
      if (pageCount == 0 && cursor == null && first != null) {
        page = first;
      } else {
        page = await _fetchPostsPage(ctx.api, user, cursor);
      }

      if (page.items.isEmpty) break;
      pageCount++;

      final newAssets = <MediaAsset>[];
      var duplicatesInPage = 0;

      for (final item in page.items) {
        final shortcode = _postCode(item);
        final postTime = _time(item);

        if (!ctx.options.all && ctx.db.isPostSeen(code, user, shortcode)) {
          duplicatesInPage++;
          continue;
        }

        ctx.db.recordPost(platform: code, user: user, postId: shortcode, postedAt: postTime);

        final targetDir = ctx.folder(Kind.posts).dir(postTime.format('yyyy-MM'));
        final assets = _postAssets(ctx, item, targetDir, shortcode);
        newAssets.addAll(assets);
        postCount++;
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
      ctx.phase(Kind.posts, '$postCount posts ($pageCount pages)');
    }

    ctx.phase(Kind.posts, '$postCount posts discovered', done: true);
  }

  Future<void> _extractStories(JobCtx ctx, _Profile prof) async {
    ctx.phase(Kind.stories, 'fetching current stories');
    final reels = await _fetchReels(ctx.api, [prof.id], prof.name);
    final items = [for (final r in reels) ...r.items];

    final assets = <MediaAsset>[];
    for (final item in items) {
      final itemId = item.$('id').or('story');
      final takenAt = _time(item);
      final dir = ctx.folder(Kind.stories).dir(takenAt.format('yyyy-MM'));
      final itemAssets = _mediaAssets(
        ctx,
        item,
        name: '${takenAt.millisecondsSinceEpoch ~/ 1000}_${Fs.sanitize(itemId)}',
        dir: dir,
        category: Kind.stories,
        parentTime: takenAt,
      );
      assets.addAll(itemAssets);
    }

    await ctx.enqueue(assets);
    ctx.phase(Kind.stories, '${assets.length} story items', done: true);
  }

  Future<void> _extractHighlights(JobCtx ctx, _Profile prof) async {
    ctx.phase(Kind.highlights, 'listing highlights');
    final ids = await _fetchHighlights(ctx.api, prof);
    ctx.phase(Kind.highlights, 'fetching ${ids.length} highlights');

    var count = 0;
    for (var i = 0; i < ids.length; i += 10) {
      final chunk = ids.sublist(i, min(i + 10, ids.length));
      final reels = await _fetchReels(ctx.api, chunk, prof.name);
      for (final r in reels) {
        final title = r.title.isEmpty ? r.id : r.title;
        final dir = ctx.folder(Kind.highlights).dir(Fs.sanitize(title));
        final assets = <MediaAsset>[];
        for (final item in r.items) {
          final itemId = item.$('id').or('hl');
          final takenAt = _time(item);
          assets.addAll(
            _mediaAssets(
              ctx,
              item,
              name: '${takenAt.millisecondsSinceEpoch ~/ 1000}_${Fs.sanitize(itemId)}',
              dir: dir,
              category: Kind.highlights,
              parentTime: takenAt,
            ),
          );
        }
        await ctx.enqueue(assets);
        count += assets.length;
      }
      ctx.phase(Kind.highlights, '$count highlight items enqueued');
    }

    ctx.phase(Kind.highlights, '$count highlight items', done: true);
  }

  List<MediaAsset> _postAssets(JobCtx ctx, Json p, Dir dir, String code) {
    final postTime = _time(p);
    final caption = p.$('caption.text|edge_media_to_caption.edges.0.node.text').text();

    final result = _mediaAssets(ctx, p, name: code, dir: dir, category: Kind.posts, parentTime: postTime);

    if (caption != null && caption.trim().isNotEmpty && result.isNotEmpty) {
      result.add(
        MediaAsset(
          id: '$code.txt',
          platform: this.code,
          user: ctx.userName ?? ctx.target.user,
          category: Kind.posts,
          to: dir.file('$code.txt'),
          text: caption,
          at: postTime,
          sourcePostId: code,
        ),
      );
    }

    return result;
  }

  List<MediaAsset> _mediaAssets(
    JobCtx ctx,
    Json item, {
    required String name,
    required Dir dir,
    required Kind category,
    DateTime? parentTime,
  }) {
    final list = _children(item);
    final itemTime = item.$('taken_at|taken_at_timestamp').isNotEmpty ? _time(item) : parentTime ?? DateTime.now();

    if (list.isNotEmpty) {
      final out = <MediaAsset>[];
      for (final (i, child) in list.indexed) {
        out.addAll(
          _mediaAssets(ctx, child, name: '${name}_${i + 1}', dir: dir, category: category, parentTime: itemTime),
        );
      }
      return out;
    }

    final video = _largest(item.$('video_versions|video_resources')) ?? item.$('video_url').text();
    final image =
        _largest(item.$('image_versions2.candidates')) ??
        _largest(item.$('display_resources')) ??
        item.$('display_url|display_uri').text();

    final out = <MediaAsset>[];
    if (video != null) {
      out.add(
        MediaAsset(
          id: '$name.mp4',
          platform: code,
          user: ctx.userName ?? ctx.target.user,
          category: category,
          to: dir.file('$name.mp4'),
          url: video,
          at: itemTime,
        ),
      );
    } else if (image != null && !image.contains('/null.jpg')) {
      out.add(
        MediaAsset(
          id: '$name.jpg',
          platform: code,
          user: ctx.userName ?? ctx.target.user,
          category: category,
          to: dir.file('$name.jpg'),
          url: image,
          at: itemTime,
        ),
      );
    }
    return out;
  }

  // ── API calls ────────────────────────────────────────────────────────────

  Future<({_Profile profile, _FeedPage? first})> _fetchProfile(Client api, String name) async {
    Json u;
    _FeedPage? first;
    if (RegExp(r'^\d+$').hasMatch(name)) {
      u = (await api.get('/api/v1/users/$name/info/').json()).$('user');
    } else {
      first = await _fetchPostsPage(api, name, null);
      u = first.items.firstOrNull?.$('user') ?? Json.of(null);
      if (u.isEmpty) {
        u = (await api.get('/api/v1/users/web_profile_info/', query: {'username': name}).json()).$('data.user');
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

  Future<_FeedPage> _fetchPostsPage(Client api, String user, String? cursor) async {
    final response = await api
        .post(
          '/graphql/query',
          headers: {'referer': '$_web/$user/'},
          body: .form({
            'doc_id': '28975909992013618',
            'server_timestamps': true,
            'variables': {
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
            },
          }),
        )
        .json();
    final feed = response.$('data.xdt_api__v1__feed__user_timeline_graphql_connection');
    final more = feed.$('page_info.has_next_page').or(false);
    return (items: feed.$('edges.*.node').toList(), next: more ? feed.$('page_info.end_cursor').text() : null);
  }

  Future<Json> _fetchPost(Client api, String code) async {
    const digits = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final id = code
        .substring(0, min(11, code.length))
        .split('')
        .fold(BigInt.zero, (n, c) => n * BigInt.from(64) + BigInt.from(digits.indexOf(c)));
    final item = (await api.get('/api/v1/media/$id/info/').json()).$('items.0');
    return item.isEmpty ? throw Exception('post not found: $code') : item;
  }

  Future<List<String>> _fetchHighlights(Client api, _Profile p) async {
    final response = await api
        .get(
          '/graphql/query/',
          query: {
            'query_hash': 'd4d88dc1500312af6f937f7b804c68c3',
            'variables': {'user_id': p.id, 'include_highlight_reels': true},
          },
          headers: {'referer': '$_web/${p.name}/'},
        )
        .json();
    return [for (final id in response.$('data.user.edge_highlight_reels.edges.*.node.id')) 'highlight:${id.text()}'];
  }

  Future<List<_Reel>> _fetchReels(Client api, List<String> ids, String user) async {
    final response = await api
        .get('/api/v1/feed/reels_media/', query: {'reel_ids': ids}, headers: {'referer': '$_web/$user/'})
        .json();
    return [
      for (final r in response.$('reels_media'))
        (id: r.$('id').or(''), title: r.$('title').or(''), items: r.$('items').toList()),
    ];
  }

  List<Json> _children(Json item) =>
      [...item.$('carousel_media'), ...item.$('edge_sidecar_to_children.edges.*.node')];

  DateTime _time(Json item) =>
      DateTime.fromMillisecondsSinceEpoch(item.$('taken_at|taken_at_timestamp').or(0) * 1000);

  String _postCode(Json post) => Fs.sanitize(post.$('code|shortcode').text() ?? 'post');

  String? _largest(Json versions) => versions.max((v) => v.$('width|config_width').or(0)).$('url|src').text();
}

typedef _Profile = ({String id, String name, String? picture});
typedef _Reel = ({String id, String title, List<Json> items});
typedef _FeedPage = ({List<Json> items, String? next});
