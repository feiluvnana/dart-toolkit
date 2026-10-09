// ignore_for_file: experimental_member_use
import 'dart:io';

import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/src/message.dart' show Response;
import 'package:dart_toolkit/xml.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart' as reference;
import 'package:xml/xpath.dart';

void main() {
  const feed = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE rss [ <!ENTITY nbsp "&#160;"> ]>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Key Sounds &amp; more</title>
    <link>https://example.com/</link>
    <!-- a comment -->
    <item id="1" lang="en">
      <title>First &lt;post&gt;</title>
      <dc:creator>Jun</dc:creator>
      <price currency="JPY">1200</price>
      <media:content url="https://cdn.example/1.mp3" type="audio/mpeg"/>
      <description><![CDATA[Some <b>bold</b> text & more]]></description>
    </item>
    <item id="2" lang="ja">
      <title>二番目</title>
      <dc:creator>Shinji</dc:creator>
      <price currency="JPY">800</price>
      <media:content url="https://cdn.example/2.flac" type="audio/flac"/>
    </item>
    <item id="3">
      <title>Third</title>
      <price currency="USD">9.5</price>
      <empty/>
    </item>
  </channel>
</rss>''';

  const expressions = [
    '//item',
    '/rss/channel/item',
    '//item/title',
    '//item[1]/title',
    '//item[last()]/title',
    '//item[@lang]',
    "//item[@lang='ja']/title",
    '//item[@id="3"]/price',
    '//price[@currency="JPY"]',
    '//item[not(@lang)]/title',
    "//item[@lang='en' or @id='3']/title",
    '//dc:creator',
    '//media:content/@url',
    '//item/@id',
    '//*[@currency]',
    '//item/*',
    '//channel/*[1]',
    '//title/text()',
    '//item[position()<3]/title',
    '//item[title="Third"]',
    "//item[contains(title,'Third')]",
    "//item[starts-with(@id,'2')]/title",
    '//channel/title | //item/title',
    '//item//text()',
    '//price/..',
    '//item[2]/following-sibling::item',
    '//item[2]/preceding-sibling::item',
    '//description',
    '//item[count(media:content)=1]/@id',
    '/rss/@version',
    '//item[normalize-space(dc:creator)="Jun"]/@id',
    '//channel/descendant::title',
    '(//item)[2]/title',
    '//*[local-name()="content"]',
    '//item[string-length(title)>5]/@id',
  ];

  group('xml', () {
    test('a document knows its URL: parse(url:) and res.xml resolve links against it', () {
      final doc = Xml.parse('<feed><entry href="a/b.xml"/></feed>', url: Uri.parse('https://x.com/feed/'));
      expect(doc.$('entry').first.link, Uri.parse('https://x.com/feed/a/b.xml'));
      final res = Response('<urlset><url href="/p"/></urlset>', 200, url: Uri.parse('https://x.com/sitemap.xml'));
      expect(res.xml.$('url').first.link, Uri.parse('https://x.com/p'));
    });

    test('the tree: names, prefixes, attributes, entities, CDATA, serialisation', () {
      final doc = feed.xml;
      expect(doc.root.name, 'rss');
      expect(doc.root.attr('version'), '2.0');
      final creator = doc.$x('//dc:creator').first as Element;
      expect((creator.name, creator.prefix, creator.local), ('dc:creator', 'dc', 'creator'));
      expect(doc.$x('//channel/title').first.text, 'Key Sounds & more');
      expect(doc.$x('//item[1]/title').first.text, 'First <post>');
      expect(doc.$x('//description').first.text, 'Some <b>bold</b> text & more');
      expect(doc.$x('//media:content').attr('url'), 'https://cdn.example/1.mp3');
      expect(doc.$x('//item').$('title').map((n) => n.text), ['First <post>', '二番目', 'Third']);
      expect(doc.$x('//empty').first.markup, '<empty/>');
      expect(doc.encode().xml.$x('//item').length, 3);
      expect(() => 'just text'.xml, throwsFormatException);
      expect(() => doc.$x('//item/'), throwsFormatException);
      expect(() => doc.$('count(//item)'), throwsFormatException);
    });

    test('one tree, two markups: CSS folds for HTML and matches as written for XML', () {
      const mixed = '<r><Item id="1"><title>Upper</title></Item><item id="2"><title>lower</title><e/></item></r>';
      final doc = mixed.xml;

      // XML names are case-sensitive, so these are different elements.
      expect(doc.$('item').texts, ['lower']);
      expect(doc.$('Item').texts, ['Upper']);
      expect(doc.$('item[id="2"]').texts, ['lower']);

      // The same document answers XPath, and both queries return the shared node types.
      expect(doc.$x('//title').texts, ['Upper', 'lower']);
      expect(doc.$('title').first, isA<Element>());
      expect(doc.$x('//title').first, isA<Node>());

      // Serialisation follows the syntax the element was parsed from.
      expect(doc.$('e').first.markup, '<e/>');
      expect('<p>a<br>b'.html.$('p').first.markup, '<p>a<br>b</p>');

      // HTML still folds case.
      expect('<DIV><P>hi</P></DIV>'.html.$('div p').first.text, 'hi');
    });

    test('a stray end tag is ignored, a mismatched one still closes', () {
      final doc = '<r><a><b>x</c></b>${'</z>' * 1000}<d/></a></r>'.xml;
      expect(doc.root.$x('/r/a/b').first.text, 'x');
      expect(doc.root.$x('/r/a/d'), hasLength(1));
      expect('<r><a><b>x</a><c/></r>'.xml.root.$x('/r/c'), hasLength(1));
    });

    test('serialisation escapes <, a newline and a tab in an attribute value', () {
      final xml = '<root attr="a &lt; b&#10;&#9;c"/>'.xml;
      expect(xml.encode(), contains('attr="a &lt; b&#10;&#9;c"'));
    });

    test('a carriage return in text survives markup', () {
      final d = '<a>x&#13;y</a>'.xml;
      expect(d.encode().xml.$x('/a/text()').first.rawText, 'x\ry');
    });

    test('an element, an HTML and an XML document take \$ and \$x alike (FMT-27, FMT-28)', () {
      final html = '<ul><li>a</li><li>b</li></ul>'.html;
      final xml = '<ul><li>a</li><li>b</li></ul>'.xml;
      final trees = <(String, Selection<Element> Function(String), Selection<Node> Function(String), String)>[
        ('html', html.$, html.$x, html.text),
        ('xml', xml.$, xml.$x, xml.text),
        ('html element', html.$('ul').first.$, html.$('ul').first.$x, html.$('ul').first.text),
        ('xml element', xml.root.$, xml.root.$x, xml.root.text),
      ];
      for (final (name, css, xpath, text) in trees) {
        expect(xpath('//li').texts, ['a', 'b'], reason: name);
        expect(css('li').texts, ['a', 'b'], reason: name);
        expect(text, name.startsWith('html') ? 'a b' : 'ab', reason: 'HTML keeps blocks apart; XML has none');
      }
      expect(html.$x('li'), isEmpty, reason: 'relative from the root element, <html>');
      expect(xml.$x('li'), hasLength(2));
    });

    test(
      'Xml.read sniffs the declared encoding; save writes UTF-8 with a declaration; a body that is not XML names its URL (FMT-15, FMT-29)',
      () async {
        final dir = Directory.systemTemp.createTempSync('tk_xml_');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/feed.xml')
          ..writeAsBytesSync([
            ...'<?xml version="1.0" encoding="ISO-8859-1"?><t>caf'.codeUnits,
            0xe9,
            ...'</t>'.codeUnits,
          ]);
        final doc = await Xml.read(file.path);
        expect(doc.text, 'café');
        final saved = await doc.save('${dir.path}/out.xml');
        expect(File(saved).readAsStringSync(), '<?xml version="1.0" encoding="UTF-8"?>\n<t>café</t>\n');
        expect((await Xml.read(saved)).text, 'café');
        File('${dir.path}/empty.xml').writeAsStringSync('just text');
        await expectLater(
          Xml.read('${dir.path}/empty.xml'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Invalid XML in ${dir.path}/empty.xml: no document element',
            ),
          ),
        );
        final page = Response('<html>oops', 200, url: Uri.parse('https://x.test/feed'));
        expect(() => page.xml.root.name, returnsNormally, reason: 'markup that is XML enough still reads');
        final text = Response('not markup', 200, url: Uri.parse('https://x.test/feed'));
        expect(
          () => text.xml,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Invalid XML in https://x.test/feed: no document element',
            ),
          ),
        );
      },
    );
  });

  group('xpath', () {
    test('nesting past 256 is a FormatException, not a stack overflow; a run of minus signs is not nesting', () {
      final doc = '<r><li>1</li><li>2</li></r>'.xml;
      expect(doc.$x('${'(' * 200}//li${')' * 200}'), hasLength(2));
      expect(() => doc.$x('${'(' * 100000}//li${')' * 100000}'), throwsFormatException);
      expect(doc.$x('//li[${'-' * 100001}1 = -1]'), hasLength(2));
      expect(doc.$x('//li[${'-' * 100000}2 = 2]'), hasLength(2));
    });

    test('every expression selects the same nodes as package:xml', () {
      final ours = feed.xml;
      final theirs = reference.XmlDocument.parse(feed);
      for (final expr in expressions) {
        final a = [for (final n in ours.$x(expr)) _ours(n)];
        final b = [for (final n in theirs.xpath(expr)) _theirs(n)];
        expect(a, equals(b), reason: expr);
      }
    });

    test('node-set to number comparisons follow XPath 1.0 (package:xml does not)', () {
      final doc = feed.xml;
      expect(doc.$x('//item[price>900]/title').texts, ['First <post>']);
      expect(doc.$x('//item[price<10]/title').texts, ['Third']);
      expect(doc.$x('//price[.>=800]/../title').texts, ['First <post>', '二番目']);
      expect(doc.$x('//item[number(price)>900]/title').texts, ['First <post>']);
      expect(doc.$x('//item[@id!="1"]/title').texts, ['二番目', 'Third']);
    });

    test('XPath on HTML: \$x with attributes, text and axes, then back to CSS', () {
      final page =
          '''
      <table id="songs"><tr><th>Title</th><th>Format</th></tr>
      <tr><td><a href="/1">One</a></td><td>MP3</td></tr>
      <tr><td><a href="/2">Two</a></td><td>FLAC</td></tr></table>
      <h2>Notes</h2><p>first</p><p>second</p>'''
              .html;
      expect(page.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').first.text, '/2');
      expect(page.$x('//a/@href').texts, ['/1', '/2']);
      expect(page.$x('//h2/following-sibling::p[2]').first.text, 'second');
      expect(page.$x('//table[.//th="Title"]').$('td:first-child a').map((a) => a.text), ['One', 'Two']);
      expect(page.$x('//td[a]').$x('a/text()').texts, ['One', 'Two']);
      expect(page.$('tr').$x('td[2]').texts, ['MP3', 'FLAC']);
      expect((() => page.$x('//nothing').attr('href')).orNull, isNull);
      expect(() => page.$x('//nothing').first.text, throwsA(isA<MissingException>()));
    });

    test('number() is XPath 1.0: no exponent, no sign but minus', () {
      final doc = '<p><i>1e2</i><i> -3.5 </i><i>+1</i><i>Infinity</i><i>.5</i></p>'.html;
      expect(doc.$x('//i[number(.) = number(.)]').texts, ['-3.5', '.5']);
      expect(doc.$x('//i[. > 0]').texts, ['.5']);
    });

    test('a comparison with a boolean reads an empty node-set as false', () {
      final doc = '<root><item>val</item></root>'.html;
      expect(doc.$x('//item[missing = false()]'), hasLength(1));
      expect(doc.$x('//item[missing = true()]'), isEmpty);
      expect(doc.$x('//item[missing != true()]'), hasLength(1));
    });

    test('booleans compare as numbers, numbers print without exponents, and arity is checked', () {
      final r = '<r/>'.xml;
      expect(r.$x('/r[true() > false()]').length, 1);
      expect(r.$x('/r[true() < 2]').length, 1);
      expect(r.$x('/r[string(1000000000000000) = "1000000000000000"]').length, 1);
      expect(r.$x('/r[string(0.0000001) = "0.0000001"]').length, 1);
      expect(r.$x('/r[string(-0.00000015) = "-0.00000015"]').length, 1);
      expect(() => r.$x('/r[contains("abc")]'), throwsFormatException);
      expect(() => r.$x('/r[count()]'), throwsFormatException);
      expect(() => r.$x('/r[true(1)]'), throwsFormatException);
    });

    test('* never matches the document node', () {
      expect('<r><a/></r>'.xml.$x('/descendant-or-self::*').length, 2);
      expect('<r><a/></r>'.xml.$x('//*[count(/descendant-or-self::*) = 2]').length, 2);
    });

    test("name() of the document is empty, as XPath 1.0 has it", () {
      expect('<r><a/></r>'.xml.$x('/*[name(/) = ""]').length, 1);
    });

    group('axes, arithmetic and functions', () {
      final doc =
          '<r><d id="1"><d id="2"><b/></d></d><ul><li>1</li><li>2</li><li>3</li><li>4</li></ul>'
                  '<book><price>12</price><title>T1</title></book><book><price>8</price><title>T2</title></book></r>'
              .xml;

      List<String> x(String e) => doc.$x(e).texts;

      test('reverse axes count nearest first', () {
        expect(x('//li[3]/preceding-sibling::li[1]'), ['2']);
        expect(x('//li[3]/preceding-sibling::li[last()]'), ['1']);
        expect(doc.$x('//b/ancestor::d[1]').attr('id'), '2');
        expect(doc.$x('//b/ancestor::*').map((e) => (e as Element).name), ['r', 'd', 'd'], reason: 'document order');
      });

      test('arithmetic, the rest of the function library, following and preceding', () {
        expect(x('//li[position() mod 2 = 0]'), ['2', '4']);
        expect(x('//li[position() * 2 = 4]'), ['2']);
        expect(x('//li[. div 2 = 2]'), ['4']);
        expect(x('//book[price - 1 > 10]/title'), ['T1']);
        expect(x('//book[price -1 > 10]/title'), ['T1']);
        expect(x('//li[last() - 1]'), ['3']);
        expect(x('//book[translate(title, "T", "t") = "t2"]/price'), ['8']);
        expect(x('//book[substring(title, 2, 1) = "2"]/price'), ['8']);
        expect(x('//book[round(price div 3) = 4]/title'), ['T1']);
        expect(x('//book[floor(price div 5) = 1 and ceiling(price div 5) = 2]/title'), ['T2']);
        expect(x('//ul[sum(li) = 10]/li[1]'), ['1']);
        expect(x('//title[1]/following::title'), ['T2']);
        expect(x('//li[4]/preceding::li[1]'), ['3']);
        expect(x('//price[.="8"]/preceding::price'), ['12']);
      });

      test('boolean node-set predicates and non-positional // predicates', () {
        expect(x('//d[.//b]/@id'), ['1', '2']);
        expect(x('//book[title]/price'), ['12', '8']);
        expect(x('//li[. > 2][1]'), ['3']);
        expect(x('(//li)[last()]'), ['4']);
      });
    });

    group('node identity and ordering', () {
      final doc = '<html><body><a href="/one">1</a><img src="/two"><a href="/three">3</a></body></html>'.html;

      test('a union of attribute sets comes back in document order, each node once', () {
        expect(doc.$x('//a/@href | //img/@src').texts, ['/one', '/two', '/three']);
        expect(doc.$x('//a/@href | //a/@href').texts, ['/one', '/three']);
      });

      test('an attribute node equals the same attribute on the same element', () {
        final first = doc.$x('//a/@href').first;
        final again = doc.$x('//a/@href').first;
        expect(first, again);
        expect({first, again}.length, 1);
      });
    });

    group('document order', () {
      List<Node> inOrder(Element root) {
        final out = <Node>[];
        void go(Node n) {
          out.add(n);
          if (n is Element) {
            for (final c in n.nodes) {
              go(c);
            }
          }
        }

        go(root);
        return out;
      }

      const markup =
          '<html><body>'
          '<div id="a"><p>one</p><span>two</span><div id="b"><p>three</p><a href="x">l</a></div></div>'
          '<ul><li>1</li><li>2</li><li>3</li><li>4</li></ul>'
          '<table><tr><th>H</th></tr><tr><td>c1</td><td>c2</td></tr></table>'
          '</body></html>';

      test('// is document order, whatever the axis underneath', () {
        final doc = markup.html;
        final order = {for (final (i, n) in inOrder(doc.root).indexed) n: i};
        for (final expression in [
          '//p',
          '//div//p',
          '//div/p',
          '//li',
          '//*',
          '//div//*',
          '//body/*',
          '//li/following-sibling::li',
          '//li/preceding-sibling::li',
          '//td | //th',
          '//p/ancestor::div',
          '//span/preceding-sibling::p',
          'descendant::p',
        ]) {
          final positions = [for (final n in doc.$x(expression)) order[n] ?? -1];
          expect(positions, orderedEquals([...positions]..sort()), reason: expression);
        }
      });

      test('a positional predicate still counts per parent, not per document', () {
        final doc = markup.html;
        expect(doc.$x('//li[1]').texts, ['1']);
        expect(doc.$x('//li[last()]').texts, ['4']);
        expect(doc.$x('//tr/td[2]').texts, ['c2']);
        expect(doc.$x('(//li)[2]').texts, ['2'], reason: 'a filter counts over the whole set');
        expect(doc.$x('//ul/li[position()>2]').texts, ['3', '4']);
        expect(doc.$x('//p[1]').texts, ['one', 'three'], reason: 'one per parent, not the first in the document');
      });

      test('a sibling axis with a pinned position takes only what it needs', () {
        final wide = StringBuffer('<ul>');
        for (var i = 0; i < 400; i++) {
          wide.write('<li>$i</li>');
        }
        final doc = '$wide</ul>'.html;
        expect(doc.$x('//li[1]/following-sibling::li[1]').texts, ['1']);
        expect(doc.$x('//li[1]/following-sibling::li[3]').texts, ['3']);
        expect(doc.$x('//li[1]/following-sibling::li[999]'), isEmpty);
        expect(doc.$x('//li/following-sibling::li'), hasLength(399), reason: 'unpinned still returns them all');
      });

      test('a child step over nested contexts comes back in document order', () {
        final nested = '<r><x><a/><x><b/></x><c/></x></r>'.xml;
        expect(nested.$x('//x/*').map((e) => (e as Element).name), ['a', 'x', 'b', 'c']);
      });

      test('a descendant step with a positional predicate from nested inputs is in document order', () {
        final d = '<r><c><c><b id="1"/></c><b id="2"/></c></r>'.xml;
        expect(d.$x('//c/descendant::b[last()]').map((e) => (e as Element).id), ['1', '2']);
      });

      test('an attribute sorts after its element and before its content, as written', () {
        final doc = '<r><e b="1" a="2"><c/></e><f a="3"/></r>'.xml;
        final nodes = doc.$x('//c | //@a | //e | //@b');
        expect(nodes.map((n) => n is Attribute ? '@${n.name}=${n.value}' : (n as Element).name), [
          'e',
          '@b=1',
          '@a=2',
          'c',
          '@a=3',
        ]);
        expect(doc.$x('//*[@a]').length, 2);
        expect(doc.$x('//e/@*').texts, ['1', '2']);
      });
    });
  });
}

String _ours(Node n) => switch (n) {
  Element() => 'E:${n.name}:${n.text.trim()}',
  Attribute() => 'A:${n.name}=${n.value}',
  Text() => 'T:${n.data.trim()}',
};

String _theirs(reference.XmlNode n) => switch (n) {
  reference.XmlElement() => 'E:${n.name.qualified}:${_read(n.innerText)}',
  reference.XmlAttribute() => 'A:${n.name.qualified}=${n.value}',
  reference.XmlText() => 'T:${n.value.trim()}',
  reference.XmlCDATA() => 'T:${n.value.trim()}',
  _ => 'O:${n.runtimeType}',
};

/// [text] as a reader sees it, as `Element.text` reads: runs of ASCII whitespace and no-break
/// spaces one space, trimmed; an ideographic space is text.
String _read(String text) => text.replaceAll(RegExp(r'[ \t\n\r\f\v\u00a0]+'), ' ').trim();
