// The in-house HTML parser and selector engine against package:html (a dev
// dependency kept for this test only): the same matches with the same tag,
// attributes and text, and the same document text, on the html_test
// fixtures plus real pages saved under test/fixtures/html.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/html.dart' as ours;
import 'package:dart_toolkit/src/dom.dart' as dom;
import 'package:dart_toolkit/src/html_parser.dart' as parser;
import 'package:dart_toolkit/src/selector.dart' as sel;
import 'package:html/dom.dart' as ref;
import 'package:html/parser.dart' as ref;
import 'package:test/test.dart';

/// Selectors both engines support (package:html has a narrow pseudo-class
/// set, and its `:nth-child`/`:empty` differ from the spec).
const selectors = [
  'a', 'p', 'div', 'span', 'li', 'img', 'table', 'tr', 'td', 'th', 'script', 'h1, h2, h3', //
  'tbody tr', 'table > tbody > tr', 'ul > li', 'div p', 'p a', 'nav a', 'form input', 'body > *', //
  'a[href]', 'a[href^="https"]', 'a[href*="wiki"]', 'img[src\$=".png"]', 'meta[property]', //
  'meta[name="description"]', 'link[rel~="stylesheet"]', '[lang|="en"]', 'li:first-child', //
  'li:last-child', 'td:only-child', 'span + span', 'h2 ~ p', 'div > span', 'b, i, strong, em', //
  'p:not(.x)', 'a:not([href])', '*', 'svg', 'select option', 'dl > dt', 'pre', 'code',
];

void main() {
  final pages = <String, String>{
    for (final f in Directory('test/fixtures/html').listSync().whereType<File>().where((f) => f.path.endsWith('.gz')))
      f.uri.pathSegments.last: utf8.decode(gzip.decode(f.readAsBytesSync()), allowMalformed: true),
    ...snippets,
  };

  test('the corpus holds at least 50 real pages', () {
    expect(pages.keys.where((k) => k.endsWith('.html.gz')).length, greaterThanOrEqualTo(50));
  });

  for (final MapEntry(key: name, value: html) in pages.entries) {
    test(name, () {
      final theirs = ref.parse(html);
      final reference = refText(theirs.documentElement!);
      if (html.trimLeft().toLowerCase().startsWith(RegExp('<!doctype|<html'))) {
        expect(ours.Html.parse(html).text(), reference, reason: 'document text through the facade');
      }
      final root = dom.Element('#root');
      parser.parseDocument(html).forEach(root.append);
      expect(myText(root.children.single), reference, reason: 'document text');
      for (final s in selectors) {
        final found = <dom.Element>[];
        sel.Selector.parse(s).collect(root, found);
        final a = [for (final e in found) sign(e.localName, e.attributes, myText(e))];
        final b = [for (final e in theirs.querySelectorAll(s)) sign(e.localName!, e.attributes, refText(e))];
        if (a.length != b.length) {
          fail('$s: ${a.length} matches, package:html ${b.length}; first difference:\n${firstDiff(a, b)}');
        }
        for (var k = 0; k < a.length; k++) {
          if (a[k] != b[k]) fail('$s #$k:\n  ours   ${a[k]}\n  theirs ${b[k]}');
        }
      }
    });
  }
}

String firstDiff(List<String> a, List<String> b) {
  for (var k = 0; k < a.length && k < b.length; k++) {
    if (a[k] != b[k]) return '  #$k ours   ${a[k]}\n  #$k theirs ${b[k]}';
  }
  return '  (one is a prefix of the other)';
}

String sign(String tag, Map<Object, String> attrs, String text) {
  final keys = attrs.keys.map((k) => '$k').toList()..sort();
  final flat = text.length > 120 ? '${text.substring(0, 120)}…' : text;
  return '<$tag ${[for (final k in keys) '$k=${attrs.entries.firstWhere((e) => '${e.key}' == k).value}'].join(' ')}> ${jsonEncode(flat)}';
}

/// html.dart's `text()` over our tree.
String myText(dom.Element root) => _text<dom.Node>(
  root,
  data: (n) => n is dom.Text ? n.data : null,
  tag: (n) => n is dom.Element ? n.localName : null,
  children: (n) => n is dom.Element ? n.nodes : const [],
);

/// html.dart's `text()` over package:html's tree.
String refText(ref.Element root) => _text<ref.Node>(
  root,
  data: (n) => n is ref.Text ? n.data : null,
  tag: (n) => n is ref.Element ? n.localName : null,
  children: (n) => n is ref.Element ? n.nodes : const [],
);

String _text<N>(
  N root, {
  required String? Function(N) data,
  required String? Function(N) tag,
  required List<N> Function(N) children,
}) {
  final out = StringBuffer();
  var gaps = 0;
  var gapNewline = false;
  void flushGap() {
    if (gaps > 0) {
      if (out.isNotEmpty) out.write(gapNewline ? '\n' : ' ');
      gaps = 0;
      gapNewline = false;
    }
  }

  void gap({required bool newline}) {
    gaps++;
    if (newline) gapNewline = true;
  }

  void push(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D) {
        gaps++;
        if (c == 0x0A || c == 0x0D) gapNewline = true;
      } else {
        flushGap();
        out.writeCharCode(c);
      }
    }
  }

  final stack = <(N?, bool)>[(root, tag(root) == 'pre')];
  while (stack.isNotEmpty) {
    final (node, pre) = stack.removeLast();
    if (node == null) {
      if (!pre && out.isNotEmpty) gap(newline: true);
      continue;
    }
    final text = data(node);
    final name = tag(node);
    if (text != null) {
      if (pre) {
        flushGap();
        out.write(text);
      } else {
        push(text);
      }
    } else if (name != null) {
      final tag = name;
      if (tag == 'script' || tag == 'style' || tag == 'noscript' || tag == 'template') continue;
      if (tag == 'br') {
        gap(newline: true);
        continue;
      }
      final isBlock = _blocks.contains(tag);
      if (isBlock && !pre && out.isNotEmpty) gap(newline: true);
      if ((tag == 'td' || tag == 'th') && !pre && out.isNotEmpty) gap(newline: false);
      final inner = pre || tag == 'pre';
      if (isBlock) stack.add((null, pre));
      final kids = children(node);
      for (var i = kids.length - 1; i >= 0; i--) {
        stack.add((kids[i], inner));
      }
    }
  }
  return out.toString();
}

const _blocks = {
  'address', 'article', 'aside', 'blockquote', 'details', 'dialog', 'div', 'dl', 'dd', 'dt', 'fieldset', //
  'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'hr', //
  'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'table', 'tbody', 'thead', 'tfoot', 'tr', 'ul',
};

/// Tricky markup the parsing algorithm has rules for, each as a document.
const snippets = {
  'misnested formatting': '<!doctype html><p><b>1<p>2</b>3</p><b><i>x</b>y</i>',
  'adoption agency': '<!doctype html><a href=1>a<div>b<a href=2>c</a>d</div>e</a><b>f<p>g</b>h',
  'tables': '<!doctype html><table><tr><td>a<td>b<tr><th>c</table><table>x<tr>y<td>z</table>',
  'foster parenting': '<!doctype html><table><b>bold<tr><td>cell</td></b>after</table>',
  'implied ends': '<!doctype html><ul><li>a<li>b<ul><li>c</ul></ul><dl><dt>t<dd>d<dt>u</dl><p>p<div>d</div>',
  'quirks table in p': '<p>before<table><tr><td>in</table>after',
  'select': '<!doctype html><select><option>a<option>b<optgroup><option>c</select><p>x',
  'raw text':
      '<!doctype html><title>a &amp; <b></title><textarea>\n<x>&lt;</textarea><script>if (a<b) "</div>"</script>',
  'entities': '<!doctype html><p>&amp &lt;&gt;&quot;&#39;&#x1F600;&#128;&notin;&notit;&copy2024 &unknown; &#0;</p><a href="?a=1&copy=2&b">x</a>',
  'svg and math': '<!doctype html><p><svg viewbox="0 0 1 1"><foreignobject><div>in</div></foreignobject><path/></svg><math><mi>x</mi></math>after',
  'head content': '<html><head><meta charset=utf-8><title>t</title><link rel=x></head>text<body>b',
  'body attributes': '<!doctype html><body class=a>x<body id=b>y</body></html>tail',
  'headings': '<!doctype html><h1>a<h2>b</h1>c<p>d</h3>e',
  'buttons and forms': '<!doctype html><form><button>a<button>b</form><form><input name=x></form>',
  'pre newline': '<!doctype html><pre>\nline</pre><pre>\n\nkeep</pre>',
  'comments and doctype': '<!-- c --><!doctype html><!--x--><p>a<!-- b -->c</p><!--->d<!-->e',
  'noscript and template': '<!doctype html><body><noscript><p>off</p></noscript><template><p>t</p></template>',
};
