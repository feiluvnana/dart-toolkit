// The in-house HTML, XML, XPath, CSS and YAML against the packages they replaced, on known
// divergences and seeded random documents.
// ignore_for_file: experimental_member_use
import 'dart:convert';
import 'dart:math';

import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/xml.dart';
import 'package:html/dom.dart' as hd;
import 'package:html/parser.dart' as hp;
import 'package:test/test.dart';
import 'package:xml/xml.dart' as xd;
import 'package:xml/xpath.dart';
import 'package:yaml/yaml.dart' as yd;

void main() {
  group('html tree matches package:html', () {
    const cases = [
      '<p>a<div>b</div>c',
      '<ul><li>a<li>b</ul>',
      '<table><tr><td>1<td>2<tr><td>3</table>',
      '<p>x &copy y &amp z &ampfoo &notit; &lang=en</p>',
      '<a href="?a=1&lang=en&copy=2&not=3&para=4&sect=5&image=6&sub=7&part=8">x</a>',
      '<a href=?a=1&amp;b=2>x</a>',
      '<p>&#0; &#128; &#x110000; &#65 &#x41; &#x9F;</p>',
      '<p>&AMP; &LT; &nbsp; &rsquo; &hellip;</p>',
      '<script>if (a < b && c > d) {"</div>"}</script><p>x',
      '<title>a &amp; <b>b</b></title>',
      '<textarea>\nline</textarea>',
      '<pre>\nfoo</pre>',
      '<div/>text',
      '<span/>after',
      '<a href=1>one<a href=2>two</a>',
      '<h1>a<h2>b</h2>',
      '<!--x-->a<!-- y -- z -->b',
      '<!-->hi',
      '<!--->hi',
      '<p>a<![CDATA[x<y]]>b</p>',
      '<select><option>a<option>b</select>',
      '<table><td>x</td></table>',
      '<table><caption>c<tr><td>x</table>',
      '<div class=a class=b ID=X>t</div>',
      '<img src="x.png" alt=\'a"b\'>',
      '<dl><dt>a<dd>b<dt>c</dl>',
      'a < b and c <3 d',
      '<svg><path d="M0"/><circle/></svg>',
      '<p>one<p>two',
      '<iframe><b>x</b></iframe>',
      '<a href="x"\nclass=y>z</a>',
      '<ruby>a<rt>b<rt>c</ruby>',
      '<head><title>t</title></head><p>x',
      '<html><body><p>x</body></html><p>after',
      '<meta charset=utf-8><p>x',
      '<div<p>x',
      '<a title="x>y">z</a>',
      '<li>a<ul><li>b</ul>c',
      '<p>x</P>y',
      '<SCRIPT>a</script >b',
      '<script>a</script\n>b',
      '<xmp><b></xmp>',
      '<textarea><b>&amp;</textarea>',
      '<svg viewBox="0 0 1 1" preserveAspectRatio=none><linearGradient gradientUnits=u/><clipPath/></svg>',
      '<svg><foreignObject width=1>x</foreignObject></svg><p>after',
      '<p>a</ p>b</>c',
      '<p>&lpar;1&rpar; &check; &star; &period;&colon;&NewLine;x</p>',
      // Not `<noscript>`: package:html reads it as raw text, ours as markup (`noscript img`).
    ];
    for (final c in cases) {
      test(c.replaceAll('\n', r'\n'), () => expect(_ours(c.html.root), _theirs(hp.parse(c).documentElement!)));
    }

    test('seeded random well-formed documents', () {
      final r = Random(7);
      for (var n = 0; n < 150; n++) {
        final src = _randomHtml(r);
        expect(_ours(src.html.root), _theirs(hp.parse(src).documentElement!), reason: src);
      }
    });
  });

  group('css matches package:html', () {
    const doc = '''<!doctype html><html><head><title>t</title></head><body>
<div id="main" class="a b" lang="en-US" data-x="Hello World">
 <ul class="list"><li class="item first">1</li><li class="item">2</li><li class="item" title="">3</li><li>4</li><li class="item last">5</li></ul>
 <p class="A">para <a href="https://x.com/a.pdf" rel="nofollow noopener">l1</a> <span>s</span> <a href="/b">l2</a></p>
 <section><h2>H</h2><p>one</p><p>two</p><div><p>three</p></div><span>x</span><p>four</p></section>
 <table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>
</div></body></html>''';
    final ours = doc.html;
    final theirs = hp.parse(doc);
    for (final s in [
      'li:not(.item)', 'li:first-child', 'li:last-child', 'span:only-child', '[title]', '[title=""]',
      '[class~="item"]', '[lang|=en]', r'[href$=".pdf"]', '[href^=https]', '[href*=x]', '[rel~=noopener]',
      'div#main > ul > li', 'h2 + p', 'h2 ~ p', 'section p', 'section > p', 'ul li.item.last', 'P.A', '.a.b',
      '#main .list li', 'li, p', 'html > body', 'a[href]:not([rel])', 'LI', 'section :first-child', //
    ]) {
      test(s, () => expect(ours.$(s).map(_ours).toList(), theirs.querySelectorAll(s).map(_theirs).toList()));
    }
  });

  group('xml tree and xpath match package:xml', () {
    for (final c in [
      '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY e "x">]><r a="1 &gt; 0" b=\'"\'>t&amp;&#x41;&#66;<![CDATA[<c>]]><!--c--><?pi x?></r>',
      '<r a="x>y">1</r>',
      '<r>a &unknown; b c</r>',
      '<r>  <a/>\n  <b></b> </r>',
      '<r xmlns:m="u"><m:a m:b="1"/></r>',
      '<r>AT&T; x</r>',
      '<r a="&#10;&#9;x"/>',
    ]) {
      test(c, () => expect(_ours(c.xml.root), _theirsXml(xd.XmlDocument.parse(c).rootElement)));
    }

    const src =
        '<root><div id="1"><a/><div id="2"><b/></div><c/></div>'
        '<book lang="en"><price>12</price><title>T1</title></book><book lang="fr"><price>8</price><title>T2</title></book>'
        '<ul><li>1</li><li>2</li><li>3</li><li>4</li></ul><m:x xmlns:m="u">mx</m:x></root>';
    final ours = src.xml;
    final theirs = xd.XmlDocument.parse(src);
    for (final e in [
      '//div/*', '//div/node()', '//div/descendant::*', '//*[@id]/*', '//book[price - 1 > 10]/title',
      '//li[position() mod 2 = 0]', '//li[position() * 2 = 4]', '//li[last()]', '//li[last() - 1]',
      '//li[position() > 1][1]', '//li[3]/preceding-sibling::li[1]', '//li[1]/following-sibling::li[2]',
      '//b/ancestor::div[1]', '//b/ancestor::*', '//title/following::title', '//li[4]/preceding::price',
      '//book[translate(@lang, "EN", "en")="en"]/title', '//book[substring(title, 2, 1)="2"]',
      '//book[sum(price) > 10]', '//li[number(.) div 2 = 1]', '//book/@lang', '//@*', '(//li)[2]',
      '(//li | //price)[last()]', '//li[. = "2"]/../li[1]', '//*[local-name()="x"]', '//m:x',
      '//li[not(position() = 1)]', '//book[title="T2" or price=12]/@lang', '//div[@id="1"]//*', '//ul/li[position()<3]',
      '//book[1]/price | //book[2]/title', '//book[starts-with(@lang,"f")]', '//li[string-length(.)=1][2]',
      '//div[.//b]', '//book[title][price]', '//*[count(*) = 4]', //
    ]) {
      test(e, () => expect([for (final n in ours.$x(e)) _node(n)], [for (final n in theirs.xpath(e)) _xmlNode(n)]));
    }
  });

  group('yaml matches package:yaml', () {
    const cases = [
      // A flow plain scalar holds spaces.
      't: [hello world, x]',
      'm: {msg: hi there, k: v}',
      'n: [a b c]',
      "a: [don't, x]\nb: 1",
      "a: [don't, 'q, r']\nb: 1",
      'a: |\n  line1\n\n  line2\n',
      'a: |\n\n  lead\n',
      'a: |2\n    indented\n  x\n',
      'a: |-\n  x\n\n\nb: 1',
      'a: |+\n  x\n\n\nb: 1',
      'a: >\n  one\n  two\n\n  three\n    more\n  four\n',
      '- |\n  a\n  b\n- c',
      '- |1\n  x\n',
      'x: &a 1\ny: *a',
      'x: &x 1\nl: [*x, 2]',
      'f: {a: 1, b: [1, 2]}',
      'f: ["[", x]\nnext: 1',
      'f: [\n  1,\n  2\n]\nz: 3',
      'k: [a: 1, b]',
      'k: {a, b: }',
      '--- 1\n--- 2\n',
      '--- foo\n--- bar\n',
      '%YAML 1.2\n---\na: 1\n',
      'a: 1\n---\nb: 2\n',
      'a: 1\n...\n',
      r's: "a\tb\u00e9\x41\U0001F600\b\e\N\_"',
      "s: 'it''s'",
      r's: "x \" # y"',
      's: "multi\n  line"',
      "s: 'multi\n  line'",
      'x: "a\\\n  b"',
      'n: [0o17, 0x1F, 017, .inf, -.Inf, 1e3, 1.5e-3, +12, 12345678901234567890, 0.1, -0, .5]',
      'b: [True, FALSE, ~, Null]',
      't: !!str 123',
      '-   a: 1\n    b: 2',
      '- - a\n  - b\n- c',
      'k: v # comment\n# full\nk2: "#notcomment"',
      'url: http://x.com/a#frag',
      'a:b: c',
      '"quoted key": 1\n\'single\': 2',
      'a:\n- 1\n- 2',
      'plain: multi\n  line\n\n  para',
      'text: >\n  a\n\n\n  b\n',
      'x: {a: [1, {b: 2}]}',
      'x: 1 # a: b',
      "x: 'a # b'",
    ];
    for (final c in [...cases, 'k${' ' * 300}: v', '- x${' ' * 300}y']) {
      test(jsonEncode(c), () {
        final theirs = [for (final d in yd.loadYamlStream(c)) _plain(d)];
        expect(_show([for (final d in Doc.parseAll(c, DocFormat.yaml)) d.raw]), _show(theirs));
      });
    }

    test('saved YAML reads back through both parsers, on seeded random values', () {
      final r = Random(11);
      for (var n = 0; n < 200; n++) {
        final v = _randomValue(r, 3);
        final y = Doc(v).encode(DocFormat.yaml);
        expect(_show(y.yaml.raw), _show(v), reason: y);
        expect(_show(_plain(yd.loadYaml(y))), _show(v), reason: y);
      }
    });
  });
}

// Normalised renderings, so two trees compare as strings.

String _attrs(Iterable<MapEntry<String, String>> a) =>
    (a.toList()..sort((x, y) => x.key.compareTo(y.key))).map((x) => ' ${x.key}="${x.value}"').join();

String _ours(Node n) => switch (n) {
  Text() => '"${n.data}"',
  Element() => '<${n.name}${_attrs(n.attributes.entries)}>${n.nodes.map(_ours).join()}</${n.name}>',
  _ => '',
};

/// Rendered children with adjacent texts merged: the references keep comments, and may leave
/// text split around one; ours drops comments.
String _merged(Iterable<String> children) {
  final parts = <String>[];
  for (final s in children) {
    if (s.isEmpty) continue;
    if (s.startsWith('"') && parts.isNotEmpty && parts.last.startsWith('"')) {
      parts.last = parts.last.substring(0, parts.last.length - 1) + s.substring(1);
    } else {
      parts.add(s);
    }
  }
  return parts.join();
}

String _theirs(hd.Node n) {
  if (n is hd.Text) return '"${n.data}"';
  if (n is! hd.Element) return '';
  final attrs = _attrs(n.attributes.entries.map((e) => MapEntry('${e.key}', e.value)));
  return '<${n.localName}$attrs>${_merged(n.nodes.map(_theirs))}</${n.localName}>';
}

String _theirsXml(xd.XmlNode n) {
  if (n is xd.XmlText || n is xd.XmlCDATA) return '"${n.value}"';
  if (n is! xd.XmlElement) return '';
  final attrs = _attrs(n.attributes.map((a) => MapEntry(a.name.qualified, a.value)));
  return '<${n.name.qualified}$attrs>${_merged(n.children.map(_theirsXml))}</${n.name.qualified}>';
}

String _node(Node n) => switch (n) {
  Element() => 'E:${n.name}:${n.text}',
  Attribute() => 'A:${n.name}=${n.value}',
  _ => 'T:${n.text}',
};

String _xmlNode(xd.XmlNode n) => switch (n) {
  xd.XmlElement() => 'E:${n.name.qualified}:${n.innerText}',
  xd.XmlAttribute() => 'A:${n.name.qualified}=${n.value}',
  _ => 'T:${n.value}',
};

Object? _plain(Object? v) => switch (v) {
  yd.YamlMap() => {for (final e in v.entries) '${e.key}': _plain(e.value)},
  yd.YamlList() => [for (final e in v) _plain(e)],
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

// Seeded generators.

const _texts = [
  'a',
  'b c',
  'x &amp; y',
  '&lt;tag&gt;',
  'q=1&lang=en',
  '&copy; 2026',
  'caf\u00e9',
  '&#65;&#x42;',
  ' ',
  '5 > 3',
];
const _values = ['x', '?a=1&lang=en', 'a&amp;b', '&copy=2', 'say "hi"', "it's", '', 'https://x.com/a:b#c'];

/// Well-formed markup nested only where HTML allows, so the parsers must agree node for node.

String _randomHtml(Random r) {
  const children = {
    'div': ['div', 'p', 'ul', 'span', 'table', 'a', 'h2'],
    'p': ['span', 'b', 'a'],
    'span': ['b', 'i'],
    'b': ['i'],
    'i': <String>[],
    'a': ['span', 'b'],
    'h2': ['span', 'a'],
    'ul': ['li'],
    'li': ['span', 'a', 'div'],
    'table': ['tbody'],
    'tbody': ['tr'],
    'tr': ['td'],
    'td': ['span', 'a', 'div'],
  };
  final sb = StringBuffer('<!doctype html><html><head><title>t</title></head><body>');
  void element(String name, int depth) {
    sb.write('<$name');
    if (r.nextInt(3) == 0) sb.write(' title="${_values[r.nextInt(_values.length)]}"');
    if (r.nextInt(4) == 0) sb.write(' class="c${r.nextInt(3)}"');
    sb.write('>');
    final kids = children[name]!;
    final count = depth > 4 ? 0 : r.nextInt(4);
    for (var k = 0; k < count; k++) {
      final text = name == 'ul' || name == 'table' || name == 'tbody' || name == 'tr' || kids.isEmpty || r.nextBool();
      if (text && name != 'ul' && name != 'table' && name != 'tbody' && name != 'tr') {
        sb.write(_texts[r.nextInt(_texts.length)]);
      } else if (kids.isNotEmpty) {
        element(kids[r.nextInt(kids.length)], depth + 1);
      }
    }
    sb.write('</$name>');
  }

  for (var k = 0; k < 3; k++) {
    element('div', 0);
  }
  sb.write('</body></html>');
  return sb.toString();
}

const _strings = [
  'plain',
  'a #b',
  'a:',
  'x: y',
  ' lead',
  'trail ',
  '- x',
  '12',
  '1e3',
  'true',
  'null',
  '~',
  '',
  "it's",
  'say "hi"',
  'multi\nline',
  '[x',
  '{y}',
  '*z',
  '&w',
  '!t',
  '%p',
  '@a',
  '`b',
  'a, b',
  'https://x.com/a:b#c',
];

Object? _randomValue(Random r, int depth) => switch (depth == 0 ? r.nextInt(5) : r.nextInt(7)) {
  0 => _strings[r.nextInt(_strings.length)],
  1 => r.nextInt(2000) - 1000,
  2 => r.nextBool(),
  3 => null,
  4 => (r.nextInt(1000) / 8) + 0.5,
  5 => [for (var k = r.nextInt(4); k > 0; k--) _randomValue(r, depth - 1)],
  _ => {for (var k = r.nextInt(4); k > 0; k--) _strings[r.nextInt(_strings.length)]: _randomValue(r, depth - 1)},
};
