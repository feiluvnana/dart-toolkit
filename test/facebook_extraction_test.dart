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
  });
}
