// ignore_for_file: experimental_member_use
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:html/parser.dart' as reference;
import 'package:test/test.dart';
import 'package:xml/xml.dart' as reference;
import 'package:xml/xpath.dart';
import 'package:yaml/yaml.dart' as reference;

void main() {
  group('yaml', () {
    const doc = '''
# a pubspec-shaped document
name: dart_toolkit
version: 0.0.4
environment:
  sdk: ^3.10.0
dependencies:
  path: ^1.9.0
  empty:
flags: [fast, --verbose, 'quoted, comma']
matrix: {os: linux, count: 3, ok: true}
steps:
  - uses: actions/checkout@v4
  - name: Test
    run: |
      dart pub get
      dart test
    if: \${{ always() }}
  - [nested, list]
  -
    - deep
notes: >
  folded text
  on two lines
anchor: &base {a: 1, b: 2}
alias: *base
quoted: "line\\nbreak \\"q\\""
single: 'it''s'
numbers: [0x1F, 1e3, -.inf, .nan, 007, 1_000]
nulls: [~, null, ""]
url: https://example.com/a:b#c
time: 12:30:00
multi: this is one
  plain scalar
''';

    test('matches package:yaml on the whole document', () {
      final ours = doc.yaml.raw;
      final theirs = _plain(reference.loadYaml(doc));
      expect(_show(ours), equals(_show(theirs)));
    });

    test('the query API is the JSON one', () {
      final y = doc.yaml;
      expect(y['name'].to<String>(), 'dart_toolkit');
      expect(y.$(r'$.dependencies.*').length, 2);
      expect(y['steps'][1]['run'].to<String>(), 'dart pub get\ndart test\n');
      expect(y['notes'].to<String>(), 'folded text on two lines\n');
      expect(y['matrix']['count'].to<int>(), 3);
      expect(y['alias']['b'].to<int>(), 2);
      expect(y['numbers'].list.map((d) => d.raw).take(2).toList(), [31, 1000.0]);
      expect(y['nulls'].list.map((d) => d.raw).toList(), [null, null, '']); // "" is text, not null
      expect(y['url'].raw, 'https://example.com/a:b#c');
      expect(y['multi'].raw, 'this is one plain scalar');
    });

    test('several documents, empty input, bad indentation', () {
      final stream = '---\na: 1\n---\nb: 2\n'.yaml;
      expect(stream.raw, {'a': 1}, reason: 'a stream reads as its first document');
      expect(stream.documents.map((d) => d.raw), [
        {'a': 1},
        {'b': 2},
      ]);
      expect('- 1'.yaml.documents, hasLength(1), reason: 'a one-item list is not a stream');
      expect(''.yaml.raw, isNull);
      expect(''.yaml.documents, isEmpty);
      expect('- 1\n- 2'.yaml.raw, [1, 2]);
      expect(() => 'a:\n  b: 1\n c: 2'.yaml, throwsFormatException);
    });

    test('toYaml round-trips through both parsers', () {
      final out = doc.yaml.toYaml();
      expect(_show(out.yaml.raw), _show(doc.yaml.raw));
      expect(_show(_plain(reference.loadYaml(out))), _show(doc.yaml.raw));
      expect(
        '{"a": "yes", "b": "1", "c": "x: y", "d": [1, {"e": null}]}'.json.toYaml(),
        'a: yes\nb: "1"\nc: "x: y"\nd:\n  - 1\n  - e: null\n', // YAML 1.2: yes is text, so it stays plain
      );
    });
  });

  group('toml', () {
    const doc = '''
# comment
title = "TOML \\u00e9 example"
literal = 'C:\\path'
multi = """
line one
line two\\
  continued"""
raw = \'\'\'
keep \\n here\'\'\'
int = 1_000
hex = 0xff
float = -3.5e2
inf = inf
bools = [true, false]
date = 1979-05-27T07:32:00Z
arr = [
  1, 2,
  3,
]
inline = { x = 1, y = "two", z = { deep = true } }
dotted.key.path = 42

[server]
host = "localhost"
port = 8080

[server.tls]
enabled = false

[[items]]
name = "a"
[[items]]
name = "b"
''';

    test('decodes tables, arrays of tables, strings, numbers and inline tables', () {
      final t = doc.toml;
      expect(t['title'].raw, 'TOML é example');
      expect(t['literal'].raw, r'C:\path');
      expect(t['multi'].raw, 'line one\nline twocontinued');
      expect(t['raw'].raw, r'keep \n here');
      expect(r'k = "a\\b\"\t"'.toml['k'].raw, 'a\\b"\t');
      expect(t['int'].raw, 1000);
      expect(t['hex'].raw, 255);
      expect(t['float'].raw, -350.0);
      expect(t['inf'].raw, double.infinity);
      expect(t['bools'].raw, [true, false]);
      expect(t['date'].raw, '1979-05-27T07:32:00Z');
      expect(t['arr'].raw, [1, 2, 3]);
      expect(t['inline']['z']['deep'].raw, true);
      expect(t['dotted']['key']['path'].raw, 42);
      expect(t['server']['port'].to<int>(), 8080);
      expect(t['server']['tls']['enabled'].raw, false);
      expect(t.$(r'$.items[*].name').map((d) => d.raw).toList(), ['a', 'b']);
    });

    test('errors name the line', () {
      expect(
        () => 'a = 1\na = 2'.toml,
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('line 2'))),
      );
      expect(() => 'a = "open'.toml, throwsFormatException);
      expect(() => 'a = nope'.toml, throwsFormatException);
    });
  });

  group('ini', () {
    test('sections, comments, quotes, dotted keys, types', () {
      final i =
          '''
; global
debug = true
name = "Key Box" ; trailing
[server]
host: localhost
port = 8080
[server.tls]
enabled = no
cert = 'a;b'
'''
              .ini;
      expect(i['debug'].raw, true);
      expect(i['name'].raw, 'Key Box');
      expect(i['server']['host'].raw, 'localhost');
      expect(i['server']['port'].to<int>(), 8080);
      expect(i['server']['tls']['enabled'].raw, false);
      expect(i['server']['tls']['cert'].raw, 'a;b');
    });
  });

  group('table formats', () {
    final t = Table.rows([
      {'name': 'a|b', 'n': 1},
      {'name': 'c', 'n': 20},
    ]);

    test('tsv, ndjson and markdown round-trip or render', () {
      expect(Table.csv(t.toCsv(separator: '\t'), separator: '\t').rows, [
        {'name': 'a|b', 'n': '1'},
        {'name': 'c', 'n': '20'},
      ]);
      expect(t.toNdjson(), '{"name":"a|b","n":1}\n{"name":"c","n":20}\n');
      expect(Table.ndjson(t.toNdjson()).rows, t.rows);
      expect(t.toMarkdown(), '| name | n |\n| --- | ---: |\n| a\\|b | 1 |\n| c | 20 |\n');
    });
  });

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
        final a = [for (final e in ours.$(sel)) (e.name, e.attrOrNull('href'), e.text.trim())];
        final b = [for (final e in theirs.querySelectorAll(sel)) (e.localName, e.attributes['href'], e.text.trim())];
        expect(a, equals(b), reason: sel);
      }
    });
  }

  group('html', () {
    test('Element.lines decodes entities and splits at <br>', () {
      final doc = HtmlDocument.parse('<p id="x">A &amp; B &lt;c&gt;<br>D\nE<br></p>');
      expect(doc.$('#x').first.lines, equals(['A & B <c>', 'D', 'E']));
    });

    test('DOM mutations: remove, replaceWith, clear, append, prepend', () {
      final doc = '<div><p class="del">1</p><p id="target">2</p><span class="del">3</span></div>'.html;
      // Elements.remove()
      doc.$('.del').remove();
      expect(doc.$('div').text.trim(), '2');

      // replaceWith
      final target = doc.$('#target').first;
      final replacement = Element('p')..append(Text('new'));
      target.replaceWith(replacement);
      expect(doc.$('p').text, 'new');

      // append / prepend
      final div = doc.$('div').first;
      div.prepend(Element('header')..append(Text('Start')));
      div.append(Element('footer')..append(Text('End')));
      expect(div.children.map((e) => e.name).toList(), ['header', 'p', 'footer']);

      // clear
      div.clear();
      expect(div.nodes, isEmpty);
      expect(div.children, isEmpty);

      // Nodes.remove() on XPath
      final xmlDoc = '<root><a id="1"/><b>keep</b><a id="2"/></root>'.xml;
      xmlDoc.$x('//a').remove();
      expect(xmlDoc.$x('//*').map((n) => (n as Element).name).toList(), ['root', 'b']);
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
      expect('&lt;a&gt; &amp; &#65;&#x42; &nbsp;x &unknown; &amp'.html.text, '<a> & AB \u00a0x &unknown; &');
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
      expect(src.html.body.innerMarkup, src);
    });
  });

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

  test('every expression selects the same nodes as package:xml', () {
    final ours = XmlDocument.parse(feed);
    final theirs = reference.XmlDocument.parse(feed);
    for (final expr in expressions) {
      final a = [for (final n in ours.$x(expr)) _ours(n)];
      final b = [for (final n in theirs.xpath(expr)) _theirs(n)];
      expect(a, equals(b), reason: expr);
    }
  });

  test('node-set to number comparisons follow XPath 1.0 (package:xml does not)', () {
    final doc = XmlDocument.parse(feed);
    expect(doc.$x('//item[price>900]/title').texts, ['First <post>']);
    expect(doc.$x('//item[price<10]/title').texts, ['Third']);
    expect(doc.$x('//price[.>=800]/../title').texts, ['First <post>', '二番目']);
    expect(doc.$x('//item[number(price)>900]/title').texts, ['First <post>']);
    expect(doc.$x('//item[@id!="1"]/title').texts, ['二番目', 'Third']);
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
    expect('<DIV><P>hi</P></DIV>'.html.$('div p').text, 'hi');
  });

  test('the tree: names, prefixes, attributes, entities, CDATA, serialisation', () {
    final doc = XmlDocument.parse(feed);
    expect(doc.root.name, 'rss');
    expect(doc.root.attr('version'), '2.0');
    final creator = doc.$x('//dc:creator').elements.first;
    expect((creator.name, creator.prefix, creator.local), ('dc:creator', 'dc', 'creator'));
    expect(doc.$x('//channel/title').text, 'Key Sounds & more');
    expect(doc.$x('//item[1]/title').text, 'First <post>');
    expect(doc.$x('//description').text, 'Some <b>bold</b> text & more');
    expect(doc.$x('//media:content').attr('url'), 'https://cdn.example/1.mp3');
    expect(doc.$x('//item').$('title').map((n) => n.text), ['First <post>', '二番目', 'Third']);
    expect(doc.$x('//empty').elements.first.markup, '<empty/>');
    expect(XmlDocument.parse(doc.markup).$x('//item').length, 3);
    expect(() => XmlDocument.parse('just text'), throwsFormatException);
    expect(() => doc.$x('//item/'), throwsFormatException);
    expect(() => doc.$('count(//item)'), throwsFormatException);
  });

  test('XPath on HTML: \$x with attributes, text and axes, then back to CSS', () {
    final page =
        '''
      <table id="songs"><tr><th>Title</th><th>Format</th></tr>
      <tr><td><a href="/1">One</a></td><td>MP3</td></tr>
      <tr><td><a href="/2">Two</a></td><td>FLAC</td></tr></table>
      <h2>Notes</h2><p>first</p><p>second</p>'''
            .html;
    expect(page.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').text, '/2');
    expect(page.$x('//a/@href').texts, ['/1', '/2']);
    expect(page.$x('//h2/following-sibling::p[2]').text, 'second');
    expect(page.$x('//table[.//th="Title"]').elements.$('td:first-child a').map((a) => a.text), ['One', 'Two']);
    expect(page.$x('//td[a]').elements.$x('a/text()').texts, ['One', 'Two']);
    expect(page.$('tr').$x('td[2]').texts, ['MP3', 'FLAC']);
    expect(page.$x('//nothing').attrOrNull('href'), isNull);
    expect(() => page.$x('//nothing').text, throwsStateError);
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

  group('yaml block scalars', () {
    test('a literal block keeps its interior blank lines', () {
      expect('text: |\n  a\n\n  b\n'.yaml['text'].to<String>(), 'a\n\nb\n');
    });

    test('a folded block folds breaks but keeps spacing inside a line', () {
      expect('text: >\n  a  b\n'.yaml['text'].to<String>(), 'a  b\n');
      expect('text: >\n  one\n  two\n'.yaml['text'].to<String>(), 'one two\n');
      expect('text: >\n  one\n\n  two\n'.yaml['text'].to<String>(), 'one\ntwo\n');
    });

    test('chomping: strip, clip and keep', () {
      expect('t: |-\n  a\n'.yaml['t'].to<String>(), 'a');
      expect('t: |\n  a\n'.yaml['t'].to<String>(), 'a\n');
      expect('t: |+\n  a\n\n'.yaml['t'].to<String>(), 'a\n\n');
    });

    test('an apostrophe in a plain scalar does not swallow the comment', () {
      expect("name: don't # trailing\n".yaml['name'].to<String>(), "don't");
    });
  });

  group('table scoping', () {
    test('a row reports its own cells, not a nested table\'s', () {
      const html =
          '<table><tr><th>a</th><th>b</th></tr>'
          '<tr><td>1</td><td><table><tr><td>inner</td></tr></table></td></tr></table>';
      final t = html.html.$('table').table;
      expect(t.columns, ['a', 'b']);
      expect(t.rows.first.length, 2);
      expect(t.length, 1);
    });

    test('a stray </div> inside a <td> does not close the table', () {
      const html = '<table><tr><th>a</th></tr><tr><td>val</div></td></tr><tr><td>row2</td></tr></table>';
      final doc = html.html;
      expect(doc.$('table tr').length, 3);
      expect(doc.$('table').table.length, 2);
    });
  });

  group('positional pseudo-classes', () {
    test('nth-child and of-type over many siblings, and at a parentless root', () {
      final doc = '<ul>${'<li>x</li>' * 50}</ul>'.html;
      expect(doc.$('li:nth-child(2n)').length, 25);
      expect(doc.$('li:first-child').length, 1);
      expect(doc.$('li:last-child').length, 1);
      expect(doc.$('li:nth-last-child(1)').length, 1);
      expect(doc.$('li:first-of-type').length, 1);
      // The root is its document's only element child, as in a browser.
      expect(doc.$(':first-of-type').length, isNonNegative);
      expect(doc.$('html:first-child').single.name, 'html');
      expect(doc.$('*:only-child').first.name, 'html');
      expect(doc.$('html:nth-child(1)'), hasLength(1));
    });
  });

  group('a nested selector reads the markup around it', () {
    test('XML keeps its case inside :not() and :has()', () {
      final doc = '<Root><Item id="1"/><item id="2"/></Root>'.xml;
      expect(doc.$('Root > :not(Item)').attr('id'), '2', reason: 'the lowercase <item> is what is left');
      expect(doc.$('Root > :not(item)').attr('id'), '1');
      expect(doc.$('Root:has(item)'), hasLength(1));
      expect(doc.$('Root:has(ITEM)'), isEmpty, reason: 'there is no <ITEM>');
      expect(doc.$('Root:has(Item)'), hasLength(1));
    });

    test('HTML still folds inside them', () {
      final doc = '<div><P>a</P><span>b</span></div>'.html;
      expect(doc.$('div:has(P)'), hasLength(1));
      expect(doc.$('div > :not(P)').first.name, 'span');
    });

    test(':has() answers the same with a match at either end of a long subtree', () {
      final head = StringBuffer('<section><a>x</a>');
      final tail = StringBuffer('<section>');
      for (var i = 0; i < 200; i++) {
        head.write('<span>y</span>');
        tail.write('<span>y</span>');
      }
      expect('$head</section>'.html.$('section:has(a)'), hasLength(1));
      expect('$tail<a>x</a></section>'.html.$('section:has(a)'), hasLength(1));
      expect('$tail</section>'.html.$('section:has(a)'), isEmpty);
    });
  });

  group('XPath selects the same nodes in the same order', () {
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
  });

  group('html regressions', () {
    test('a query string keeps its ampersands; text decodes legacy names only', () {
      const href = '?a=1&lang=en&copy=2&not=3&para=4&sub=7&part=8';
      final doc = '<a href="$href">x &copy y &lang=en &notit; &#0;&#128;&#x110000;</a>'.html;
      expect(doc.$('a').attr('href'), href);
      expect(doc.$('a').first.markup.html.$('a').attr('href'), href, reason: 'and survives a round trip');
      expect(doc.$('a').text, 'x © y &lang=en ¬it; \u{fffd}€\u{fffd}');
      expect('<a href="?x&amp;y&copy;">'.html.$('a').attr('href'), '?x&y©');
    });

    test('noscript and template in head keep the rest of head there', () {
      final doc =
          '<head><meta charset=utf-8><noscript><img src=p></noscript><template><div>t</div></template>'
                  '<title>T</title><meta name=description content=d><link rel=canonical href=/c></head><p>x'
              .html;
      expect(doc.head.$('title').text, 'T');
      expect(doc.head.$('meta[name=description]').attr('content'), 'd');
      expect(doc.head.$('link[rel=canonical]').attr('href'), '/c');
      expect(doc.head.$('noscript img').attr('src'), 'p');
      expect(doc.body.$('p').text, 'x');
    });

    test('tag soup: links and headings do not nest, /> on a div is noise, leading newlines go', () {
      expect('<a href=1>one<a href=2>two'.html.$('a').texts, ['one', 'two']);
      expect('<h1>a<h2>b'.html.$('h1').text, 'a');
      expect('<div/>text'.html.$('div').text, 'text');
      expect('<svg><circle/><path/></svg>'.html.$('svg > *').length, 2, reason: '/> closes in SVG');
      expect('<pre>\nfoo</pre><textarea>\nbar</textarea>'.html.$('pre, textarea').texts, ['foo', 'bar']);
      expect('<!-->hi'.html.body.text, 'hi');
    });

    test('adjacent text and bare ampersands stay linear', () {
      expect(('<p>${'a < b ' * 20000}').html.$('p').text.length, 120000);
      expect(('<r>${'a & b ' * 20000}</r>').xml.text.length, 120000);
    });

    test('a hundred thousand nested elements read without overflowing', () {
      final doc = '${'<div>' * 100000}<span>x</span>'.html;
      expect(doc.text, 'x');
      expect(doc.$('span').text, 'x');
      expect(doc.$x('//span').text, 'x');
      expect(doc.markup.length, greaterThan(1100000));
    });

    test('Element.lines breaks at blocks and skips what is not read', () {
      final doc =
          '<div><p>a</p><p>b &amp; c</p><ul><li>d<li>e</ul><script>x()</script><style>p{}</style>'
                  '<noscript>n</noscript><template>t</template><h2>T</h2>f<br>g<table><tr><td>1<td>2</table></div>'
              .html;
      expect(doc.$('div').lines, ['a', 'b & c', 'd', 'e', 'T', 'f', 'g', '1\t2']);
    });

    test('a table: thead of td, duplicate headers, colspan and rowspan', () {
      final t =
          '<table><thead><tr><td>Name<td>Score<td>Score</thead>'
                  '<tr><td rowspan=2>a<td colspan=2>1<tr><td>2<td>3</table>'
              .html
              .$('table')
              .table;
      expect(t.columns, ['Name', 'Score', 'Score_2']);
      expect(t.rows.map((r) => r.values.toList()), [
        ['a', '1', '1'],
        ['a', '2', '3'],
      ]);
    });

    test('serialisation is markup, everywhere', () {
      const src = '<p class="a&amp;b">x &lt; y</p>';
      expect(src.html.body.innerMarkup, src);
      expect(src.html.markup, '<html><head></head><body>$src</body></html>');
      expect('<r><e/></r>'.xml.markup, '<?xml version="1.0" encoding="UTF-8"?><r><e/></r>');
    });
  });

  group('css regressions', () {
    final doc =
        '<ul><li title="">a</li><li title="x">b</li></ul><div class="md:flex" id="123">t</div>'
                '<section><h2>H</h2><p>1</p><p>2</p><div><img></div><span>s</span></section>'
                '<dl><dt>k</dt><dd>v</dd><dt>lonely</dt></dl>'
            .html;

    test('an empty substring or word matches nothing', () {
      for (final s in ['[title^=""]', '[title*=""]', r'[title$=""]', '[title~=""]', '[title~="a b"]']) {
        expect(doc.$(s), isEmpty, reason: s);
      }
      expect(doc.$('[title=""]').text, 'a');
    });

    test('escapes, :is, :where, :only-of-type, :nth-last-of-type', () {
      expect(doc.$(r'.md\:flex').text, 't');
      expect(doc.$(r'#\31 23').text, 't');
      expect(doc.$('[class="md\\:flex"]').text, 't');
      expect(doc.$(':is(h2, span)').texts, ['H', 's']);
      expect(doc.$('section > :where(p):nth-last-of-type(1)').text, '2');
      expect(doc.$('section > :only-of-type').map((e) => e.name), ['h2', 'div', 'span']);
    });

    test(':has takes a relative selector', () {
      expect(doc.$('section:has(> img)'), isEmpty);
      expect(doc.$('section:has(> div > img)'), hasLength(1));
      expect(doc.$('div:has(img)'), hasLength(1));
      expect(doc.$('dt:has(+ dd)').text, 'k');
      expect(doc.$('h2:has(~ span)').text, 'H');
      expect(doc.$('section:has(ul li)'), isEmpty, reason: 'the ul is outside the section');
    });

    test('nested descendant combinators do not backtrack exponentially', () {
      final deep = '${'<div>' * 200}<span>x</span>'.html;
      expect(deep.$('p div div div div div span'), isEmpty);
      expect(deep.$('div div div div div span'), hasLength(1));
    });
  });

  group('xpath 1.0', () {
    final doc =
        '<r><d id="1"><d id="2"><b/></d></d><ul><li>1</li><li>2</li><li>3</li><li>4</li></ul>'
                '<book><price>12</price><title>T1</title></book><book><price>8</price><title>T2</title></book></r>'
            .xml;
    List<String> x(String e) => doc.$x(e).texts;

    test('reverse axes count nearest first', () {
      expect(x('//li[3]/preceding-sibling::li[1]'), ['2']);
      expect(x('//li[3]/preceding-sibling::li[last()]'), ['1']);
      expect(doc.$x('//b/ancestor::d[1]').attr('id'), '2');
      expect(doc.$x('//b/ancestor::*').elements.map((e) => e.name), ['r', 'd', 'd'], reason: 'document order');
    });

    test('a child step over nested contexts comes back in document order', () {
      final nested = '<r><x><a/><x><b/></x><c/></x></r>'.xml;
      expect(nested.$x('//x/*').elements.map((e) => e.name), ['a', 'x', 'b', 'c']);
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

  group('yaml regressions', () {
    Object? y(String s) => s.yaml.raw;

    test('a flow mapping inside a sequence terminates; unterminated flow is a FormatException', () {
      expect(y('[a: 1]'), [
        {'a': 1},
      ]);
      expect(() => y('[a, b'), throwsFormatException);
      expect(y('f: ["[", x]\nnext: 1'), {
        'f': ['[', 'x'],
        'next': 1,
      });
      expect(y('x: &x 1\nl: [*x, 2]'), {
        'x': 1,
        'l': [1, 2],
      });
    });

    test('documents, directives, quotes, escapes, indentation', () {
      expect('--- foo\n--- bar\n'.yaml.documents.map((d) => d.raw), ['foo', 'bar']);
      expect(y('%YAML 1.2\n---\na: 1\n'), {'a': 1});
      expect(y(r's: "x \" # y"'), {'s': 'x " # y'});
      expect(y('s: "multi\n  line"'), {'s': 'multi line'});
      expect(y('x: "a\\\n  b"'), {'x': 'ab'});
      expect(y('-   a: 1\n    b: 2'), [
        {'a': 1, 'b': 2},
      ]);
      expect(y(r's: "\U0001F600\b\e\N\_"'), {'s': '😀\b\x1b\u0085 '});
      expect(y('t: !!str 123'), {'t': '123'});
      expect(y('n: 12345678901234567890'), {'n': 12345678901234567890.0});
      expect(y('k${' ' * 20000}: v'), isA<Map<String, Object?>>());
    });

    test('block scalars: indentation indicator, leading blanks, more-indented folds', () {
      expect(y('a: |2\n    x\n'), {'a': '  x\n'});
      expect(y('a: |\n\n  lead\n'), {'a': '\nlead\n'});
      expect(y('a: >\n  one\n  two\n\n  three\n    more\n  four\n'), {'a': 'one two\nthree\n  more\nfour\n'});
    });

    test('toYaml quotes what would not read back', () {
      for (final v in [
        {'k': 'a #b'},
        ['a:'],
        {'k': 'x: y'},
        {'k': ' lead'},
        {'k': '- x'},
      ]) {
        expect(JsonDocument(v).toYaml().yaml.raw, v);
      }
    });
  });

  group('toml, ini and json regressions', () {
    test('a TOML integer past 64 bits is an error with a line', () {
      expect(() => 'x = 12345678901234567890'.toml, throwsA(isA<FormatException>()));
    });

    test('INI keeps text that is not a number as written', () {
      final i = 'v = 1.10\nzip = 01234\nhex = 0x10\nn = NaN\nport = 8080\nf = 1.5\n[s] ; comment\nk = v'.ini;
      expect(i.raw, {
        'v': '1.10',
        'zip': '01234',
        'hex': '0x10',
        'n': 'NaN',
        'port': 8080,
        'f': 1.5,
        's': {'k': 'v'},
      });
      expect(() => 'a = 1\n[a]\nb = 2'.ini, throwsFormatException);
    });

    test('to<T>() is the value or a StateError that says where; toOrNull<T>() is null', () {
      final d = '{"tags":["a","b"],"n":1.7,"i":2.0,"s":"12","m":{"x":1,"y":2},"no":null}'.json;
      expect(d['tags'].to<List<String>>(), ['a', 'b']);
      expect(d['m'].to<Map<String, int>>(), {'x': 1, 'y': 2});
      expect(d['i'].to<int>(), 2);
      expect(d['s'].to<int>(), 12);
      expect(
        () => d['n'].to<int>(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', r'$.n is 1.7 (double), expected int')),
      );
      expect(
        () => d['tags'].to<List<int>>(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains(r'$.tags[0]'))),
      );
      expect(() => d['missing'].to<bool>(), throwsStateError);
      expect(d['n'].toOrNull<int>(), isNull);
      expect(d['no'].toOrNull<String>(), isNull);
      expect(d['no'].to<String?>(), isNull);
      expect(d['s'].toOrNull<int>(), 12);
    });

    test('JSONPath slices and unions; a filter is a FormatException', () {
      final d = '{"l":[0,1,2,3,4,5],"a":1,"x.y":2}'.json;
      List<Object?> q(String e) => [for (final v in d.$(e)) v.raw];
      expect(q(r'$.l[1:4]'), [1, 2, 3]);
      expect(q(r'$.l[::-2]'), [5, 3, 1]);
      expect(q(r'$.l[-2:]'), [4, 5]);
      expect(q(r'$.l[0,2]'), [0, 2]);
      expect(q(r"$['a','x.y']"), [1, 2]);
      expect(() => d.$(r'$.l[?(@ > 1)]'), throwsFormatException);
    });

    test('a NaN serialises as null', () {
      expect('a: .nan\nb: [.inf, 1]'.yaml.toString(), '{"a":null,"b":[null,1]}');
    });
  });

  group('every bad escape is a FormatException', () {
    test('TOML', () {
      for (final bad in [r'a = "\', r'a = "\u00', r'a = "\U40001F600"', r'a = "\uD800"', r'a = "\uZZZZ"']) {
        expect(
          () => bad.toml,
          throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('TOML line 1'))),
          reason: bad,
        );
      }
      expect(r'a = "\u00e9\U0001F600"'.toml['a'].raw, 'é😀');
    });

    test('YAML takes exactly the hex digits, and no sign', () {
      for (final bad in [r'a: "\u-00e"', r'a: "\UFFFFFFFF"', r'a: "\x+1z"', r'a: "\u12"']) {
        expect(
          () => bad.yaml,
          throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('YAML line 1'))),
          reason: bad,
        );
      }
      expect(r'a: "\x41\u00e9"'.yaml['a'].raw, 'Aé');
    });
  });

  group('TOML tables are defined once', () {
    test('an array of tables is only one [[a]] made', () {
      expect(() => 'a = [1]\n[[a]]'.toml, throwsFormatException);
      expect(() => 'a = 1\n[[a]]'.toml, throwsFormatException);
      expect('[[a]]\nx = 1\n[[a]]\nx = 2\n[a.b]\ny = 1'.toml.raw, {
        'a': [
          {'x': 1},
          {
            'x': 2,
            'b': {'y': 1},
          },
        ],
      });
    });

    test('redefining, and extending an inline table, are errors', () {
      for (final bad in [
        '[a]\n[a]',
        'a = {b = 1}\na.c = 2',
        'a.b = 1\n[a]',
        '[a.b]\nc = 1\n[a]\nb.d = 2',
        '[t]\nx = {y = 1}\n[t.x.z]',
      ]) {
        expect(() => bad.toml, throwsFormatException, reason: bad);
      }
      // A header's path may be defined by a later header, and a dotted table grown by one.
      expect('[a.b]\n[a]\nx = 1'.toml.raw, {
        'a': {'b': <String, Object?>{}, 'x': 1},
      });
      expect('[f]\napple.color = "r"\n[f.apple.texture]\ns = 1'.toml['f']['apple']['texture']['s'].raw, 1);
    });

    test('a date keeps its inner space and trailing spaces are not the value', () {
      expect('d = 1979-05-27 07:32:00Z   # c\nn = 1    '.toml.raw, {'d': '1979-05-27 07:32:00Z', 'n': 1});
    });
  });

  group('YAML', () {
    test('a duplicate key is an error, in block and flow', () {
      expect(
        () => 'a: 1\na: 2'.yaml,
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('"a" is defined twice'))),
      );
      expect(() => '{a: 1, a: 2}'.yaml, throwsFormatException);
    });

    test('an anchor before a key belongs to the key', () {
      expect('&a b: c\nd: *a'.yaml.raw, {'b': 'c', 'd': 'b'});
      expect('- &x k: v\n  j: w\n- *x'.yaml.raw, [
        {'k': 'v', 'j': 'w'},
        'k',
      ]);
    });

    test('text after a closing quote is an error', () {
      expect(() => 'a: "a" extra'.yaml, throwsFormatException);
      expect('a: "a" # comment'.yaml['a'].raw, 'a');
    });

    test('merge keys, one mapping or a list, with written keys winning', () {
      final d =
          '''
base: &b {x: 1, y: 2}
other: &o {y: 9, z: 3}
one:
  <<: *b
  y: 3
two:
  <<: [*b, *o]
  w: 0
flow: {<<: *o, z: 4}
'''
              .yaml;
      expect(d['one'].raw, {'x': 1, 'y': 3});
      expect(d['two'].raw, {'x': 1, 'y': 2, 'z': 3, 'w': 0});
      expect(d['flow'].raw, {'y': 9, 'z': 4});
      expect(() => 'a:\n  <<: 1'.yaml, throwsFormatException);
    });
  });

  group('nesting deeper than 1000 is a FormatException, not a stack overflow', () {
    test('YAML flow and block, TOML', () {
      for (final deep in [
        '${'[' * 1200}${']' * 1200}',
        '- ' * 20000,
        List.generate(1200, (i) => '${' ' * i}-').join('\n'),
      ]) {
        expect(
          () => deep.yaml,
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('nested deeper than 1000'))),
        );
      }
      expect(() => 'a = ${'[' * 1200}${']' * 1200}'.toml, throwsFormatException);
      expect('a = ${'[' * 900}${']' * 900}'.toml['a'].raw, isA<List<Object?>>());
    });

    test('JSONPath .. walks any depth jsonDecode reads, in document order', () {
      final deep = '${'{"a":' * 50000}1${'}' * 50000}'.json;
      expect(deep.$(r'$..a'), hasLength(50000));
      final d = '{"a":{"id":1,"b":[{"id":2},{"c":{"id":3}}]},"id":4}'.json;
      expect([for (final v in d.$(r'$..id')) v.raw], [4, 1, 2, 3]);
      expect(d.$(r'$..*'), hasLength(9));
    });
  });

  group('INI reads properties files', () {
    test('a key that cannot nest stays whole', () {
      expect('log4j.appender.A1=X\nlog4j.appender.A1.layout=Y'.ini.raw, {
        'log4j': {
          'appender': {'A1': 'X'},
        },
        'log4j.appender.A1.layout': 'Y',
      });
      expect('a.b.c = 2\na.b = 1'.ini.raw, {
        'a': {
          'b': {'c': 2},
        },
        'a.b': 1,
      });
    });

    test('a quoted part of a section name is one name', () {
      expect('["www.example.com"]\nk = v'.ini.raw, {
        'www.example.com': {'k': 'v'},
      });
      expect('[remote "a.b"]\nurl = x'.ini['remote']['a.b']['url'].raw, 'x');
      expect('[My Section]\nk = v'.ini['My Section']['k'].raw, 'v');
    });
  });

  group('HTML', () {
    test('attr is the value or a StateError naming it; attrOrNull expects absence', () {
      final doc = '<a href="/x">x</a><b>y</b>'.html;
      expect(doc.$('a').attr('href'), '/x');
      expect(
        () => doc.$('b').attr('href'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', '<b> has no href attribute')),
      );
      expect(() => doc.$('i').attr('href'), throwsStateError);
      expect(doc.$('b').attrOrNull('href'), isNull);
      expect(doc.$('i').attrOrNull('href'), isNull);
      expect(doc.$x('//a').attr('href'), '/x');
      expect(doc.$x('//i').attrOrNull('href'), isNull);
      expect(doc.$('a').first.attrOrNull('rel'), isNull);
    });

    test(':contains matches on text, quoted or not', () {
      final doc = '<table><tr><th>Name</th><td>a</td></tr><tr><th>Price</th><td>9</td></tr></table>'.html;
      expect(doc.$('th:contains(Price) + td').text, '9');
      expect(doc.$('th:contains("Name") + td').text, 'a');
      expect(doc.$('tr:contains(Nope)'), isEmpty);
    });

    test('SVG keeps its case, and a folded selector still finds it', () {
      final doc = '<svg viewBox="0 0 24 24"><foreignObject><b>x</b></foreignObject><clipPath id="c"/></svg>'.html;
      final svg = doc.$('svg').first;
      expect(svg.attr('viewBox'), '0 0 24 24');
      expect(svg.markup, startsWith('<svg viewBox="0 0 24 24"><foreignObject>'));
      expect(doc.$('[viewBox]'), hasLength(1));
      expect(doc.$('[viewbox="0 0 24 24"]'), hasLength(1));
      expect(doc.$('foreignObject b').text, 'x');
      expect(doc.$('clippath').single.id, 'c');
      expect(doc.$x('//svg/@viewBox').text, '0 0 24 24');
      // Outside <svg> nothing is recased.
      expect('<div viewBox=1>'.html.$('div').first.attributes.keys, ['viewbox']);
    });

    test('</ p> and </> are dropped, as a browser drops them', () {
      expect('<p>a</ p>b</>c</p>'.html.body.markup, '<body><p>abc</p></body>');
      expect('a</'.html.body.text, 'a</');
    });

    test('HTML 5 punctuation names decode', () {
      expect('<p>&lpar;1&rpar; &check; &star;&period;</p>'.html.$('p').text, '(1) ✓ ☆.');
    });

    test('nextElement and previousElement stay right after the tree changes', () {
      final ul = '<ul><li>1</li> <li>2</li><li>3</li></ul>'.html.$('ul').first;
      final items = ul.children.toList();
      expect(items[0].nextElement?.text, '2');
      expect(items[2].previousElement?.text, '2');
      ul.nodes.removeAt(0);
      expect(items[1].previousElement, isNull);
      expect(items[1].nextElement?.text, '3');
      final many = '<div>${'<i></i>' * 20000}</div>'.html.$('div').first;
      var n = 0;
      for (Element? e = many.children.first; e != null; e = e.nextElement) {
        n++;
      }
      expect(n, 20000);
    });
  });

  group('XML and XPath', () {
    test('a stray end tag is ignored, a mismatched one still closes', () {
      final doc = XmlDocument.parse('<r><a><b>x</c></b>${'</z>' * 1000}<d/></a></r>');
      expect(doc.root.$x('/r/a/b').text, 'x');
      expect(doc.root.$x('/r/a/d'), hasLength(1));
      expect(XmlDocument.parse('<r><a><b>x</a><c/></r>').root.$x('/r/c'), hasLength(1));
    });

    test('number() is XPath 1.0: no exponent, no sign but minus', () {
      final doc = '<p><i>1e2</i><i> -3.5 </i><i>+1</i><i>Infinity</i><i>.5</i></p>'.html;
      expect(doc.$x('//i[number(.) = number(.)]').texts, [' -3.5 ', '.5']);
      expect(doc.$x('//i[. > 0]').texts, ['.5']);
    });
  });

  group('JsonDocument.read', () {
    test('reads by extension', () async {
      final dir = await Directory.systemTemp.createTemp('fmt');
      addTearDown(() => dir.delete(recursive: true));
      Future<String> write(String name, String text) async =>
          (await File('${dir.path}/$name').writeAsString(text)).path;
      expect((await JsonDocument.read(await write('a.json', '{"x":1}')))['x'].raw, 1);
      expect((await JsonDocument.read(await write('a.YML', 'x: 2')))['x'].raw, 2);
      expect((await JsonDocument.read(await write('a.toml', 'x = 3')))['x'].raw, 3);
      expect((await JsonDocument.read(await write('a.conf', 'x = 4')))['x'].raw, 4);
      await expectLater(
        JsonDocument.read(await write('a.txt', 'x')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('".txt"'))),
      );
    });
  });

  group('audit formats regressions (FMT-2..14)', () {
    test('FMT-2: optgroup after optgroup does not nest', () {
      final doc = '<select><optgroup label="A"><option>1</option><optgroup label="B"><option>2</option></select>'.html;
      final groups = doc.$('select > optgroup');
      expect(groups, hasLength(2));
      expect(groups.first.attr('label'), 'A');
      expect(groups.last.attr('label'), 'B');
    });

    test('FMT-3: td/th directly in thead/tfoot gets implied tr for table', () {
      final doc =
          '<table><thead><th>Col A</th><th>Col B</th></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>'.html;
      final table = doc.root.table;
      expect(table.columns, ['Col A', 'Col B']);
      expect(table.rows, hasLength(1));
    });

    test('FMT-4: :scope in Element.\$ matches the element itself', () {
      final doc = '<div><ul id="u1"><li>1</li><li>2</li></ul><ul id="u2"><li>3</li></ul></div>'.html;
      final u1 = doc.$('#u1').first;
      expect(u1.$(':scope > li').texts, ['1', '2']);
    });

    test('FMT-5: XML serialization escapes < in attribute values and newlines/tabs', () {
      final xml = XmlDocument.parse('<root attr="a &lt; b&#10;&#9;c"/>');
      expect(xml.markup, contains('attr="a &lt; b&#10;&#9;c"'));
    });

    test('FMT-6: toYaml round-trips control chars, U+0085, --- and ...', () {
      for (final s in ['...', '---', '\x07bell', '\x85nel', '--- \nhello']) {
        final y = JsonDocument({'k': s});
        expect(y.toYaml().yaml['k'].raw, s);
      }
    });

    test('FMT-7: INI continuation lines append to key value', () {
      final ini =
          '''
[options]
install_requires =
    requests
    urllib3
'''
              .ini;
      expect(ini['options']['install_requires'].raw, 'requests\nurllib3');
    });

    test('FMT-8: INI table followed by scalar at same key throws FormatException', () {
      expect(() => 'a.b = 1\na = 2'.ini, throwsFormatException);
    });

    test('FMT-9: pre/textarea/listing preserves leading newline on re-parse and deep tables do not stack overflow', () {
      final doc = '<pre>\n\nfirst line\nsecond line</pre>'.html;
      expect(doc.$('pre').first.text, '\nfirst line\nsecond line');
      final serialized = doc.markup;
      final reparsed = serialized.html;
      expect(reparsed.$('pre').first.text, '\nfirst line\nsecond line');

      var html = '<table>';
      for (var i = 0; i < 500; i++) {
        html += '<div>';
      }
      html += '<tr><td>deep</td></tr>';
      for (var i = 0; i < 500; i++) {
        html += '</div>';
      }
      html += '</table>';
      expect(html.html.root.table.rows, hasLength(1));
    });

    test('FMT-10: YAML block scalar spaces, empty block, +.Inf, flow key raw text, ? error', () {
      final doc1 =
          '''
literal: |
  line 1  
  line 2  
folded: >
  line 1  
  line 2  
'''
              .yaml;
      expect(doc1['literal'].raw, 'line 1  \nline 2  \n');
      expect(doc1['folded'].raw, 'line 1 line 2\n');

      final emptyBlock = 'empty: |\nnext: 1'.yaml;
      expect(emptyBlock['empty'].raw, '');

      final inf = 'pos: +.Inf\npos_upper: +.INF'.yaml;
      expect(inf['pos'].raw, double.infinity);
      expect(inf['pos_upper'].raw, double.infinity);

      final flow = '{1.20: val}'.yaml;
      expect(flow.raw, {'1.20': 'val'});

      expect(() => '? a\n: 1'.yaml, throwsFormatException);
    });

    test('FMT-11: &lang; and &rang; decode to U+27E8 and U+27E9', () {
      final doc = '<p>&lang;math&rang;</p>'.html;
      expect(doc.$('p').first.text, '\u{27e8}math\u{27e9}');
    });

    test('FMT-12: XPath comparison involving booleans handles empty node-sets properly', () {
      final doc = '<root><item>val</item></root>'.html;
      expect(doc.$x('//item[missing = false()]'), hasLength(1));
      expect(doc.$x('//item[missing = true()]'), isEmpty);
      expect(doc.$x('//item[missing != true()]'), hasLength(1));
    });

    test('FMT-13: exhaustive switch over Node without default case', () {
      final Node node = '<div/>'.html.root;
      final kind = switch (node) {
        Element() => 'element',
        Text() => 'text',
        Attribute() => 'attribute',
      };
      expect(kind, 'element');
    });

    test('FMT-14: TOML arrays require commas between elements', () {
      expect(() => 'a = ["x" "y"]'.toml, throwsFormatException);
      expect(() => 'a = [1\n2]'.toml, throwsFormatException);
      expect('a = ["x", "y"]'.toml['a'].raw, ['x', 'y']);
    });
  });

  group('JsonDocument reading', () {
    test('an error names the path, however the value was reached', () {
      final doc = '{"a": [{"b c": "x"}], "items": [{"id": "q"}]}'.json;
      expect(
        () => doc['a'][0]['b c'].to<int>(),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', r'''$.a[0]['b c'] is "x" (String), expected int'''),
        ),
      );
      expect(
        () => doc.$(r'$..id').first.to<int>(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', startsWith(r'($..id)[0] is "q"'))),
      );
      expect(
        () => doc['items'].$(r'$[*].id').first.to<int>(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', startsWith(r'$.items($[*].id)[0] is'))),
      );
      expect(
        () => doc['items'].list.first.map['id']!.to<bool>(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', startsWith(r'$.items[0].id is'))),
      );
      expect(
        () => '{"m": {"k": "x"}}'.json['m'].to<Map<String, int>>(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', r'$.m.k is "x", expected int')),
      );
    });

    test('or is the default, typed by it', () {
      final ini = 'debug = true\nport = x\n'.ini;
      expect(ini['debug'].or(false), isTrue);
      expect(ini['missing'].or(false), isFalse);
      expect(ini['port'].or(8080), 8080);
      expect('{"n": "42"}'.json['n'].or(0), 42);
    });

    test('to<DateTime> reads ISO 8601 text', () {
      final doc = '{"t": "2026-10-01T12:30:00Z", "d": "2026-10-01", "bad": "soon"}'.json;
      expect(doc['t'].to<DateTime>(), DateTime.utc(2026, 10, 1, 12, 30));
      expect(doc['d'].to<DateTime>(), DateTime(2026, 10, 1));
      expect(doc['bad'].toOrNull<DateTime>(), isNull);
      expect(() => doc['bad'].to<DateTime>(), throwsStateError);
    });

    test('Doc.table reads CSV, TSV and JSON tables; a non-array JSON or a missing file throws', () async {
      final dir = await Directory.systemTemp.createTemp('tk_fmt');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/a.csv').writeAsStringSync('name,n\nx,1\ny,2\n');
      File('${dir.path}/b.tsv').writeAsStringSync('name\tn\nz\t3\n');
      File('${dir.path}/c.json').writeAsStringSync('[{"name": "w", "n": 4}]');
      File('${dir.path}/d.json').writeAsStringSync('{"not": "a list"}');

      final csv = await Doc.table('${dir.path}/a.csv');
      expect(csv.columns, ['name', 'n']);
      expect(csv.length, 2);
      expect((await Doc.table('${dir.path}/b.tsv')).rows.single.text('name'), 'z');
      expect((await Doc.table('${dir.path}/c.json')).rows.single.number('n'), 4);
      expect((await Doc.table('${dir.path}/a.csv', separator: ';')).columns, ['name,n']);
      await expectLater(Doc.table('${dir.path}/d.json'), throwsA(isA<FormatException>()));
      await expectLater(Doc.table('${dir.path}/missing.csv'), throwsA(isA<FileSystemException>()));
    });

    test('save writes JSON or YAML by extension, and read reads it back', () async {
      final dir = await Directory.systemTemp.createTemp('tk_fmt');
      addTearDown(() => dir.delete(recursive: true));
      final doc = '{"name": "x", "list": [1, 2.5, null], "nan": 1}'.json;
      final json = await doc.save('${dir.path}/a/b.json');
      expect(await json.readAsString(), '${const JsonEncoder.withIndent('  ').convert(doc.raw)}\n');
      expect((await JsonDocument.read(json.path)).raw, doc.raw);
      final yaml = await doc.save('${dir.path}/c.yml');
      expect(await yaml.readAsString(), doc.toYaml());
      expect((await JsonDocument.read(yaml.path)).raw, doc.raw);
      expect(
        () => doc.save('${dir.path}/c.toml'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('".toml"'))),
      );
      expect(await File('${dir.path}/c.toml').exists(), isFalse);
    });

    test('save replaces a file atomically, keeps an odd mode, and follows a link', () async {
      final dir = await Directory.systemTemp.createTemp('tk_fmt');
      addTearDown(() => dir.delete(recursive: true));
      final doc = '{"a": 1}'.json;
      final plain = File('${dir.path}/plain.json')..writeAsStringSync('old');
      final private = File('${dir.path}/private.json')..writeAsStringSync('old');
      await Process.run('chmod', ['600', private.path]);
      final link = Link('${dir.path}/link.json')..createSync(plain.path);

      await doc.save(plain.path);
      await doc.save(private.path);
      await doc.save(link.path);

      expect(plain.readAsStringSync(), '{\n  "a": 1\n}\n');
      expect(private.readAsStringSync(), '{\n  "a": 1\n}\n');
      expect(private.statSync().mode & 0x1ff, 0x180, reason: 'written in place: mode 600 stays');
      expect(FileSystemEntity.isLinkSync(link.path), isTrue, reason: 'the link still points at plain.json');
      expect(dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')), isEmpty);
    }, testOn: '!windows');

    test('in-place mutation with []= and remove()', () {
      final doc = '{"server": {"port": 8080, "tags": ["a", "b"]}}'.json;
      doc['server']['port'] = 9000;
      doc['server']['tags'][0] = 'first';
      doc['server']['ssl'] = true;
      expect(doc['server']['port'].raw, 9000);
      expect(doc['server']['tags'][0].raw, 'first');
      expect(doc['server']['ssl'].raw, true);

      final removed = doc['server'].remove('ssl');
      expect(removed, true);
      expect(doc['server']['ssl'].raw, isNull);

      final removedItem = doc['server']['tags'].remove(1);
      expect(removedItem, 'b');
      expect(doc['server']['tags'].list.length, 1);
    });
  });

  group('Elements, one hop closer', () {
    final doc =
        '<ul id="u"><li class="x"><a href="/a">A</a></li><li><a>B</a></li><li class="x"><a href="b">C</a></li></ul>'
            .html;

    test('attrs, markup and table', () {
      expect(doc.$('a').attrs('href'), ['/a', 'b']);
      expect(doc.$('nothing').attrs('href'), isEmpty);
      expect(doc.$('li.x').markup, '<li class="x"><a href="/a">A</a></li>');
      expect(() => doc.$('nothing').markup, throwsStateError);
      expect('<table><tr><th>k</th></tr><tr><td>v</td></tr></table>'.html.$('table').table.rows, [
        {'k': 'v'},
      ]);
    });

    test('a leading combinator reads from the element', () {
      final ul = doc.$('#u').first;
      expect(ul.$('> li.x').texts, ['A', 'C']);
      expect(ul.$('> a'), isEmpty);
      final first = doc.$('li').first;
      expect(first.$('+ li').texts, ['B']);
      expect(first.$('~ li').texts, ['B', 'C']);
      expect(first.$('~ li > a[href]').attrs('href'), ['b']);
      expect(first.$('> a, ~ li a').texts, ['A', 'B', 'C']);
      expect(doc.$('li').$('+ li').texts, ['B', 'C']);
      expect(doc.$('li.x').$('> a').texts, ['A', 'C']);
      // Without a combinator nothing changes: a descendant, with ancestors anywhere.
      expect(first.$('ul a').texts, ['A']);
    });

    test('links resolve against the address and the <base href>', () {
      const page = '<a href="/x?q=1">1</a><a href="y">2</a><a>none</a><img src="i.png"><a href="http://o/">3</a>';
      final url = Uri.parse('https://site.test/dir/page.html');
      expect(page.html.$('a, img').links.map((u) => '$u'), ['/x?q=1', 'y', 'i.png', 'http://o/']);
      expect(HtmlDocument.parse(page, url: url).$('a, img').links.map((u) => '$u'), [
        'https://site.test/x?q=1',
        'https://site.test/dir/y',
        'https://site.test/dir/i.png',
        'http://o/',
      ]);
      final based = HtmlDocument.parse('<head><base href="/other/"></head>$page', url: url);
      expect(based.base, Uri.parse('https://site.test/other/'));
      expect(based.$('a').links.take(2).map((u) => '$u'), ['https://site.test/x?q=1', 'https://site.test/other/y']);
      expect(
        '<base href="https://cdn.test/s/"><a href="y">'.html.$('a').links.single,
        Uri.parse('https://cdn.test/s/y'),
      );
      expect('<a href="http://[bad">'.html.$('a').links, isEmpty);
      expect(page.html.base, isNull);
      final res = Response('<a href="y">', 200, url: Uri.parse('https://site.test/d/p'));
      expect(res.html.$('a').links.single, Uri.parse('https://site.test/d/y'));
    });
  });

  group('XPath order with attributes', () {
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

  group('formats hunt regressions', () {
    test('XPath * never matches the document node', () {
      expect('<r><a/></r>'.xml.$x('/descendant-or-self::*').length, 2);
      expect('<r><a/></r>'.xml.$x('//*[count(/descendant-or-self::*) = 2]').length, 2);
    });

    test('a descendant step with a positional predicate from nested inputs is in document order', () {
      final d = '<r><c><c><b id="1"/></c><b id="2"/></c></r>'.xml;
      expect(d.$x('//c/descendant::b[last()]').elements.map((e) => e.id), ['1', '2']);
    });

    test('XPath compares booleans as numbers, writes numbers without exponents, checks arity', () {
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

    test('or() converts to the fallback\'s type even where T is Object', () {
      final ini = 'debug = maybe\nport = 80x\non = yes'.ini;
      final Map<String, Object> cfg = {
        'debug': ini['debug'].or(false),
        'port': ini['port'].or(8080),
        'on': ini['on'].or(false),
      };
      expect(cfg, {'debug': false, 'port': 8080, 'on': true});
      expect(JsonDocument(1.5).or<num>(5), 1.5);
    });

    test('a rowspan carried past a short row keeps its column', () {
      final h = '<table><tr><th>A<th>B<th>C<tr><td>a<td>b<td rowspan=2>c<tr><td>d<tr><td>e<td>f<td>g</table>';
      expect(h.html.$('table').table.rows, [
        {'A': 'a', 'B': 'b', 'C': 'c'},
        {'A': 'd', 'B': null, 'C': 'c'},
        {'A': 'e', 'B': 'f', 'C': 'g'},
      ]);
    });

    test('a raw-text end tag may carry a slash or attributes', () {
      for (final end in ['</script/>', '</script foo>', '</SCRIPT >']) {
        expect('<script>a$end<p>x</p>'.html.body.markup, '<body><p>x</p></body>');
      }
      expect('<script>a</scriptx>b</script><p>x</p>'.html.$('script').text, 'a</scriptx>b');
      expect('<title>t</title foo><p>x</p>'.html.$('title').text, 't');
    });

    test('to<int> refuses a double past int64; to<DateTime> wants a real ISO date', () {
      expect(JsonDocument(1e300).toOrNull<int>(), isNull);
      expect(JsonDocument(9223372036854775808.0).toOrNull<int>(), isNull);
      expect(() => JsonDocument(-1e19).to<int>(), throwsStateError);
      expect(JsonDocument(-9223372036854775808.0).to<int>(), -9223372036854775807 - 1);
      for (final bad in ['2024-02-30', '2023-02-29', '2024-13-45T25:61:61', '2024-01-01T24:00', '12345678']) {
        expect(JsonDocument(bad).toOrNull<DateTime>(), isNull, reason: bad);
      }
      expect(JsonDocument('2024-02-29 03:04').to<DateTime>(), DateTime(2024, 2, 29, 3, 4));
    });

    test('YAML: only a plain << merges, and toYaml quotes the key', () {
      final y = 'a: &a {x: 1}\nb:\n  "<<": *a\n  y: 2\nc: {"<<": 1}';
      expect(_plain(y.yaml.raw), _plain(reference.loadYaml(y)));
      expect(JsonDocument({'<<': 1}).toYaml(), '"<<": 1\n');
      expect(
        JsonDocument({
          '<<': {'a': 1},
        }).toYaml().yaml.raw,
        {
          '<<': {'a': 1},
        },
      );
    });

    test('YAML: an anchored or tagged value takes items at its key\'s indent', () {
      for (final y in ['a: &x\n- 1\n- 2\nb: *x', 'a: !!seq\n- 1\nb: 2', '- &x\n- 1']) {
        expect(_plain(y.yaml.raw), _plain(reference.loadYaml(y)), reason: y);
      }
    });

    test('INI: an indented [line] continues a value', () {
      expect('x =\n   [1, 2]\ny = 3'.ini.raw, {'x': '[1, 2]', 'y': 3});
    });

    test('a leading combinator on a document reads from its root', () {
      final d = '<ul><li>1<ul><li>a<li>b</ul><li>2</ul>'.html;
      expect(d.$('> body').single.name, 'body');
      expect('<r><a/><b><a/></b></r>'.xml.$('> a').length, 1);
      expect(d.$('ul').$('> li').map((e) => e.nodes.first.text), ['1', 'a', 'b', '2']);
      expect(d.$('ul').$x('li').elements.map((e) => e.nodes.first.text), ['1', 'a', 'b', '2']);
      expect(d.$('li').$x('following-sibling::li[1]').texts, ['b', '2']);
    });

    test('base, url, pre, lone CR, !!str and Windows paths', () {
      final u = Uri.parse('https://ex.com/dir/page.html');
      expect(HtmlDocument.parse('<p>hi</p><base href="/sub/"><a href="x">', url: u).$('a').links.single.path, '/sub/x');
      expect(
        HtmlDocument.parse('<base target=_blank><base href="/s2/"><a href="x">', url: u).$('a').links.single.path,
        '/s2/x',
      );
      final doc = HtmlDocument.parse('<a href="x">', url: u);
      HtmlDocument(doc.root, url: Uri.parse('https://other/'));
      expect(doc.$('a').links.single.host, 'ex.com');
      expect('<pre>&#10;x</pre>'.html.$('pre').text, reference.parse('<pre>&#10;x</pre>').querySelector('pre')!.text);
      expect('a: 1\rb: 2'.yaml.raw, {'a': 1, 'b': 2});
      expect('a=1\rb=2'.ini.raw, {'a': 1, 'b': 2});
      expect('a: !!str\nb: 1'.yaml.raw, {'a': '', 'b': 1});
      expect(
        JsonDocument.read(r'C:\cfg.d\settings'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('no extension'))),
      );
    });

    test('Elements and Nodes textOrNull and link helpers', () {
      final doc = HtmlDocument.parse(
        '<div><a href="/target">Click</a><p>Hello</p></div>',
        url: Uri.parse('https://example.com/base/'),
      );
      expect(doc.$('p').text, 'Hello');
      expect(doc.$('p').textOrNull, 'Hello');
      expect(doc.$('.missing').textOrNull, isNull);
      expect(() => doc.$('.missing').text, throwsStateError);

      expect(doc.$x('//p').text, 'Hello');
      expect(doc.$x('//p').textOrNull, 'Hello');
      expect(doc.$x('//missing').textOrNull, isNull);
      expect(() => doc.$x('//missing').text, throwsStateError);

      final a = doc.$('a').first;
      expect(a.link, Uri.parse('https://example.com/target'));
      expect(doc.$('a').link, Uri.parse('https://example.com/target'));
      expect(doc.$('p').link, isNull);
      expect(doc.$('.missing').link, isNull);
    });
  });
}

/// package:yaml's YamlMap/YamlList as plain Dart, for comparison.
Object? _plain(Object? v) => switch (v) {
  reference.YamlMap() => {for (final e in v.entries) '${e.key}': _plain(e.value)},
  reference.YamlList() => [for (final e in v) _plain(e)],
  Map() => {for (final e in v.entries) '${e.key}': _plain(e.value)},
  List() => [for (final e in v) _plain(e)],
  _ => v,
};

/// A stable rendering; NaN never equals itself, so it is spelled out.
String _show(Object? v) => switch (v) {
  Map() => '{${v.entries.map((e) => '${e.key}: ${_show(e.value)}').join(', ')}}',
  List() => '[${v.map(_show).join(', ')}]',
  double() when v.isNaN => 'NaN',
  String() => '"$v"',
  _ => '$v',
};

String _ours(Node n) => switch (n) {
  Element() => 'E:${n.name}:${n.text.trim()}',
  Attribute() => 'A:${n.name}=${n.value}',
  Text() => 'T:${n.data.trim()}',
};

String _theirs(reference.XmlNode n) => switch (n) {
  reference.XmlElement() => 'E:${n.name.qualified}:${n.innerText.trim()}',
  reference.XmlAttribute() => 'A:${n.name.qualified}=${n.value}',
  reference.XmlText() => 'T:${n.value.trim()}',
  reference.XmlCDATA() => 'T:${n.value.trim()}',
  _ => 'O:${n.runtimeType}',
};
