// ignore_for_file: experimental_member_use
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
      expect('---\na: 1\n---\nb: 2\n'.yaml.raw, [
        {'a': 1},
        {'b': 2},
      ]);
      expect(''.yaml.raw, isNull);
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
      expect(Table.tsv(t.toTsv()).rows, [
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
      final a = [for (final n in ours.$(expr)) _ours(n)];
      final b = [for (final n in theirs.xpath(expr)) _theirs(n)];
      expect(a, equals(b), reason: expr);
    }
  });

  test('node-set to number comparisons follow XPath 1.0 (package:xml does not)', () {
    final doc = XmlDocument.parse(feed);
    expect(doc.$('//item[price>900]/title').texts, ['First <post>']);
    expect(doc.$('//item[price<10]/title').texts, ['Third']);
    expect(doc.$('//price[.>=800]/../title').texts, ['First <post>', '二番目']);
    expect(doc.$('//item[number(price)>900]/title').texts, ['First <post>']);
    expect(doc.$('//item[@id!="1"]/title').texts, ['二番目', 'Third']);
  });

  test('the tree: names, prefixes, attributes, entities, CDATA, serialisation', () {
    final doc = XmlDocument.parse(feed);
    expect(doc.root.name, 'rss');
    expect(doc.root.attr('version'), '2.0');
    final creator = doc.$('//dc:creator').elements.first;
    expect((creator.name, creator.prefix, creator.local), ('dc:creator', 'dc', 'creator'));
    expect(doc.$('//channel/title').text, 'Key Sounds & more');
    expect(doc.$('//item[1]/title').text, 'First <post>');
    expect(doc.$('//description').text, 'Some <b>bold</b> text & more');
    expect(doc.$('//media:content').attr('url'), 'https://cdn.example/1.mp3');
    expect(doc.$('//item').$('title').map((n) => n.text), ['First <post>', '二番目', 'Third']);
    expect(doc.$('//empty').elements.first.outerXml, '<empty/>');
    expect(XmlDocument.parse(doc.outerXml).$('//item').length, 3);
    expect(() => XmlDocument.parse('just text'), throwsFormatException);
    expect(() => doc.$('//item/'), throwsFormatException);
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
    expect(page.$x('//nothing').attr('href'), isNull);
    expect(() => page.$x('//nothing').text, throwsStateError);
  });

  test('parsing is not slower than package:xml', () {
    final big = StringBuffer('<rss><channel>');
    for (var i = 0; i < 5000; i++) {
      big.write('<item id="$i"><title>Item $i &amp; co</title><price currency="JPY">${i * 3}</price></item>');
    }
    big.write('</channel></rss>');
    final src = big.toString();
    for (var i = 0; i < 2; i++) {
      XmlDocument.parse(src);
      reference.XmlDocument.parse(src);
    }
    final ours = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      XmlDocument.parse(src).$('//item[price>9000]/title');
    }
    ours.stop();
    final ref = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      reference.XmlDocument.parse(src).xpath('//item[price>9000]/title');
    }
    ref.stop();
    expect(
      ours.elapsedMicroseconds,
      lessThan(ref.elapsedMicroseconds * 1.5),
      reason: '${ours.elapsed} vs ${ref.elapsed}',
    );
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

String _ours(XmlNode n) => switch (n) {
  XmlElement() => 'E:${n.name}:${n.text.trim()}',
  XmlAttribute() => 'A:${n.name}=${n.value}',
  XmlText() => 'T:${n.data.trim()}',
  _ => 'O:${n.runtimeType}',
};

String _theirs(reference.XmlNode n) => switch (n) {
  reference.XmlElement() => 'E:${n.name.qualified}:${n.innerText.trim()}',
  reference.XmlAttribute() => 'A:${n.name.qualified}=${n.value}',
  reference.XmlText() => 'T:${n.value.trim()}',
  reference.XmlCDATA() => 'T:${n.value.trim()}',
  _ => 'O:${n.runtimeType}',
};
