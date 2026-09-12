import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/html.dart';
import 'package:html/dom.dart';
import 'package:test/test.dart';

void main() {
  group('jQuery-like Selector \$()', () {
    const sampleHtml = '''
    <div id="container" class="main-box">
      <h1 class="title">Album Title</h1>
      <ul class="track-list">
        <li class="track" data-id="1">
          <span class="num">01.</span>
          <a href="/track/1" class="link">Track One</a>
          <span class="duration">03:45</span>
        </li>
        <li class="track" data-id="2">
          <span class="num">02.</span>
          <a href="/track/2" class="link">Track Two</a>
          <span class="duration">04:12</span>
        </li>
        <li class="track bonus" data-id="3">
          <span class="num">03.</span>
          <a href="https://example.com/bonus" class="link">Bonus Track</a>
          <span class="duration">05:00</span>
        </li>
      </ul>
      <div class="footer">
        <p>Copyright 2026</p>
      </div>
    </div>
    ''';

    test('parses HTML markup directly into Markup', () {
      final query = $(sampleHtml);
      expect(query.empty, isFalse);
      expect(query.$('.title').text, equals('Album Title'));
    });

    test('\$ selects straight out of markup', () {
      final tracks = $(sampleHtml, '.track');
      expect(tracks.count, equals(3));
      expect(
        tracks.elements.first.query.$('.num').text,
        equals('01.'),
      );
      expect(
        tracks.elements.last.query.$('.num').text,
        equals('03.'),
      );
    });

    test('text, texts, and html extraction', () {
      final doc = $(sampleHtml);
      expect(doc.$('h1').text, equals('Album Title'));
      expect(
        doc.$('.track a').texts,
        equals(['Track One', 'Track Two', 'Bonus Track']),
      );
      expect(doc.$('.footer p').text, equals('Copyright 2026'));
      expect(doc.$('.footer').html.trim(), equals('<p>Copyright 2026</p>'));
    });

    test('attributes extraction with attr and attrs', () {
      final doc = $(sampleHtml);
      expect(doc.$('.track').attr('data-id'), equals('1'));
      expect(
        doc.$('.track').attrs('data-id'),
        equals(['1', '2', '3']),
      );
      expect(
        doc.$('.track a').attrs('href'),
        equals(['/track/1', '/track/2', 'https://example.com/bonus']),
      );
    });

    test('traversal: find, children, parent, filter, matching, and eq', () {
      final doc = $(sampleHtml);

      expect(doc.$('.track').at(1).$('.link').text, equals('Track Two'));
      expect(doc.$('.track').at(-1).$('.link').text, equals('Bonus Track'));
      expect(doc.$('.track').at(9).empty, isTrue);

      final bonus = doc
          .$('.track')
          .filter((Element el) => el.classes.contains('bonus'));
      expect(bonus.count, equals(1));
      expect(bonus.$('.link').text, equals('Bonus Track'));

      // Selector-based filtering is a separate, typed method.
      expect(doc.$('.track').matching('.bonus').count, equals(1));
      expect(doc.$('.track').matching(':not(.bonus)').count, equals(2));

      expect(bonus.matching('.bonus').empty, isFalse);
      expect(bonus.matching('.non-existent').empty, isTrue);

      expect(doc.$('.track-list').children().count, equals(3));
      expect(doc.$('.track').parent().matching('.track-list').empty, isFalse);
      expect(doc.$('.num').closest('.track').count, equals(3));
      expect(doc.$('.track').at(0).siblings().count, equals(2));
    });

    test('the cursor door, and the extension on Element', () {
      final q = $(sampleHtml, '.title');
      expect(q.text, equals('Album Title'));

      final elem = q.elements.firstOrNull;
      expect(elem, isNotNull);
      expect(elem!.query.text, equals('Album Title'));
      expect(elem.attributes['class'], equals('title'));
    });

    test('a data attribute is attr with its prefix spelled out', () {
      final track = $(sampleHtml).$('.track');
      expect(track.attr('data-id'), equals('1'));
      expect(
        track.elements.first.attributes.keys.where(
          (k) => '$k'.startsWith('data-'),
        ),
        equals(['data-id']),
      );
    });

    test('Markup is a real Iterable', () {
      final texts = $(
        sampleHtml,
      ).$('.num').elements.map((Element e) => e.text.trim()).toList();
      expect(texts, equals(['01.', '02.', '03.']));
    });

    test('firstOrNull and find() / call() API', () {
      final q = $(sampleHtml);
      final firstTrack = q.$('.track').elements.firstOrNull;
      expect(firstTrack, isNotNull);
      expect(firstTrack?.attributes['data-id'], equals('1'));
      expect(q.$('.missing').elements.firstOrNull, isNull);

      final allTracks = q.$('.track');
      expect(allTracks.count, equals(3));
      expect(
        allTracks.elements.first.attributes['data-id'],
        equals('1'),
      );
    });

    test(
      'jQuery-like selectors: :contains, :has, :eq, :first, :last, :even, :odd, :header, :input',
      () {
        const advancedHtml = '''
        <div id="page">
          <h1>Main Header</h1>
          <h2>Sub Header</h2>
          <div class="box with-link">
            <a href="/alpha" class="btn">First Button</a>
            <span class="info">Click here</span>
          </div>
          <div class="box no-link">
            <span class="info">No button here</span>
            <input type="text" name="user" value="Alice" />
            <input type="checkbox" checked />
          </div>
          <div class="empty-div"></div>
          <ul>
            <li class="row">Row 0</li>
            <li class="row">Row 1</li>
            <li class="row">Row 2</li>
            <li class="row">Row 3</li>
          </ul>
        </div>
      ''';

        final doc = $(advancedHtml);

        // :contains and :icontains
        expect(doc.$('a:contains("First")').text, equals('First Button'));
        expect(doc.$('span:icontains("click")').text, equals('Click here'));

        // :has
        final boxWithLink = doc.$('.box:has(a.btn)');
        expect(boxWithLink.count, equals(1));
        expect(boxWithLink.matching('.with-link').empty, isFalse);

        // :header
        expect(
          doc.$(':header').texts,
          equals(['Main Header', 'Sub Header']),
        );

        // :first and :last
        expect(doc.$('ul li:first').text, equals('Row 0'));
        expect(doc.$('ul li:last').text, equals('Row 3'));

        // :even and :odd
        expect(
          doc.$('ul li:even').texts,
          equals(['Row 0', 'Row 2']),
        );
        expect(
          doc.$('ul li:odd').texts,
          equals(['Row 1', 'Row 3']),
        );

        // :eq with positive and negative index
        expect(doc.$('ul li:eq(1)').text, equals('Row 1'));
        expect(doc.$('ul li:eq(-1)').text, equals('Row 3'));

        // :input
        expect(doc.$(':input').count, equals(2));
        expect(doc.$(':checkbox').count, equals(1));
        expect(doc.$(':text').attr('value'), equals('Alice'));

        // :empty
        expect(doc.$('div:empty').matching('.empty-div').empty, isFalse);
      },
    );

    test('XPath querying with \$xpath, xpath(), and xpathvalues()', () {
      final xp = $xpath(sampleHtml);

      // firstOrNull on xpath result
      final firstA = xp.$xpath('//a').elements.firstOrNull;
      expect(firstA, isNotNull);
      expect(firstA?.text.trim(), equals('Track One'));

      // xpath returns Markup
      final allA = xp.$xpath('//a');
      expect(allA.count, equals(3));
      expect(
        allA.texts,
        equals(['Track One', 'Track Two', 'Bonus Track']),
      );

      // Text and attributes off an XPath cursor, read the way a CSS one is
      // read. `xpathvalues` was a third reader for this through 6.1.0.
      expect(
        xp.$xpath('//a').texts,
        equals(['Track One', 'Track Two', 'Bonus Track']),
      );
      expect(
        xp.$xpath('//a').attrs('href'),
        equals(['/track/1', '/track/2', 'https://example.com/bonus']),
      );
      expect(xp.$xpath('//a').attr('href'), equals('/track/1'));
      expect(
        xp.$xpath('//a').attrs('href'),
        equals(['/track/1', '/track/2', 'https://example.com/bonus']),
      );
    });

    test(
      'frequently used crawler attribute helpers: href, hrefs, src, srcs, text, texts',
      () {
        const mediaHtml = '''
        <div id="wrapper">
          <a href="/target1" title="Link Title 1">Alpha</a>
          <a href="/target2" title="Link Title 2">Beta</a>
          <img src="/img/1.png" alt="Image 1" />
          <img src="/img/2.png" alt="Image 2" />
          <form action="/submit-form">
            <input name="email" value="test@example.com" />
          </form>
        </div>
      ''';

        final selector = $(mediaHtml);

        // Chainable Markup attribute helpers
        expect(selector.$('a').attr('href'), equals('/target1'));
        expect(
          selector.$('a').attrs('href'),
          equals(['/target1', '/target2']),
        );
        expect(selector.$('img').attr('src'), equals('/img/1.png'));
        expect(
          selector.$('img').attrs('src'),
          equals(['/img/1.png', '/img/2.png']),
        );
        expect(selector.$('a').attr('title'), equals('Link Title 1'));
        expect(
          selector.$('a').attrs('title'),
          equals(['Link Title 1', 'Link Title 2']),
        );
        expect(selector.$('img').attr('alt'), equals('Image 1'));
        expect(
          selector.$('img').attrs('alt'),
          equals(['Image 1', 'Image 2']),
        );
        expect(selector.$('form').attr('action'), equals('/submit-form'));
        expect(selector.$('input').value, equals('test@example.com'));

        // Markup getters
        final q = $(mediaHtml);
        expect(q.$('a').attr('href'), equals('/target1'));
        expect(
          q.$('a').attrs('href'),
          equals(['/target1', '/target2']),
        );
        expect(q.$('a').attr('title'), equals('Link Title 1'));
        expect(
          q.$('a').attrs('title'),
          equals(['Link Title 1', 'Link Title 2']),
        );
        expect(q.$('img').attr('alt'), equals('Image 1'));
        expect(
          q.$('img').attrs('alt'),
          equals(['Image 1', 'Image 2']),
        );
        expect(q.$('form').attr('action'), equals('/submit-form'));
        expect(q.$('input').value, equals('test@example.com'));

        // Element extension getters
        final firstImg = q.$('img').elements.firstOrNull;
        expect(firstImg?.attributes['src'], equals('/img/1.png'));
        expect(firstImg?.attributes['alt'], equals('Image 1'));
      },
    );

    test('handles nested and quoted pseudo-selectors', () {
      // The targets sit *below* the fragment's top-level element, because
      // find() searches descendants — see the agreement test further down.
      final nested = $(
        '<section><div><p><b>hi</b></p></div></section>',
      ).$('div:has(p:contains(hi))');
      expect(nested.count, equals(1));

      final quotedParen = $('<div><p>a)b</p></div>').$('p:contains("a)b")');
      expect(quotedParen.count, equals(1));

      final escapedQuote = $('<div><p>a"b</p></div>').$(r'p:contains("a\"b")');
      expect(escapedQuote.count, equals(1));
    });

    test('find and the callable are one search, whichever selector', () {
      // 4.0.0: `find` used to mean strict descendants of the current set while
      // the callable searched the whole parsed document, so on a page cursor —
      // whose elements are the body's *children* — `find('h1')` missed an h1
      // sitting at the top level and `('h1')` did not. One page, two answers,
      // depending on which spelling you reached for. They are the same search
      // now, and `matching` is how you ask whether the set itself qualifies.
      final fragment = $('<div class="x">hello</div>');
      expect(fragment.$('div').count, equals(1));
      expect(fragment.$('div:contains(hello)').count, equals(1));
      expect(fragment.$('.x:first').count, equals(1));
      expect(fragment.$('div:contains(hello)').count, equals(1));
      expect(fragment.matching('div:contains(hello)').count, equals(1));

      // An extended selector used to match the context element itself while
      // the plain-CSS fast path did not, so the same query answered
      // differently depending on whether it happened to carry a pseudo.
      final page = $('<html><body><p>x</p></body></html>');
      expect(page.$('body:has(p)').count, equals(1));
      expect(page.$('body:has(p)').count, equals(1));

      // Scoped, though: the result of a search is not rooted on the document,
      // so a chained find cannot quietly search the page again.
      final rows = $(
        '<div class="row"><b class="name">in</b></div><b class="name">out</b>',
      );
      expect(rows.$('.name').count, equals(2));
      expect(rows.$('.row').$('.name').texts, equals(['in']));
    });

    test('value and values agree on textarea text and input value', () {
      const formHtml = '''
        <form>
          <input name="user" value="alice" />
          <textarea name="bio">Software developer</textarea>
          <input name="role" value="admin" />
        </form>
      ''';
      final form = $(formHtml);
      final fields = form.$('input, textarea');
      expect(fields.elements.first.value, equals('alice'));
      expect(fields.at(1).value, equals('Software developer'));
      expect(
        fields.elements
            .map((e) => e.value)
            .nonNulls
            .toList(),
        equals(['alice', 'Software developer', 'admin']),
      );
    });

    test(
      'href and hrefs return own attributes without searching descendants',
      () {
        const containerHtml = '''
        <div class="card" id="c1">
          <a href="/card/1">Item 1</a>
        </div>
      ''';
        final card = $(containerHtml, '.card');
        // The card container itself has no href attribute:
        expect(card.attr('href'), isNull);
        expect(card.elements.firstOrNull?.attributes['href'], isNull);
        expect(card.attrs('href'), isEmpty);

        // Descendant links are reached when queried explicitly:
        expect(card.$('a').attr('href'), equals('/card/1'));
        expect(card.$('a').attrs('href'), equals(['/card/1']));
      },
    );

    test('system.console builds a Table, Progress and Spinner', () {
      final table = System.console.table(headers: ['Name', 'Age']);
      table.add(['Bob', 30]);
      expect(table.headers, equals(['Name', 'Age']));
      expect(table.render(), contains('Bob'));

      final progress = System.console.progress(
        total: 10,
        message: 'Downloading',
      );
      expect(progress.total, equals(10));

      expect(System.console.spinner().spinning, isFalse);
    });
  });

  group('structural pseudo-classes', () {
    const html =
        '<html><body>'
        '<ul><li>1</li><li>2</li><li>3</li><li>4</li><li>5</li></ul>'
        '<div class="box">'
        '<p>pa</p><span>s1</span><p>pb</p><span>s2</span><p>pc</p>'
        '</div>'
        '<section><h2>only</h2></section>'
        '</body></html>';

    Markup page() => parseHtml(html);

    // csslib evaluates :first-child and :last-child and then stops.
    // `:nth-child(2)` matched nothing at all — a scraper written against it
    // collected nothing and reported success — and `:nth-of-type(2)` threw
    // UnimplementedError out of the middle of a match.
    test('nth-child counts every sibling', () {
      expect(page().$('li:nth-child(2)').texts, equals(['2']));
      expect(page().$('li:nth-child(1)').texts, equals(['1']));
      expect(page().$('li:nth-child(5)').texts, equals(['5']));
      expect(page().$('li:nth-child(6)').texts, isEmpty);
    });

    test('nth-child takes an+b, odd and even', () {
      expect(
        page().$('li:nth-child(odd)').texts,
        equals(['1', '3', '5']),
      );
      expect(
        page().$('li:nth-child(even)').texts,
        equals(['2', '4']),
      );
      expect(
        page().$('li:nth-child(2n+1)').texts,
        equals(['1', '3', '5']),
      );
      expect(
        page().$('li:nth-child(3n)').texts,
        equals(['3']),
      );
      expect(
        page().$('li:nth-child(-n+2)').texts,
        equals(['1', '2']),
      );
      expect(
        page().$('li:nth-child(n)').texts,
        equals(['1', '2', '3', '4', '5']),
      );
    });

    test('nth-of-type counts only siblings of the same tag', () {
      expect(
        page().$('.box p:nth-of-type(2)').texts,
        equals(['pb']),
      );
      expect(
        page().$('.box span:nth-of-type(2)').texts,
        equals(['s2']),
      );
      expect(
        page().$('.box p:first-of-type').texts,
        equals(['pa']),
      );
      expect(
        page().$('.box p:last-of-type').texts,
        equals(['pc']),
      );
      expect(
        page().$('.box span:nth-last-of-type(1)').texts,
        equals(['s2']),
      );
    });

    test('the -last- pair counts from the end', () {
      expect(
        page().$('li:nth-last-child(1)').texts,
        equals(['5']),
      );
      expect(
        page().$('li:nth-last-child(2)').texts,
        equals(['4']),
      );
      expect(
        page().$('li:nth-last-child(odd)').texts,
        equals(['1', '3', '5']),
      );
    });

    test('only-child and only-of-type', () {
      expect(
        page().$('h2:only-child').texts,
        equals(['only']),
      );
      expect(
        page().$('h2:only-of-type').texts,
        equals(['only']),
      );
      expect(page().$('li:only-child').texts, isEmpty);
      expect(page().$('.box p:only-of-type').texts, isEmpty);
    });

    test('matching uses the same evaluation as find', () {
      final second = page().$('li').at(1);
      expect(second.matching('li:nth-child(2)').count, equals(1));
      expect(second.matching('li:nth-child(3)').count, equals(0));
    });

    test('is and where match any of their branches', () {
      expect(
        page().$('.box :is(span)').texts,
        equals(['s1', 's2']),
      );
      expect(page().$(':where(h2)').texts, equals(['only']));
    });

    test('a selector this cannot evaluate is a FormatException', () {
      // csslib raised UnimplementedError — an Error, not an Exception — from
      // inside a match, in a cursor documented to give the empty result. A
      // selector it cannot read is a problem with the selector.
      expect(() => page().$('p:hover'), throwsFormatException);
      expect(() => page().$(':target'), throwsFormatException);
      expect(() => page().$('::marker'), throwsFormatException);
      expect(() => page().$('li:nth-child(banana)'), throwsFormatException);
    });
  });

  group('the simple-compound fast path', () {
    // `matching`, `not` and `closest` used to walk to the document root and
    // run `querySelectorAll` over the whole tree once per element, so testing
    // 500 rows against `.row` was 500 scans of a 500-row page — 156µs a call.
    // A compound with no combinator is answered off the element instead, which
    // is 97x faster and has to agree with csslib exactly.
    const html =
        '<html><body>'
        '<div id="main" class="wrap box" data-id="1" lang="en-GB">'
        '<p class="lead">A</p>'
        '<p class="lead active">B</p>'
        '<a href="/x.mp3" title="a b c" rel="next">m</a>'
        '<a href="/y.pdf">n</a>'
        '<input name="q" value="v" disabled>'
        '<SPAN class="Upper">U</SPAN>'
        '</div>'
        '<div class="wrap"><p>C</p></div>'
        '</body></html>';

    test('agrees with find for every shape it claims', () {
      final page = parseHtml(html);
      final every = page.$('*').elements;
      const selectors = [
        'p',
        'div',
        'a',
        '*',
        'P',
        'span',
        '.lead',
        '.active',
        '.wrap',
        '.lead.active',
        '.box.wrap',
        '#main',
        'div#main',
        'div#main.wrap',
        '[data-id]',
        '[data-id="1"]',
        '[href^="/x"]',
        r'[href$=".pdf"]',
        '[href*="y"]',
        '[title~="b"]',
        '[lang|="en"]',
        '[disabled]',
        'a[rel="next"]',
        'input[name="q"][value="v"]',
        '.nope',
        '#nope',
        '[nope]',
        '[data-id="2"]',
      ];
      for (final selector in selectors) {
        final viaFind = page.$(selector).elements.toSet();
        final viaMatching = every
            .where((Element e) => e.query.matching(selector).count == 1)
            .toSet();
        expect(
          viaMatching,
          equals(viaFind),
          reason: 'find and matching disagree on "$selector"',
        );
      }
    });

    test(
      'anything with a combinator or a pseudo still takes the slow path',
      () {
        final page = parseHtml(html);
        final b = page.$('.active').elements.first;
        expect(b.query.matching('div p').count, equals(1));
        expect(b.query.matching('div > p.active').count, equals(1));
        expect(b.query.matching('p:nth-child(2)').count, equals(1));
        expect(b.query.matching('p:first-child').count, equals(0));
        expect(b.query.matching('.lead, .nope').count, equals(1));
      },
    );
  });
}
