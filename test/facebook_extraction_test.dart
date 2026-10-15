import 'package:test/test.dart';
import '../projects/medialoader/facebook.dart';

void main() {
  group('Facebook text and unicode decoding', () {
    test('decodes unicode escape sequences and emojis correctly', () {
      const raw =
          r'Th\u1ea3 tim \u0111\u1ec3 b\u1ea1n Ph\u01b0\u01a1ng Linh si\u00eang \u0111\u0103ng h\u00ecnh h\u01a1n \ud83d\ude36';
      final decoded = decodeFacebookText(raw);
      expect(decoded, 'Thả tim để bạn Phương Linh siêng đăng hình hơn 😶');
    });

    test('handles quotes, newlines, and HTML entities', () {
      const raw = r'Line 1\nLine 2\n\"Quoted\" &amp; &#039;test&#039; &quot;yes&quot;';
      final decoded = decodeFacebookText(raw);
      expect(decoded, 'Line 1\nLine 2\n"Quoted" & \'test\' "yes"');
    });

    test('handles numeric and hex entities', () {
      const raw = r'&#8220;smart quotes&#8221; &amp; &#x2764;';
      final decoded = decodeFacebookText(raw);
      expect(decoded, '“smart quotes” & ❤');
    });

    test('cleanCaption forwards to decodeFacebookText', () {
      const raw = r'Ti\u1ebfng Vi\u1ec7t';
      expect(cleanCaption(raw), 'Tiếng Việt');
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
      expect(platform.parseUser('https://www.facebook.com/ngocvyne05'), 'ngocvyne05');
      expect(platform.parseUser('https://www.facebook.com/profile.php?id=100083148192841'), '100083148192841');
      expect(platform.parseUser('https://facebook.com/people/Some-Name/61569950545630'), '61569950545630');
      expect(platform.parseUser('ngocvyne05'), 'ngocvyne05');
      expect(platform.parseUser('@ngocvyne05'), 'ngocvyne05');
    });

    test('unescapes Facebook Comet URLs', () {
      const raw = r'https:\/\/scontent.xx.fbcdn.net\/v\/t39.30808-6\/test.jpg\u00253Foh\u003D123\u0026oe\u003D456';
      expect(unescapeUrl(raw), 'https://scontent.xx.fbcdn.net/v/t39.30808-6/test.jpg%3Foh=123&oe=456');
    });

    test('categories contains post, photo, video, album, story, highlight, and profile', () {
      final names = platform.categories.map((c) => c.name).toSet();
      expect(names, containsAll(['post', 'photo', 'video', 'album', 'story', 'highlight', 'profile']));
    });
  });

  group('Facebook timeline posts extraction', () {
    test('extracts post with caption, photo, and video attachments', () {
      const mockHtml = '''
<html><body>
<script type="application/json">
{
  "require": [
    ["RelayModern", "ProfileCometTimelineFeedQuery", [], {
      "timeline_list_feed_units": {
        "edges": [
          {
            "node": {
              "__typename": "Story",
              "post_id": "1001",
              "creation_time": 1700000000,
              "comet_sections": {
                "content": {
                  "story": {
                    "__typename": "Story",
                    "message": {"text": "Hello world \\ud83d\\ude0a"},
                    "attachments": [
                      {
                        "media": {
                          "__typename": "Photo",
                          "id": "2001",
                          "image": {"uri": "https:\\/\\/scontent.xx.fbcdn.net\\/p2001.jpg"}
                        }
                      },
                      {
                        "media": {
                          "__typename": "Video",
                          "id": "3001",
                          "playable_url": "https:\\/\\/scontent.xx.fbcdn.net\\/v3001.mp4"
                        }
                      }
                    ]
                  }
                }
              }
            }
          }
        ]
      }
    }]
  ]
}
</script>
</body></html>
''';

      final posts = extractTimelinePosts(mockHtml);
      expect(posts.length, 1);
      final p = posts.first;
      expect(p.id, '1001');
      expect(p.date, 1700000000);
      expect(p.caption, 'Hello world 😊');
      expect(p.photoIds, ['2001']);
      expect(p.videoIds, ['3001']);
    });
  });

  group('Facebook story media extraction', () {
    test('extracts and deduplicates photos and videos', () {
      const mockStoryHtml = '''
<html><body>
<script type="application/json">
{
  "progressive_urls": [
    {"progressive_url": "https:\\/\\/scontent.xx.fbcdn.net\\/o1\\/v\\/m1\\/vid1.mp4?xpv_asset_id%22%3A999"}
  ],
  "playable_url": "https:\\/\\/scontent.xx.fbcdn.net\\/o1\\/v\\/m1\\/vid1_sd.mp4?xpv_asset_id%22%3A999",
  "image": {"uri": "https:\\/\\/scontent.xx.fbcdn.net\\/v\\/t39.30808-6\\/111_22222_333_n.jpg"}
}
</script>
</body></html>
''';

      final media = extractStoryMedia(mockStoryHtml);
      expect(media.any((m) => m.isVideo), isTrue);
      expect(media.any((m) => !m.isVideo), isTrue);
      // Videos deduplicated by asset ID
      expect(media.where((m) => m.isVideo).length, 1);
      // Photo extracted
      expect(media.where((m) => !m.isVideo).first.id, '22222');
    });
  });
}
