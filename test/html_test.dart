import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:html/parser.dart' as reference;
import 'package:test/test.dart';

void main() {
  const selectors = [
    'a', 'a[href]', 'div', 'p', 'li', 'tr', 'td', 'table tr', 'ul > li', 'ol > li', 'h1, h2, h3', 'img[src]', 'span', //
    'tr > td', 'body > div', 'head > title', 'meta[name]', 'a[href^="http"]', 'li:first-child', 'div > p', 'table',
    'tbody > tr', 'form input', 'select option', 'script', 'style', 'p + p', 'h2 ~ p', 'a:not([href])',
    '.key_cd_track_box ul li', '.track_disc_title', '.track_disc_text_style1', '.key_cd_artworks_box',
    'tr.athing', '.titleline > a', 'td.subtext', '.site-header a', 'nav a[href]',
  ];

  for (final name in ['key_box', 'hn', 'dart_dev']) {
    test('$name.html parses like the reference', () {
      final src = File('test/fixtures/$name.html').readAsStringSync();
      final ours = HtmlDocument.parse(src);
      final theirs = reference.parse(src);
      for (final sel in selectors) {
        final a = [for (final e in ours.$(sel)) (e.name, e.attr('href'), e.text.trim())];
        final b = [for (final e in theirs.querySelectorAll(sel)) (e.localName, e.attributes['href'], e.text.trim())];
        expect(a, equals(b), reason: sel);
      }
    });
  }

  test('the in-house parser is not slower than the reference on the largest fixture', () {
    final src = File('test/fixtures/key_box.html').readAsStringSync();
    for (var i = 0; i < 3; i++) {
      HtmlDocument.parse(src);
      reference.parse(src);
    }
    final ours = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      HtmlDocument.parse(src);
    }
    ours.stop();
    final ref = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      reference.parse(src);
    }
    ref.stop();
    expect(
      ours.elapsedMicroseconds,
      lessThan(ref.elapsedMicroseconds * 1.5),
      reason: '${ours.elapsed} vs ${ref.elapsed}',
    );
  });

  group('html', () {
    test('Element.lines decodes entities and splits at <br>', () {
      final doc = HtmlDocument.parse('<p id="x">A &amp; B &lt;c&gt;<br>D\nE<br></p>');
      expect(doc.$('#x').first.lines, equals(['A & B <c>', 'D', 'E']));
    });
  });

  group('html parser', () {
    test('tag soup lands where a browser puts it', () {
      final doc = '<p>one<p>two<ul><li>a<li>b</ul><table><tr><td>1<td>2</table>'.html;
      expect(doc.$('p').map((p) => p.text), ['one', 'two']);
      expect(doc.$('ul > li').map((li) => li.text), ['a', 'b']);
      expect(doc.$('table > tbody > tr > td').map((td) => td.text), ['1', '2']);
      expect(doc.body.children.map((e) => e.name), ['p', 'p', 'ul', 'table']);
    });

    test('head and body are synthesised, title is in head, script text is raw', () {
      final doc = '<title>T &amp; U</title><script>if (a < b) {}</script><div>x</div>'.html;
      expect(doc.head.$('title').text, 'T & U');
      expect(doc.head.$('script').text, 'if (a < b) {}');
      expect(doc.body.$('div').text, 'x');
    });

    test('entities: named, decimal, hex, and unterminated', () {
      expect(decodeEntities('&lt;a&gt; &amp; &#65;&#x42; &nbsp;x &unknown; &amp'), '<a> & AB \u00a0x &unknown; &');
    });

    test('attributes: quoted, unquoted, valueless, duplicated, case', () {
      final a = '<A HREF=/x Data-Id="7" disabled title=\'q "t"\' href="/dup">'.html.$('a').first;
      expect(a.attributes, {'href': '/x', 'data-id': '7', 'disabled': '', 'title': 'q "t"'});
    });

    test('selectors: combinators, attribute operators, pseudo-classes, lists', () {
      final doc =
          '''
        <div id="root" class="a b">
          <p class="x">1</p><p>2</p><span>3</span><p lang="en-US">4</p>
          <ul><li>i</li><li>ii</li><li>iii</li></ul>
        </div>'''
              .html;
      String t(String sel) => doc.$(sel).map((e) => e.text).join(',');
      expect(t('#root > p'), '1,2,4');
      expect(t('div p.x'), '1');
      expect(t('p + p'), '2');
      expect(t('p ~ span'), '3');
      expect(t('p ~ p'), '2,4');
      expect(t('[lang|=en]'), '4');
      expect(t('[class~=b] > span'), '3');
      expect(t('li:first-child, li:last-child'), 'i,iii');
      expect(t('li:nth-child(2)'), 'ii');
      expect(t('li:nth-child(odd)'), 'i,iii');
      expect(t('li:not(:first-child)'), 'ii,iii');
      expect(t('div:has(span) > p:first-of-type'), '1');
      expect(t('P.x'), '1'); // type names are case-insensitive, class names are not
      expect(t('p.X'), '');
      expect(() => doc.$('p >'), throwsFormatException);
    });

    test('serialisation round-trips', () {
      const src = '<div class="a"><p>x &amp; y</p><br><img src="i.png"></div>';
      expect(src.html.body.innerHtml, src);
    });
  });
}
