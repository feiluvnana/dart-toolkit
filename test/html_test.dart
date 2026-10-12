import 'package:dart_toolkit/html.dart';
import 'package:test/test.dart';

void main() {
  group('Html.parse', () {
    test('returns Elements', () {
      expect(Html.parse('<div></div>'), isA<Elements>());
    });

    test('never throws on malformed markup', () {
      expect(() => Html.parse('<div><p>oops'), returnsNormally);
      expect(() => Html.parse(''), returnsNormally);
      expect(() => Html.parse('<'), returnsNormally);
    });
  });

  group('Elements', () {
    final doc = Html.parse(
      '<div class="a"><p>Hello <a href="/">link</a></p><p>Two</p></div>'
      '<ul><li>1</li><li>2</li></ul>',
    );

    test(r'$() filters', () {
      expect(doc.$('div.a').length, 1);
      expect(doc.$('p').length, 2);
    });

    test(r'chained $() searches within all hits', () {
      expect(doc.$('div').$('p').length, 2);
      expect(doc.$('div.a').$('a').length, 1);
    });

    test(r'$() matches self as well as descendants', () {
      expect(doc.$('div').$('div').length, 1);
    });

    test(r'$() dedupes overlapping subtrees', () {
      expect(doc.$('div, p').$('p').length, 2);
    });

    test('no match is empty, never null', () {
      final els = doc.$('.missing');
      expect(els, isEmpty);
      expect(els.$('p'), isEmpty);
    });

    test('[] indexing', () {
      expect(doc.$('li')[0].text(), '1');
      expect(doc.$('li')[1].text(), '2');
      expect(() => doc.$('li')[2], throwsRangeError);
    });

    test('safe head access via isEmpty', () {
      final hit = doc.$('a');
      expect(hit.isEmpty ? null : hit[0].text(), 'link');
      final miss = doc.$('.missing');
      expect(miss.isEmpty ? null : miss[0].text(), isNull);
    });

    test('is iterable', () {
      expect(doc.$('p').map((e) => e.text()), ['Hello link', 'Two']);
    });

    test('combinators', () {
      expect(doc.$('div > p').length, 2);
      expect(doc.$('div p a').firstOrNull?.text(), 'link');
    });
  });

  group('Element', () {
    test('text() concatenates descendant text', () {
      final doc = Html.parse('<div><p>Hello <a>link</a></p></div>');
      expect(doc.$('div')[0].text(), 'Hello link');
    });

    test('attr() is case-insensitive, null if absent', () {
      final doc = Html.parse('<a HREF="/" CLASS="x">t</a>');
      final a = doc.$('a')[0];
      expect(a.attr('href'), '/');
      expect(a.attr('HREF'), '/');
      expect(a.attr('missing'), isNull);
    });

    test('boolean attributes map to empty string', () {
      final doc = Html.parse('<input disabled>');
      expect(doc.$('input')[0].attr('disabled'), '');
    });

    test('parent() walks up, null at top level', () {
      final doc = Html.parse('<div><p><a>t</a></p></div>');
      final a = doc.$('a')[0];
      expect(a.parent()?.text(), 't');
      expect(a.parent()?.parent()?.text(), 't');
      expect(doc.$('div')[0].parent(), isNull);
    });

    test('entities are decoded', () {
      final doc = Html.parse('<p title="a &quot;b&quot;">a &amp; b</p>');
      expect(doc.$('p')[0].text(), 'a & b');
      expect(doc.$('p')[0].attr('title'), 'a "b"');
    });

    test('void elements and script raw text', () {
      final doc = Html.parse(
        '<div><br><img src="i.png"></div><script>if (a < b) x();</script>',
      );
      expect(doc.$('br').length, 1);
      expect(doc.$('img')[0].attr('src'), 'i.png');
      expect(doc.$('script')[0].text(), contains('a < b'));
    });
  });
}
