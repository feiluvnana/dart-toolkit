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
      expect(query.find('.title').text, equals('Album Title'));
    });

    test('String.\$ selects straight out of markup', () {
      final tracks = sampleHtml.$('.track');
      expect(tracks.count, equals(3));
      expect(tracks.elements.first!.$('.num').text, equals('01.'));
      expect(tracks.elements.last!.$('.num').text, equals('03.'));
    });

    test('text, texts, and html extraction', () {
      final doc = $(sampleHtml);
      expect(doc.find('h1').text, equals('Album Title'));
      expect(
        doc.find('.track a').texts,
        equals(['Track One', 'Track Two', 'Bonus Track']),
      );
      expect(doc.find('.footer p').text, equals('Copyright 2026'));
      expect(doc.find('.footer').html.trim(), equals('<p>Copyright 2026</p>'));
    });

    test('attributes extraction with attr and attrs', () {
      final doc = $(sampleHtml);
      expect(doc.find('.track').attr('data-id'), equals('1'));
      expect(doc.find('.track').attrs('data-id'), equals(['1', '2', '3']));
      expect(
        doc.find('.track a').attrs('href'),
        equals(['/track/1', '/track/2', 'https://example.com/bonus']),
      );
    });

    test('traversal: find, children, parent, filter, matching, and eq', () {
      final doc = $(sampleHtml);

      expect(doc.find('.track').at(1).find('.link').text, equals('Track Two'));
      expect(
        doc.find('.track').at(-1).find('.link').text,
        equals('Bonus Track'),
      );
      expect(doc.find('.track').at(9).empty, isTrue);

      final bonus = doc
          .find('.track')
          .filter((Element el) => el.classes.contains('bonus'));
      expect(bonus.count, equals(1));
      expect(bonus.find('.link').text, equals('Bonus Track'));

      // Selector-based filtering is a separate, typed method.
      expect(doc.find('.track').matching('.bonus').count, equals(1));
      expect(doc.find('.track').not('.bonus').count, equals(2));

      expect(bonus.has('bonus'), isTrue);
      expect(bonus.has('non-existent'), isFalse);

      expect(doc.find('.track-list').children().count, equals(3));
      expect(doc.find('.track').parent().has('track-list'), isTrue);
      expect(doc.find('.num').closest('.track').count, equals(3));
      expect(doc.find('.track').at(0).siblings().count, equals(2));
    });

    test('extensions on String and Element', () {
      final q = sampleHtml.$('.title');
      expect(q.text, equals('Album Title'));

      final elem = q.elements.first;
      expect(elem, isNotNull);
      expect(elem!.query.text, equals('Album Title'));
      expect(elem.attr('class'), equals('title'));
    });

    test('data reads a single key and dataset reads them all', () {
      final track = $(sampleHtml).find('.track');
      expect(track.data('id'), equals('1'));
      expect(track.dataset, equals({'id': '1'}));
    });

    test('Markup is a real Iterable', () {
      final texts = $(
        sampleHtml,
      ).find('.num').elements.to((Element e) => e.text.trim());
      expect(texts.list, equals(['01.', '02.', '03.']));
    });

    test('firstOrNull and find() / call() API', () {
      final q = $(sampleHtml);
      final firstTrack = q.find('.track').elements.first;
      expect(firstTrack, isNotNull);
      expect(firstTrack?.attr('data-id'), equals('1'));
      expect(q.find('.missing').elements.first, isNull);

      final allTracks = q('.track');
      expect(allTracks.count, equals(3));
      expect(allTracks.elements.first!.attr('data-id'), equals('1'));
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
        expect(doc.find('a:contains("First")').text, equals('First Button'));
        expect(doc.find('span:icontains("click")').text, equals('Click here'));

        // :has
        final boxWithLink = doc.find('.box:has(a.btn)');
        expect(boxWithLink.count, equals(1));
        expect(boxWithLink.has('with-link'), isTrue);

        // :header
        expect(
          doc.find(':header').texts,
          equals(['Main Header', 'Sub Header']),
        );

        // :first and :last
        expect(doc.find('ul li:first').text, equals('Row 0'));
        expect(doc.find('ul li:last').text, equals('Row 3'));

        // :even and :odd
        expect(doc.find('ul li:even').texts, equals(['Row 0', 'Row 2']));
        expect(doc.find('ul li:odd').texts, equals(['Row 1', 'Row 3']));

        // :eq with positive and negative index
        expect(doc.find('ul li:eq(1)').text, equals('Row 1'));
        expect(doc.find('ul li:eq(-1)').text, equals('Row 3'));

        // :input
        expect(doc.find(':input').count, equals(2));
        expect(doc.find(':checkbox').count, equals(1));
        expect(doc.find(':text').attr('value'), equals('Alice'));

        // :empty
        expect(doc.find('div:empty').has('empty-div'), isTrue);
      },
    );

    test('XPath querying with \$xpath, xpath(), and xpathvalues()', () {
      final xp = $xpath(sampleHtml);

      // firstOrNull on xpath result
      final firstA = xp('//a').elements.first;
      expect(firstA, isNotNull);
      expect(firstA?.text.trim(), equals('Track One'));

      // xpath returns Markup
      final allA = xp('//a');
      expect(allA.count, equals(3));
      expect(allA.texts, equals(['Track One', 'Track Two', 'Bonus Track']));

      // XPath values (text nodes and attributes)
      expect(
        xp.xpathvalues('//a/text()'),
        equals(['Track One', 'Track Two', 'Bonus Track']),
      );
      expect(
        xp.xpathvalues('//a/@href'),
        equals(['/track/1', '/track/2', 'https://example.com/bonus']),
      );
      expect(xp('//a').href, equals('/track/1'));
      expect(
        xp('//a').hrefs,
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

        final selector = mediaHtml.$;

        // Chainable Markup attribute helpers
        expect(selector('a').href, equals('/target1'));
        expect(selector('a').hrefs, equals(['/target1', '/target2']));
        expect(selector('img').src, equals('/img/1.png'));
        expect(selector('img').srcs, equals(['/img/1.png', '/img/2.png']));
        expect(selector('a').attr('title'), equals('Link Title 1'));
        expect(
          selector('a').attrs('title'),
          equals(['Link Title 1', 'Link Title 2']),
        );
        expect(selector('img').attr('alt'), equals('Image 1'));
        expect(selector('img').attrs('alt'), equals(['Image 1', 'Image 2']));
        expect(selector('form').attr('action'), equals('/submit-form'));
        expect(selector('input').value, equals('test@example.com'));

        // Markup getters
        final q = $(mediaHtml);
        expect(q.find('a').href, equals('/target1'));
        expect(q.find('a').hrefs, equals(['/target1', '/target2']));
        expect(q.find('a').attr('title'), equals('Link Title 1'));
        expect(
          q.find('a').attrs('title'),
          equals(['Link Title 1', 'Link Title 2']),
        );
        expect(q.find('img').attr('alt'), equals('Image 1'));
        expect(q.find('img').attrs('alt'), equals(['Image 1', 'Image 2']));
        expect(q.find('form').attr('action'), equals('/submit-form'));
        expect(q.find('input').value, equals('test@example.com'));

        // Element extension getters
        final firstImg = q.find('img').elements.first;
        expect(firstImg?.src, equals('/img/1.png'));
        expect(firstImg?.attr('alt'), equals('Image 1'));
      },
    );

    test('handles nested and quoted pseudo-selectors', () {
      // The targets sit *below* the fragment's top-level element, because
      // find() searches descendants — see the agreement test further down.
      final nested = $(
        '<section><div><p><b>hi</b></p></div></section>',
      ).find('div:has(p:contains(hi))');
      expect(nested.count, equals(1));

      final quotedParen = $('<div><p>a)b</p></div>').find('p:contains("a)b")');
      expect(quotedParen.count, equals(1));

      final escapedQuote = $(
        '<div><p>a"b</p></div>',
      ).find(r'p:contains("a\"b")');
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
      expect(fragment.find('div').count, equals(1));
      expect(fragment.find('div:contains(hello)').count, equals(1));
      expect(fragment.find('.x:first').count, equals(1));
      expect(fragment('div:contains(hello)').count, equals(1));
      expect(fragment.matching('div:contains(hello)').count, equals(1));

      // An extended selector used to match the context element itself while
      // the plain-CSS fast path did not, so the same query answered
      // differently depending on whether it happened to carry a pseudo.
      final page = $('<html><body><p>x</p></body></html>');
      expect(page('body:has(p)').count, equals(1));
      expect(page.find('body:has(p)').count, equals(1));

      // Scoped, though: the result of a search is not rooted on the document,
      // so a chained find cannot quietly search the page again.
      final rows = $(
        '<div class="row"><b class="name">in</b></div><b class="name">out</b>',
      );
      expect(rows.find('.name').count, equals(2));
      expect(rows.find('.row').find('.name').texts, equals(['in']));
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
      final fields = form.find('input, textarea');
      expect(fields.elements.first!.value, equals('alice'));
      expect(fields.at(1).value, equals('Software developer'));
      expect(fields.values, equals(['alice', 'Software developer', 'admin']));
    });

    test(
      'href and hrefs return own attributes without searching descendants',
      () {
        const containerHtml = '''
        <div class="card" id="c1">
          <a href="/card/1">Item 1</a>
        </div>
      ''';
        final card = containerHtml.$('.card');
        // The card container itself has no href attribute:
        expect(card.href, isNull);
        expect(card.elements.first?.href, isNull);
        expect(card.hrefs, isEmpty);

        // Descendant links are reached when queried explicitly:
        expect(card.find('a').href, equals('/card/1'));
        expect(card.find('a').hrefs, equals(['/card/1']));
      },
    );

    test('system.console builds a Table, Progress and Spinner', () {
      final table = system.console.table(headers: ['Name', 'Age']);
      table.add(['Bob', 30]);
      expect(table.headers, equals(['Name', 'Age']));
      expect(table.render(), contains('Bob'));

      final progress = system.console.progress(
        total: 10,
        message: 'Downloading',
      );
      expect(progress.total, equals(10));

      expect(system.console.spinner().spinning, isFalse);
    });
  });
}
