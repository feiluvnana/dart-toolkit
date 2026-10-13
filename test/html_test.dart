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

    test('takes a baseUrl', () {
      final doc = Html.parse('<a href="/x">t</a>', baseUrl: 'https://e.com/d/');
      expect(doc.$('a')[0].attr('href'), 'https://e.com/x');
    });
  });

  group('Reader.html', () {
    test('parses bytes', () async {
      final doc = await _Mem('<p>hi</p>').html();
      expect(doc.$('p').text(), 'hi');
    });

    test('mirror on Future<Reader>', () async {
      final doc = await Future<Reader>.value(_Mem('<p>hi</p>')).html();
      expect(doc.$('p').text(), 'hi');
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

    test('without removes matches and subtrees', () {
      final clean = doc.without('ul');
      expect(clean.$('li'), isEmpty);
      expect(clean.$('p').length, 2);
      expect(doc.$('li').length, 2); // receiver unchanged
    });

    test('without sees only the new tree', () {
      final clean = doc.without('div');
      expect(clean.$('div'), isEmpty);
      expect(clean.$('ul').$('li').length, 2);
    });

    test('text joins every element', () {
      expect(doc.$('li').text(), '12');
      expect(doc.$('title').text(), '');
    });

    test('attr is the first match, null when nothing matched', () {
      final linked = Html.parse('<a href="/1">a</a><a href="/2">b</a>');
      expect(linked.$('a').attr('href'), '/1');
      expect(linked.$('.missing').attr('href'), isNull);
    });

    test('attrs lists every value, absent skipped', () {
      final mixed = Html.parse('<a href="/1">a</a><a>b</a><a href="/3">c</a>');
      expect(mixed.$('a').attrs('href'), ['/1', '/3']);
    });

    test('attrs resolves links against the base', () {
      final based = Html.parse(
        '<a class="i" href="/x">a</a><a class="i" href="/y">b</a>',
        baseUrl: 'https://e.com/',
      );
      expect(based.$('a.i').attrs('href'),
          ['https://e.com/x', 'https://e.com/y']);
    });

    test('bad selector is a FormatException naming it', () {
      expect(() => doc.$('['), throwsA(isA<FormatException>().having(
        (e) => e.message,
        'message',
        contains('['),
      )));
      expect(() => doc.without('['), throwsA(isA<FormatException>()));
    });

    test('is iterable', () {
      expect(doc.$('p').map((e) => e.text()), ['Hello link', 'Two']);
    });

    test('Future mirrors match', () async {
      final f = Future.value(doc);
      expect((await f.$('p')).length, 2);
      expect(await f.$('li')[0].text(), '1');
      expect((await f.without('ul')).$('li'), isEmpty);
      expect(await f.$('li').text(), '12');
      expect(await f.$('a').attr('href'), '/');
      expect(await f.$('a').attrs('href'), ['/']);
    });
  });

  group('Element', () {
    test(r'$() queries within the element, self included', () {
      final doc = Html.parse('<div><p>Hello <a>link</a></p></div>');
      final div = doc.$('div')[0];
      expect(div.$('p').length, 1);
      expect(div.$('div').length, 1);
      expect(div.$('span'), isEmpty);
    });

    test('without copies without the parts', () {
      final doc = Html.parse('<div><p>a</p><script>var x = 1;</script></div>');
      final clean = doc.$('div')[0].without('script');
      expect(clean.$('script'), isEmpty);
      expect(clean.$('p').text(), 'a');
      expect(doc.$('script').length, 1);
    });

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

    test('attr resolves href and src with a base', () {
      final doc = Html.parse('<img src="i.png">', baseUrl: 'https://e.com/d/');
      expect(doc.$('img')[0].attr('src'), 'https://e.com/d/i.png');
    });

    test('parent() walks up, null at top level', () {
      final doc = Html.parse('<div><p><a>t</a></p></div>');
      final a = doc.$('a')[0];
      expect(a.parent()?.text(), 't');
      expect(a.parent()?.parent()?.text(), 't');
      expect(doc.$('div')[0].parent(), isNull);
    });

    test('Future mirrors match', () async {
      final doc = Html.parse('<div><p><a href="/x">t</a></p></div>');
      final f = Future.value(doc.$('div')[0]);
      expect((await f.$('a')).length, 1);
      expect((await f.without('p')).$('a'), isEmpty);
      expect(await f.text(), contains('t'));
      expect(await f.$('a').attr('href'), '/x');
      expect(await f.parent(), isNull);
    });
  });
}

final class _Mem with Reader {
  _Mem(String text) : _data = text;
  final String _data;
  @override
  Stream<List<int>> stream() => Stream.value(_data.codeUnits);
}
