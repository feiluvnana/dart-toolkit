// ignore_for_file: experimental_member_use
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/src/message.dart' show Response;
import 'package:dart_toolkit/xml.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as reference;
import 'package:test/test.dart';

void main() {
  group('typed queries', () {
    test('Css and XPath are checked when made and go where a query does', () {
      final page = Html.parse('<p><a href="/x">one</a></p>');
      expect(page.$('p a'.css).texts, ['one']);
      expect(page.$x('//a/@href'.xpath).length, 1);
      expect(() => 'p >'.css, throwsFormatException);
      expect(() => Css('a[href'), throwsFormatException);
      expect(() => '//a['.xpath, throwsFormatException);
      expect(XPath('//a'), '//a');
    });
  });

  group('html parser', () {
    const selectors = [
      'a',
      'a[href]',
      'div',
      'p',
      'li',
      'tr',
      'td',
      'table tr',
      'ul > li',
      'ol > li',
      'h1, h2, h3',
      'img[src]',
      'span', //
      'tr > td', 'body > div', 'head > title', 'meta[name]', 'a[href^="http"]', 'li:first-child', 'div > p', 'table',
      'tbody > tr', 'form input', 'select option', 'script', 'style', 'p + p', 'h2 ~ p', 'a:not([href])',
      '.key_cd_track_box ul li', '.track_disc_title', '.track_disc_text_style1', '.key_cd_artworks_box',
      'tr.athing', '.titleline > a', 'td.subtext', '.site-header a', 'nav a[href]',
    ];

    for (final name in ['key_box', 'hn', 'dart_dev']) {
      test('$name.html parses like the reference', () {
        final src = File('test/fixtures/$name.html').readAsStringSync();
        final ours = Html.parse(src);
        final theirs = reference.parse(src);
        for (final sel in selectors) {
          final a = [for (final e in ours.$(sel)) (e.name, (() => e.attr('href')).orNull, e.text.trim())];
          final b = [for (final e in theirs.querySelectorAll(sel)) (e.localName, e.attributes['href'], _visible(e))];
          expect(a, equals(b), reason: sel);
        }
      });
    }

    test('tag soup lands where a browser puts it', () {
      final doc = '<p>one<p>two<ul><li>a<li>b</ul><table><tr><td>1<td>2</table>'.html;
      expect(doc.$('p').map((p) => p.text), ['one', 'two']);
      expect(doc.$('ul > li').map((li) => li.text), ['a', 'b']);
      expect(doc.$('table > tbody > tr > td').map((td) => td.text), ['1', '2']);
      expect(doc.body.children.map((e) => e.name), ['p', 'p', 'ul', 'table']);
    });

    test('head and body are synthesised, title is in head, script text is raw', () {
      final doc = '<title>T &amp; U</title><script>if (a < b) {}</script><div>x</div>'.html;
      expect(doc.head.$('title').first.text, 'T & U');
      expect(doc.head.$('script').first.text, 'if (a < b) {}');
      expect(doc.body.$('div').first.text, 'x');
    });

    test('attributes: quoted, unquoted, valueless, duplicated, case', () {
      final a = '<A HREF=/x Data-Id="7" disabled title=\'q "t"\' href="/dup">'.html.$('a').first;
      expect(a.attributes, {'href': '/x', 'data-id': '7', 'disabled': '', 'title': 'q "t"'});
    });

    test('noscript and template in head keep the rest of head there', () {
      final doc =
          '<head><meta charset=utf-8><noscript><img src=p></noscript><template><div>t</div></template>'
                  '<title>T</title><meta name=description content=d><link rel=canonical href=/c></head><p>x'
              .html;
      expect(doc.head.$('title').first.text, 'T');
      expect(doc.head.$('meta[name=description]').first.attr('content'), 'd');
      expect(doc.head.$('link[rel=canonical]').first.attr('href'), '/c');
      expect(doc.head.$('noscript img').first.attr('src'), 'p');
      expect(doc.body.$('p').first.text, 'x');
    });

    test('tag soup: links and headings do not nest, /> on a div is noise, leading newlines go', () {
      expect('<a href=1>one<a href=2>two'.html.$('a').texts, ['one', 'two']);
      expect('<h1>a<h2>b'.html.$('h1').first.text, 'a');
      expect('<div/>text'.html.$('div').first.text, 'text');
      expect('<svg><circle/><path/></svg>'.html.$('svg > *').length, 2, reason: '/> closes in SVG');
      expect('<pre>\nfoo</pre><textarea>\nbar</textarea>'.html.$('pre, textarea').texts, ['foo', 'bar']);
      expect('<!-->hi'.html.body.text, 'hi');
    });

    test('a raw-text end tag may carry a slash or attributes', () {
      for (final end in ['</script/>', '</script foo>', '</SCRIPT >']) {
        expect('<script>a$end<p>x</p>'.html.body.markup, '<body><p>x</p></body>');
      }
      expect('<script>a</scriptx>b</script><p>x</p>'.html.$('script').first.text, 'a</scriptx>b');
      expect('<title>t</title foo><p>x</p>'.html.$('title').first.text, 't');
    });

    test('</ p> and </> are dropped, as a browser drops them', () {
      expect('<p>a</ p>b</>c</p>'.html.body.markup, '<body><p>abc</p></body>');
      expect('a</'.html.body.text, 'a</');
    });

    test('SVG keeps its case, and a folded selector still finds it', () {
      final doc = '<svg viewBox="0 0 24 24"><foreignObject><b>x</b></foreignObject><clipPath id="c"/></svg>'.html;
      final svg = doc.$('svg').first;
      expect(svg.attr('viewBox'), '0 0 24 24');
      expect(svg.markup, startsWith('<svg viewBox="0 0 24 24"><foreignObject>'));
      expect(doc.$('[viewBox]'), hasLength(1));
      expect(doc.$('[viewbox="0 0 24 24"]'), hasLength(1));
      expect(doc.$('foreignObject b').first.text, 'x');
      expect(doc.$('clippath').single.id, 'c');
      expect(doc.$x('//svg/@viewBox').first.text, '0 0 24 24');
      // Outside <svg> nothing is recased.
      expect('<div viewBox=1>'.html.$('div').first.attributes.keys, ['viewbox']);
    });

    test('adjacent text and bare ampersands stay linear', () {
      expect(('<p>${'a < b ' * 20000}').html.$('p').first.text.length, 119999, reason: 'trimmed');
      expect(('<r>${'a & b ' * 20000}</r>').xml.text.length, 119999);
    });

    test('a hundred thousand nested elements read without overflowing', () {
      final doc = '${'<div>' * 100000}<span>x</span>'.html;
      expect(doc.text, 'x');
      expect(doc.$('span').first.text, 'x');
      expect(doc.$x('//span').first.text, 'x');
      expect(doc.encode().length, greaterThan(1100000));
    });

    test('an optgroup after an optgroup closes it', () {
      final doc = '<select><optgroup label="A"><option>1</option><optgroup label="B"><option>2</option></select>'.html;
      final groups = doc.$('select > optgroup');
      expect(groups, hasLength(2));
      expect(groups.first.attr('label'), 'A');
      expect(groups.last.attr('label'), 'B');
    });

    test('a newline written as a reference at the start of <pre> is kept, as package:html keeps it', () {
      expect(
        '<pre>&#10;x</pre>'.html.$('pre').first.text,
        reference.parse('<pre>&#10;x</pre>').querySelector('pre')!.text,
      );
    });
  });

  group('entities', () {
    test('named, decimal, hex, and unterminated', () {
      expect('&lt;a&gt; &amp; &#65;&#x42; &nbsp;x &unknown; &amp'.html.text, '<a> & AB x &unknown; &');
      expect(
        '&nbsp;x'.html.$x('//body/text()').first.rawText,
        '\u00a0x',
        reason: 'the markup keeps it; text reads it as a space',
      );
    });

    test('a query string keeps its ampersands; text decodes legacy names only', () {
      const href = '?a=1&lang=en&copy=2&not=3&para=4&sub=7&part=8';
      final doc = '<a href="$href">x &copy y &lang=en &notit; &#0;&#128;&#x110000;</a>'.html;
      expect(doc.$('a').first.attr('href'), href);
      expect(doc.$('a').first.markup.html.$('a').first.attr('href'), href, reason: 'and survives a round trip');
      expect(doc.$('a').first.text, 'x © y &lang=en ¬it; \u{fffd}€\u{fffd}');
      expect('<a href="?x&amp;y&copy;">'.html.$('a').first.attr('href'), '?x&y©');
    });

    test('HTML 5 punctuation names decode', () {
      expect('<p>&lpar;1&rpar; &check; &star;&period;</p>'.html.$('p').first.text, '(1) ✓ ☆.');
    });

    test('&lang; and &rang; decode to U+27E8 and U+27E9', () {
      final doc = '<p>&lang;math&rang;</p>'.html;
      expect(doc.$('p').first.text, '\u{27e8}math\u{27e9}');
    });
  });

  group('serialisation', () {
    test('is markup, everywhere, and round-trips', () {
      const src = '<p class="a&amp;b">x &lt; y</p>';
      expect(src.html.body.innerMarkup, src);
      expect(src.html.encode(), '<html><head></head><body>$src</body></html>');
      expect('<r><e/></r>'.xml.encode(), '<?xml version="1.0" encoding="UTF-8"?>\n<r><e/></r>\n');
      const elements = '<div class="a"><p>x &amp; y</p><br><img src="i.png"></div>';
      expect(elements.html.body.innerMarkup, elements);
    });

    test('a newline after <pre> is dropped once, so a second one survives a round trip', () {
      final doc = '<pre>\n\nfirst line\nsecond line</pre>'.html;
      expect(doc.$x('//pre/text()').first.rawText, '\nfirst line\nsecond line');
      expect(doc.encode().html.$x('//pre/text()').first.rawText, '\nfirst line\nsecond line');
    });
  });

  group('tree', () {
    test('Element.lines decodes entities and splits at <br>', () {
      final doc = Html.parse('<p id="x">A &amp; B &lt;c&gt;<br>D\nE<br></p>');
      expect(doc.$('#x').first.lines, equals(['A & B <c>', 'D', 'E']));
    });

    test('Element.lines breaks at blocks and skips what is not read', () {
      final doc =
          '<div><p>a</p><p>b &amp; c</p><ul><li>d<li>e</ul><script>x()</script><style>p{}</style>'
                  '<noscript>n</noscript><template>t</template><h2>T</h2>f<br>g<table><tr><td>1<td>2</table></div>'
              .html;
      expect(doc.$('div').first.lines, ['a', 'b & c', 'd', 'e', 'T', 'f', 'g', '1\t2']);
    });

    test('replace an earlier sibling moves it, losing nothing else', () {
      final div = '<div><a></a><b></b><c></c></div>'.html.$('div').first;
      final [a, b, _] = div.children.toList();
      b.replace(a);
      expect(div.children.map((e) => e.name), ['a', 'c']);
      a.replace(a);
      expect(div.children.map((e) => e.name), ['a', 'c']);
    });

    test('DOM mutations: remove, replace, clear, append, prepend', () {
      final doc = '<div><p class="del">1</p><p id="target">2</p><span class="del">3</span></div>'.html;
      // Elements.remove()
      doc.$('.del').detach();
      expect(doc.$('div').first.text.trim(), '2');

      // replace
      final target = doc.$('#target').first;
      final replacement = Element('p')..append(Text('new'));
      target.replace(replacement);
      expect(doc.$('p').first.text, 'new');

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
      xmlDoc.$x('//a').detach();
      expect(xmlDoc.$x('//*').map((n) => (n as Element).name).toList(), ['root', 'b']);
    });

    test('closest finds self, an ancestor, or nothing', () {
      final doc = '<div class="item"><section><p id="deep">x</p></section></div>'.html;
      final deep = doc.$('#deep').first;
      expect(deep.closest('p')?.name, 'p');
      expect(deep.closest('.item')?.name, 'div');
      expect(deep.closest('section')?.name, 'section');
      expect(deep.closest('.missing'), isNull);
      expect(doc.$('html').first.closest('html')?.name, 'html');
    });

    test('ancestors run from the parent upward', () {
      final doc = '<div class="item"><section><p id="deep">x</p></section></div>'.html;
      final deep = doc.$('#deep').first;
      expect(deep.ancestors.map((e) => e.name).toList(), ['section', 'div', 'body', 'html']);
    });

    test('nodes is an unmodifiable view: edits go through append and replace', () {
      final div = '<div><a></a></div>'.html.$('div').first;
      expect(() => div.nodes.add(Element('b')), throwsUnsupportedError);
      expect(div.nodes, hasLength(1));
      final a = div.$('a').first;
      final b = Element('b');
      a.replace(b);
      expect(b.parent, same(div));
      expect(a.parent, isNull);
      expect(div.children.map((e) => e.name), ['b']);
    });

    test('next and previous stay right after the tree changes', () {
      final ul = '<ul><li>1</li> <li>2</li><li>3</li></ul>'.html.$('ul').first;
      final items = ul.children.toList();
      expect(items[0].next?.text, '2');
      expect(items[2].previous?.text, '2');
      items[0].detach();
      expect(items[1].previous, isNull);
      expect(items[1].next?.text, '3');
      final many = '<div>${'<i></i>' * 20000}</div>'.html.$('div').first;
      var n = 0;
      for (Element? e = many.children.first; e != null; e = e.next) {
        n++;
      }
      expect(n, 20000);
    });

    test('a switch over Node is exhaustive without a default', () {
      final Node node = '<div/>'.html.root;
      final kind = switch (node) {
        Element() => 'element',
        Text() => 'text',
        Attribute() => 'attribute',
      };
      expect(kind, 'element');
    });
  });

  group('css selectors', () {
    test('combinators, attribute operators, pseudo-classes, lists', () {
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

    final soup =
        '<ul><li title="">a</li><li title="x">b</li></ul><div class="md:flex" id="123">t</div>'
                '<section><h2>H</h2><p>1</p><p>2</p><div><img></div><span>s</span></section>'
                '<dl><dt>k</dt><dd>v</dd><dt>lonely</dt></dl>'
            .html;

    test('an empty substring or word matches nothing', () {
      for (final s in ['[title^=""]', '[title*=""]', r'[title$=""]', '[title~=""]', '[title~="a b"]']) {
        expect(soup.$(s), isEmpty, reason: s);
      }
      expect(soup.$('[title=""]').first.text, 'a');
    });

    test('escapes, :is, :where, :only-of-type, :nth-last-of-type', () {
      expect(soup.$(r'.md\:flex').first.text, 't');
      expect(soup.$(r'#\31 23').first.text, 't');
      expect(soup.$('[class="md\\:flex"]').first.text, 't');
      expect(soup.$(':is(h2, span)').texts, ['H', 's']);
      expect(soup.$('section > :where(p):nth-last-of-type(1)').first.text, '2');
      expect(soup.$('section > :only-of-type').map((e) => e.name), ['h2', 'div', 'span']);
    });

    test(':has takes a relative selector', () {
      expect(soup.$('section:has(> img)'), isEmpty);
      expect(soup.$('section:has(> div > img)'), hasLength(1));
      expect(soup.$('div:has(img)'), hasLength(1));
      expect(soup.$('dt:has(+ dd)').first.text, 'k');
      expect(soup.$('h2:has(~ span)').first.text, 'H');
      expect(soup.$('section:has(ul li)'), isEmpty, reason: 'the ul is outside the section');
    });

    test('nested descendant combinators do not backtrack exponentially', () {
      final deep = '${'<div>' * 200}<span>x</span>'.html;
      expect(deep.$('p div div div div div span'), isEmpty);
      expect(deep.$('div div div div div span'), hasLength(1));
    });

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

    test(':contains matches on text, quoted or not', () {
      final doc = '<table><tr><th>Name</th><td>a</td></tr><tr><th>Price</th><td>9</td></tr></table>'.html;
      expect(doc.$('th:contains(Price) + td').first.text, '9');
      expect(doc.$('th:contains("Name") + td').first.text, 'a');
      expect(doc.$('tr:contains(Nope)'), isEmpty);
    });

    test(':scope in Element.\$ matches the element itself', () {
      final doc = '<div><ul id="u1"><li>1</li><li>2</li></ul><ul id="u2"><li>3</li></ul></div>'.html;
      final u1 = doc.$('#u1').first;
      expect(u1.$(':scope > li').texts, ['1', '2']);
    });

    test('a leading combinator on a document reads from its root', () {
      final d = '<ul><li>1<ul><li>a<li>b</ul><li>2</ul>'.html;
      expect(d.$('> body').single.name, 'body');
      expect('<r><a/><b><a/></b></r>'.xml.$('> a').length, 1);
      expect(d.$('ul').$('> li').map((e) => e.nodes.first.text), ['1', 'a', 'b', '2']);
      expect(d.$('ul').$x('li').elements.map((e) => e.nodes.first.text), ['1', 'a', 'b', '2']);
      expect(d.$('li').$x('following-sibling::li[1]').texts, ['b', '2']);
    });

    group('a nested selector reads the markup around it', () {
      test('XML keeps its case inside :not() and :has()', () {
        final doc = '<Root><Item id="1"/><item id="2"/></Root>'.xml;
        expect(doc.$('Root > :not(Item)').first.attr('id'), '2', reason: 'the lowercase <item> is what is left');
        expect(doc.$('Root > :not(item)').first.attr('id'), '1');
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
  });

  group('tables', () {
    test('table throws when there is no table, as text and attr do', () {
      final doc = '<div><p>x</p></div>'.html;
      expect(() => doc.$('table').first.table, throwsA(isA<MissingException>()));
      expect(() => doc.$('div').first.table, throwsA(isA<MissingException>()));
    });

    test('a row reports its own cells, not a nested table\'s', () {
      const html =
          '<table><tr><th>a</th><th>b</th></tr>'
          '<tr><td>1</td><td><table><tr><td>inner</td></tr></table></td></tr></table>';
      final t = html.html.$('table').first.table;
      expect(t.columns, ['a', 'b']);
      expect(t.rows.first.length, 2);
      expect(t.length, 1);
    });

    test('a stray </div> inside a <td> does not close the table', () {
      const html = '<table><tr><th>a</th></tr><tr><td>val</div></td></tr><tr><td>row2</td></tr></table>';
      final doc = html.html;
      expect(doc.$('table tr').length, 3);
      expect(doc.$('table').first.table.length, 2);
    });

    test('a table: thead of td, duplicate headers, colspan and rowspan', () {
      final t =
          '<table><thead><tr><td>Name<td>Score<td>Score</thead>'
                  '<tr><td rowspan=2>a<td colspan=2>1<tr><td>2<td>3</table>'
              .html
              .$('table')
              .first
              .table;
      expect(t.columns, ['Name', 'Score', 'Score_2']);
      expect(t.rows.map((r) => r.values.toList()), [
        ['a', '1', '1'],
        ['a', '2', '3'],
      ]);
    });

    test('a rowspan carried past a short row keeps its column', () {
      final h = '<table><tr><th>A<th>B<th>C<tr><td>a<td>b<td rowspan=2>c<tr><td>d<tr><td>e<td>f<td>g</table>';
      expect(h.html.$('table').first.table.rows, [
        {'A': 'a', 'B': 'b', 'C': 'c'},
        {'A': 'd', 'B': null, 'C': 'c'},
        {'A': 'e', 'B': 'f', 'C': 'g'},
      ]);
    });

    test('a th or td directly in thead gets an implied tr', () {
      final doc =
          '<table><thead><th>Col A</th><th>Col B</th></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>'.html;
      final table = doc.root.table;
      expect(table.columns, ['Col A', 'Col B']);
      expect(table.rows, hasLength(1));
    });

    test('a table under 500 stray <div>s still reads its row', () {
      final html = '<table>${'<div>' * 500}<tr><td>deep</td></tr>${'</div>' * 500}</table>';
      expect(html.html.root.table.rows, hasLength(1));
    });
  });

  group('readings', () {
    test('attr is the value or a MissingException naming it; orNull expects absence', () {
      final doc = '<a href="/x">x</a><b>y</b>'.html;
      expect(doc.$('a').first.attr('href'), '/x');
      expect(
        () => doc.$('b').first.attr('href'),
        throwsA(isA<MissingException>().having((e) => e.message, 'message', 'Missing attribute "href" in <b>')),
      );
      expect(
        () => doc.$('i').first,
        throwsA(isA<MissingException>().having((e) => e.message, 'message', 'Missing match for "i"')),
      );
      expect((() => doc.$('b').first.attr('href')).orNull, isNull);
      expect(doc.$('i').firstOrNull?.attr('href'), isNull);
      expect(doc.$x('//a').elements.first.attr('href'), '/x');
      expect((() => doc.$('b').first.attr('href')).or('none'), 'none');
      expect(doc.$('b').first.attr('href', or: 'none'), 'none');
      expect(doc.$('a').first.attr('href', or: 'none'), '/x', reason: 'a present value wins');
      expect(doc.$('a').first.attr('rel', or: ''), '');
    });

    test('Element.imageLink extracts lazy attributes, srcset and filters placeholders', () {
      final html = '''
        <html>
          <body>
            <img id="lazy" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-src="https://example.com/real.jpg" />
            <img id="original" src="/blank.gif" data-original="https://example.com/highres.jpg" />
            <img id="srcset" srcset="thumb.jpg 320w, large.jpg 1280w, medium.jpg 640w" src="thumb.jpg" />
            <div id="wrapper">
              <img src="https://example.com/nested.webp" />
            </div>
            <img id="plain" src="https://example.com/photo.png" />
          </body>
        </html>
      ''';
      final doc = html.html;

      expect(doc.$('#lazy').first.imageLink, Uri.parse('https://example.com/real.jpg'));
      expect(doc.$('#original').first.imageLink, Uri.parse('https://example.com/highres.jpg'));
      expect(doc.$('#srcset').first.imageLink, Uri.parse('large.jpg'));
      expect(doc.$('#wrapper').first.imageLink, Uri.parse('https://example.com/nested.webp'));
      expect(doc.$('#plain').first.imageLink, Uri.parse('https://example.com/photo.png'));

      expect(
        doc.imageLinks.map((u) => u.toString()),
        containsAll([
          'https://example.com/real.jpg',
          'https://example.com/highres.jpg',
          'large.jpg',
          'https://example.com/photo.png',
        ]),
      );
    });

    test('every imageLink is total, and orNull is the expected-absence door', () {
      final doc = '<div id="empty"></div><img id="ok" src="/a.png">'.html;
      final empty = doc.$('#empty');
      final noneMatched = doc.$('#missing');

      // the grid: one reading, its `orNull`, its default, and the throw it makes
      expect(doc.$('#ok').imageLink, Uri.parse('/a.png'));
      expect((() => empty.imageLink).orNull, isNull);
      expect((() => noneMatched.imageLink).orNull, isNull);
      expect((() => empty.imageLink).or(Uri.parse('/fallback.png')), Uri.parse('/fallback.png'));

      // and it throws, naming what was missing
      expect(
        () => empty.imageLink,
        throwsA(isA<MissingException>().having((e) => e.message, 'message', contains('image link'))),
      );
      expect(() => noneMatched.imageLink, throwsA(isA<MissingException>()));

      // the same rows on Nodes, and on the document
      final bare = '<p>no images</p>'.html;
      expect((() => bare.$('p').imageLink).orNull, isNull);
      expect(() => bare.$('p').imageLink, throwsA(isA<MissingException>()));
      expect(
        () => bare.imageLink,
        throwsA(
          isA<MissingException>().having((e) => e.message, 'message', contains('Missing image link in the page')),
        ),
      );
      expect((() => bare.imageLink).orNull, isNull);

      // the plural is unaffected: it is a search, so it is empty rather than absent
      expect(empty.imageLinks, isEmpty);
      expect(doc.imageLinks, [Uri.parse('/a.png')]);
    });

    test('a selection is a collection: at, first, last, single, where, take, skip stay typed (FMT-32)', () {
      final doc = Html.parse('<ul><li>a</li><li>b</li><li>c</li></ul><p>x</p>', url: Uri.parse('https://ex.com/'));
      final li = doc.$('li');
      expect(li.at(1).text, 'b');
      expect(li.at(-1).text, 'c');
      expect(
        () => li.at(3),
        throwsA(isA<MissingException>().having((e) => e.message, 'message', 'Missing match 3 for "li" (3 matched)')),
      );
      expect(li.last.text, 'c');
      expect(doc.$('p').single.text, 'x');
      expect(
        () => li.single,
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', 'Invalid HTML: 3 matches for "li", not one'),
        ),
      );
      expect(() => doc.$('nope').last, throwsA(isA<MissingException>()));
      expect(() => doc.$('nope').single, throwsA(isA<MissingException>()));
      final kept = li.where((e) => e.text != 'b');
      expect(kept, isA<Selection<Element>>());
      expect(kept.texts, ['a', 'c']);
      expect(li.take(2).texts, ['a', 'b']);
      expect(li.skip(1).texts, ['b', 'c']);
      expect(doc.$('ul').first.children.texts, ['a', 'b', 'c']);
      expect(() => li.where((e) => false).first, throwsA(isA<MissingException>()), reason: 'it still names the query');
      expect(doc.$x('//li/text()').texts, ['a', 'b', 'c']);
    });

    test('every plural lines up with its matches: attrs has a null where one has none (FMT-25)', () {
      final doc = '<a href="/1" class="x">1</a><a class="y">2</a><a href="/3">3</a>'.html;
      final a = doc.$('a');
      expect(a.texts, ['1', '2', '3']);
      expect(a.attrs('href'), ['/1', null, '/3']);
      expect(a.attrs('class'), ['x', 'y', null]);
      expect(a.links.map((u) => '$u'), ['/1', '/3'], reason: 'links skip what is not a link');
      expect(doc.$x('//a/@href').attrs('href'), [null, null], reason: 'an attribute has no attributes');
    });

    test('pairs reads th/td rows, dt/dd and Label: value lines, the first of a label kept', () {
      final doc =
          '''<div class="info">
        <table><tr><th>Size:</th><td>4 MB</td></tr><tr><th>Size</th><td>5 MB</td></tr><tr><td>a</td><td>b</td></tr></table>
        <dl><dt>Released</dt><dd>2019</dd></dl>
        <p>Password unrar: <span>mrcong.com</span></p><p>http://example.com</p><p>Empty: </p>
      </div>'''
              .html;
      expect(doc.$('.info').first.pairs, {'Size': '4 MB', 'Released': '2019', 'Password unrar': 'mrcong.com'});
      expect(doc.$('dl').first.pairs, {'Released': '2019'});
      expect('<p>x</p>'.html.$('p').first.pairs, isEmpty);
      expect(() => doc.$('.none').first.pairs, throwsA(isA<MissingException>()));
    });

    test('an XPath selection reads as a CSS one does, and its attributes are links (FMT-26)', () {
      final doc = Html.parse(
        '<div><a href="/a" class="x">one</a><a class="y">two</a><table><tr><th>k</th><td>v</td></tr></table></div>',
        url: Uri.parse('https://ex.com/d/'),
      );
      final links = doc.$x('//a');
      expect(links.attrs('class'), ['x', 'y']);
      expect(links.elements.first.lines, ['one']);
      expect(links.first.markup, '<a href="/a" class="x">one</a>');
      expect(doc.$x('//table').elements.first.table.rows.single, {'c1': 'k', 'c2': 'v'});
      expect(doc.$x('//div').elements.first.pairs, {'k': 'v'});
      expect(doc.$x('//a/@href').links, [Uri.parse('https://ex.com/a')]);
      expect(doc.$x('//a/@href').texts, ['/a']);
      expect(() => doc.$x('//none').first, throwsA(isA<MissingException>()));
    });

    group('Selection', () {
      final doc =
          '<ul id="u"><li class="x"><a href="/a">A</a></li><li><a>B</a></li><li class="x"><a href="b">C</a></li></ul>'
              .html;

      test('attrs, markup and table', () {
        expect(doc.$('a').attrs('href'), ['/a', null, 'b']);
        expect(doc.$('nothing').attrs('href'), isEmpty);
        expect(doc.$('li.x').first.markup, '<li class="x"><a href="/a">A</a></li>');
        expect('<table><tr><th>k</th></tr><tr><td>v</td></tr></table>'.html.$('table').first.table.rows, [
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

      test('a selection queries within every match', () {
        final doc = '<ul><li><a href="/1">one</a></li><li><a href="/2">two</a></li></ul><p>x</p>'.html;
        expect(doc.$('li a').first.text, 'one');
        expect(doc.$('li').$('a').map((a) => a.attr('href')), ['/1', '/2']);
        expect(doc.$('nothing').firstOrNull, isNull);
        expect(doc.$('li').length, 2);
      });
    });
  });

  group('links', () {
    test('links resolve against the address and the <base href>', () {
      const page = '<a href="/x?q=1">1</a><a href="y">2</a><a>none</a><img src="i.png"><a href="http://o/">3</a>';
      final url = Uri.parse('https://site.test/dir/page.html');
      expect(page.html.$('a, img').links.map((u) => '$u'), ['/x?q=1', 'y', 'i.png', 'http://o/']);
      expect(Html.parse(page, url: url).$('a, img').links.map((u) => '$u'), [
        'https://site.test/x?q=1',
        'https://site.test/dir/y',
        'https://site.test/dir/i.png',
        'http://o/',
      ]);
      final based = Html.parse('<head><base href="/other/"></head>$page', url: url);
      expect(based.base, Uri.parse('https://site.test/other/'));
      expect(based.$('a').links.take(2).map((u) => '$u'), ['https://site.test/x?q=1', 'https://site.test/other/y']);
      expect(
        '<base href="https://cdn.test/s/"><a href="y">'.html.$('a').links.single,
        Uri.parse('https://cdn.test/s/y'),
      );
      // a link that is there but reads as no URL is a broken document, not a missing link
      expect(() => '<a href="http://[bad">'.html.$('a').at(0).link, throwsFormatException);
      // the bulk path stays exception-free: it drops the bad one rather than throw mid-crawl
      expect('<a href="http://[bad">'.html.$('a').links, isEmpty, reason: 'the bulk path drops a malformed URL');
      expect('<a>x</a>'.html.$('a').links, isEmpty, reason: 'an <a> with no href has no link');
      expect(page.html.base, isNull);
      final res = Response('<a href="y">', 200, url: Uri.parse('https://site.test/d/p'));
      expect(res.html.$('a').links.single, Uri.parse('https://site.test/d/y'));

      // onclick URL extraction and HtmlDocument.links
      final onclickDoc = Html.parse('''
        <div onclick="location.href='/items?p=1'">Items</div>
        <button onclick="window.location = 'https://other.test/view'">Other</button>
        <span onclick="window.open('/popup')">Popup</span>
        <a href="/normal">Link</a>
        ''', url: Uri.parse('https://site.test/app/'));
      expect(onclickDoc.$('div').first.link, Uri.parse('https://site.test/items?p=1'));
      expect(onclickDoc.$('button').first.link, Uri.parse('https://other.test/view'));
      expect(onclickDoc.$('span').first.link, Uri.parse('https://site.test/popup'));
      expect(onclickDoc.links.map((u) => '$u'), [
        'https://site.test/items?p=1',
        'https://other.test/view',
        'https://site.test/popup',
        'https://site.test/normal',
      ]);
    });

    test('a link follows a <base> added, edited or removed after a first read', () {
      final doc = Html.parse(
        '<head></head><a href="y">1</a><img src="i.png">',
        url: Uri.parse('https://site.test/dir/p'),
      );
      final a = doc.$('a').first;
      final img = doc.$('img').first;
      expect('${a.link}', 'https://site.test/dir/y');
      final base = Element('base');
      doc.head.append(base);
      expect('${a.link}', 'https://site.test/dir/y', reason: 'a <base> without href changes nothing');
      base.attributes['href'] = '/b1/';
      expect('${a.link}', 'https://site.test/b1/y', reason: 'the <base> gained an href');
      expect('${img.imageLink}', 'https://site.test/b1/i.png');
      expect(doc.base, Uri.parse('https://site.test/b1/'));
      base.attributes['href'] = '/b2/';
      expect('${doc.$('a').links.single}', 'https://site.test/b2/y', reason: 'its href was edited');
      base.attributes.remove('href');
      expect('${a.link}', 'https://site.test/dir/y', reason: 'its href was removed');
      base.attributes.addAll({'href': '/b3/'});
      expect('${a.link}', 'https://site.test/b3/y');
      base.detach();
      expect('${a.link}', 'https://site.test/dir/y', reason: 'the <base> left the tree');
      doc.head.prepend('<base href="/b4/">'.html.$('base').first);
      expect('${a.link}', 'https://site.test/b4/y', reason: 'a parsed <base> moved in');
      doc.head.clear();
      expect('${a.link}', 'https://site.test/dir/y');
      doc.head.replace(Element('head')..append(Element('base', {'href': '/b5/'})));
      expect('${a.link}', 'https://site.test/b5/y', reason: 'a replace brought one in');
    });

    test('a <base href> counts after content, and after a <base> with no href', () {
      final u = Uri.parse('https://ex.com/dir/page.html');
      expect(Html.parse('<p>hi</p><base href="/sub/"><a href="x">', url: u).$('a').links.single.path, '/sub/x');
      expect(
        Html.parse('<base target=_blank><base href="/s2/"><a href="x">', url: u).$('a').links.single.path,
        '/s2/x',
      );
      expect(Html.parse('<a href="x">', url: u).$('a').links.single.host, 'ex.com');
    });
  });

  group('Element.fields', () {
    test('a disabled fieldset or optgroup disables what it holds, but not the first legend', () {
      final form = Html.parse('''<form>
  <input name="a" value="1">
  <fieldset disabled><legend><input name="inLegend" value="2"></legend><input name="b" value="3"><select name="s"><option>x</option></select></fieldset>
  <select name="g"><optgroup disabled><option>no</option></optgroup><option>yes</option></select>
</form>''').$('form').first;
      expect(form.fields, {'a': '1', 'inLegend': '2', 'g': 'yes'});
      expect(form.$('input:disabled').map((e) => e.attributes['name']), ['b']);
      expect(form.$('select:enabled').map((e) => e.attributes['name']), ['g']);
      expect(form.$('p:enabled'), isEmpty, reason: 'not a control');
    });

    test('extracts all valid form controls according to browser form submission rules', () {
      final doc =
          '''
          <form action="/login" method="post">
            <input type="text" name="user" value="alice">
            <input type="hidden" name="csrf" value="token123">
            <input type="password" name="pass" value="secret">
            <textarea name="bio">hello world</textarea>
            <input type="checkbox" name="opt" value="1" checked>
            <input type="checkbox" name="opt" value="2" checked>
            <input type="checkbox" name="unopt" value="3">
            <input type="checkbox" name="agree" checked>
            <input type="radio" name="plan" value="free">
            <input type="radio" name="plan" value="pro" checked>
            <select name="country">
              <option value="us">US</option>
              <option value="uk" selected>UK</option>
            </select>
            <select name="tags" multiple>
              <option value="dart" selected>Dart</option>
              <option value="flutter" selected>Flutter</option>
              <option value="go">Go</option>
            </select>
            <input type="text" name="disabled_input" value="ignored" disabled>
            <input type="submit" name="submit_btn" value="Submit">
            <button type="submit" name="btn" value="Go">Go</button>
            <input type="file" name="attachment">
            <input type="text" value="unnamed">
          </form>
        '''
              .html;

      final form = doc.$('form').first;
      final fields = form.fields;

      expect(fields['user'], 'alice');
      expect(fields['csrf'], 'token123');
      expect(fields['pass'], 'secret');
      expect(fields['bio'], 'hello world');
      expect(fields['opt'], ['1', '2']);
      expect(fields['agree'], 'on');
      expect(fields.containsKey('unopt'), isFalse);
      expect(fields['plan'], 'pro');
      expect(fields['country'], 'uk');
      expect(fields['tags'], ['dart', 'flutter']);
      expect(fields.containsKey('disabled_input'), isFalse);
      expect(fields.containsKey('submit_btn'), isFalse);
      expect(fields.containsKey('btn'), isFalse);
      expect(fields.containsKey('attachment'), isFalse);
    });

    test('reads fields from individual input elements and arbitrary containers', () {
      final input = '<input type="text" name="q" value="search terms">'.html.$('input').first;
      expect(input.fields, {'q': 'search terms'});

      final container = '<div><input name="a" value="1"><input name="b" value="2"></div>'.html.$('div').first;
      expect(container.fields, {'a': '1', 'b': '2'});
    });
  });

  group('Element.submission', () {
    final page = Uri.parse('https://a.com/dir/page');
    Element first(String html, String selector) => Html.parse(html, url: page).$(selector).first;

    test('an image button sends where it was clicked; a button outside its form names it by form=', () {
      final image = first('<form action="/s"><input type="image" name="go" src="g.png"></form>', 'input');
      expect(image.submission.url.queryParameters, {'go.x': '0', 'go.y': '0'});
      final outside = first(
        '<form id="f" action="/s"><input name="q" value="1"></form><button form="f" name="b" value="2">Go</button>',
        'button',
      );
      expect(outside.submission.url, Uri.parse('https://a.com/s?q=1&b=2'));
    });

    test('a GET replaces the action\'s query with the fields', () {
      final req = first('<form action="/s?old=1&amp;tag=a"><input name="q" value="dart"></form>', 'form').submission;
      expect(req.method, 'GET');
      expect(req.url, Uri.parse('https://a.com/s?q=dart'));
      expect(req.bytes, isEmpty);
    });

    test('a POST carries the fields as a form body, the action resolved against the page', () {
      final req = first(
        '<form action="post" method="POST"><input name="a" value="1"><input name="b" value="x y"></form>',
        'form',
      ).submission;
      expect(req.method, 'POST');
      expect(req.url, Uri.parse('https://a.com/dir/post'));
      expect(req.headers['content-type'], contains('application/x-www-form-urlencoded'));
      expect(Uri.splitQueryString(req.text), {'a': '1', 'b': 'x y'});
    });

    test('a pressed button adds its own name and value; the form alone sends no button', () {
      const html =
          '<form action="/s"><input name="q" value="1">'
          '<button name="op" value="save">Save</button><input type="submit" name="go" value="Go">'
          '<button type="button" name="no" value="x">x</button></form>';
      expect(first(html, 'form').submission.url.queryParameters, {'q': '1'});
      expect(first(html, 'button[name=op]').submission.url.queryParameters, {'q': '1', 'op': 'save'});
      expect(first(html, 'input[name=go]').submission.url.queryParameters, {'q': '1', 'go': 'Go'});
      expect(
        () => first(html, 'button[name=no]').submission,
        throwsA(isA<MissingException>()),
        reason: 'a type=button presses nothing',
      );
    });

    test('a button\'s formaction and formmethod override the form\'s', () {
      const html =
          '<form action="/a" method="get"><input name="q" value="1">'
          '<button formaction="/b" formmethod="post" name="op" value="x">B</button>'
          '<button name="op" value="y">Y</button></form>';
      final pressed = first(html, 'button[formaction]').submission;
      expect(pressed.method, 'POST');
      expect(pressed.url, Uri.parse('https://a.com/b'));
      expect(Uri.splitQueryString(pressed.text), {'q': '1', 'op': 'x'});
      final plain = first(html, 'button[value=y]').submission;
      expect(plain.method, 'GET');
      expect(plain.url, Uri.parse('https://a.com/a?q=1&op=y'));
    });

    test('a form with no action submits to the page it is on', () {
      final req = first('<form method="post"><input name="q" value="1"></form>', 'form').submission;
      expect(req.method, 'POST');
      expect(req.url, page);
      expect(req.text, 'q=1');
    });

    test('anything but a form or a submit button in one is a MissingException naming it', () {
      const html = '<div>x</div><button name="b">loose</button><form><input name="q"></form>';
      for (final selector in ['div', 'button', 'input']) {
        expect(
          () => first(html, selector).submission,
          throwsA(isA<MissingException>().having((e) => '$e', 'message', contains('<$selector>'))),
          reason: selector,
        );
      }
    });
  });

  group('text', () {
    test('text is what a page shows: no script, style or title, blocks apart, whitespace collapsed (FMT-23, FMT-24)', () {
      final page =
          '<html><head><title>T</title><style>p{}</style></head><body><h1>Big  News</h1><p>a\n  b</p>'
                  '<script>var x</script><ul><li>1</li><li>2</li></ul>x<br>y<table><tr><td>c</td><td>d</td></tr></table></body></html>'
              .html;
      expect(page.text, 'Big News a b 1 2 x y c d');
      expect(page.$('title').first.text, 'T', reason: 'an element a page hides is still its own text');
      expect(page.$('script').first.text, 'var x');
      expect(page.rawText, contains('var x'));
      expect(page.$('p').first.rawText, 'a\n  b');
      expect(page.$x('//p/text()').first.text, 'a b', reason: 'a text node reads the same way');
      expect(page.$x('//p/text()').first.rawText, 'a\n  b');
    });

    test(':contains() and XPath compare the visible text', () {
      final doc = '<p>a\n   b</p><div><span>one</span><span>two</span></div><p>x<script>hidden</script></p>'.html;
      expect(doc.$('p:contains("a b")'), hasLength(1));
      expect(doc.$('p:contains("a  b")'), hasLength(1), reason: 'the wanted text folds too');
      expect(doc.$x('//p[.="a b"]'), hasLength(1));
      expect(doc.$x('//p[contains(., "hidden")]'), isEmpty);
      expect(doc.$x('//div[.="onetwo"]'), hasLength(1), reason: 'inline elements are not kept apart');
    });

    test('Html.decodeEntities decodes as HTML text does (FMT-37)', () {
      expect(Html.decodeEntities('caf&eacute; &amp; &lt;b&gt; &#x41;'), 'café & <b> A');
      expect(Html.decodeEntities('no entities'), 'no entities');
    });
  });

  group('tree edits', () {
    test('classes is a live set: add and remove write the attribute (FMT-31)', () {
      final p = '<p class="a  b">x</p><i>y</i>'.html;
      final el = p.$('p').first;
      expect(el.classes, {'a', 'b'});
      expect(el.classes.add('c'), isTrue);
      expect(el.classes.add('a'), isFalse);
      expect(el.attr('class'), 'a b c');
      el.classes.remove('a');
      expect(el.attributes['class'], 'b c');
      final i = p.$('i').first;
      i.classes.add('only');
      expect(i.attributes['class'], 'only', reason: 'an element with no class gains one');
      i.classes.remove('only');
      expect(i.attributes.containsKey('class'), isFalse);
      expect(() => i.classes.add('two words'), throwsArgumentError);
    });

    test('detach takes a selection or a node out of its tree; an attribute is not a child', () {
      final doc = '<ul><li>1</li><li class="x">2</li><li>3</li></ul>'.html;
      doc.$('li.x').detach();
      expect(doc.$('li').texts, ['1', '3']);
      final li = doc.$('li').first..detach();
      expect(li.parent, isNull);
      doc.$('ul').first.append(li);
      expect(doc.$('li').texts, ['3', '1']);
      final attribute = '<b id="q">'.html.$x('//b/@id').first;
      expect(() => doc.$('ul').first.append(attribute), throwsArgumentError);
    });

    test('editing while reading links stays linear: only a <base> invalidates the base (FMT-33)', () {
      final doc = Html.parse('<body>${'<p><a href="x">a</a></p>' * 4000}</body>', url: Uri.parse('https://ex.com/d/'));
      final watch = Stopwatch()..start();
      for (final p in doc.$('p').toList()) {
        p.append(Element('span'));
        expect(p.$('a').first.link.path, '/d/x');
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      doc.head.append(Element('base', {'href': '/b/'}));
      expect(doc.$('a').first.link.path, '/b/x', reason: 'a <base> still counts');
    });
  });

  group('images', () {
    test('a <picture> yields its image, from its <img> or its <source> (FMT-22)', () {
      final doc = Html.parse(
        '<picture><source srcset="/big.webp 2x, /small.webp 1x"><img src="/fallback.jpg"></picture>'
        '<picture><img src="/only.jpg"></picture>',
        url: Uri.parse('https://ex.com/'),
      );
      expect(doc.imageLink, Uri.parse('https://ex.com/big.webp'));
      expect(doc.$('picture').first.imageLink, Uri.parse('https://ex.com/big.webp'));
      expect(doc.$('picture').imageLinks.map((u) => u.path), ['/big.webp', '/only.jpg']);
      expect(doc.imageLinks.map((u) => u.path), ['/big.webp', '/only.jpg'], reason: 'a picture counts once');
      expect('<div><p>x</p></div><div><img src="/a.png"></div>'.html.$('div').imageLink, Uri.parse('/a.png'));
    });
  });

  group('links and forms', () {
    test('a javascript: href is not a link, unless it navigates (FMT-40)', () {
      final doc = Html.parse(
        '<a href="javascript:void(0)">no</a><a href="javascript:location.href=\'/go\'">go</a><a href="/x">x</a>',
        url: Uri.parse('https://ex.com/'),
      );
      expect(doc.links.map((u) => u.path), ['/go', '/x']);
      expect(() => doc.$('a').first.link, throwsA(isA<MissingException>()));
    });

    test(
      'form submission follows the browser: no empty ?, a relative action needs an address, a GET otherwise (FMT-34)',
      () {
        final page = Uri.parse('https://ex.com/dir/page');
        expect(
          Html.parse('<form action="/s"></form>', url: page).$('form').first.submission.url,
          Uri.parse('https://ex.com/s'),
        );
        expect(
          Html.parse(
            '<form action="/s"><input name="q" value=""><input name="t" value="a b"></form>',
            url: page,
          ).$('form').first.submission.url.toString(),
          'https://ex.com/s?q=&t=a+b',
        );
        expect(
          () => Html.parse('<form action="s"></form>').$('form').first.submission,
          throwsA(isA<MissingException>().having((e) => e.message, 'message', contains('page address'))),
        );
        expect(
          Html.parse('<form action="https://other.test/s"></form>').$('form').first.submission.url.host,
          'other.test',
        );
        final odd = Html.parse('<form action="/s" method="dialog"><input name="q" value="1"></form>', url: page);
        expect(odd.$('form').first.submission.method, 'GET');
        expect(
          Html.parse('<form method="PoSt" action="/p"></form>', url: page).$('form').first.submission.method,
          'POST',
        );
      },
    );
  });

  group('files', () {
    test('Html.read sniffs the charset as a browser does; save keeps the doctype (FMT-29, FMT-39)', () async {
      final dir = Directory.systemTemp.createTempSync('tk_html_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final latin = File('${dir.path}/latin.html')
        ..writeAsBytesSync([
          ...'<!DOCTYPE html><html><head><meta charset="windows-1252"></head><body><p>caf'.codeUnits,
          0xe9,
          ...' 1'.codeUnits,
          0x80,
          ...'</p></body></html>'.codeUnits,
        ]);
      final page = await Html.read(latin.path);
      expect(page.$('p').first.text, 'café 1€');
      final saved = await page.save('${dir.path}/copy.html');
      expect(saved, '${dir.path}/copy.html');
      final bytes = File(saved).readAsBytesSync();
      expect(bytes.take(3), [0xef, 0xbb, 0xbf], reason: 'a UTF-8 mark outranks the <meta> that says otherwise');
      expect(utf8.decode(bytes.skip(3).toList()), startsWith('<!DOCTYPE html><html>'));
      expect((await Html.read(saved)).$('p').first.text, 'café 1€', reason: 'it reads back as it was');
      final plain = await '<!doctype html><p>x</p>'.html.save('${dir.path}/plain.html');
      expect(File(plain).readAsStringSync(), '<!doctype html><html><head></head><body><p>x</p></body></html>');
      final fromFuture = await Future.value('<p>z</p>'.html).save('${dir.path}/later.html');
      expect(File(fromFuture).readAsStringSync(), contains('<p>z</p>'), reason: 'save works on a Future of an Html');
      final skipped = '<p>y</p>'.html.save(plain, conflict: Conflict.skip);
      expect((await skipped.settled), isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse));
    });

    test('a response reads as HTML whatever its status; awaited, only a 2xx', () async {
      final res = Response('<p>gone</p>', 404, url: Uri.parse('https://ex.com/x'));
      expect(res.html.$('p').first.text, 'gone');
      expect(res.html.url, Uri.parse('https://ex.com/x'));
      await expectLater(Future.value(res).html, throwsA(isA<HttpException>()));
      expect((await Future.value(Response('<p>ok</p>', 200)).html).text, 'ok');
    });
  });
}

/// [text] as a reader sees it, as `Element.text` reads: runs of ASCII whitespace and no-break
/// spaces one space, trimmed; an ideographic space is text.
String _read(String text) => text.replaceAll(RegExp(r'[ \t\n\r\f\v\u00a0]+'), ' ').trim();

/// package:html's [root] read as `Element.text` reads one: what a page shows, a block, a cell
/// or a `<br>` keeping the words either side apart.
String _visible(html_dom.Element root) {
  const hidden = {'head', 'script', 'style', 'title', 'template', 'noscript'};
  const blocks = {
    'address', 'article', 'aside', 'blockquote', 'body', 'caption', 'center', 'dd', 'details', 'dialog', 'dir', //
    'div', 'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'header', 'hgroup', 'hr', 'html', 'legend', 'li', 'main', 'menu', 'nav', 'ol', 'option', 'p', 'pre', 'section',
    'summary', 'table', 'tbody', 'tfoot', 'thead', 'tr', 'ul', 'br', 'td', 'th',
  };
  final sb = StringBuffer();
  void walk(html_dom.Node n) {
    for (final c in n.nodes) {
      if (c is html_dom.Text) {
        sb.write(c.text);
      } else if (c is html_dom.Element && !hidden.contains(c.localName)) {
        final apart = blocks.contains(c.localName);
        if (apart) sb.write(' ');
        walk(c);
        if (apart) sb.write(' ');
      }
    }
  }

  walk(root);
  return _read('$sb');
}
