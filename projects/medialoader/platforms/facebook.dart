// Facebook's web pages, read from the data they embed: posts, photos,
// videos, albums, stories, highlights and profile pictures.
library;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/utils.dart';

import '../job.dart';
import '../platform.dart';

const web = 'https://www.facebook.com';

final _digits = RegExp(r'^\d+$');

// A page: its elements, the JSON its scripts embed, and its markup. A
// missing page (404, 410) is empty.
typedef Doc = ({Elements page, Json data, String text});

Future<Doc> load(Client c, String path) async {
  final page = await c.get(path).html(or: Html.parse(''));
  return (page: page, data: page.json(), text: page.markup());
}

// Every string in the page's data, and every link in its markup.
List<String> links(Doc d) => [...d.data.$('**').texts(), ...d.page.$('a[href]').attrs('href')];

String ext(String url) {
  final e = Uri.parse(url).path.split('.').last.toLowerCase();
  return e.length <= 4 && e.isNotEmpty ? e : 'jpg';
}

typedef Profile = ({String id, String name, String? avatar, String? cover, Doc doc});

Future<Profile> profile(Client c, String name) async {
  final d = await load(c, _digits.hasMatch(name) ? '/profile.php?id=$name' : '/$name/');
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

typedef Photo = ({String id, String url, String? caption, DateTime at, String? next});

// A photo page: the full-size image and the next photo of its set.
Future<Photo?> photo(Client c, String id, [String set = '']) async {
  final clean = set.isNotEmpty && !set.contains(';') && !set.startsWith('utf');
  final d = await load(c, '/photo/?fbid=$id${clean ? '&set=$set' : ''}');
  final url =
      d.page.$('link[rel="preload"][as="image"][data-preloader*="CometPhotoRoot"]').attr('href') ??
      d.data.$('**.uri').texts().where((u) => u.contains('t39.30808-6')).firstOrNull ??
      d.data.$('**.viewer_image.uri|**.image.uri|**.browser_native_hd_url|**.image.*.uri|**.prefetch_uris_v2.*.uri').text();
  if (url == null) return null;
  return (
    id:
        d.data.$('**').where((n) => n.$('__isNode').text() == 'Photo').firstOrNull?.$('id').text() ??
        d.data.$('**.photo_id').text() ??
        id,
    url: url,
    caption: d.data.$('**.message.text').text(),
    at: d.data.$('**.publish_time|**.created_time|**.creation_time').or(DateTime.now()),
    next: d.data.$('**.nextMediaAfterNodeId.id|**.nextMedia.edges.0.node.id').text(),
  );
}

typedef Video = ({String id, String url, String? title, DateTime at});

// A video page: its MP4 (HD when there is one).
Future<Video?> video(Client c, String id) async {
  final d = await load(c, '/watch/?v=$id');
  final progressive = d.data.$('**.progressive_urls.*');
  final url =
      (progressive.where((p) => p.$('metadata.quality').text() == 'HD').firstOrNull ?? progressive.firstOrNull)
          ?.$('progressive_url')
          .text() ??
      d.data.$('**.progressive_url|**.browser_native_hd_url|**.browser_native_sd_url|**.playable_url_quality_hd|**.playable_url').text() ??
      RegExp(r'(?:<|\\u003C)BaseURL>(https:[^<\\"]+)')
          .firstMatch(d.text)?[1]
          ?.replaceAll(r'\/', '/')
          .replaceAll('&amp;', '&');
  if (url == null) return null;
  return (
    id: id,
    url: url,
    title: d.data.$('**.savable_title.text|**.message.text').text(),
    at: d.data.$('**.publish_time|**.created_time|**.creation_time').or(DateTime.now()),
  );
}

typedef Item = ({String id, bool video, String? url});
typedef Post = ({String id, DateTime at, String? caption, List<Item> items});

// The timeline posts a profile page embeds (and its pinned post).
List<Post> timeline(Json data) {
  final seen = <String>{};
  return [
    for (final node in [...data.$('**.timeline_list_feed_units.edges.*.node'), ...data.$('**.profile_pinned_post')])
      if (_post(node) case final p? when seen.add(p.id)) p,
  ];
}

Post? _post(Json node) {
  final inner = node.$('comet_sections.content.story|post');
  final story = inner.isEmpty ? node : inner;
  const message =
      'message.text|comet_sections.message.story.message.text|comet_sections.message_container.story.message.text';
  final items = <String, Item>{};
  for (final n in story.$('**')) {
    final type = n.$('__typename').text() ?? '', id = n.$('id').text();
    if (id == null || !const {'Photo', 'CometPhoto', 'Video', 'CometVideo'}.contains(type)) continue;
    final video = type.endsWith('Video');
    items[id] ??= (
      id: id,
      video: video,
      url: n.$(video ? 'browser_native_hd_url|playable_url|browser_native_sd_url' : 'photo_image.uri|image.uri').text(),
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

typedef StoryItem = ({String id, bool video, String url});

// A story (or highlight) page's photos and videos, each once.
List<StoryItem> storyItems(Json data) {
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

// The photo ids a page shows, its photo nodes first (the newest).
List<String> photoIds(Doc d) => {
  for (final n in d.data.$('**'))
    if (n.$('__typename').text() == 'Photo') ?n.$('id').text(),
  ...d.data.$('**.photo_id').texts(),
  for (final l in links(d))
    if (RegExp(r'[?&]fbid=(\d+)').firstMatch(l) case final m?) m[1]!,
}.toList();

// The first media set (`set=`) among [links] that passes [test].
String? setIn(Iterable<String> links, [bool Function(String set)? test]) => links
    .map((l) => RegExp(r'[?&]set=([^&#"]+)').firstMatch(l)?[1])
    .nonNulls
    .where((s) => !s.startsWith('utf') && (test?.call(s) ?? true))
    .firstOrNull;

// The set of a profile's photos: the photo grid's, else any `pb.` set.
String? profileSet(Doc d) => setIn(d.data.$('**.pageItems.**').texts()) ?? setIn(links(d), (s) => s.startsWith('pb.'));

final platform = Facebook();

final class Facebook extends Platform {
  @override
  final code = 'fbk', name = 'Facebook', site = web;

  @override
  final kinds = const [Kind.posts, Kind.photos, Kind.videos, Kind.albums, Kind.stories, Kind.highlights, Kind.profiles];

  @override
  final loginCookies = const {'c_user', 'xs'};

  // Polite: 60 pages per 10 minutes.
  late final apiRate = rate(60, 10.minutes);

  static final _url = RegExp(r'^(?:https?://)?(?:www\.|m\.|web\.)?(?:facebook\.com|fb\.com)/([^/?#]+)');

  @override
  bool matches(String input) => _url.hasMatch(input.trim());

  @override
  Target parse(String input) {
    final s = input.trim();
    for (final re in [r'[?&]id=(\d+)', r'/people/[^/?#]+/(\d+)', r'/stories/(?:highlights/)?([^/?#]+)']) {
      if (RegExp(re).firstMatch(s)?[1] case final user? when user != 'highlights') return Target(this, user);
    }
    const nonProfile = {'photo', 'photos', 'media', 'watch', 'story', 'stories', 'groups', 'share', 'login'};
    if (_url.firstMatch(s)?[1] case final seg? when !nonProfile.contains(seg.toLowerCase()) && !seg.contains('.php')) {
      return Target(this, seg);
    }
    return Target(this, username(s, name));
  }

  @override
  Client client(Cookies jar) =>
      Http.client(base: web, rate: apiRate, check: true, cookies: jar, headers: HttpUtils.page, login: const ['/login']);

  @override
  Future<void> explore(Job j) async {
    final p = await profile(j.api, j.target.user);
    await j.open(p.name, id: p.id);
    String tab(String t) => _digits.hasMatch(p.name) ? '/profile.php?id=${p.name}&sk=$t' : '/${p.name}/$t/';
    await Future.wait([
      if (j.wants(Kind.profiles)) Future(() => _profile(j, p)),
      if (j.wants(Kind.posts)) _posts(j, p),
      if (j.wants(Kind.photos)) _photos(j, p, tab),
      if (j.wants(Kind.videos)) _videos(j, p, tab),
      if (j.wants(Kind.albums)) _albums(j, tab),
      if (j.wants(Kind.stories)) _stories(j, p),
      if (j.wants(Kind.highlights)) _highlights(j, p),
    ]);
  }

  // Whether [key] was downloaded whole before (the index), so its page need not load.
  bool _known(Job j, String key) => !j.o.all && j.index.posts.containsKey(key);

  // Queues [files] and remembers [key] once they are all down.
  Future<Results> _remember(Job j, String key, List<Download> files, [List<String> items = const []]) =>
      j.add(files)..then((r) {
        if (r.failures().isEmpty) j.index.posts[key] = items;
      });

  void _profile(Job j, Profile p) {
    j.profile(p.avatar, 'new profile avatar');
    j.profile(
      p.cover,
      'new cover photo',
      id: 'cover_${Fs.sanitize(Uri.parse(p.cover ?? '').pathSegments.lastOrNull ?? '')}',
    );
  }

  // The posts the profile page embeds: each photo or video at full size from its page.
  Future<void> _posts(Job j, Profile p) async {
    j.phase(Kind.posts, 'fetching timeline posts');
    var n = 0;
    for (final post in timeline(p.doc.data)) {
      if (_known(j, 'post:${post.id}') || !j.keep(post.at)) continue;
      final dir = j.folder(Kind.posts).dir(post.at.format('yyyy-MM'));
      // Photos and videos are numbered apart: <id>.jpg, <id>_1.mp4 …
      String name(Item i) {
        final same = [
          for (final o in post.items)
            if (o.video == i.video) o.id,
        ];
        return same.length > 1 ? '${post.id}_${same.indexOf(i.id) + 1}' : post.id;
      }

      final files = <Download>[];
      for (final i in post.items) {
        final url = i.video ? (await video(j.api, i.id))?.url ?? i.url : (await photo(j.api, i.id))?.url ?? i.url;
        if (url != null) {
          files.add(Download(dir.file('${name(i)}.${i.video ? 'mp4' : ext(url)}'), url: url, at: post.at));
        }
      }
      if (post.caption case final c? when c.trim().isNotEmpty) {
        files.add(Download(dir.file('${post.id}.txt'), text: c, at: post.at));
      }
      if (files.isEmpty) continue;
      _remember(j, 'post:${post.id}', files, [for (final i in post.items) i.id]);
      j.phase(Kind.posts, '${++n} posts');
    }
    j.phase(Kind.posts, '$n posts', done: true);
  }

  // Walks a photo set (http's Feed, one photo a page) from the first of
  // [start] along each photo's next one, then the other start points, into
  // [dir]; stops after 3 known photos in a row. With [mark], where it got to
  // is kept there, and a rerun lists what is new, then continues from it.
  Future<int> _walk(Job j, List<String> start, String set, String key, Dir Function(Photo) dir, {File? mark}) async {
    if (start.isEmpty) return 0;
    final jumps = mark != null && !set.startsWith('pcb.'); // the profile's photos wrap around
    var n = 0, known = 0;
    // The other start points, each walked once the chain before it ends.
    final rest = start.skip(1).toList();
    String? more() => rest.isEmpty ? null : rest.removeAt(0);
    final photos = Feed<({String id, Photo? photo})>((cursor) async {
      for (String? id = cursor ?? start.first; id != null; id = more()) {
        if (_known(j, '$key:$id')) return (items: [(id: id, photo: null)], next: more());
        final ph = await photo(j.api, id, set);
        if (ph == null) continue;
        // In the profile's photos, a next photo far after this one is the set starting over.
        final jump = jumps && (int.tryParse(ph.next ?? '') ?? 0) > (int.tryParse(id) ?? 1 << 62) + 5000000;
        return (items: [(id: id, photo: ph)], next: jump ? more() : ph.next ?? more());
      }
      return (items: const <({String id, Photo? photo})>[], next: null);
    }, cursor: mark == null || j.o.dry ? null : mark.path);
    await photos.run(all: j.o.all, (page) async {
      final ph = page.items().single.photo;
      final file = ph == null ? null : dir(ph).file('${ph.id}.${ext(ph.url)}');
      if (ph == null || file == null || !j.o.all && await file.exists()) {
        if (ph != null) j.index.posts['$key:${ph.id}'] = const [];
        if (++known >= 3) page.stop();
        return;
      }
      known = 0;
      // The profile's photos run newest first: past --since, the rest are older.
      if (!j.keep(ph.at)) return mark != null ? page.stop() : null;
      page.add(
        _remember(j, '$key:${ph.id}', [
          Download(file, url: ph.url, at: ph.at),
          if (ph.caption case final c? when c.trim().isNotEmpty)
            Download(dir(ph).file('${ph.id}.txt'), text: c, at: ph.at),
        ]).then((r) => r.failures().isEmpty),
      );
      n++;
    });
    return n;
  }

  Future<void> _photos(Job j, Profile p, String Function(String) tab) async {
    j.phase(Kind.photos, 'fetching photos index');
    final by = await load(j.api, tab('photos_by'));
    var set = profileSet(by);
    if (set == null) {
      final all = await load(j.api, tab('photos'));
      set = profileSet(all) ?? setIn(links(all)) ?? all.data.$('**.mediaSetToken').text();
    }
    final ids = [...photoIds(by), ...photoIds(p.doc)];
    if (set != null) ids.insertAll(0, photoIds(await load(j.api, '/media/set/?set=$set')));
    if (ids.isEmpty && set == null) {
      final all = await load(j.api, tab('photos_all'));
      ids.addAll(photoIds(all));
      set = profileSet(all);
    }
    j.phase(Kind.photos, 'listing photos');
    final n = await _walk(
      j,
      ids,
      set ?? '',
      'photo',
      (ph) => j.folder(Kind.photos).dir(ph.at.format('yyyy-MM')),
      mark: j.cursor(Kind.photos),
    );
    j.phase(Kind.photos, '$n photos listed', done: true);
  }

  Future<void> _videos(Job j, Profile p, String Function(String) tab) async {
    j.phase(Kind.videos, 'fetching videos index');
    final pages = [
      await load(j.api, tab('videos')),
      await load(j.api, tab(_digits.hasMatch(p.name) ? 'reels_tab' : 'reels')),
    ];
    final ids = {
      for (final d in pages) ...[
        for (final l in links(d))
          if (RegExp(r'/(?:videos|reels?)/(\d+)|/watch/?\?v=(\d+)').firstMatch(l) case final m?) m[1] ?? m[2]!,
        ...d.data.$('**.video_id').texts(),
      ],
    };
    var n = 0;
    for (final id in ids) {
      if (_known(j, 'video:$id')) continue;
      final v = await video(j.api, id);
      if (v == null || !j.keep(v.at)) continue;
      final dir = j.folder(Kind.videos).dir(v.at.format('yyyy-MM'));
      _remember(j, 'video:$id', [
        Download(dir.file('${v.id}.mp4'), url: v.url, at: v.at),
        if (v.title case final t? when t.trim().isNotEmpty) Download(dir.file('${v.id}.txt'), text: t, at: v.at),
      ]);
      j.phase(Kind.videos, '${++n} videos discovered');
    }
    j.phase(Kind.videos, '$n videos listed', done: true);
  }

  Future<void> _albums(Job j, String Function(String) tab) async {
    j.phase(Kind.albums, 'fetching albums index');
    final d = await load(j.api, tab('photos_albums'));
    final albums = <String, String>{}; // set → title
    for (final n in d.data.$('**')) {
      if (RegExp(r'/media/set/?\?set=(a\.\d+)').firstMatch(n.$('url').text() ?? '')?[1] case final set?) {
        albums[set] ??= n.$('title.text').text() ?? set;
      }
    }
    for (final set in links(d).map((l) => RegExp(r'[?&]set=(a\.\d+)').firstMatch(l)?[1]).nonNulls) {
      albums[set] ??= set;
    }
    var n = 0;
    for (final MapEntry(key: set, value: title) in albums.entries) {
      final page = await load(j.api, '/media/set/?set=$set');
      final name =
          page.data.$('**').where((n) => n.$('__isMediaSet').text() == 'Album').firstOrNull?.$('title.text').text() ??
          page.data.$('**.title.text').text() ??
          title;
      final dir = j.folder(Kind.albums).dir(Fs.sanitize(name));
      n += await _walk(j, photoIds(page), set, 'album:$set', (_) => dir);
      j.phase(Kind.albums, '${albums.length} albums, $n photos');
    }
    j.phase(Kind.albums, '${albums.length} albums, $n photos', done: true);
  }

  // Story files by the month they were first seen (the index keeps it), so a
  // story is downloaded once.
  List<Download> _storyFiles(Job j, List<StoryItem> items, Dir Function(DateTime seen) dir) => [
    for (final s in items)
      if (firstSeen(j.index, s.id) case final seen)
        Download(dir(seen).file('${s.id}.${s.video ? 'mp4' : ext(s.url)}'), url: s.url, at: seen),
  ];

  Future<void> _stories(Job j, Profile p) async {
    j.phase(Kind.stories, 'fetching active stories');
    final buckets = {
      ...p.doc.data.$('**.story_bucket.nodes.*.id').texts(),
      ...p.doc.data.$('**.story_bucket.id').texts(),
    };
    var files = <Download>[];
    for (final path in [
      for (final b in buckets) '/stories/$b/',
      '/stories/${_digits.hasMatch(p.id) ? p.id : p.name}/',
    ]) {
      final items = storyItems((await load(j.api, path)).data);
      files = _storyFiles(j, items, (seen) => j.folder(Kind.stories).dir(seen.format('yyyy-MM')));
      if (files.isNotEmpty) break;
    }
    j.add(files);
    j.phase(Kind.stories, '${files.length} stories up now', done: true);
  }

  // Highlights: each link to /stories/highlights/<id>/ in the profile's data, titled by its object.
  Future<void> _highlights(Job j, Profile p) async {
    final index = j.index;
    j.phase(Kind.highlights, 'listing highlights');
    final found = <String, String>{}; // id → title
    final link = RegExp(r'/stories/highlights/(\d+)');
    for (final n in p.doc.data.$('**')) {
      final id = link.firstMatch(n.$('url').text() ?? '')?[1] ?? link.firstMatch(n.value<String>() ?? '')?[1];
      if (id != null && (found[id] ?? '').isEmpty) found[id] = n.$('title.text').text() ?? '';
    }
    for (final id in p.doc.data.$('**.highlight_id').texts()) {
      found[id] ??= '';
    }
    final now = <String, Set<String>>{};
    var total = 0;
    for (final MapEntry(key: id, value: name) in found.entries) {
      final title = name.isEmpty ? 'highlight_$id' : name;
      final items = storyItems((await load(j.api, '/stories/highlights/$id/')).data);
      final files = _storyFiles(j, items, (_) => j.folder(Kind.highlights).dir(Fs.sanitize(title)));
      total += files.length;
      j.add(files);
      final ids = {for (final i in items) i.id};
      if (index.highlights[title] case final before?) {
        final (added, removed) = (ids.difference(before).length, before.difference(ids).length);
        if (added + removed > 0) j.changed('highlight "$title": $added added, $removed removed');
      } else if (index.highlights.isNotEmpty) {
        j.changed('new highlight "$title"');
      }
      now[title] = ids;
    }
    for (final title in index.highlights.keys.where((t) => !now.containsKey(t))) {
      j.changed('highlight "$title" gone, files kept');
    }
    index.highlights = now;
    j.phase(
      Kind.highlights,
      '${found.length} ${found.length == 1 ? 'highlight' : 'highlights'}, $total items',
      done: true,
    );
  }
}
