import 'package:dart_toolkit/html.dart';
import 'package:test/test.dart';

import '../projects/medialoader/facebook.dart';

// A page embedding [json] the way Facebook does.
Json embedded(String json) => Html.parse('<html><body><script type="application/json">$json</script></body></html>').json();

// A profile page whose timeline holds one post with [story] as its content.
Json timelineWith(String story) => embedded('''
{"require": [["RelayModern", "ProfileCometTimelineFeedQuery", [], {
  "timeline_list_feed_units": {"edges": [{"node": {
    "__typename": "Story", "post_id": "1001", "creation_time": 1700000000,
    "comet_sections": {"content": {"story": $story}}
  }}]}
}]]}
''');

void main() {
  group('Facebook text from the embedded JSON', () {
    String? caption(String text) => timeline(timelineWith('{"__typename": "Story", "message": {"text": "$text"}}')).single.caption;

    test('unicode escapes and emoji (surrogate pairs) decode', () {
      expect(
        caption(r'Thả tim để bạn Phương Linh siêng đăng hình hơn 😶'),
        'Thả tim để bạn Phương Linh siêng đăng hình hơn 😶',
      );
      expect(caption(r'Tiếng Việt'), 'Tiếng Việt');
    });

    test('quotes, newlines and symbols come through as written', () {
      expect(caption(r'Line 1\nLine 2\n\"Quoted\" & “smart quotes” ❤'), 'Line 1\nLine 2\n"Quoted" & “smart quotes” ❤');
    });

    test('escaped Comet URLs come out plain', () {
      final post = timeline(timelineWith(r'''
        {"__typename": "Story", "attachments": [{"media": {"__typename": "Photo", "id": "2001",
          "image": {"uri": "https:\/\/scontent.xx.fbcdn.net\/v\/t39.30808-6\/test.jpg%3Foh=123&oe=456"}}}]}
      ''')).single;
      expect(post.items.single.url, 'https://scontent.xx.fbcdn.net/v/t39.30808-6/test.jpg%3Foh=123&oe=456');
    });
  });

  group('Facebook platform URL parsing and matching', () {
    test('matches facebook domains', () {
      expect(platform.matches('https://www.facebook.com/username'), isTrue);
      expect(platform.matches('https://m.facebook.com/username/'), isTrue);
      expect(platform.matches('https://fb.com/100083148192841'), isTrue);
      expect(platform.matches('https://instagram.com/user'), isFalse);
    });

    test('parses username, profile ID, or URL', () {
      String user(String input) => platform.parse(input).user;
      expect(user('https://www.facebook.com/ngocvyne05'), 'ngocvyne05');
      expect(user('https://www.facebook.com/profile.php?id=100083148192841'), '100083148192841');
      expect(user('https://facebook.com/people/Some-Name/61569950545630'), '61569950545630');
      expect(user('https://www.facebook.com/stories/ngocvyne05/'), 'ngocvyne05');
      expect(user('ngocvyne05'), 'ngocvyne05');
      expect(user('@ngocvyne05'), 'ngocvyne05');
    });

    test('categories contains post, photo, video, album, story, highlight, and profile', () {
      final names = platform.categories.map((c) => c.name).toSet();
      expect(names, containsAll(['post', 'photo', 'video', 'album', 'story', 'highlight', 'profile']));
    });
  });

  group('Facebook timeline posts extraction', () {
    test('extracts post with caption, photo, and video attachments', () {
      final posts = timeline(timelineWith(r'''
        {"__typename": "Story", "message": {"text": "Hello world 😊"}, "attachments": [
          {"media": {"__typename": "Photo", "id": "2001", "image": {"uri": "https:\/\/scontent.xx.fbcdn.net\/p2001.jpg"}}},
          {"media": {"__typename": "Video", "id": "3001", "playable_url": "https:\/\/scontent.xx.fbcdn.net\/v3001.mp4"}}
        ]}
      '''));
      expect(posts.length, 1);
      final p = posts.first;
      expect(p.id, '1001');
      expect(p.at, DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
      expect(p.caption, 'Hello world 😊');
      expect([for (final i in p.items) (i.id, i.video)], [('2001', false), ('3001', true)]);
    });

    test('each photo keeps its own URL (regression: every photo got the first one)', () {
      final p = timeline(timelineWith(r'''
        {"__typename": "Story", "attachments": [
          {"media": {"__typename": "Photo", "id": "1", "image": {"uri": "https://x.fbcdn.net/a.jpg"}}},
          {"media": {"__typename": "Photo", "id": "2", "photo_image": {"uri": "https://x.fbcdn.net/b.jpg"}}}
        ]}
      ''')).single;
      expect([for (final i in p.items) i.url], ['https://x.fbcdn.net/a.jpg', 'https://x.fbcdn.net/b.jpg']);
    });

    test('the pinned post is read too, each post once', () {
      final data = embedded('''
        [{"profile_pinned_post": {"id": "77", "post": {"__typename": "Story", "creation_time": 1600000000, "message": {"text": "pinned"}}}},
         {"profile_pinned_post": {"id": "77", "post": {"__typename": "Story", "message": {"text": "pinned"}}}}]
      ''');
      expect([for (final p in timeline(data)) (p.id, p.caption)], [('77', 'pinned')]);
    });
  });

  group('Facebook story media extraction', () {
    test('extracts and deduplicates photos and videos', () {
      final items = storyItems(embedded(r'''
{
  "progressive_urls": [
    {"progressive_url": "https:\/\/scontent.xx.fbcdn.net\/o1\/v\/m1\/vid1.mp4?xpv_asset_id%22%3A999"}
  ],
  "playable_url": "https:\/\/scontent.xx.fbcdn.net\/o1\/v\/m1\/vid1_sd.mp4?xpv_asset_id%22%3A999",
  "image": {"uri": "https:\/\/scontent.xx.fbcdn.net\/v\/t39.30808-6\/111_22222_333_n.jpg"}
}
'''));
      // Videos deduplicated by asset ID, the photo by its id in the file name.
      expect([for (final i in items) (i.id, i.video)], [('999', true), ('22222', false)]);
    });
  });

  test('photo ids: photo nodes first, then photo_id keys and fbid links', () {
    final d = Html.parse('''
      <html><body><a href="/photo/?fbid=33&set=pb.1">x</a>
      <script type="application/json">{"a": {"__typename": "Photo", "id": "11"}, "photo_id": "22"}</script></body></html>
    ''', base: 'https://www.facebook.com/');
    final doc = (page: d, data: d.json(), text: '');
    expect(photoIds(doc), ['11', '22', '33']);
    expect(profileSet(doc), 'pb.1');
  });
}
