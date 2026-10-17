// Facebook extractor for MediaLoader.
library;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/utils.dart';

import '../engine.dart';

const _web = 'https://www.facebook.com';
final _digits = RegExp(r'^\d+$');

final class FacebookExtractor extends Extractor {
  @override
  final code = 'fbk';

  @override
  final name = 'Facebook';

  @override
  final site = _web;

  @override
  final kinds = const [
    Kind.posts,
    Kind.photos,
    Kind.videos,
    Kind.albums,
    Kind.stories,
    Kind.highlights,
    Kind.profiles,
  ];

  @override
  final loginCookies = const {'c_user', 'xs'};

  late final apiRate = rate(120, 5.minutes, pause: 500.milliseconds);

  final _photoCache = <String, _Photo>{};
  final _videoCache = <String, _Video>{};

  static final _url = RegExp(r'^(?:https?://)?(?:www\.|m\.|web\.)?(?:facebook\.com|fb\.com)/([^/?#]+)');

  @override
  bool matches(String input) {
    final s = input.trim();
    if (_url.hasMatch(s)) return true;
    if (s.toLowerCase().startsWith('fbk:')) return true;
    return false;
  }

  @override
  Target parse(String input) {
    var s = input.trim();
    if (s.toLowerCase().startsWith('fbk:')) {
      s = s.substring(4).trim();
    }
    for (final re in [r'[?&]id=(\d+)', r'/people/[^/?#]+/(\d+)', r'/stories/(?:highlights/)?([^/?#]+)']) {
      if (RegExp(re).firstMatch(s)?[1] case final user? when user != 'highlights') return Target(code, user);
    }
    const nonProfile = {'photo', 'photos', 'media', 'watch', 'story', 'stories', 'groups', 'share', 'login'};
    if (_url.firstMatch(s)?[1] case final seg? when !nonProfile.contains(seg.toLowerCase()) && !seg.contains('.php')) {
      return Target(code, seg);
    }
    final sanitized = s.replaceAll('@', '');
    return Target(code, sanitized);
  }

  @override
  Client client(Cookies jar) =>
      Http.client(base: _web, rate: apiRate, cookies: jar, headers: HttpUtils.page, login: const ['/login']);

  @override
  Future<void> extract(JobCtx ctx) async {
    _photoCache.clear();
    _videoCache.clear();
    final p = await _fetchProfile(ctx.api, ctx.target.user);
    final user = _digits.hasMatch(ctx.target.user) ? ctx.target.user : p.name;
    ctx.userId = p.id;
    ctx.userName = user;
    ctx.avatarUrl = p.avatar;

    ctx.db.recordTarget(platform: code, user: user, id: p.id, displayName: p.name, avatarUrl: p.avatar);

    String tab(String t) => _digits.hasMatch(p.name) ? '/profile.php?id=${p.name}&sk=$t' : '/${p.name}/$t/';

    if (ctx.wants(Kind.profiles)) {
      if (p.avatar != null) ctx.profileAsset(p.avatar, id: 'avatar');
      if (p.cover != null) {
        final last = Uri.parse(p.cover!).pathSegments.lastOrNull ?? '';
        ctx.profileAsset(p.cover, id: 'cover_${Fs.sanitize(last)}');
      }
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

    if (ctx.wants(Kind.posts)) tasks.add(safeRun(Kind.posts, () => _extractPosts(ctx, p)));
    if (ctx.wants(Kind.photos)) tasks.add(safeRun(Kind.photos, () => _extractPhotos(ctx, p, tab)));
    if (ctx.wants(Kind.videos)) tasks.add(safeRun(Kind.videos, () => _extractVideos(ctx, p, tab)));
    if (ctx.wants(Kind.albums)) tasks.add(safeRun(Kind.albums, () => _extractAlbums(ctx, tab)));
    if (ctx.wants(Kind.stories)) tasks.add(safeRun(Kind.stories, () => _extractStories(ctx, p)));
    if (ctx.wants(Kind.highlights)) tasks.add(safeRun(Kind.highlights, () => _extractHighlights(ctx, p)));

    await Future.wait(tasks);
  }

  Future<void> _extractPosts(JobCtx ctx, _Profile p) async {
    ctx.phase(Kind.posts, 'fetching timeline posts');
    var n = 0;
    for (final post in _timeline(p.doc.data)) {
      if (!ctx.options.all && ctx.db.isPostSeen(code, ctx.userName ?? ctx.target.user, post.id)) {
        continue;
      }
      ctx.db.recordPost(
        platform: code,
        user: ctx.userName ?? ctx.target.user,
        postId: post.id,
        postedAt: post.at,
        caption: post.caption,
      );

      final dir = ctx.folder(Kind.posts).dir(post.at.format('yyyy-MM'));
      String name(_Item i) {
        final same = [
          for (final o in post.items)
            if (o.video == i.video) o.id,
        ];
        return same.length > 1 ? '${post.id}_${same.indexOf(i.id) + 1}' : post.id;
      }

      final assets = <MediaAsset>[];
      for (final i in post.items) {
        final url = i.url ??
            (i.video
                ? (_videoCache[i.id] ?? await _video(ctx.api, i.id))?.url
                : (_photoCache[i.id] ?? await _photo(ctx.api, i.id))?.url);
        if (url != null) {
          final fileExt = i.video ? 'mp4' : _ext(url);
          final fileName = '${name(i)}.$fileExt';
          assets.add(
            MediaAsset(
              id: fileName,
              platform: code,
              user: ctx.userName ?? ctx.target.user,
              category: Kind.posts,
              to: dir.file(fileName),
              url: url,
              at: post.at,
              sourcePostId: post.id,
            ),
          );
        }
      }

      if (post.caption case final c? when c.trim().isNotEmpty) {
        assets.add(
          MediaAsset(
            id: '${post.id}.txt',
            platform: code,
            user: ctx.userName ?? ctx.target.user,
            category: Kind.posts,
            to: dir.file('${post.id}.txt'),
            text: c,
            at: post.at,
            sourcePostId: post.id,
          ),
        );
      }

      if (assets.isNotEmpty) {
        await ctx.enqueue(assets);
        n++;
        ctx.phase(Kind.posts, '$n posts');
      }
    }
    ctx.phase(Kind.posts, '$n posts', done: true);
  }

  Future<void> _extractPhotos(JobCtx ctx, _Profile p, String Function(String) tab) async {
    ctx.phase(Kind.photos, 'fetching photos index');
    final by = await _load(ctx.api, tab('photos_by'));
    var set = _profileSet(by);
    if (set == null) {
      final all = await _load(ctx.api, tab('photos'));
      set = _profileSet(all) ?? _setIn(_links(all)) ?? all.data.$('**.mediaSetToken').text();
    }
    final ids = [..._photoIds(by), ..._photoIds(p.doc)];
    if (set != null) ids.insertAll(0, _photoIds(await _load(ctx.api, '/media/set/?set=$set')));
    if (ids.isEmpty && set == null) {
      final all = await _load(ctx.api, tab('photos_all'));
      ids.addAll(_photoIds(all));
      set = _profileSet(all);
    }
    ctx.phase(Kind.photos, 'listing photos');
    final n = await _walk(ctx, ids, set ?? '', 'photo', (ph) => ctx.folder(Kind.photos).dir(ph.at.format('yyyy-MM')));
    ctx.phase(Kind.photos, '$n photos listed', done: true);
  }

  Future<void> _extractVideos(JobCtx ctx, _Profile p, String Function(String) tab) async {
    ctx.phase(Kind.videos, 'fetching videos index');
    final pages = [
      await _load(ctx.api, tab('videos')),
      await _load(ctx.api, tab(_digits.hasMatch(p.name) ? 'reels_tab' : 'reels')),
    ];
    final ids = {
      for (final d in pages) ...[
        for (final l in _links(d))
          if (RegExp(r'/(?:videos|reels?)/(\d+)|/watch/?\?v=(\d+)').firstMatch(l) case final m?) m[1] ?? m[2]!,
        ...d.data.$('**.video_id').texts(),
      ],
    };
    var n = 0;
    for (final id in ids) {
      if (!ctx.options.all && ctx.db.isPostSeen(code, ctx.userName ?? ctx.target.user, 'video:$id')) continue;
      final v = _videoCache[id] ?? await _video(ctx.api, id);
      if (v == null) continue;
      final dir = ctx.folder(Kind.videos).dir(v.at.format('yyyy-MM'));
      ctx.db.recordPost(
        platform: code,
        user: ctx.userName ?? ctx.target.user,
        postId: 'video:$id',
        postedAt: v.at,
        caption: v.title,
      );

      final assets = <MediaAsset>[
        MediaAsset(
          id: '${v.id}.mp4',
          platform: code,
          user: ctx.userName ?? ctx.target.user,
          category: Kind.videos,
          to: dir.file('${v.id}.mp4'),
          url: v.url,
          at: v.at,
          sourcePostId: 'video:$id',
        ),
      ];
      if (v.title case final t? when t.trim().isNotEmpty) {
        assets.add(
          MediaAsset(
            id: '${v.id}.txt',
            platform: code,
            user: ctx.userName ?? ctx.target.user,
            category: Kind.videos,
            to: dir.file('${v.id}.txt'),
            text: t,
            at: v.at,
            sourcePostId: 'video:$id',
          ),
        );
      }
      await ctx.enqueue(assets);
      ctx.phase(Kind.videos, '${++n} videos discovered');
    }
    ctx.phase(Kind.videos, '$n videos listed', done: true);
  }

  Future<void> _extractAlbums(JobCtx ctx, String Function(String) tab) async {
    ctx.phase(Kind.albums, 'fetching albums index');
    final d = await _load(ctx.api, tab('photos_albums'));
    final albums = <String, String>{};
    for (final n in d.data.$('**')) {
      if (RegExp(r'/media/set/?\?set=(a\.\d+)').firstMatch(n.$('url').text() ?? '')?[1] case final set?) {
        albums[set] ??= n.$('title.text').text() ?? set;
      }
    }
    for (final set in _links(d).map((l) => RegExp(r'[?&]set=(a\.\d+)').firstMatch(l)?[1]).nonNulls) {
      albums[set] ??= set;
    }
    var n = 0;
    for (final MapEntry(key: set, value: title) in albums.entries) {
      final page = await _load(ctx.api, '/media/set/?set=$set');
      final name =
          page.data.$('**').where((n) => n.$('__isMediaSet').text() == 'Album').firstOrNull?.$('title.text').text() ??
          page.data.$('**.title.text').text() ??
          title;
      final dir = ctx.folder(Kind.albums).dir(Fs.sanitize(name));
      n += await _walk(ctx, _photoIds(page), set, 'album:$set', (_) => dir);
      ctx.phase(Kind.albums, '${albums.length} albums, $n photos');
    }
    ctx.phase(Kind.albums, '${albums.length} albums, $n photos', done: true);
  }

  Future<void> _extractStories(JobCtx ctx, _Profile p) async {
    ctx.phase(Kind.stories, 'fetching active stories');
    final buckets = {
      ...p.doc.data.$('**.story_bucket.nodes.*.id').texts(),
      ...p.doc.data.$('**.story_bucket.id').texts(),
    };
    final assets = <MediaAsset>[];
    for (final path in [
      for (final b in buckets) '/stories/$b/',
      '/stories/${_digits.hasMatch(p.id) ? p.id : p.name}/',
    ]) {
      final items = _storyItems((await _load(ctx.api, path)).data);
      for (final s in items) {
        final now = DateTime.now();
        final dir = ctx.folder(Kind.stories).dir(now.format('yyyy-MM'));
        final ext = s.video ? 'mp4' : _ext(s.url);
        assets.add(
          MediaAsset(
            id: '${s.id}.$ext',
            platform: code,
            user: ctx.userName ?? ctx.target.user,
            category: Kind.stories,
            to: dir.file('${s.id}.$ext'),
            url: s.url,
            at: now,
          ),
        );
      }
      if (assets.isNotEmpty) break;
    }
    await ctx.enqueue(assets);
    ctx.phase(Kind.stories, '${assets.length} stories', done: true);
  }

  Future<void> _extractHighlights(JobCtx ctx, _Profile p) async {
    ctx.phase(Kind.highlights, 'fetching highlights');
    final doc = await _load(ctx.api, '/stories/highlights/${p.id}/');
    final items = _storyItems(doc.data);
    final assets = <MediaAsset>[];
    for (final s in items) {
      final now = DateTime.now();
      final dir = ctx.folder(Kind.highlights).dir(now.format('yyyy-MM'));
      final ext = s.video ? 'mp4' : _ext(s.url);
      assets.add(
        MediaAsset(
          id: '${s.id}.$ext',
          platform: code,
          user: ctx.userName ?? ctx.target.user,
          category: Kind.highlights,
          to: dir.file('${s.id}.$ext'),
          url: s.url,
          at: now,
        ),
      );
    }
    await ctx.enqueue(assets);
    ctx.phase(Kind.highlights, '${assets.length} highlight items', done: true);
  }

  Future<int> _walk(
    JobCtx ctx,
    List<String> start,
    String set,
    String key,
    Dir Function(_Photo) dir,
  ) async {
    if (start.isEmpty) return 0;
    var n = 0;
    var known = 0;
    for (final id in start) {
      if (!ctx.options.all && ctx.db.isPostSeen(code, ctx.userName ?? ctx.target.user, '$key:$id')) {
        if (++known >= 3) break;
        continue;
      }
      final ph = _photoCache[id] ?? await _photo(ctx.api, id, set);
      if (ph == null) continue;
      known = 0;
      ctx.db.recordPost(
        platform: code,
        user: ctx.userName ?? ctx.target.user,
        postId: '$key:$id',
        postedAt: ph.at,
        caption: ph.caption,
      );

      final file = dir(ph).file('${ph.id}.${_ext(ph.url)}');
      final assets = <MediaAsset>[
        MediaAsset(
          id: '${ph.id}.${_ext(ph.url)}',
          platform: code,
          user: ctx.userName ?? ctx.target.user,
          category: Kind.photos,
          to: file,
          url: ph.url,
          at: ph.at,
          sourcePostId: '$key:$id',
        ),
      ];
      if (ph.caption case final c? when c.trim().isNotEmpty) {
        assets.add(
          MediaAsset(
            id: '${ph.id}.txt',
            platform: code,
            user: ctx.userName ?? ctx.target.user,
            category: Kind.photos,
            to: dir(ph).file('${ph.id}.txt'),
            text: c,
            at: ph.at,
            sourcePostId: '$key:$id',
          ),
        );
      }
      await ctx.enqueue(assets);
      n++;
    }
    return n;
  }

  // ── Helpers & API ────────────────────────────────────────────────────────

  Future<_Doc> _load(Client c, String path) async {
    final page = await c.get(path).html(or: Html.parse(''));
    final doc = (page: page, data: page.json(), text: page.markup());
    _cacheFromDoc(doc);
    return doc;
  }

  void _cacheFromDoc(_Doc d) {
    for (final ph in _docPhotos(d).values) {
      _photoCache.putIfAbsent(ph.id, () => ph);
    }
    for (final v in _docVideos(d).values) {
      _videoCache.putIfAbsent(v.id, () => v);
    }
  }

  Map<String, _Photo> _docPhotos(_Doc d) {
    final photos = <String, _Photo>{};
    for (final n in d.data.$('**')) {
      final type = n.$('__typename').text() ?? '';
      if (type != 'Photo' && type != 'CometPhoto' && n.$('__isNode').text() != 'Photo') continue;
      final id = n.$('id|photo_id|legacy_photo_id').text();
      if (id == null || !_digits.hasMatch(id)) continue;
      final url =
          n
              .$(
                'viewer_image.uri|large_share_image.uri|photo_image.uri|image.uri',
              )
              .text() ??
          n.$('image.*.uri').texts().firstOrNull ??
          n.$('prefetch_uris_v2.*.uri').texts().firstOrNull;
      if (url == null) continue;
      final at = n.$('publish_time|created_time|creation_time').value<int>();
      final dt = at != null ? DateTime.fromMillisecondsSinceEpoch(at * 1000) : DateTime.now();
      photos[id] = (
        id: id,
        url: url,
        caption: n.$('message.text|accessibility_caption').text(),
        at: dt,
        next: n.$('nextMediaAfterNodeId.id|nextMedia.edges.0.node.id').text(),
      );
    }
    return photos;
  }

  Map<String, _Video> _docVideos(_Doc d) {
    final videos = <String, _Video>{};
    for (final n in d.data.$('**')) {
      final type = n.$('__typename').text() ?? '';
      if (type != 'Video' && type != 'CometVideo' && !type.endsWith('Video') && n.$('__isNode').text() != 'Video') {
        continue;
      }
      final id = n.$('id|video_id').text();
      if (id == null || !_digits.hasMatch(id)) continue;
      final progressive = n.$('progressive_urls.*');
      final url =
          (progressive.where((p) => p.$('metadata.quality').text() == 'HD').firstOrNull ?? progressive.firstOrNull)
              ?.$('progressive_url')
              .text() ??
          n
              .$(
                'browser_native_hd_url|playable_url_quality_hd|browser_native_sd_url|playable_url|progressive_url',
              )
              .text();
      if (url == null) continue;
      final at = n.$('publish_time|created_time|creation_time').value<int>();
      final dt = at != null ? DateTime.fromMillisecondsSinceEpoch(at * 1000) : DateTime.now();
      videos[id] = (
        id: id,
        url: url,
        title: n.$('savable_title.text|message.text|name').text(),
        at: dt,
      );
    }
    return videos;
  }

  List<String> _links(_Doc d) => [...d.data.$('**').texts(), ...d.page.$('a[href]').attrs('href')];

  String _ext(String url) {
    final e = Uri.parse(url).path.split('.').last.toLowerCase();
    return e.length <= 4 && e.isNotEmpty ? e : 'jpg';
  }

  Future<_Profile> _fetchProfile(Client c, String name) async {
    final d = await _load(c, _digits.hasMatch(name) ? '/profile.php?id=$name' : '/$name/');
    if (d.text.isEmpty ||
        d.text.contains('>Page Not Found<') ||
        d.text.contains("This content isn't available right now")) {
      throw Exception('user not found or unavailable: "$name"');
    }
    return (
      id: d.data.$('**.profile_owner.id|**.entity_id|**.userID').text() ?? name,
      name: d.data.$('**.userVanity|**.vanity').text() ?? name,
      avatar:
          d.data.$('**.profilePicLarge.uri|**.profilePhoto.url|**.profile_pic_url').text() ??
          d.data.$('**.uri').texts().where((u) => u.contains('t39.30808-1')).firstOrNull,
      cover: d.data.$('**.coverPhoto.url|**.cover_photo.uri|**.cover_photo.**.image.uri').text(),
      doc: d,
    );
  }

  Future<_Photo?> _photo(Client c, String id, [String set = '']) async {
    if (_photoCache[id] case final hit?) return hit;
    final clean = set.isNotEmpty && !set.contains(';') && !set.startsWith('utf');
    final d = await _load(c, '/photo/?fbid=$id${clean ? '&set=$set' : ''}');
    final url =
        d.page.$('link[rel="preload"][as="image"][data-preloader*="CometPhotoRoot"]').attr('href') ??
        d.data.$('**.uri').texts().where((u) => u.contains('t39.30808-6')).firstOrNull ??
        d.data
            .$('**.viewer_image.uri|**.image.uri|**.browser_native_hd_url|**.image.*.uri|**.prefetch_uris_v2.*.uri')
            .text();
    if (url == null) return null;
    final ph = (
      id:
      d.data.$('**').where((n) => n.$('__isNode').text() == 'Photo').firstOrNull?.$('id').text() ??
          d.data.$('**.photo_id').text() ??
          id,
      url: url,
      caption: d.data.$('**.message.text').text(),
      at: d.data.$('**.publish_time|**.created_time|**.creation_time').or(DateTime.now()),
      next: d.data.$('**.nextMediaAfterNodeId.id|**.nextMedia.edges.0.node.id').text(),
    );
    _photoCache[id] = ph;
    _photoCache[ph.id] = ph;
    return ph;
  }

  Future<_Video?> _video(Client c, String id) async {
    if (_videoCache[id] case final hit?) return hit;
    final d = await _load(c, '/watch/?v=$id');
    final progressive = d.data.$('**.progressive_urls.*');
    final url =
        (progressive.where((p) => p.$('metadata.quality').text() == 'HD').firstOrNull ?? progressive.firstOrNull)
            ?.$('progressive_url')
            .text() ??
        d.data
            .$(
          '**.progressive_url|**.browser_native_hd_url|**.browser_native_sd_url|**.playable_url_quality_hd|**.playable_url',
        )
            .text() ??
        RegExp(r'(?:<|\\u003C)BaseURL>(https:[^<\\"]+)')
            .firstMatch(d.text)?[1]
            ?.replaceAll(r'\/', '/')
            .replaceAll('&amp;', '&');
    if (url == null) return null;
    final v = (
      id: id,
      url: url,
      title: d.data.$('**.savable_title.text|**.message.text').text(),
      at: d.data.$('**.publish_time|**.created_time|**.creation_time').or(DateTime.now()),
    );
    _videoCache[id] = v;
    return v;
  }

  List<_Post> _timeline(Json data) {
    final seen = <String>{};
    return [
      for (final node in [
        ...data.$('**.timeline_list_feed_units.edges.*.node'),
        ...data.$('**.profile_pinned_post'),
        ...data.$('**.feed_units.edges.*.node'),
        ...data.$('**.timeline_feed_units.edges.*.node'),
      ])
        if (_post(node) case final p? when seen.add(p.id)) p,
    ];
  }

  _Post? _post(Json node) {
    final inner = node.$('comet_sections.content.story|post');
    final story = inner.isEmpty ? node : inner;
    const message =
        'message.text|comet_sections.message.story.message.text|comet_sections.message_container.story.message.text';
    final items = <String, _Item>{};
    for (final n in story.$('**')) {
      final type = n.$('__typename').text() ?? '', id = n.$('id|photo_id|legacy_photo_id|video_id').text();
      if (id == null || !const {'Photo', 'CometPhoto', 'Video', 'CometVideo'}.contains(type)) continue;
      final video = type.endsWith('Video');
      final progressive = n.$('progressive_urls.*');
      final videoUrl =
          (progressive.where((p) => p.$('metadata.quality').text() == 'HD').firstOrNull ?? progressive.firstOrNull)
              ?.$('progressive_url')
              .text() ??
          n
              .$(
            'browser_native_hd_url|playable_url_quality_hd|browser_native_sd_url|playable_url|progressive_url',
          )
              .text();
      final photoUrl =
          n
              .$(
            'viewer_image.uri|large_share_image.uri|photo_image.uri|image.uri',
          )
              .text() ??
          n.$('image.*.uri').texts().firstOrNull ??
          n.$('prefetch_uris_v2.*.uri').texts().firstOrNull;
      items[id] ??= (
        id: id,
        video: video,
        url: video ? videoUrl : photoUrl,
      );
    }
    final caption = story.$(message).text() ?? story.$('comet_sections.content.story').$(message).text();
    final id =
        story.$('post_id|legacy_token').text() ??
        node.$('post_id').text() ??
        [
          story.$('id').text(),
          node.$('id').text(),
          ...items.keys,
        ].firstWhere((i) => i != null && _digits.hasMatch(i), orElse: () => null);
    if (id == null || (items.isEmpty && caption == null)) return null;
    final at = story.$('creation_time').value<int>() ?? node.$('creation_time').value<int>();
    return (
      id: id,
      at: at == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(at * 1000),
      caption: caption,
      items: [...items.values],
    );
  }

  List<_StoryItem> _storyItems(Json data) {
    final seen = <String>{};
    return [
      for (final url
      in data.$('**.progressive_url').texts() +
          data.$('**.browser_native_hd_url').texts() +
          data.$('**.playable_url').texts())
        if (RegExp(r'xpv_asset_id%22%3A(\d+)').firstMatch(url)?[1] ??
            RegExp(r'/m\d+/([\w-]+)\.mp4').firstMatch(url)?[1] ??
            Uri.parse(url).pathSegments.last.split('.').first
        case final id when seen.add(id))
          (id: id, video: true, url: url),
      for (final url in [
        ...data.$('**.uri').texts().where((u) => u.contains('t39.30808-6')),
        ...data.$('**.viewer_image.uri').texts(),
        ...data.$('**.image.uri').texts(),
      ])
        if (Uri.parse(url).pathSegments.last case final file)
          if (RegExp(r'^\d+_(\d+)_').firstMatch(file)?[1] ?? file.split('.').first case final id when seen.add(id))
            (id: id, video: false, url: url),
    ];
  }

  List<String> _photoIds(_Doc d) => {
    for (final n in d.data.$('**'))
      if (n.$('__typename').text() == 'Photo') ?n.$('id').text(),
    ...d.data.$('**.photo_id').texts(),
    for (final l in _links(d))
      if (RegExp(r'[?&]fbid=(\d+)').firstMatch(l) case final m?) m[1]!,
  }.toList();

  String? _setIn(Iterable<String> links, [bool Function(String set)? test]) => links
      .map((l) => RegExp(r'[?&]set=([^&#"]+)').firstMatch(l)?[1])
      .nonNulls
      .where((s) => !s.startsWith('utf') && (test?.call(s) ?? true))
      .firstOrNull;

  String? _profileSet(_Doc d) =>
      _setIn(d.data.$('**.pageItems.**').texts()) ?? _setIn(_links(d), (s) => s.startsWith('pb.'));
}

typedef _Doc = ({Elements page, Json data, String text});
typedef _Profile = ({String id, String name, String? avatar, String? cover, _Doc doc});
typedef _Photo = ({String id, String url, String? caption, DateTime at, String? next});
typedef _Video = ({String id, String url, String? title, DateTime at});
typedef _Item = ({String id, bool video, String? url});
typedef _Post = ({String id, DateTime at, String? caption, List<_Item> items});
typedef _StoryItem = ({String id, bool video, String url});
