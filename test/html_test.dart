import 'dart:convert';

import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/src/charset.dart';
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

  group('Charset', () {
    test('single-byte legacy codecs decode', () {
      expect(Charset.decode([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], contentType: 'text/html; charset=windows-1251'), 'Привет');
      expect(Charset.decode([0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4], contentType: 'text/html; charset=koi8-r'), 'Привет');
      expect(Charset.decode([0xB1, 0xE6], contentType: 'text/html; charset=iso-8859-2'), 'ąć');
    });

    test('an unknown header charset falls through to the meta hint', () {
      final page = [...utf8.encode('<meta charset="windows-1251">'), 0xCF, 0xF0];
      expect(Charset.decode(page, contentType: 'text/html; charset=x-made-up'), endsWith('Пр'));
    });

    test('utf-8 decodes whole, skips the BOM, replaces bad bytes', () {
      expect(Charset.decode([0xEF, 0xBB, 0xBF, ...utf8.encode('é')]), 'é');
      expect(Charset.decode(utf8.encode('é').followedBy([0xFF]).toList()), 'é\uFFFD');
      expect(Charset.decode([0xFF, 0xFE, 0x41, 0x00]), 'A');
    });

    test('a meta utf-16 label means utf-8', () {
      final page = utf8.encode('<meta charset="utf-16"><p>héllo</p>');
      expect(Charset.decode(page), '<meta charset="utf-16"><p>héllo</p>');
    });
  });

  test('text() separates table cells', () {
    final t = Html.parse('<table><tr><th>Name</th><th>Price</th></tr><tr><td>A</td><td>1</td></tr></table>');
    expect(t.text(), 'Name Price\nA 1');
  });

  group('base href', () {
    test('a document <base> wins over the page URL', () {
      final doc = Html.parse(
        '<!doctype html><head><base href="https://cdn.e.com/a/"></head>'
        '<body><a href="x">t</a></body>',
        baseUrl: 'https://e.com/d/',
      );
      expect(doc.$('a')[0].attr('href'), 'https://cdn.e.com/a/x');
    });

    test('a relative <base> resolves against the page URL', () {
      final doc = Html.parse(
        '<html><head><base href="/s/"></head><body><a href="x">t</a></body></html>',
        baseUrl: 'https://e.com/d/',
      );
      expect(doc.$('a')[0].attr('href'), 'https://e.com/s/x');
    });
  });

  group('Reader.html', () {
    test('parses bytes', () async {
      final doc = await _Mem('<p>hi</p>').html();
      expect(doc.$('p').text(), 'hi');
    });

    test('a piped Future<Reader> keeps its origin for links', () async {
      final src = _Mem('<a href="b.html">x</a>', const Origin(url: 'https://e.com/d/'));
      final doc = await (Future<Reader>.value(src) | null).html();
      expect(doc.$('a')[0].attr('href'), 'https://e.com/d/b.html');
      final piped = await (Future<Reader>.value(src) | _Id()).html();
      expect(piped.$('a')[0].attr('href'), 'https://e.com/d/b.html');
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

    test('text reads the first match', () {
      expect(doc.$('li').text(), '1');
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

    test('texts() pairs text/texts like attr/attrs', () {
      expect(doc.$('p').texts(), ['Hello link', 'Two']);
      expect(doc.$('.missing').texts(), isEmpty);
      final linked = Html.parse('<a href="/1">a</a><a href="/2">b</a>');
      expect(linked.$('a').texts(), ['a', 'b']);
    });

    test('Future mirrors match', () async {
      final f = Future.value(doc);
      expect((await f.$('p')).length, 2);
      expect(await f.$('li')[0].text(), '1');
      expect((await f.without('ul')).$('li'), isEmpty);
      expect(await f.$('li').text(), '1');
      expect(await f.$('li').texts(), ['1', '2']);
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

  group('document parsing (M1)', () {
    test('a full document keeps html/head/body', () {
      final doc = Html.parse(
        '<html><head><title>t</title></head><body><p>hi</p></body></html>',
      );
      expect(doc.$('body').length, 1);
      expect(doc.$('body').text(), 'hi');
      expect(doc.$('html').length, 1);
      expect(doc.$('title').text(), 't');
    });

    test('doctype and case variants parse as documents', () {
      expect(
        Html.parse(
          '<!DOCTYPE html><html><body><p>x</p></body></html>',
        ).$('body').text(),
        'x',
      );
      expect(
        Html.parse('  <HTML><BODY><P>y</P></BODY></HTML>').$('body').text(),
        'y',
      );
    });

    test('anything else stays a fragment', () {
      final frag = Html.parse('<p>hi</p>');
      expect(frag.$('body'), isEmpty);
      expect(frag.length, 1);
      expect(frag.$('p').text(), 'hi');
    });
  });

  group('without clones (M2)', () {
    test('table rows survive without', () {
      final doc = Html.parse(
        '<table><tr class="x"><td>a</td></tr><tr><td>b</td></tr></table>',
      );
      final kept = doc.$('tr').without('.x');
      expect(kept.length, 1);
      expect(kept.text(), 'b');
      expect(doc.$('tr').length, 2); // receiver unchanged
    });

    test('a top-level self match drops the subtree', () {
      final doc = Html.parse('<div class="x"><p>a</p></div><div><p>b</p></div>');
      final kept = doc.$('div').without('.x');
      expect(kept.length, 1);
      expect(kept.text(), 'b');
    });
  });

  group('self matching (M3)', () {
    test('a lone top-level element sees the real tree', () {
      final frag = Html.parse('<p>hi</p>');
      expect(frag.$('div p'), isEmpty);
      expect(frag.$('p').length, 1);
    });

    test('matches sees the root element itself', () {
      // Exercises the engine-internal `matches` on a root (not just
      // descendants): without it a lone root never matches itself.
      final frag = Html.parse('<p class="x">hi</p>');
      expect(frag.$('p.x').length, 1);
      expect(frag.$('p.x').text(), 'hi');
      expect(frag.$('.x').texts(), ['hi']);
    });

    test('chained queries include the element itself', () {
      final doc = Html.parse('<div class="o"><p>x</p></div><span>y</span>');
      expect(doc.$('div, span').$('div.o').length, 1);
      expect(doc.$('div').$('div.o').length, 1);
      expect(doc.$('div')[0].$('div.o').length, 1);
    });
  });

  group('URL attributes (M4)', () {
    test('attr trims before resolving', () {
      final doc = Html.parse(
        '<a href=" /path ">t</a>',
        baseUrl: 'https://e.com/d/',
      );
      expect(doc.$('a')[0].attr('href'), 'https://e.com/path');
    });

    test('data-src, poster and action resolve too', () {
      final doc = Html.parse(
        '<img data-src=" img.png "><video poster=" p.png ">',
        baseUrl: 'https://e.com/d/',
      );
      expect(doc.$('img')[0].attr('data-src'), 'https://e.com/d/img.png');
      expect(doc.$('video')[0].attr('poster'), 'https://e.com/d/p.png');
      final form = Html.parse(
        '<form action=" /go ">',
        baseUrl: 'https://e.com/d/',
      );
      expect(form.$('form')[0].attr('action'), 'https://e.com/go');
    });

    test('trim applies without a base', () {
      expect(Html.parse('<a href=" /x ">t</a>').$('a')[0].attr('href'), '/x');
    });
  });

  group('innerText text() (V10)', () {
    test('collapses spaces, one newline per run, trims', () {
      final doc = Html.parse('<div>  a   b\n\n  c  </div>');
      expect(doc.$('div')[0].text(), 'a b\nc');
    });

    test('Elements.text reads the first match only', () {
      final doc = Html.parse('<li>1</li><li>2</li>');
      expect(doc.$('li').text(), '1');
      expect(doc.$('.missing').text(), '');
    });

    test('pre keeps its whitespace', () {
      final doc = Html.parse('<div><pre>x   y\nz</pre></div>');
      expect(doc.$('div')[0].text(), 'x   y\nz');
    });
  });
}

final class _Mem with Reader {
  _Mem(String text, [this._origin = const Origin()]) : _data = text;
  final String _data;
  final Origin _origin;
  @override
  Origin origin() => _origin;
  @override
  Stream<List<int>> stream() => Stream.value(_data.codeUnits);
}

final class _Id with Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) => input;
}
