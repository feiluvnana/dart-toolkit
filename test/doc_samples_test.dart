/// Hand-written checks that the documented samples *behave* as documented.
///
/// Compiling them is `test/docs_test.dart`, which extracts and analyzes every
/// `dart` block in `docs/`, `README.md`, `NAMESPACE.md` and every `///`
/// comment under `lib/`. This file is the other half: a sample that compiles
/// can still return the wrong answer, so the ones whose *output* the docs
/// state are asserted here.
library;

import 'dart:io' as dart_io;

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/html.dart';
import 'package:test/test.dart';

void main() {
  group('Documentation Samples Verification', () {
    test('html.md samples work as documented', () {
      const html = '''
        <ul class="tracks">
          <li class="track" data-id="1"><a href="/t/1">Track One</a></li>
          <li class="track bonus" data-id="2"><a href="/t/2">Track Two</a></li>
        </ul>
      ''';

      expect(
        $(html).find('.track a').texts.iterable,
        equals(['Track One', 'Track Two']),
      );
      expect(html.$('.bonus').data('id'), equals('2'));

      final res = Reply.text('''
          <div class="main">
            <h1>Breaking News</h1>
            <p class="desc">A story</p>
            <a class="morelink" href="https://example.com/next">More</a>
            <ul>
              <li>0</li>
              <li>1</li>
              <li>2</li>
            </ul>
          </div>
        ''', requested: 'https://example.com'.url);

      expect(
        res.parse(format.html).find('a:contains("More")').count,
        equals(1),
      );
      expect(res.parse(format.html).find('div:has(p.desc)').count, equals(1));
      expect(
        res.parse(format.html).find('ul > li:even').texts.iterable,
        equals(['0', '2']),
      );
      expect(
        res.parse(format.html).find(':header').texts.iterable,
        equals(['Breaking News']),
      );
      expect(
        res.parse(format.html).xpath('//a[@class="morelink"]').texts.iterable,
        equals(['More']),
      );

      expect(
        res.parse(format.html).find('a.morelink').attr('href'),
        equals('https://example.com/next'),
      );
      expect(
        res.parse(format.html).find('a.morelink').attrs('href').iterable,
        equals(['https://example.com/next']),
      );
      expect(res.parse(format.html).find('h1').text, equals('Breaking News'));
      expect(
        res.parse(format.html).find('h1').texts.iterable,
        equals(['Breaking News']),
      );

      final brHtml = '<div>01. First<br>02. Second</div>';
      expect($(brHtml).lines.iterable, equals(['01. First', '02. Second']));
    });

    test('crawl.md samples and builder options compile and execute', () async {
      final titles = await net
          .crawl<String>('https://news.ycombinator.com'.url)
          .concurrent(4)
          .delay(250.ms, perhost: true)
          .perhost(true)
          .limit(1)
          .depth(1)
          .allow(RegExp(r'.*'))
          .deny(RegExp(r'\.pdf$'))
          .samehost(false)
          .headers({'User-Agent': 'TestBot'})
          .timeout(5.s)
          .downloader(
            MapDownloader<String>({
              'https://news.ycombinator.com':
                  '<html><body><a class="titleline" href="/item">Title 1</a></body></html>',
            }),
          )
          .collect((res) {
            for (final title
                in res.parse(format.html).find('.titleline').texts.iterable) {
              res.emit(title);
            }
          });

      expect(titles.iterable, equals(['Title 1']));
    });

    test('http.md declarative extract and features work as documented', () {
      final res = Reply.text('''
          <html>
            <head><link rel="canonical" href="https://example.com/product/1"></head>
            <body>
              <h1 class="title">Widget</h1>
              <span class="price">\$19.99</span>
              <ul class="breadcrumbs">
                <li>Home</li>
                <li>Tools</li>
              </ul>
              <div class="review">
                <span class="author">Alice</span>
                <span class="stars" data-rating="5">*****</span>
                <p class="body">Great!</p>
              </div>
            </body>
          </html>
        ''', requested: 'https://example.com/product/1'.url);

      final product = res.parse(format.html).extract({
        'title': 'h1.title',
        'price': '.price@text',
        'canonical': 'link[rel="canonical"]@href',
        'categories': ['ul.breadcrumbs > li'],
        'reviews': [
          '.review',
          {
            'user': '.author',
            'rating': '.stars@data-rating',
            'comment': '.body',
          },
        ],
      });

      expect(product['title'], equals('Widget'));
      expect(product['price'], equals('\$19.99'));
      expect(product['canonical'], equals('https://example.com/product/1'));
      expect(product['categories'], equals(['Home', 'Tools']));
      final reviews = product['reviews'] as List<dynamic>;
      expect(reviews.length, equals(1));
      expect((reviews[0] as Map)['user'], equals('Alice'));
      expect((reviews[0] as Map)['rating'], equals('5'));
      expect((reviews[0] as Map)['comment'], equals('Great!'));
    });

    test('concurrent.md features run as documented', () async {
      // 1. stream
      final streamResults = await concurrent.stream<int, String>([20, 10], (
        ms,
      ) async {
        await util.time.wait(ms.ms);
        return 'done-$ms';
      }, size: 2).toList();
      expect(streamResults, containsAll(['done-20', 'done-10']));

      // 2. settle
      final pool = Pool<int>(size: 2);
      final settled = await pool.settle([2, 0], (n) async {
        if (n == 0) throw Exception('zero');
        return 10 ~/ n;
      });
      expect(settled.collect(.list())[0].ok, isTrue);
      expect(settled.collect(.list())[0].value, equals(5));
      expect(settled.collect(.list())[1].ok, isFalse);

      // 3. retry
      var attempts = 0;
      final retried = await concurrent.retry(
        () async {
          attempts++;
          if (attempts < 2) throw Exception('temporary');
          return 'success';
        },
        retries: 2,
        backoff: 10.ms,
      );
      expect(retried, equals('success'));
      expect(attempts, equals(2));

      // 4. Semaphore — `concurrent.mutex()` was Semaphore(1) under a second
      // name, so one argument covers both.
      final sem = Semaphore(2);
      await sem.take();
      sem.release();
      await concurrent.semaphore(1).guard(() async {});
    });

    test('form.md samples read a form as documented', () {
      final page = Reply.text('''
        <div id="panel">
          <form id="login" action="/session" method="post">
            <input type="hidden" name="csrf" value="tok-123">
            <input type="text" name="user">
            <input type="checkbox" name="remember" value="yes" checked>
            <select name="lang">
              <option value="en">English</option>
              <option value="fr" selected>French</option>
            </select>
            <button type="submit" name="do" value="login">Log in</button>
          </form>
        </div>
        <form class="search" action="/search?stale=1">
          <input name="q" value="dart">
        </form>
      ''', requested: 'https://example.com/login'.url);

      final markup = page.parse(format.html);

      // The table of what a form collects.
      expect(markup.form('#login')!.fields, {
        'csrf': 'tok-123',
        'user': '',
        'remember': 'yes',
        'lang': 'fr',
        'do': 'login',
      });

      // A wrapper's id finds the form inside it.
      expect(markup.form('#panel')!.element.attributes['id'], equals('login'));
      expect(markup.form('form:has(input[type=hidden])'), isNotNull);

      // Filling returns the form, and keeps what the page carried. `at` tells
      // it where the markup came from, which a cursor cannot know.
      final form = markup.form('#login')!.at(page.url).fill({'user': 'me'});
      expect(form.fields['user'], equals('me'));
      expect(form.fields['csrf'], equals('tok-123'));
      expect(form.method, equals(HttpMethod.post));
      expect(form.action, equals(Uri.parse('https://example.com/session')));

      // A GET carries its fields in the query, replacing the action's own.
      expect(
        markup.form('form.search')!.at(page.url).fill({'q': 'widgets'}).url,
        equals(Uri.parse('https://example.com/search?q=widgets')),
      );

      // A page with no form says so.
      expect(format.html.parse('<p>none</p>').form(), isNull);
    });

    test('cli.md features parse as documented', () {
      final cli = Cli([
        '--force',
        '--concurrency',
        '8',
        '--offset',
        '-5',
        '--no-cache',
        '--',
        'file.txt',
      ]);

      final force = cli.flag('force', alias: 'f', desc: 'Overwrite');
      final size = cli.number(
        'concurrency',
        alias: 'c',
        desc: 'Workers',
        def: 4,
      );
      final offset = cli.number('offset', desc: 'Offset');
      final cache = cli.flag('cache', desc: 'Cache', def: true);

      expect(force(), isTrue);
      expect(size(), equals(8));
      expect(offset(), equals(-5));
      expect(cache.negated(), isTrue);
      expect(cache(), isFalse);
      expect(cli.args, equals(['file.txt']));

      final help = cli.usage(syntax: 'tool [options]');
      expect(help, contains('tool [options]'));
      expect(help, contains('--force'));
    });

    test('csv.md matrix read, stream, write work as documented', () async {
      final temp = dart_io.Directory.systemTemp.createTempSync('doc_csv_');
      try {
        final path = dart_io.File('${temp.path}/people.csv').path;
        await io.csv.write(path, [
          {'name': 'Alice', 'role': 'admin'},
          {'name': 'Bob', 'role': 'user'},
        ]);

        final sheet = await format.csv.read(path);
        expect(sheet.maps.collect(.count()), equals(2));
        expect(sheet.maps.collect(.first())?['name'], equals('Alice'));
        expect(sheet.column('name').iterable, equals(['Alice', 'Bob']));

        expect(sheet.headers.iterable, equals(['name', 'role']));
        expect(sheet.count, equals(2));
        expect(
          sheet.rows.collect(.first())?.iterable,
          equals(['Alice', 'admin']),
        );

        final streamed = await io.csv.records(path).toList();
        expect(streamed.length, equals(2));

        final cells = await io.csv.rows(path).toList();
        expect(cells.first, equals(['name', 'role']));

        // Excel and RFC 4180 want CRLF, which format and write both take.
        expect(
          format.csv.format([
            {'a': '1'},
          ], newline: '\r\n'),
          equals('a\r\n1\r\n'),
        );
      } finally {
        io.remove(temp.path);
      }
    });
  });
}
