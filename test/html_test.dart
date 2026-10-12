import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

void main() {
  group('html documents', () {
    test('drop(css) copies without the match; the receiver is unchanged', () {
      final doc = Html.parse('<div><p>keep</p><script>var x = 1;</script></div>');
      final clean = doc.drop('script');
      expect(clean.all('script'), isEmpty);
      expect(clean.find('p')?.text, 'keep');
      expect(doc.all('script'), hasLength(1));
    });

    test('prev/next skip text nodes', () {
      final doc = Html.parse('<div><b id="a">x</b> tail <i id="b">y</i></div>');
      expect(doc.find('#b')?.prev?.attr('id'), 'a');
      expect(doc.find('#a')?.next?.attr('id'), 'b');
      expect(doc.find('#a')?.prev, isNull);
    });

    test('doc.html is the whole markup as a String', () {
      final doc = Html.parse('<p>hi</p>');
      expect(doc.html, isA<String>());
      expect(doc.html, contains('<p>hi</p>'));
    });

    test('a real page parses: hn.html has links', () async {
      final doc = await File('test/fixtures/hn.html').html();
      expect(doc.all('a[href]'), isNotEmpty);
    });
  });
}
