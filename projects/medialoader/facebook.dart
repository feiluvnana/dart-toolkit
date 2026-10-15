// Facebook media extraction. Import with `as facebook`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';

import 'dashboard.dart';
import 'download.dart';
import 'media.dart' as media;
import 'platform.dart';

const site = 'https://www.facebook.com';
const agent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

// Polite rate limit for Facebook web scraping.
Rate rate(int calls) => Rate(
  calls,
  10.minutes,
  pause: 2.seconds,
  onWait: (w) => board.holdPause('Facebook rate limit: waiting ${w.human()}', w, platform: 'fbk'),
);
final apiRate = rate(60);

// CDN client with retries and resume.
final cdn = Http.client(headers: {'user-agent': agent, 'referer': '$site/'}, retries: 3, resume: true);

// Web client for anonymous queries.
final web = Http.client(
  base: site,
  rate: apiRate,
  check: false,
  headers: {
    'user-agent': agent,
    'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'accept-language': 'en-US,en;q=0.9',
    'sec-fetch-dest': 'document',
    'sec-fetch-mode': 'navigate',
    'sec-fetch-site': 'none',
    'sec-fetch-user': '?1',
  },
);

// The logged-in client from .fbk.session (cookies.txt export plus a "user-agent: ..." line), or null.
Future<Client?> login() async {
  var file = Fs.scriptDir().file('.fbk.session');
  if (!await file.exists()) {
    final cur = Fs.file('.fbk.session');
    if (await cur.exists()) {
      file = cur;
    } else {
      final p = Fs.file('projects/medialoader/.fbk.session');
      if (await p.exists()) file = p;
    }
  }
  final text = await file.text(or: '');
  final cookies = Cookies.parse(text);
  if (cookies['c_user'] == null && cookies['xs'] == null) return null;
  final ua = RegExp(r'^user-agent:(.*)$', multiLine: true, caseSensitive: false).firstMatch(text)?[1]?.trim();
  if (ua == null) Console.log('warning: .fbk.session has no user-agent line, so requests use default browser');
  return Http.client(
    base: site,
    rate: apiRate,
    check: false,
    cookies: cookies,
    headers: {
      'user-agent': ua ?? agent,
      'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
      'accept-language': 'en-US,en;q=0.9',
      'sec-fetch-dest': 'document',
      'sec-fetch-mode': 'navigate',
      'sec-fetch-site': 'same-origin',
    },
  );
}

typedef Profile = ({String id, String name, String? avatar, String? cover, String html});

String unescapeUrl(String s) {
  var url = s.replaceAll(r'\/', '/');
  url = url.replaceAll(r'\u0025', '%').replaceAll(r'\u0026', '&').replaceAll(r'\u003D', '=').replaceAll(r'\u003F', '?');
  return url;
}

String decodeFacebookText(String s) {
  String decoded;
  try {
    var escaped = s.replaceAll(r'\"', '"');
    escaped = escaped
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n')
        .replaceAll('\t', r'\t')
        .replaceAll('"', r'\"');
    decoded = jsonDecode('"$escaped"') as String;
  } catch (_) {
    decoded = s
        .replaceAllMapped(
          RegExp(r'\\u([0-9a-fA-F]{4})'),
          (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
        )
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\"', '"')
        .replaceAll(r'\/', '/');
  }

  decoded = decoded
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
      .replaceAll(r'\/', '/');

  return decoded.trim();
}

String cleanCaption(String s) => decodeFacebookText(s);


// Resolves a Facebook profile page.
Future<Profile> profile(Client client, String name) async {
  board.requests++;
  final isId = RegExp(r'^\d+$').hasMatch(name);
  final url = isId ? '/profile.php?id=$name' : '/$name/';
  final response = await client.get(url);
  final html = await response.text();
  if (response.url().contains('/login') ||
      html.contains('>Page Not Found<') ||
      html.contains("This content isn't available right now")) {
    if (response.url().contains('/login')) {
      throw const UsageException('Facebook login required: please export session cookies into .fbk.session.');
    }
    throw Exception('Facebook user not found or unavailable: "$name".');
  }

  final id =
      RegExp(r'"profile_owner":\{"id":"(\d+)"\}').firstMatch(html)?[1] ??
      RegExp(r'"owner":\{"__typename":"User","id":"(\d+)"\}').firstMatch(html)?[1] ??
      RegExp(r'"entity_id":"(\d+)"').firstMatch(html)?[1] ??
      RegExp(r'"userID":"(\d+)"').firstMatch(html)?[1] ??
      name;

  final vanity =
      RegExp(r'"userVanity":"([^"]+)"').firstMatch(html)?[1] ??
      RegExp(r'"vanity":"([^"]+)"').firstMatch(html)?[1] ??
      name;

  String? avatar;
  if (RegExp(r'"profilePicLarge":\{"uri":"([^"]+)"\}').firstMatch(html) case final m?) {
    avatar = unescapeUrl(m[1]!);
  } else if (RegExp(r'"profilePhoto":\{"url":"([^"]+)"\}').firstMatch(html) case final m?) {
    avatar = unescapeUrl(m[1]!);
  } else if (RegExp(r'"profile_pic_url":"([^"]+)"').firstMatch(html) case final m?) {
    avatar = unescapeUrl(m[1]!);
  } else if (RegExp(r'"(?:viewer_image|image)":\{"uri":"(https:[^"]+)"\}').firstMatch(html) case final m?) {
    avatar = unescapeUrl(m[1]!);
  } else if (RegExp(r'"uri":"(https:[^"]+t39\.30808-1[^"]+)"').firstMatch(html) case final m?) {
    avatar = unescapeUrl(m[1]!);
  }

  String? cover;
  if (RegExp(r'"coverPhoto":\{"url":"([^"]+)"\}').firstMatch(html) case final m?) {
    cover = unescapeUrl(m[1]!);
  } else if (RegExp(r'"cover_photo":\{"uri":"([^"]+)"\}').firstMatch(html) case final m?) {
    cover = unescapeUrl(m[1]!);
  } else if (RegExp(r'"cover_photo":\{.*?"image":\{"uri":"([^"]+)"\}').firstMatch(html) case final m?) {
    cover = unescapeUrl(m[1]!);
  }

  return (id: id, name: vanity, avatar: avatar, cover: cover, html: html);
}

typedef FacebookPhoto = ({String id, String url, String? caption, int date, String? nextPhotoId});

// Parses a single photo page to obtain its high-res image and the link to the next photo in the set.
Future<FacebookPhoto?> photoPage(Client client, String photoId, String setId) async {
  board.requests++;
  final cleanSet = setId.isNotEmpty && !setId.contains(';') && !setId.startsWith('utf') ? setId : '';
  final url = cleanSet.isEmpty ? '/photo/?fbid=$photoId' : '/photo/?fbid=$photoId&set=$cleanSet';
  final response = await client.get(url);
  final html = await response.text();

  if (response.url().contains('/login')) {
    throw const UsageException('Facebook login required: please export session cookies into .fbk.session.');
  }

  // Extract photo ID
  final id =
      RegExp(r'"__isNode":"Photo","id":"(\d+)"').firstMatch(html)?[1] ??
      RegExp(r'"photo_id":"(\d+)"').firstMatch(html)?[1] ??
      photoId;

  // Extract direct image CDN URL
  String? imgUrl;
  if (RegExp(r'<link rel="preload" href="([^"]+)" as="image" data-preloader="[^"]*CometPhotoRoot').firstMatch(html)
      case final m?) {
    imgUrl = unescapeUrl(m[1]!.replaceAll('&amp;', '&'));
  } else if (RegExp(r'"uri":"(https:[^"]+t39\.30808-6[^"]+)"').firstMatch(html) case final m?) {
    imgUrl = unescapeUrl(m[1]!);
  } else if (RegExp(r'"(?:viewer_image|image)":\{"uri":"([^"]+)"').firstMatch(html) case final m?) {
    imgUrl = unescapeUrl(m[1]!);
  } else if (RegExp(r'"browser_native_hd_url":"([^"]+)"').firstMatch(html) case final m?) {
    imgUrl = unescapeUrl(m[1]!);
  } else if (RegExp(r'"image":\[\{"uri":"([^"]+)"\}').firstMatch(html) case final m?) {
    imgUrl = unescapeUrl(m[1]!);
  } else if (RegExp(r'"prefetch_uris_v2":\[\{"uri":"(https:[^"]+scontent[^"]+)"').firstMatch(html) case final m?) {
    imgUrl = unescapeUrl(m[1]!);
  }

  if (imgUrl == null) return null;

  // Extract timestamp
  final rawTime =
      RegExp(r'\\?"publish_time\\?":(\d+)').firstMatch(html)?[1] ??
      RegExp(r'\\?"created_time\\?":(\d+)').firstMatch(html)?[1] ??
      RegExp(r'"creation_time":(\d+)').firstMatch(html)?[1];
  final date = rawTime != null ? int.parse(rawTime) : DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // Extract caption text
  String? caption;
  if (RegExp(r'"message":\{.*?"text":"((?:[^"\\]|\\.)*)"', dotAll: true).firstMatch(html) case final m?) {
    caption = decodeFacebookText(m[1]!);
  }

  // Extract next photo ID in the set
  final nextId =
      RegExp(r'"nextMediaAfterNodeId":\{"__typename":"Photo","id":"(\d+)"').firstMatch(html)?[1] ??
      RegExp(r'"nextMedia":\{"edges":\[\{"node":\{"__typename":"Photo","id":"(\d+)"').firstMatch(html)?[1];

  return (id: id, url: imgUrl, caption: caption, date: date, nextPhotoId: nextId);
}

typedef FacebookVideo = ({String id, String url, String? title, int date});

// Parses a single video page to obtain its video stream.
Future<FacebookVideo?> videoPage(Client client, String videoId) async {
  board.requests++;
  final response = await client.get('/watch/?v=$videoId');
  final html = await response.text();

  if (response.url().contains('/login')) {
    throw const UsageException('Facebook login required: please export session cookies into .fbk.session.');
  }

  // High quality or standard quality MP4
  String? videoUrl;

  // 1. Check progressive_urls (prefer HD)
  final progMatches = RegExp(r'"progressive_url":"([^"]+)"').allMatches(html).toList();
  for (final m in progMatches) {
    final u = unescapeUrl(m[1]!);
    final window = html.substring(m.start, (m.end + 120).clamp(0, html.length));
    if (window.contains('"HD"')) {
      videoUrl = u;
      break;
    }
    videoUrl ??= u;
  }

  // 2. Progressive fallback (highest bitrate usually last)
  if (videoUrl == null && progMatches.isNotEmpty) {
    videoUrl = unescapeUrl(progMatches.last[1]!);
  }

  // 3. Comet / legacy video url keys
  if (videoUrl == null) {
    if (RegExp(r'"browser_native_hd_url":"([^"]+)"').firstMatch(html) case final m?) {
      videoUrl = unescapeUrl(m[1]!);
    } else if (RegExp(r'"browser_native_sd_url":"([^"]+)"').firstMatch(html) case final m?) {
      videoUrl = unescapeUrl(m[1]!);
    } else if (RegExp(r'"playable_url_quality_hd":"([^"]+)"').firstMatch(html) case final m?) {
      videoUrl = unescapeUrl(m[1]!);
    } else if (RegExp(r'"playable_url":"([^"]+)"').firstMatch(html) case final m?) {
      videoUrl = unescapeUrl(m[1]!);
    }
  }

  // 4. DASH BaseURL fallback
  if (videoUrl == null) {
    if (RegExp(r'(?:<BaseURL>|\\u003CBaseURL>)(https:[^<\\"]+)(?:<\/BaseURL>|\\u003C\\/BaseURL>)').firstMatch(html)
        case final m?) {
      videoUrl = unescapeUrl(m[1]!.replaceAll('&amp;', '&'));
    }
  }

  if (videoUrl == null) return null;

  final rawTime =
      RegExp(r'\\?"publish_time\\?":(\d+)').firstMatch(html)?[1] ??
      RegExp(r'\\?"created_time\\?":(\d+)').firstMatch(html)?[1] ??
      RegExp(r'"creation_time":(\d+)').firstMatch(html)?[1];
  final date = rawTime != null ? int.parse(rawTime) : DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String? title;
  if (RegExp(r'"savable_title":\{.*?"text":"((?:[^"\\]|\\.)*)"', dotAll: true).firstMatch(html) case final m?) {
    title = decodeFacebookText(m[1]!);
  } else if (RegExp(r'"message":\{.*?"text":"((?:[^"\\]|\\.)*)"', dotAll: true).firstMatch(html) case final m?) {
    title = decodeFacebookText(m[1]!);
  }

  return (id: videoId, url: videoUrl, title: title, date: date);
}

typedef FacebookTimelinePost = ({
  String id,
  int date,
  String? caption,
  List<String> photoIds,
  List<String> videoIds,
  List<String> directUrls,
});

List<FacebookTimelinePost> extractTimelinePosts(String html) {
  final scripts = RegExp(r'<script type="application/json"[^>]*>(.*?)</script>', dotAll: true).allMatches(html);
  final posts = <FacebookTimelinePost>[];
  final seenIds = <String>{};

  for (final s in scripts) {
    final text = s.group(1)!;
    if (!text.contains('timeline_list_feed_units') &&
        !text.contains('profile_pinned_post') &&
        !text.contains('ProfileCometTimelineFeedQuery')) {
      continue;
    }

    try {
      final json = jsonDecode(text);

      void inspectStory(Map<String, dynamic> story) {
        final postId = story['post_id']?.toString() ??
            story['legacy_token']?.toString() ??
            (story['id'] != null && RegExp(r'^\d+$').hasMatch(story['id'].toString()) ? story['id'].toString() : null);

        final creationTime = story['creation_time'] as int?;
        final date = creationTime ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

        String? caption;
        String? extractText(Object? m) {
          if (m is Map && m['text'] is String) return m['text'] as String;
          return null;
        }

        final cometSec = story['comet_sections'] as Map<String, dynamic>?;
        final contentStory = cometSec?['content'] is Map ? (cometSec!['content'] as Map)['story'] as Map<String, dynamic>? : null;
        final msgStory = cometSec?['message'] is Map ? (cometSec!['message'] as Map)['story'] as Map<String, dynamic>? : null;
        final msgContainer = cometSec?['message_container'] is Map ? (cometSec!['message_container'] as Map)['story'] as Map<String, dynamic>? : null;

        if (extractText(story['message']) case final t?) {
          caption = decodeFacebookText(t);
        } else if (extractText(msgStory?['message']) case final t?) {
          caption = decodeFacebookText(t);
        } else if (extractText(msgContainer?['message']) case final t?) {
          caption = decodeFacebookText(t);
        } else if (contentStory != null) {
          final cComet = contentStory['comet_sections'] as Map<String, dynamic>?;
          final cMsg = cComet?['message'] is Map ? (cComet!['message'] as Map)['story'] as Map<String, dynamic>? : null;
          final cCnt = cComet?['message_container'] is Map ? (cComet!['message_container'] as Map)['story'] as Map<String, dynamic>? : null;
          if (extractText(contentStory['message']) case final t?) {
            caption = decodeFacebookText(t);
          } else if (extractText(cMsg?['message']) case final t?) {
            caption = decodeFacebookText(t);
          } else if (extractText(cCnt?['message']) case final t?) {
            caption = decodeFacebookText(t);
          }
        }

        final photoIds = <String>[];
        final videoIds = <String>[];
        final directUrls = <String>[];

        void findMedia(Object? mObj) {
          if (mObj is Map) {
            final map = mObj is Map<String, dynamic> ? mObj : Map<String, dynamic>.from(mObj);
            final typename = map['__typename']?.toString() ?? '';
            final id = map['id']?.toString();

            if (typename == 'Photo' || typename == 'CometPhoto') {
              if (id != null && !photoIds.contains(id)) photoIds.add(id);
              if (map['photo_image'] is Map && (map['photo_image'] as Map)['uri'] is String) {
                directUrls.add(unescapeUrl((map['photo_image'] as Map)['uri'] as String));
              }
              if (map['image'] is Map && (map['image'] as Map)['uri'] is String) {
                directUrls.add(unescapeUrl((map['image'] as Map)['uri'] as String));
              }
            } else if (typename == 'Video' || typename == 'CometVideo') {
              if (id != null && !videoIds.contains(id)) videoIds.add(id);
              if (map['playable_url'] is String) directUrls.add(unescapeUrl(map['playable_url'] as String));
              if (map['browser_native_hd_url'] is String) directUrls.add(unescapeUrl(map['browser_native_hd_url'] as String));
              if (map['browser_native_sd_url'] is String) directUrls.add(unescapeUrl(map['browser_native_sd_url'] as String));
            }

            for (final val in map.values) {
              findMedia(val);
            }
          } else if (mObj is List) {
            for (final item in mObj) {
              findMedia(item);
            }
          }
        }

        findMedia(story);

        final effectiveId =
            postId ?? (photoIds.isNotEmpty ? photoIds.first : (videoIds.isNotEmpty ? videoIds.first : null));
        if (effectiveId != null && (photoIds.isNotEmpty || videoIds.isNotEmpty || caption != null)) {
          if (seenIds.add(effectiveId)) {
            posts.add((
              id: effectiveId,
              date: date,
              caption: caption,
              photoIds: photoIds,
              videoIds: videoIds,
              directUrls: directUrls,
            ));
          }
        }
      }

      void search(Object? obj) {
        if (obj is Map) {
          final map = obj is Map<String, dynamic> ? obj : Map<String, dynamic>.from(obj);
          if (map['__typename'] == 'Story' &&
              (map.containsKey('post_id') || map.containsKey('comet_sections') || map.containsKey('creation_time'))) {
            inspectStory(map);
          } else if (map.containsKey('timeline_list_feed_units')) {
            final tUnits = map['timeline_list_feed_units'] as Map?;
            final edges = tUnits?['edges'] as List?;
            if (edges != null) {
              for (final e in edges) {
                if (e is Map && e['node'] is Map) {
                  final node = Map<String, dynamic>.from(e['node'] as Map);
                  final nodeComet = node['comet_sections'] as Map?;
                  final nodeContent = nodeComet?['content'] as Map?;
                  if (nodeContent?['story'] is Map) {
                    final sMap = Map<String, dynamic>.from(nodeContent!['story'] as Map);
                    sMap['post_id'] ??= node['post_id'];
                    sMap['creation_time'] ??= node['creation_time'];
                    inspectStory(sMap);
                  } else {
                    inspectStory(node);
                  }
                }
              }
            }
          } else if (map['profile_pinned_post'] is Map) {
            final pinned = map['profile_pinned_post'] as Map;
            if (pinned['post'] is Map) {
              final sMap = Map<String, dynamic>.from(pinned['post'] as Map);
              sMap['post_id'] ??= pinned['id'];
              sMap['creation_time'] ??= pinned['creation_time'];
              inspectStory(sMap);
            } else {
              inspectStory(Map<String, dynamic>.from(pinned));
            }
          }
          for (final val in map.values) {
            search(val);
          }
        } else if (obj is List) {
          for (final item in obj) {
            search(item);
          }
        }
      }

      search(json);
    } catch (_) {}
  }

  return posts;
}

typedef FacebookStoryMedia = ({String id, bool isVideo, String url, int? date});

List<FacebookStoryMedia> extractStoryMedia(String html) {
  final items = <FacebookStoryMedia>[];
  final seenIds = <String>{};

  // 1. Extract videos (pick HD over SD)
  final videoUrls = <String>[
    for (final m in RegExp(r'"progressive_url"\s*:\s*"([^"]+)"').allMatches(html)) unescapeUrl(m[1]!),
    for (final m in RegExp(r'"browser_native_hd_url"\s*:\s*"([^"]+)"').allMatches(html)) unescapeUrl(m[1]!),
    for (final m in RegExp(r'"playable_url"\s*:\s*"([^"]+)"').allMatches(html)) unescapeUrl(m[1]!),
  ];

  for (final url in videoUrls) {
    final assetId = RegExp(r'xpv_asset_id%22%3A(\d+)').firstMatch(url)?[1] ??
        RegExp(r'/m\d+/([a-zA-Z0-9_-]+)\.mp4').firstMatch(url)?[1] ??
        url.split('?').first.split('/').last.split('.').first;

    if (seenIds.add(assetId)) {
      items.add((id: assetId, isVideo: true, url: url, date: null));
    }
  }

  // 2. Extract photos
  final photoUrls = <String>[
    for (final m in RegExp(r'"image"\s*:\s*\{\s*"uri"\s*:\s*"(https:[^"]+t39\.30808-6[^"]+)"').allMatches(html))
      unescapeUrl(m[1]!),
    for (final m in RegExp(r'"uri"\s*:\s*"(https:[^"]+t39\.30808-6[^"]+)"').allMatches(html)) unescapeUrl(m[1]!),
    for (final m in RegExp(r'"(?:viewer_image|image)"\s*:\s*\{\s*"uri"\s*:\s*"([^"]+)"').allMatches(html))
      unescapeUrl(m[1]!),
  ];

  for (final url in photoUrls) {
    final filename = url.split('?').first.split('/').last;
    final photoId = RegExp(r'^\d+_(\d+)_').firstMatch(filename)?[1] ?? filename.split('.').first;

    if (seenIds.add(photoId)) {
      items.add((id: photoId, isVideo: false, url: url, date: null));
    }
  }

  return items;
}

Object explain(Object e) => switch (e) {
  HttpStatusException(status: 404, :final url) => 'Facebook user not found: $url',
  HttpStatusException(status: final status && (401 || 403), :final url) =>
    'Facebook refused (HTTP $status): your session in .fbk.session may have expired or is invalid ($url)',
  HttpStatusException(status: 429, :final url) =>
    'Facebook rate limit reached (HTTP 429): please wait a few minutes ($url)',
  _ => e,
};

final platform = FacebookPlatform();

final class FacebookPlatform implements Platform {
  @override
  String get code => 'fbk';

  @override
  String get name => 'facebook';

  @override
  List<Category> get categories => const [
    Category('post', folder: 'posts', help: 'Timeline posts (captions, images, videos)'),
    Category('photo', folder: 'photos', help: 'User photos and uploads'),
    Category('video', folder: 'videos', help: 'User videos and reels'),
    Category('album', folder: 'albums', help: 'Photo albums'),
    Category('story', folder: 'stories', help: 'Active stories'),
    Category('highlight', folder: 'highlights', help: 'Featured story highlights'),
    Category('profile', folder: 'profiles', help: 'Profile picture and cover photo'),
  ];

  @override
  bool matches(String input) {
    final trimmed = input.trim();
    return RegExp(r'^(?:https?://)?(?:www\.|m\.|web\.)?(?:facebook\.com|fb\.com)/').hasMatch(trimmed);
  }

  @override
  String parseUser(String input) {
    final trimmed = input.trim();
    // 1. Query parameter: ?id=100083148192841
    if (RegExp(r'[?&]id=(\d+)').firstMatch(trimmed) case final m?) {
      return m[1]!;
    }
    // 2. /people/<name>/<id> route
    if (RegExp(r'/people/[^/?#]+/(\d+)').firstMatch(trimmed) case final m?) {
      return m[1]!;
    }
    // 3. /stories/<user> route
    if (RegExp(r'/stories/(?:highlights/)?([^/?#]+)').firstMatch(trimmed) case final m?) {
      final seg = m[1]!;
      if (seg != 'highlights') return seg;
    }
    // 4. Standard path segment: https://facebook.com/<user>
    if (RegExp(r'^(?:https?://)?(?:www\.|m\.|web\.)?(?:facebook\.com|fb\.com)/([^/?#]+)').firstMatch(trimmed)
        case final m?) {
      final seg = m[1]!;
      const nonProfile = {
        'photo',
        'photos',
        'media',
        'watch',
        'story',
        'stories',
        'groups',
        'share',
        'login',
        'events',
        'marketplace',
        'gaming',
        'hashtag',
        'search',
      };
      if (!nonProfile.contains(seg.toLowerCase())) {
        return seg;
      }
    }
    final handle = trimmed.replaceFirst(RegExp(r'^@'), '').split('?').first.split('/').first;
    if (handle.isEmpty) {
      throw FormatException('expected a Facebook username, profile ID, or URL, got "$input"');
    }
    return handle;
  }

  @override
  Future<Client?> login() => facebookLogin();

  @override
  Future<void> close(Client? api) async {
    await api?.close();
    await web.close();
    await cdn.close();
  }

  @override
  Object explain(Object error) => facebookExplain(error);

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
      throw const UsageException(
        'Facebook downloads require a login session: export cookies from facebook.com into .fbk.session.',
      );
    }
    final client = api;

    final p = await profile(client, u.name);
    u
      ..name = p.name
      ..id = p.id;

    final postsDir = categories.contains('post') ? userDir.dir('posts') : null;
    final photosDir = categories.contains('photo') ? userDir.dir('photos') : null;
    final videosDir = categories.contains('video') ? userDir.dir('videos') : null;
    final albumsDir = categories.contains('album') ? userDir.dir('albums') : null;
    final highlightsDir = categories.contains('highlight') ? userDir.dir('highlights') : null;

    String subpath(String tab) =>
        RegExp(r'^\d+$').hasMatch(p.name) ? '/profile.php?id=${p.name}&sk=$tab' : '/${p.name}/$tab/';

    Future<Results> add(List<media.Download> files) {
      final batch = queue.add(u, userDir, files);
      batches.add(batch);
      return batch;
    }

    // 1. Explore Profile
    Future<void> exploreProfile() async {
      final part = [?u.parts['profiles']];
      phase(part, 'fetching profile avatar and cover');
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
      if (p.cover case final cover?) {
        final rawId = Uri.parse(cover).pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'cover.jpg';
        final id = 'cover_${Fs.sanitize(rawId.split('?').first)}';
        if (!index.profiles.containsKey(id)) {
          if (index.profiles.isNotEmpty) changed('new cover photo');
          index.profiles[id] = DateTime.now().format('yyyy-MM-dd');
          await index.save();
        }
        toAdd.add((to: userDir.dir('profiles').file('${index.profiles[id]}_$id'), url: cover, text: null));
      }
      if (toAdd.isNotEmpty) add(toAdd);
      phase(part, '${toAdd.length} profile ${toAdd.length == 1 ? 'asset' : 'assets'}', done: true);
    }

    // 2. Explore Posts
    Future<void> explorePosts() async {
      if (postsDir == null) return;
      final part = [?u.parts['posts']];
      phase(part, 'fetching timeline posts');

      final posts = extractTimelinePosts(p.html);
      var totalPosts = 0;
      var consecutiveExisting = 0;

      for (final post in posts) {
        final month = DateTime.fromMillisecondsSinceEpoch(post.date * 1000).format('yyyy-MM');
        final targetDir = postsDir.dir(month);
        final postFiles = <media.Download>[];

        // 1. Photo attachments
        for (final (idx, pid) in post.photoIds.indexed) {
          final name = post.photoIds.length > 1 ? '${post.id}_${idx + 1}' : post.id;
          final photo = await photoPage(client, pid, '');
          if (photo != null) {
            final ext = photo.url.split('?').first.split('.').lastOrNull ?? 'jpg';
            postFiles.add((to: targetDir.file('$name.$ext'), url: photo.url, text: null));
          } else if (post.directUrls.firstOrNull case final dUrl?) {
            postFiles.add((to: targetDir.file('$name.jpg'), url: dUrl, text: null));
          }
        }

        // 2. Video attachments
        for (final (idx, vid) in post.videoIds.indexed) {
          final name = post.videoIds.length > 1 ? '${post.id}_${idx + 1}' : post.id;
          final video = await videoPage(client, vid);
          if (video != null) {
            postFiles.add((to: targetDir.file('$name.mp4'), url: video.url, text: null));
          } else if (post.directUrls.where((u) => u.contains('.mp4')).firstOrNull case final dUrl?) {
            postFiles.add((to: targetDir.file('$name.mp4'), url: dUrl, text: null));
          }
        }

        // 3. Caption text
        if (post.caption case final cap?) {
          if (cap.trim().isNotEmpty) {
            postFiles.add((to: targetDir.file('${post.id}.txt'), url: null, text: cap));
          }
        }

        if (postFiles.isEmpty) continue;

        // Incremental sync skip
        final primaryFile = postFiles.firstWhere((f) => f.url != null, orElse: () => postFiles.first).to;
        if (!all && await primaryFile.exists()) {
          consecutiveExisting++;
          if (consecutiveExisting >= 3) break;
          continue;
        }
        consecutiveExisting = 0;

        add(postFiles);
        totalPosts++;
      }

      phase(part, '$totalPosts posts', done: true);
    }

    Set<String> extractPhotoIds(String html) {
      final ids = <String>{};
      for (final m in RegExp(r'photo(?:\.php)?\\?/\?fbid=(\d+)').allMatches(html)) {
        ids.add(m[1]!);
      }
      for (final m in RegExp(r'[?&]fbid=(\d+)').allMatches(html)) {
        ids.add(m[1]!);
      }
      for (final m in RegExp(r'"id":"(\d+)"[^{}]*"__typename":"Photo"').allMatches(html)) {
        ids.add(m[1]!);
      }
      for (final m in RegExp(r'"__typename":"Photo"[^{}]*"id":"(\d+)"').allMatches(html)) {
        ids.add(m[1]!);
      }
      for (final m in RegExp(r'"photo_id":"(\d+)"').allMatches(html)) {
        ids.add(m[1]!);
      }
      return ids;
    }

    String? extractFirstPhotoId(String setHtml) {
      const startStr = '{"__typename":"Photo","__isMedia":"Photo","';
      final startIdx = setHtml.indexOf(startStr);
      if (startIdx >= 0) {
        const endStr = '","creation_story"';
        final endIdx = setHtml.indexOf(endStr, startIdx);
        if (endIdx > startIdx) {
          final sub = setHtml.substring(startIdx, endIdx);
          final idIdx = sub.lastIndexOf('"id":"');
          if (idIdx >= 0) {
            return sub.substring(idIdx + 6).split('"').first;
          }
        }
      }
      return extractPhotoIds(setHtml).firstOrNull;
    }

    String extractProfileSetId(String html) {
      final pageItemsIdx = html.indexOf('"pageItems"');
      final pageInfoIdx = html.indexOf('"page_info"', pageItemsIdx >= 0 ? pageItemsIdx : 0);
      if (pageItemsIdx >= 0 && pageInfoIdx > pageItemsIdx) {
        final sub = html.substring(pageItemsIdx, pageInfoIdx);
        if (RegExp(r'set=([^"&\\]+)').firstMatch(sub) case final m?) {
          final s = m[1]!;
          if (!s.startsWith('utf')) return s;
        }
      }
      if (RegExp(r'[?&]set=(pb\.[^"&\\]+)').firstMatch(html) case final m?) {
        return m[1]!;
      }
      return '';
    }

    String extractSetId(String html) {
      final profileSet = extractProfileSetId(html);
      if (profileSet.isNotEmpty) return profileSet;
      if (RegExp(r'[?&]set=([a-zA-Z0-9._-]+)').firstMatch(html) case final m?) {
        final s = m[1]!;
        if (!s.startsWith('utf')) return s;
      }
      if (RegExp(r'"mediaSetToken":"([^"]+)"').firstMatch(html) case final m?) {
        return m[1]!;
      }
      return '';
    }

    // 2. Explore Photos
    Future<void> explorePhotos() async {
      if (photosDir == null) return;
      final part = [?u.parts['photos']];
      phase(part, 'fetching photos index');

      // Fetch photos overview pages
      board.requests++;
      final response = await client.get(subpath('photos_by'));
      final photosByHtml = await response.text();

      var setId = extractProfileSetId(photosByHtml);
      if (setId.isEmpty) {
        board.requests++;
        final altRes = await client.get(subpath('photos'));
        final photosHtml = await altRes.text();
        setId = extractProfileSetId(photosHtml);
        if (setId.isEmpty) setId = extractSetId(photosHtml);
      }

      String? firstPhotoId;
      final initialIds = <String>{...extractPhotoIds(photosByHtml), ...extractPhotoIds(p.html)};

      if (setId.isNotEmpty) {
        board.requests++;
        final setRes = await client.get('/media/set/?set=$setId');
        final setHtml = await setRes.text();
        firstPhotoId = extractFirstPhotoId(setHtml);
        initialIds.addAll(extractPhotoIds(setHtml));
      }

      if (initialIds.isEmpty && setId.isEmpty) {
        board.requests++;
        final allRes = await client.get(subpath('photos_all'));
        final allHtml = await allRes.text();
        initialIds.addAll(extractPhotoIds(allHtml));
        setId = extractProfileSetId(allHtml);
      }

      final mark = userDir.file('.fbk-cursor-photos');
      final resume = all ? '' : (await mark.text(or: '')).trim();

      final queueIds = <String>[
        if (resume.isNotEmpty) resume,
        ?firstPhotoId,
        ...initialIds,
      ];

      final seen = <String>{};
      var count = 0;
      var qIdx = 0;
      var consecutiveExisting = 0;

      while (qIdx < queueIds.length) {
        final currentId = queueIds[qIdx++];
        if (seen.contains(currentId)) continue;
        seen.add(currentId);

        final photo = await photoPage(client, currentId, setId);
        if (photo == null) continue;

        final month = DateTime.fromMillisecondsSinceEpoch(photo.date * 1000).format('yyyy-MM');
        final targetDir = photosDir.dir(month);
        final ext = photo.url.split('?').first.split('.').lastOrNull ?? 'jpg';
        final file = targetDir.file('${photo.id}.$ext');

        if (!all && await file.exists()) {
          consecutiveExisting++;
          if (consecutiveExisting >= 3) {
            // Reached already downloaded media in incremental sync
            break;
          }
          if (photo.nextPhotoId case final nextId?) {
            if (!seen.contains(nextId) && !queueIds.contains(nextId)) {
              queueIds.add(nextId);
            }
          }
          continue;
        }
        consecutiveExisting = 0;

        final currentFiles = <media.Download>[
          (to: file, url: photo.url, text: null),
          if (photo.caption case final caption?)
            (to: targetDir.file('${photo.id}.txt'), url: null, text: caption),
        ];
        add(currentFiles);

        count++;
        phase(part, '$count photos discovered');
        await mark.write(currentId);

        if (photo.nextPhotoId case final nextId?) {
          if (!seen.contains(nextId) && !queueIds.contains(nextId)) {
            final nextNum = int.tryParse(nextId);
            final currNum = int.tryParse(currentId);
            if (nextNum != null && currNum != null && !setId.startsWith('pcb.') && nextNum > currNum + 5000000) {
              // detect jump to beginning of set
            } else {
              queueIds.add(nextId);
            }
          }
        }
      }

      await mark.delete();
      phase(part, '$count photos listed', done: true);
    }

    // 3. Explore Videos
    Future<void> exploreVideos() async {
      if (videosDir == null) return;
      final part = [?u.parts['videos']];
      phase(part, 'fetching videos index');

      board.requests++;
      final response = await client.get(subpath('videos'));
      final html = await response.text();

      // Also discover reels
      board.requests++;
      final reelsUrl = RegExp(r'^\d+$').hasMatch(p.name)
          ? '/profile.php?id=${p.name}&sk=reels_tab'
          : '/${p.name}/reels/';
      final rRes = await client.get(reelsUrl);
      final rHtml = await rRes.text();
      final combinedHtml = '$html\n$rHtml';

      final videoIds = <String>{
        for (final m in RegExp(r'\\?/(?:videos|reel|reels)\\?/(\d+)').allMatches(combinedHtml)) m[1]!,
        for (final m in RegExp(r'\\?/watch/\\?\?v=(\d+)').allMatches(combinedHtml)) m[1]!,
        for (final m in RegExp(r'"video_id":"(\d+)"').allMatches(combinedHtml)) m[1]!,
      };

      var count = 0;

      for (final vid in videoIds) {
        final v = await videoPage(client, vid);
        if (v == null) continue;
        final month = DateTime.fromMillisecondsSinceEpoch(v.date * 1000).format('yyyy-MM');
        final targetDir = videosDir.dir(month);
        final file = targetDir.file('${v.id}.mp4');

        if (!all && await file.exists()) continue;

        final toAdd = <media.Download>[
          (to: file, url: v.url, text: null),
          if (v.title case final title?)
            (to: targetDir.file('${v.id}.txt'), url: null, text: title),
        ];
        add(toAdd);
        count++;
        phase(part, '$count videos discovered');
      }

      phase(part, '$count videos listed', done: true);
    }

    // 4. Explore Albums
    Future<void> exploreAlbums() async {
      if (albumsDir == null) return;
      final part = [?u.parts['albums']];
      phase(part, 'fetching albums index');

      board.requests++;
      final response = await client.get(subpath('photos_albums'));
      final html = await response.text();

      final albums = <({String title, String setId})>[];
      final seenSets = <String>{};

      // 1. Check TimelineAppCollectionAlbumsRenderer (gallery-dl pattern)
      final pos = html.indexOf('"TimelineAppCollectionAlbumsRenderer"');
      if (pos >= 0) {
        final pageItemsIdx = html.indexOf('"pageItems":', pos);
        if (pageItemsIdx >= 0) {
          final chunk = html.substring(pageItemsIdx, (pageItemsIdx + 50000).clamp(0, html.length));
          for (final m in RegExp(
            r'\{"node":\{.*?"url":"https:\\/\\/www\.facebook\.com\\/media\\/set\\\/\?set=(a\.\d+)[^"]*".*?"title":\{"text":"((?:[^"\\]|\\.)*)"\}',
            dotAll: true,
          ).allMatches(chunk)) {
            final setId = m[1]!;
            final title = decodeFacebookText(m[2]!);
            if (seenSets.add(setId)) {
              albums.add((title: title, setId: setId));
            }
          }
        }
      }

      // 2. Discover album sets from URLs
      for (final m in RegExp(r'\\?/media\\?/set\\?/\?set=([^&"\\#]+)').allMatches(html)) {
        final setId = m[1]!;
        if (setId.startsWith('a.') && seenSets.add(setId)) {
          albums.add((title: setId, setId: setId));
        }
      }
      for (final m in RegExp(r'[?&]set=(a\.\d+)').allMatches(html)) {
        final setId = m[1]!;
        if (seenSets.add(setId)) {
          albums.add((title: setId, setId: setId));
        }
      }

      var totalPhotos = 0;
      for (final album in albums) {
        board.requests++;
        final setRes = await client.get('/media/set/?set=${album.setId}');
        final setHtml = await setRes.text();

        final albumTitle =
            RegExp(r'"__isMediaSet":"Album","title":\{"text":"((?:[^"\\]|\\.)*)"\}').firstMatch(setHtml)?[1] ??
            RegExp(r'"title":\{"text":"((?:[^"\\]|\\.)*)"\}').firstMatch(setHtml)?[1] ??
            RegExp(r'"album_title":"((?:[^"\\]|\\.)*)"').firstMatch(setHtml)?[1] ??
            RegExp(r'{"__typename":"Album","name":"((?:[^"\\]|\\.)*)"}').firstMatch(setHtml)?[1] ??
            album.title;
        final cleanTitle = decodeFacebookText(albumTitle);
        final aDir = albumsDir.dir(Fs.sanitize(cleanTitle));

        final firstPhotoId = extractFirstPhotoId(setHtml);
        final queueIds = <String>[
          ?firstPhotoId,
          ...extractPhotoIds(setHtml),
        ];

        final aSeen = <String>{};
        var aIdx = 0;
        var aConsecutiveExisting = 0;

        while (aIdx < queueIds.length) {
          final pid = queueIds[aIdx++];
          if (aSeen.contains(pid)) continue;
          aSeen.add(pid);

          final photo = await photoPage(client, pid, album.setId);
          if (photo == null) continue;

          final ext = photo.url.split('?').first.split('.').lastOrNull ?? 'jpg';
          final file = aDir.file('${photo.id}.$ext');
          if (!all && await file.exists()) {
            aConsecutiveExisting++;
            if (aConsecutiveExisting >= 3) break;
            if (photo.nextPhotoId case final nextId?) {
              if (!aSeen.contains(nextId) && !queueIds.contains(nextId)) {
                queueIds.add(nextId);
              }
            }
            continue;
          }
          aConsecutiveExisting = 0;

          final toAdd = <media.Download>[
            (to: file, url: photo.url, text: null),
            if (photo.caption case final cap?)
              (to: aDir.file('${photo.id}.txt'), url: null, text: cap),
          ];
          add(toAdd);
          totalPhotos++;

          if (photo.nextPhotoId case final nextId?) {
            if (!aSeen.contains(nextId) && !queueIds.contains(nextId)) {
              queueIds.add(nextId);
            }
          }
        }
      }

      phase(part, '${albums.length} albums, $totalPhotos photos', done: true);
    }

    // 5. Explore Stories
    Future<void> exploreStories() async {
      if (!categories.contains('story')) return;
      final part = [?u.parts['stories']];
      phase(part, 'fetching active stories');

      final bucketIds = <String>{
        for (final m in RegExp(r'"story_bucket":\{"nodes":\[\{[^{}]*"id":"(\d+)"').allMatches(p.html)) m[1]!,
        for (final m in RegExp(r'"story_bucket":\{"id":"(\d+)"').allMatches(p.html)) m[1]!,
      };

      final storyUrls = <String>[
        for (final b in bucketIds) '/stories/$b/',
        RegExp(r'^\d+$').hasMatch(p.id) ? '/stories/${p.id}/' : '/stories/${p.name}/',
      ];

      final filesToAdd = <media.Download>[];
      final month = DateTime.now().format('yyyy-MM');
      final sDir = userDir.dir('stories').dir(month);
      final seenMediaIds = <String>{};

      for (final sUrl in storyUrls) {
        board.requests++;
        final response = await client.get(sUrl);
        final html = await response.text();
        final items = extractStoryMedia(html);

        for (final item in items) {
          if (!seenMediaIds.add(item.id)) continue;
          final ext = item.isVideo ? 'mp4' : 'jpg';
          final file = sDir.file('${item.id}.$ext');
          if (!all && await file.exists()) continue;
          filesToAdd.add((to: file, url: item.url, text: null));
        }
        if (filesToAdd.isNotEmpty) break;
      }

      if (filesToAdd.isNotEmpty) add(filesToAdd);
      phase(part, '${filesToAdd.length} stories up now', done: true);
    }

    // 6. Explore Highlights (Featured Stories)
    Future<void> exploreHighlights() async {
      if (highlightsDir == null) return;
      final part = [?u.parts['highlights']];
      phase(part, 'listing highlights');

      final foundHighlights = <({String id, String title})>[];
      final seenIds = <String>{};

      for (final m in RegExp(r'\\?/stories\\?/highlights\\?/(\d+)\\?/').allMatches(p.html)) {
        final hid = m[1]!;
        if (seenIds.add(hid)) {
          foundHighlights.add((id: hid, title: 'highlight_$hid'));
        }
      }

      for (final m in RegExp(r'"(?:highlight_id|bucket_id)":"(\d+)"').allMatches(p.html)) {
        final hid = m[1]!;
        if (seenIds.add(hid)) {
          foundHighlights.add((id: hid, title: 'highlight_$hid'));
        }
      }

      for (final m in RegExp(
        r'"title":\{.*?"text":"((?:[^"\\]|\\.)*)"\}[^}]*"\\?/stories\\?/highlights\\?/(\d+)\\?/"',
        dotAll: true,
      ).allMatches(p.html)) {
        final title = decodeFacebookText(m[1]!);
        final hid = m[2]!;
        if (seenIds.contains(hid)) {
          final idx = foundHighlights.indexWhere((h) => h.id == hid);
          if (idx >= 0) foundHighlights[idx] = (id: hid, title: title);
        }
      }

      for (final m in RegExp(
        r'\{[^{}]*"id":"(\d+)"[^{}]*"title":\{"text":"((?:[^"\\]|\\.)*)"\}[^{}]*\}',
      ).allMatches(p.html)) {
        final hid = m[1]!;
        final title = decodeFacebookText(m[2]!);
        if (seenIds.add(hid)) {
          foundHighlights.add((id: hid, title: title));
        }
      }

      final now = <String, Set<String>>{};
      var totalMedia = 0;

      for (final h in foundHighlights) {
        final title = h.title.isEmpty ? h.id : h.title;
        final hDir = highlightsDir.dir(Fs.sanitize(title));
        final filesToAdd = <media.Download>[];
        final currentItemIds = <String>{};

        board.requests++;
        final hRes = await client.get('/stories/highlights/${h.id}/');
        final hHtml = await hRes.text();
        final items = extractStoryMedia(hHtml);

        for (final item in items) {
          final ext = item.isVideo ? 'mp4' : 'jpg';
          final file = hDir.file('${item.id}.$ext');
          currentItemIds.add(item.id);

          if (!all && await file.exists()) continue;
          filesToAdd.add((to: file, url: item.url, text: null));
        }

        if (filesToAdd.isNotEmpty) {
          totalMedia += filesToAdd.length;
          add(filesToAdd);
        }

        final before = index.highlights[title];
        if (before != null) {
          final (added, removed) = (currentItemIds.difference(before).length, before.difference(currentItemIds).length);
          if (added + removed > 0) changed('highlight "$title": $added added, $removed removed');
        } else if (index.highlights.isNotEmpty) {
          changed('new highlight "$title"');
        }
        now[title] = currentItemIds;
      }

      for (final title in index.highlights.keys.where((t) => !now.containsKey(t))) {
        changed('highlight "$title" gone, files kept');
      }
      index.highlights = now;
      phase(
        part,
        '${foundHighlights.length} ${foundHighlights.length == 1 ? 'highlight' : 'highlights'}, $totalMedia items',
        done: true,
      );
    }

    await Future.wait([
      if (categories.contains('profile')) exploreProfile(),
      if (postsDir != null) explorePosts(),
      if (photosDir != null) explorePhotos(),
      if (videosDir != null) exploreVideos(),
      if (albumsDir != null) exploreAlbums(),
      if (categories.contains('story')) exploreStories(),
      if (highlightsDir != null) exploreHighlights(),
    ]);
  }
}

Future<Client?> facebookLogin() => login();
Object facebookExplain(Object error) => explain(error);
