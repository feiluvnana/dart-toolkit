// ignore_for_file: experimental_member_use
import 'package:dart_toolkit/formats.dart';
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
