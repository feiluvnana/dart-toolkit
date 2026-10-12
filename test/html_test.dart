import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

void main() {
  group('html documents', () {
    test('drop(css) copies without the match; the receiver is unchanged', () {
      final doc = Html.parse('<div><p>keep</p><script>var x = 1;</script></div>');
      final clean = doc.drop('script');
      expect(clean.all('script'), isEmpty);
      expect(clean.find('p')?.text, 'keep');
      expect(doc.all('script'), hasLength(1));
    });

    test('prev/next skip text nodes', () {
      final doc = Html.parse('<div><b id="a">x</b> tail <i id="b">y</i></div>');
      expect(doc.find('#b')?.prev?.attr('id'), 'a');
      expect(doc.find('#a')?.next?.attr('id'), 'b');
      expect(doc.find('#a')?.prev, isNull);
    });

    test('doc.html is the whole markup as a String', () {
      final doc = Html.parse('<p>hi</p>');
      expect(doc.html, isA<String>());
      expect(doc.html, contains('<p>hi</p>'));
    });

    test('a real page parses: hn.html has links', () async {
      final doc = await File('test/fixtures/hn.html').html();
      expect(doc.all('a[href]'), isNotEmpty);
    });

    test('every selector runs on a drop()ed doc without throwing', () {
      final doc = Html.parse('<div><p>x</p><script>s</script></div>').drop('script');
      const selectors = [
        'div',
        'p',
        'section p',
        'div p',
        'div > p',
        '*',
        '*:first-child',
        ':root',
        'p:first-child',
        'p:last-child',
        'p:nth-child(1)',
        'p:contains(x)',
        ':not(script)',
        'div:has(p)',
        '#missing',
        '.missing',
        '[data-x]',
      ];
      for (final s in selectors) {
        doc.all(s);
        doc.find(s);
      }
      expect(doc.find('p')?.text, 'x');
      expect(doc.all('script'), isEmpty);
    });

    test('serialised markup reparses to the same tree', () {
      const src =
          '<!DOCTYPE html><html><head><title>a & b</title></head><body>'
          '<p>a &lt;b&gt; &amp; c</p><br><img src="x?a=1&b=2">'
          '<script>if (a < b && c > d) { x = "y"; }</script>'
          '<a title=\'q "quoted" & amped\'>t</a></body></html>';
      final once = Html.parse(src).html;
      expect(Html.parse(once).html, once);
      expect(once, startsWith('<!DOCTYPE html>'));
      expect(once, contains('<br>'));
      expect(once, isNot(contains('</br>')));
      expect(once, contains('x?a=1&amp;b=2'));
      expect(once, contains('q &quot;quoted&quot; &amp; amped'));
      expect(once, contains('if (a < b && c > d)'));
      // No element smuggled in through entities.
      expect(Html.parse(src).all('b'), isEmpty);
    });

    test('angle brackets in text and quoted attributes stay text', () {
      final doc = Html.parse('<p>1 < 2 and 3 > 2</p>');
      expect(doc.find('p')?.text, '1 < 2 and 3 > 2');
      expect(doc.all('*').where((e) => e.tag == '2'), isEmpty);
      final a = Html.parse('<a title="x>y">t</a>');
      expect(a.find('a')?.attr('title'), 'x>y');
      expect(a.find('a')?.text, 't');
    });

    test('bad numeric entities become U+FFFD, named ones decode', () {
      expect(Html.parse('<p>&#99999999;</p>').find('p')?.text, '�');
      expect(Html.parse('<p>&#0;</p>').find('p')?.text, '�');
      expect(Html.parse('<p>&#xD800;</p>').find('p')?.text, '�');
      expect(Html.parse('<p>&rsquo;&eacute;&euro;</p>').find('p')?.text, '’é€');
    });

    test('hn.html parses as before: same links and text', () async {
      final doc = await File('test/fixtures/hn.html').html();
      expect(doc.all('a[href]'), hasLength(225));
      expect(doc.text.length, 3894);
    });
  });

  group('selector scope and errors', () {
    test('find and all search below the element, never the element itself', () {
      final doc = Html.parse('<div class="card"><div class="body"><p>x</p></div></div>');
      final card = doc.find('.card')!;
      expect(card.find('div')!.attr('class'), 'body');
      expect(card.all('div').map((e) => e.attr('class')), ['body']);
      expect(card.matches('div'), isTrue);
    });

    test('the synthetic document root never appears in results', () {
      final doc = Html.parse('<p>a</p>');
      expect(doc.find('*')!.tag, 'html');
      expect(doc.all(':not(p)').map((e) => e.tag), isNot(contains('#document')));
      expect(doc.all(':root').map((e) => e.tag), ['html']);
    });

    test('an unknown pseudo-class is a FormatException', () {
      final doc = Html.parse('<ul><li>a</li><li>b</li></ul>');
      expect(() => doc.all('li:hovr'), throwsFormatException);
      expect(() => doc.all('li:nth-last-child(1)'), throwsFormatException);
    });

    test(':has(> x) looks at children only', () {
      final doc = Html.parse('<ul id="a"><li>x</li></ul><div id="b"><ul><li>y</li></ul></div>');
      expect(doc.all('div:has(> li)'), isEmpty);
      expect(doc.all('ul:has(> li)').map((e) => e.attr('id')), contains('a'));
      expect(doc.all('div:has(li)').map((e) => e.attr('id')), ['b']);
    });
  });

  group('links, lines and closest', () {
    test('link resolves against the document URL, moved by <base href>', () {
      final doc = Html.parse('<a href="b/c?x=1">c</a><img src="/i.png">', url: 'https://h.test/a/page.html');
      expect(doc.url, 'https://h.test/a/page.html');
      expect(doc.find('a')!.link(), 'https://h.test/a/b/c?x=1');
      expect(doc.find('img')!.link('src'), 'https://h.test/i.png');
      expect(doc.find('img')!.link(), isNull);
      final based = Html.parse('<base href="/root/"><a href="x">x</a>', url: 'https://h.test/a/page.html');
      expect(based.find('a')!.link(), 'https://h.test/root/x');
      expect(based.drop('base').find('a')!.link(), 'https://h.test/root/x');
    });

    test('without a URL a link reads as written', () {
      expect(Html.parse('<a href=" rel/x ">x</a>').find('a')!.link(), 'rel/x');
    });

    test('a file reading links against the file', () async {
      final dir = await Dir.temp();
      try {
        final file = dir.file('p.html');
        await file.write('<a href="next.html">n</a>');
        final doc = await file.html();
        expect(Uri.parse(doc.find('a')!.link()!).toFilePath(), endsWith('next.html'));
        expect(Uri.parse(doc.url!).isAbsolute, isTrue);
      } finally {
        await dir.drop();
      }
    });

    test('lines break at <br> and blocks, trimmed, blanks dropped', () {
      final doc = Html.parse('<div id=t> 1. One<br>2. Two <br/><br> <p>Three</p><span>Four</span>\n Five</div>');
      expect(doc.find('#t')!.lines, ['1. One', '2. Two', 'Three', 'Four', 'Five']);
    });

    test('closest is the nearest matching ancestor, never the element', () {
      final doc = Html.parse('<div class=row id=outer><div class=row id=inner><a class=row>x</a></div></div>');
      expect(doc.find('a')!.closest('.row')!.id, 'inner');
      expect(doc.find('#outer')!.closest('.row'), isNull);
      expect(doc.find('a')!.closest('table'), isNull);
    });
  });
}
