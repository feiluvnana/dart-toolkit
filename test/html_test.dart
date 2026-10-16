import 'dart:convert';

import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/src/charset.dart';
import 'package:dart_toolkit/utils.dart';

import 'support/io.dart';
import 'package:test/test.dart';

void main() {
  group('Html.parse', () {
    test('text() of a page nested 20,000 deep does not overflow', () {
      final deep = '${'<b>' * 20000}deep${'</b>' * 20000}';
      expect(Html.parse(deep).text(), 'deep');
    });

    test('returns Elements', () {
      expect(Html.parse('<div></div>'), isA<Elements>());
    });

    test('never throws on malformed markup', () {
      expect(() => Html.parse('<div><p>oops'), returnsNormally);
      expect(() => Html.parse(''), returnsNormally);
      expect(() => Html.parse('<'), returnsNormally);
    });

    test('XHTML and pages that open with <head> or <body> are documents', () {
      expect(Html.parse('<?xml version="1.0"?>\n<html><body><p>x</p></body></html>').$('body'), hasLength(1));
      expect(Html.parse('<head><title>t</title></head><body><p>x</p>').$('body p'), hasLength(1));
      expect(Html.parse('<body class=a><p>x</p>').$('body.a'), hasLength(1));
      expect(Html.parse('<header>h</header>').$('body'), isEmpty); // a fragment
    });

    test('table parts inside <template> stay in it (template insertion modes)', () {
      final doc = Html.parse(
        '<!doctype html><head><template id=row><tr><td>N</td><td>M</td></tr></template></head>'
        '<body><table><template id=t><tr><td>x</td></tr></template></table>'
        '<template id=cell><td>c</td></template><template id=cap><caption>k</caption><col></template>',
      );
      expect(doc.$('#row > tr > td').texts(), ['N', 'M']);
      expect(doc.$('#t > tr > td').texts(), ['x']);
      expect(doc.$('#cell > td').texts(), ['c']);
      expect(doc.$('#cap > caption, #cap > col').length, 2);
    });

    test('takes a base', () {
      final doc = Html.parse('<a href="/x">t</a>', base: 'https://e.com/d/');
      expect(doc.$('a')[0].attr('href'), 'https://e.com/x');
    });

    test('a fragment keeps its text', () {
      expect(Html.parse('Tom &amp; Jerry').text(), 'Tom & Jerry');
    });
  });

  group('Charset', () {
    test('the meta prescan reads charset attributes only, never comments or other metas\' text', () {
      String? sniff(String head) => Charset.metaCharset(head.codeUnits);
      expect(sniff('<meta name="description" content="we use charset=shift_jis here"><meta charset="utf-8">'), 'utf-8');
      expect(sniff('<!-- <meta charset=windows-1251> --><meta charset=koi8-r>'), 'koi8-r');
      expect(
        sniff('<meta data-charset="big5"><meta http-equiv="Content-Type" content="text/html; charset=EUC-JP">'),
        'EUC-JP',
      );
      expect(sniff('<meta content="text/html; charset=gbk">'), isNull); // no http-equiv
      expect(sniff("<META CHARSET='iso-8859-2'>"), 'iso-8859-2');
    });

    test('windows-1252 passes its five unassigned bytes through, as WHATWG does', () {
      expect(
        Charset.decode([0x81, 0x8D, 0x8F, 0x90, 0x9D, 0x80], contentType: 'text/html; charset=windows-1252'),
        '\u0081\u008D\u008F\u0090\u009D€',
      );
    });

    test('single-byte legacy codecs decode', () {
      expect(
        Charset.decode([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], contentType: 'text/html; charset=windows-1251'),
        'Привет',
      );
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
        base: 'https://e.com/d/',
      );
      expect(doc.$('a')[0].attr('href'), 'https://cdn.e.com/a/x');
    });

    test('a relative <base> resolves against the page URL', () {
      final doc = Html.parse(
        '<html><head><base href="/s/"></head><body><a href="x">t</a></body></html>',
        base: 'https://e.com/d/',
      );
      expect(doc.$('a')[0].attr('href'), 'https://e.com/s/x');
    });

    test('a bad <base> is ignored (regression: parse threw FormatException)', () {
      const page = '<html><head><base href="http://[bad"></head><body><a href="x">t</a></body></html>';
      expect(Html.parse(page, base: 'https://e.com/d/').$('a')[0].attr('href'), 'https://e.com/d/x');
      expect(Html.parse(page).$('a')[0].attr('href'), 'x');
    });
  });

  group('selectors', () {
    test('structural, form, logical, relational, attribute and escaped selectors', () {
      final doc = Html.parse('''
<div id=root lang="en-GB">
  <ul id=l><li id=a class="x Y">1</li><li id=b>2</li><li id=c class=x>3</li><li id=d>4</li><li id=e class=x>5</li></ul>
  <p id=p1></p><span id=s1>t</span><p id=p2>x</p>
  <form><fieldset disabled><input id=i1></fieldset><input id=i2 checked><input id=i3 disabled><input id=cb type=checkbox name=cb>
  <select><option id=o1 selected>z</option></select></form>
  <a id=k1 href="/x">l</a><a id=k2>n</a><b id="we:ird" lang=fr></b><b id="1st"></b>
  <section id=h><b id=hb></b></section><section id=h2></section>
</div>''');
      final cases = {
        'li:nth-child(2n+1)': 'a c e',
        'li:nth-child(even)': 'b d',
        'li:nth-child(-n+2)': 'a b',
        'li:nth-last-child(1)': 'e',
        'li:nth-child(2 of .x)': 'c',
        'li:nth-of-type(2)': 'b',
        'p:first-of-type, p:last-of-type': 'p1 p2',
        'span:only-of-type': 's1',
        'p:empty': 'p1',
        ':root': 'root',
        ':link': 'k1',
        'input:checked, option:checked': 'i2 o1',
        'input:disabled': 'i1 i3',
        'input:enabled': 'i2 cb',
        'li:is(#a, #b)': 'a b',
        'li:where(.x):not(#a)': 'c e',
        'section:has(> b)': 'h',
        'p:has(+ span)': 'p1',
        'b:lang(fr)': 'we:ird',
        'li[class~=y i]': 'a',
        'li[class^=x]': 'a c e',
        'li[class|=x]': 'c e',
        'input[type=CHECKBOX]': 'cb',
        'input[type=CHECKBOX s]': '',
        'input[name=CB]': '', // name is case-sensitive
        r'#we\:ird, #\31 st': 'we:ird 1st',
        'li::before, li:hover': '',
      };
      for (final MapEntry(key: sel, value: ids) in cases.entries) {
        expect(doc.$(sel).attrs('id').join(' '), ids, reason: sel);
      }
      for (final bad in ['li:nth-child(x)', 'li:bogus', ':has(', 'li[', 'li >']) {
        expect(() => doc.$(bad), throwsFormatException, reason: bad);
      }
    });

    test('B26: any whitespace around "of"; a select\'s implied option is :checked', () {
      final doc = Html.parse('<li>1<li class=e>2<li class=e>3<li class=e>4');
      for (final sel in ['li:nth-child(odd\tof .e)', 'li:nth-child(odd\nof\n.e)', 'li:nth-child( odd  of  .e )']) {
        expect(doc.$(sel).texts(), ['2', '4'], reason: sel);
      }
      final form = Html.parse('''
<select><option id=a disabled>x<option id=b>y<option id=c>z</select>
<select><option id=d selected>x<option id=e selected>y</select>
<select multiple><option id=f>x<option id=g selected>y<option id=h selected>z</select>
<datalist><option id=i>x</datalist>''');
      expect(form.$('option:checked').attrs('id'), ['b', 'e', 'g', 'h']);
    });
  });

  group('deep documents', () {
    test('every query works 20,000 deep: parse, \$, not and text never recurse', () {
      final doc = Html.parse('${'<div>' * 20000}<a>x</a>${'</div>' * 20000}');
      expect(doc.$('div a').text(), 'x');
      expect(doc.not('a').$('a'), isEmpty);
      expect(doc.text(), 'x');
    });

    test('a page 20,000 deep parses in linear time (regression: every tag walked the open stack)', () {
      final sw = Stopwatch()..start();
      Html.parse('${'<div>' * 20000}${'<b>' * 20000}x<table><tr><td>y</table>');
      expect(sw.elapsedMilliseconds, lessThan(1500)); // was ~7 s
    });

    test('chained descendant combinators never backtrack exponentially', () {
      final doc = Html.parse('<section>${'<div>' * 1000}x${'</div>' * 1000}</section>');
      final sw = Stopwatch()..start();
      expect(doc.$('section div div div'), hasLength(998));
      expect(doc.$('section div div div p'), isEmpty);
      expect(sw.elapsedMilliseconds, lessThan(1000)); // was 400 s
    });

    test('sibling combinators and :nth-* stay linear on a long list', () {
      final doc = Html.parse('<ul>${'<li>x</li>' * 20000}</ul>');
      final sw = Stopwatch()..start();
      expect(doc.$('li + li'), hasLength(19999));
      expect(doc.$('li:first-child, li:nth-last-child(1)'), hasLength(2));
      expect(doc.$('li:nth-child(2n) ~ li'), hasLength(19998));
      expect(sw.elapsedMilliseconds, lessThan(1500)); // was ~17 s
    });

    test('text merging, adoption and foster parenting stay linear', () {
      final sw = Stopwatch()..start();
      expect(Html.parse('xy</q>' * 50000).text(), hasLength(100000));
      expect(Html.parse('<b><div>${'<br>' * 30000}</b>').$('br'), hasLength(30000));
      expect(Html.parse('<table>${'<i></i>' * 30000}').$('i'), hasLength(30000));
      expect(sw.elapsedMilliseconds, lessThan(1500)); // was ~5 s
    });

    test('not() on a long sibling list stays linear', () {
      final doc = Html.parse('<div>${'<br><i>x</i>' * 50000}</div>');
      final sw = Stopwatch()..start();
      final kept = doc.not('br');
      expect(sw.elapsedMilliseconds, lessThan(1000)); // was 8 s
      expect(kept.$('br'), isEmpty);
      expect(kept.$('i'), hasLength(50000));
    });

    test('S4: the tree is at most 512 deep, like Chromium: deeper elements land beside the 512th', () {
      final doc = Html.parse('<body>${'<div>' * 2000}<a>x</a>');
      var depth = 0;
      for (Element? e = doc.$('a').first; e != null; e = e.parent()) {
        depth++;
      }
      expect(depth, lessThanOrEqualTo(513));
      expect(doc.$('div'), hasLength(2000));
      expect(doc.$('a').text(), 'x');
    });

    test('S4: misnested formatting (<a><b>x</a>) parses in linear time', () {
      final sw = Stopwatch()..start();
      expect(Html.parse('<body>${'<a><b>x</a>' * 160000}').$('a'), hasLength(160000));
      expect(sw.elapsedMilliseconds, lessThan(2000)); // was 6.2 s
    });

    test('S4: :has() searches only where its combinators can reach', () {
      final list = Html.parse('<ul>${'<li>x</li>' * 20000}<li class=z>z</li></ul>');
      final deep = Html.parse('<body>${'<div>' * 30000}<a>x</a>');
      final sw = Stopwatch()..start();
      expect(list.$('li:has(+ .z)'), hasLength(1));
      expect(list.$('ul:has(> li.z)'), hasLength(1));
      expect(deep.$('div:has(> a)'), hasLength(1));
      expect(deep.$('div:has(a)'), hasLength(509)); // the a's ancestors: the tree is capped at 512
      expect(sw.elapsedMilliseconds, lessThan(3000)); // :has(+ .z) was 2.3 s at 8,000
      final small = Html.parse('<ul><li>a<li>b<li class=z><i>z</i><li>c</ul><p><b><i>x</i></b></p>');
      expect([for (final e in small.$('li:has(~ .z)')) e.text()], ['a', 'b']);
      expect([for (final e in small.$('li:has(+ .z > i)')) e.text()], ['b']);
      expect([for (final e in small.$('li:has(+ li + li)')) e.text()], ['a', 'b']);
      expect(small.$('p:has(> b > i)'), hasLength(1));
      expect(small.$('p:has(> i)'), isEmpty);
    });

    test('S6: 120,000 unclosed formatting tags parse in linear time', () {
      final sw = Stopwatch()..start();
      expect(Html.parse('${'<b><i><u>' * 40000}x').text(), 'x');
      expect(sw.elapsedMilliseconds, lessThan(1500)); // ~90 ms; quadratic was 3 s
    });

    test('nested roots are walked once (regression: one walk per root)', () {
      final doc = Html.parse('${'<div>' * 3000}<a>x</a>${'</div>' * 3000}<div><a>y</a></div>');
      final divs = doc.$('div');
      final one = Stopwatch()..start();
      for (var i = 0; i < 5; i++) {
        doc.$('a');
      }
      one.stop();
      final sw = Stopwatch()..start();
      late Elements links;
      for (var i = 0; i < 5; i++) {
        links = divs.$('a');
      }
      expect(links.texts(), ['x', 'y']);
      // Relative to one walk of the tree, so load cannot fail it: a walk per
      // root (3,001 of them) is ~1,000× one walk.
      expect(sw.elapsed, lessThan(one.elapsed * 20 + 50.milliseconds));
      expect(divs.$('div').length, 3001);
    });
  });

  group('Reader.html', () {
    test('parses bytes', () async {
      final doc = await Mem('<p>hi</p>').html();
      expect(doc.$('p').text(), 'hi');
    });

    test('a piped Future<Reader> keeps its origin for links', () async {
      final src = Mem('<a href="b.html">x</a>', const Origin(url: 'https://e.com/d/'));
      final doc = await (Future<Reader>.value(src) | null).html();
      expect(doc.$('a')[0].attr('href'), 'https://e.com/d/b.html');
      final piped = await (Future<Reader>.value(src) | _Id()).html();
      expect(piped.$('a')[0].attr('href'), 'https://e.com/d/b.html');
    });

    test('mirror on Future<Reader>', () async {
      final doc = await Future<Reader>.value(Mem('<p>hi</p>')).html();
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
      final clean = doc.not('ul');
      expect(clean.$('li'), isEmpty);
      expect(clean.$('p').length, 2);
      expect(doc.$('li').length, 2); // receiver unchanged
    });

    test('without sees only the new tree', () {
      final clean = doc.not('div');
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
      final based = Html.parse('<a class="i" href="/x">a</a><a class="i" href="/y">b</a>', base: 'https://e.com/');
      expect(based.$('a.i').attrs('href'), ['https://e.com/x', 'https://e.com/y']);
    });

    test('bad selector is a FormatException naming it', () {
      expect(() => doc.$('['), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('['))));
      expect(() => doc.not('['), throwsA(isA<FormatException>()));
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
      expect((await f.not('ul')).$('li'), isEmpty);
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
      final clean = doc.$('div').not('script');
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
      final doc = Html.parse('<img src="i.png">', base: 'https://e.com/d/');
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
      expect(await f.markup(), '<div><p><a href="/x">t</a></p></div>');
      expect(await f.text(), contains('t'));
      expect(await f.$('a').attr('href'), '/x');
      expect(await f.parent(), isNull);
    });
  });

  group('document parsing (M1)', () {
    test('a full document keeps html/head/body', () {
      final doc = Html.parse('<html><head><title>t</title></head><body><p>hi</p></body></html>');
      expect(doc.$('body').length, 1);
      expect(doc.$('body').text(), 'hi');
      expect(doc.$('html').length, 1);
      expect(doc.$('title').text(), 't');
    });

    test('doctype and case variants parse as documents', () {
      expect(Html.parse('<!DOCTYPE html><html><body><p>x</p></body></html>').$('body').text(), 'x');
      expect(Html.parse('  <HTML><BODY><P>y</P></BODY></HTML>').$('body').text(), 'y');
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
      final doc = Html.parse('<table><tr class="x"><td>a</td></tr><tr><td>b</td></tr></table>');
      final kept = doc.$('tr').not('.x');
      expect(kept.length, 1);
      expect(kept.text(), 'b');
      expect(doc.$('tr').length, 2); // receiver unchanged
    });

    test('a top-level self match drops the subtree', () {
      final doc = Html.parse('<div class="x"><p>a</p></div><div><p>b</p></div>');
      final kept = doc.$('div').not('.x');
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
      final doc = Html.parse('<a href=" /path ">t</a>', base: 'https://e.com/d/');
      expect(doc.$('a')[0].attr('href'), 'https://e.com/path');
    });

    test('data-src, poster and action resolve too', () {
      final doc = Html.parse('<img data-src=" img.png "><video poster=" p.png ">', base: 'https://e.com/d/');
      expect(doc.$('img')[0].attr('data-src'), 'https://e.com/d/img.png');
      expect(doc.$('video')[0].attr('poster'), 'https://e.com/d/p.png');
      final form = Html.parse('<form action=" /go ">', base: 'https://e.com/d/');
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

  group('fragments with loose text', () {
    test('the fragment root holds the text; no synthetic div appears', () {
      final doc = Html.parse('Tom &amp; <b>Jerry</b> <i>!</i>');
      expect(doc.length, 1);
      expect(doc.text(), 'Tom & Jerry !');
      expect(doc.$('div'), isEmpty);
      expect(doc.$('*').texts(), ['Jerry', '!']);
      expect(doc.$('b + i').text(), '!');
      expect(doc[0].parent(), isNull);
      expect(doc.$('b')[0].parent(), isNull);
      expect(doc.not('b').text(), 'Tom & !');
    });
  });

  group('embedded data, tables, forms', () {
    test('json() reads JSON/ld+json/__NEXT_DATA__ scripts, skipping invalid ones', () {
      final doc = Html.parse('''<html><body>
<script type="application/json">{"a":{"user":{"pk":1}}}</script>
<script type="application/ld+json">{"@type":"Thing"}</script>
<script id="__NEXT_DATA__">{"props":{"user":{"pk":2}}}</script>
<script type="application/json">{broken</script>
<script>var x = {"user":{"pk":3}};</script>
</body></html>''');
      final data = doc.json();
      expect(data.length, 3);
      expect(data.$('**.user.pk').asList<int>(), [1, 2]);
      expect(doc.$('p').json().length, 0);
    });

    test('table() maps rows by the first row; colspan repeats', () {
      final doc = Html.parse('''<div><table>
<thead><tr><th>Name</th><th colspan="2">Score</th></tr></thead>
<tbody><tr><td>ann</td><td>1</td><td>2</td></tr><tr><td colspan="3">all</td></tr></tbody>
</table></div>''');
      expect(doc.table(), [
        {'Name': 'ann', 'Score': '2'},
        {'Name': 'all', 'Score': 'all'},
      ]);
      expect(Html.parse('<table><tr><td>k</td></tr><tr><td>v</td></tr></table>').table(), [
        {'k': 'v'},
      ]);
      expect(Html.parse('<p>x</p>').table(), isEmpty);
    });

    test('form() gives action, method and fields to post, hidden ones included', () {
      final doc = Html.parse('''<html><body><form action="/login" method="post">
<input type="hidden" name="csrf" value="T">
<input name="user" value="">
<input type="checkbox" name="keep" checked>
<input type="checkbox" name="spam">
<select name="lang"><option value="en">EN</option><option value="ja" selected>JA</option></select>
<textarea name="note">hi</textarea>
<input type="submit" name="go" value="Go">
<input name="off" value="x" disabled>
</form></body></html>''', base: 'https://site.test/page');
      final f = doc.form()!;
      expect(f.action, 'https://site.test/login');
      expect(f.method, 'POST');
      expect(f.fields, {
        'csrf': ['T'],
        'user': [''],
        'keep': ['on'],
        'lang': ['ja'],
        'note': ['hi'],
      });
      expect(Html.parse('<form></form>', base: 'https://a.test/x').form()!.action, 'https://a.test/x');
      expect(Html.parse('<p></p>').form(), isNull);
    });

    test('form() keeps repeated names and select multiple (regression: last value won)', () {
      final f = Html.parse('''<form>
<input type="checkbox" name="tag" value="a" checked><input type="checkbox" name="tag" value="b" checked>
<select name="pick" multiple><option selected>x</option><option>y</option><option value="z" selected>Z</option></select>
<select name="one"><option selected>p</option><option selected>q</option></select>
</form>''').form()!;
      expect(f.fields, {
        'tag': ['a', 'b'],
        'pick': ['x', 'z'],
        'one': ['q'],
      });
    });

    test('form() reads a table-wrapped form and form="id" controls (B7)', () {
      final login = Html.parse(
        '<html><body><table><form action="/in"><tr><td><input name="user" value="u">'
        '<input type="hidden" name="csrf" value="t"></td></tr></form></table></body></html>',
      ).form()!;
      expect(login.fields, {
        'user': ['u'],
        'csrf': ['t'],
      });
      final split = Html.parse(
        '<html><body><form id="f"><input name="a" value="1"></form>'
        '<input name="b" form="f" value="2"><form id="g"><input name="c" form="other"></form></body></html>',
      ).form()!;
      expect(split.fields, {
        'a': ['1'],
        'b': ['2'],
      });
    });

    test('form() without an action posts to the document URL, not <base href> (regression)', () {
      const page =
          '<html><head><base href="https://cdn.test/assets/"></head><body><form><input name="a"></form>'
          '<form action="go"></form></body></html>';
      final doc = Html.parse(page, base: 'https://site.test/page?id=1');
      expect(doc.form()!.action, 'https://site.test/page?id=1');
      expect(doc.$('form')[1].$(':scope').form()!.action, 'https://cdn.test/assets/go');
    });

    test('table() carries rowspan down (regression: ignored)', () {
      final doc = Html.parse('''<table>
<tr><th>Group</th><th>Item</th><th>Note</th></tr>
<tr><td rowspan="2">g1</td><td>a</td><td rowspan="3">n</td></tr>
<tr><td>b</td></tr>
<tr><td>g2</td><td>c</td></tr>
</table>''');
      expect(doc.table(), [
        {'Group': 'g1', 'Item': 'a', 'Note': 'n'},
        {'Group': 'g1', 'Item': 'b', 'Note': 'n'},
        {'Group': 'g2', 'Item': 'c', 'Note': 'n'},
      ]);
    });

    test('json() reads ld+json with parameters (regression: "; charset" skipped)', () {
      final doc = Html.parse(
        '<script type="application/ld+json; charset=utf-8">{"@type":"X"}</script>'
        '<script type=" Application/JSON ">[1]</script>',
      );
      expect(doc.json().length, 2);
      expect(doc.json().$('0.@type').text(), 'X');
    });
  });

  group('selectors: scope, errors, speed', () {
    test(':scope and a leading combinator are relative to the receiver', () {
      final doc = Html.parse('<ul id="o"><li>a<ul><li>b</li></ul></li><li>c</li></ul><p>x</p><p>y</p>');
      final outer = doc.$('#o')[0];
      expect(outer.$('> li').length, 2);
      expect(outer.$('li').length, 3);
      expect(outer.$(':scope > li > ul > li').text(), 'b');
      expect(outer.$(':scope').length, 1);
      expect(doc.$('ul').$('> li').texts(), ['a\nb', 'b', 'c']);
      expect(doc.$('p').$('+ p').text(), 'y', reason: 'a root itself may match relative to another root');
      // B23: a leading + or ~ reaches the receiver's later siblings.
      final h = Html.parse('<h2>t</h2><p>x</p><div><p>in</p></div><p>y</p><h2>u</h2><p>z</p>');
      expect(h.$('h2').first.$('+ p').texts(), ['x']);
      expect(h.$('h2').first.$('~ p').texts(), ['x', 'y', 'z']);
      expect(h.$('h2').$('+ p').texts(), ['x', 'z']);
      expect(h.$('h2').first.$('~ div p').texts(), ['in']);
      expect(doc.$('p')[0].$('+ p').text(), 'y');
      expect(doc.$('#o').not('> li > ul').$('li').length, 2);
      expect(doc.$(':scope'), hasLength(3), reason: 'the top-level elements are the scope');
    });

    test('a bad selector names itself once (regression: prefix doubled)', () {
      for (final bad in ['p[', 'a:nope', ':nth-child(x)', '> ', 'a,']) {
        expect(
          () => Html.parse('<p>x</p>').$(bad),
          throwsA(
            isA<ContentException>().having((e) => 'invalid selector'.allMatches(e.message).length, 'prefix count', 1),
          ),
          reason: bad,
        );
      }
      expect(
        () => Html.parse('<p>x</p>').$('p['),
        throwsA(isA<ContentException>().having((e) => e.message, 'message', "invalid selector 'p[': expected a name")),
      );
      expect(() => Html.parse('<p>x</p>').not('p['), throwsA(isA<ContentException>()));
    });

    test('*-of-type and nth-child(of S) stay linear on a long list (regression: O(n²))', () {
      final doc = Html.parse('<ul>${'<li>x</li><li class="k">y</li>' * 10000}</ul>');
      final sw = Stopwatch()..start();
      expect(doc.$('li:last-of-type'), hasLength(1));
      expect(doc.$('li:nth-of-type(2n)'), hasLength(10000));
      expect(doc.$('li:only-of-type'), isEmpty);
      expect(doc.$('li:nth-child(odd of .k)'), hasLength(5000));
      expect(doc.$('li:nth-last-child(1 of .k)'), hasLength(1));
      expect(sw.elapsedMilliseconds, lessThan(1000)); // was 1-3.5 s per query
      final mixed = Html.parse('<div><b>1</b><i>2</i><b>3</b><i>4</i></div>');
      expect(mixed.$('b:last-of-type').text(), '3');
      expect(mixed.$('i:first-of-type').text(), '2');
      expect(mixed.$('i:nth-last-of-type(2)').text(), '2');
      expect(mixed.$(':nth-child(2 of b)').text(), '3');
    });
  });

  group('links and markup', () {
    test('srcset candidates and a meta content path resolve against the base', () {
      final doc = Html.parse(
        '<img srcset="a.jpg 1x, /b.jpg 2x,c.jpg" data-srcset="  d.webp 640w  ">'
        '<meta property="og:image" content="/og.jpg"><meta property="og:title" content="Hello / world">'
        '<meta name="u" content="https://abs.test/x.jpg">',
        base: 'https://s.test/p/',
      );
      expect(doc.$('img').attr('srcset'), 'https://s.test/p/a.jpg 1x, https://s.test/b.jpg 2x, https://s.test/p/c.jpg');
      expect(doc.$('img').attr('data-srcset'), 'https://s.test/p/d.webp 640w');
      expect(doc.$('meta[property="og:image"]').attr('content'), 'https://s.test/og.jpg');
      expect(doc.$('meta[property="og:title"]').attr('content'), 'Hello / world');
      expect(doc.$('meta[name=u]').attr('content'), 'https://abs.test/x.jpg');
      expect(Html.parse('<img srcset="a.jpg 1x">').$('img').attr('srcset'), 'a.jpg 1x');
    });

    test('html() is the outer markup: escaped text, raw scripts, void elements', () {
      final doc = Html.parse(
        '<div class="a&quot;b" id=x>1 &lt; 2 &amp; 3 <br><script>if (a < b) {}</script><img src=i.png></div>',
      );
      expect(
        doc.$('div')[0].markup(),
        '<div class="a&quot;b" id="x">1 &lt; 2 &amp; 3&nbsp;<br><script>if (a < b) {}</script><img src="i.png"></div>',
      );
      expect(doc.$('br').markup(), '<br>');
      expect(doc.$('nope').markup(), '');
      expect(Html.parse('loose <b>t</b>').markup(), 'loose <b>t</b>');
      final deep = Html.parse('${'<i>' * 20000}x');
      expect(deep.$('i')[0].markup(), hasLength(20000 * 7 + 1));
    });

    test('html exports json: chains reach Json with one import', () async {
      final j = await Mem('<script type="application/json">{"a":{"b":5}}</script>').html().json().$('**.b');
      expect(j.asList<int>(), [5]);
    });
  });
}

final class _Id with Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) => input;
}
