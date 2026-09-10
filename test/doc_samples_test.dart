import 'dart:io' as dart_io;

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/selector.dart';
import 'package:test/test.dart';

void main() {
  group('Documentation Samples Verification', () {
    test('selector.md samples work as documented', () {
      const html = '''
        <ul class="tracks">
          <li class="track" data-id="1"><a href="/t/1">Track One</a></li>
          <li class="track bonus" data-id="2"><a href="/t/2">Track Two</a></li>
        </ul>
      ''';

      expect(
        $(html).find('.track a').texts,
        equals(['Track One', 'Track Two']),
      );
      expect(html.$('.bonus').data('id'), equals('2'));

      final res = HttpResponse.text('''
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

      expect(res.$('a:contains("More")').length, equals(1));
      expect(res.$('div:has(p.desc)').length, equals(1));
      expect(res.$('ul > li:even').texts, equals(['0', '2']));
      expect(res.$(':header').texts, equals(['Breaking News']));
      expect(res.$xpath('//a[@class="morelink"]').texts, equals(['More']));

      expect(res.$('a.morelink').href, equals('https://example.com/next'));
      expect(res.$('a.morelink').hrefs, equals(['https://example.com/next']));
      expect(res.$('h1').text, equals('Breaking News'));
      expect(res.$('h1').texts, equals(['Breaking News']));

      final brHtml = '<div>01. First<br>02. Second</div>';
      expect($(brHtml).lines, equals(['01. First', '02. Second']));
    });

    test('crawl.md samples and builder options compile and execute', () async {
      final titles = await net
          .crawl<String>('https://news.ycombinator.com')
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
            for (final title in res.$('.titleline').texts) {
              res.emit(title);
            }
          });

      expect(titles, equals(['Title 1']));
    });

    test('http.md declarative extract and features work as documented', () {
      final res = HttpResponse.text('''
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

      final product = res.extract({
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
      final streamResults =
          await concurrent.stream<int, String>([20, 10], (ms) async {
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
      expect(settled[0].ok, isTrue);
      expect(settled[0].value, equals(5));
      expect(settled[1].ok, isFalse);

      // 3. compute
      final compResult = await concurrent.compute(
        (msg) => msg.toUpperCase(),
        'hello',
      );
      expect(compResult, equals('HELLO'));

      // 4. retry
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

      // 5. Mutex & Semaphore
      final mutex = Mutex();
      await mutex.protect(() async {});

      final sem = Semaphore(2);
      await sem.acquire();
      sem.release();
    });

    test('form.md samples read a form as documented', () {
      final page = HttpResponse.text('''
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

      // The table of what a form collects.
      expect(page.form('#login')!.fields, {
        'csrf': 'tok-123',
        'user': '',
        'remember': 'yes',
        'lang': 'fr',
        'do': 'login',
      });

      // A wrapper's id finds the form inside it.
      expect(page.form('#panel')!.element.attributes['id'], equals('login'));
      expect(page.form('form:has(input[type=hidden])'), isNotNull);

      // Filling returns the form, and keeps what the page carried.
      final form = page.form('#login')!.fill({'user': 'me'});
      expect(form.fields['user'], equals('me'));
      expect(form.fields['csrf'], equals('tok-123'));
      expect(form.method, equals(HttpMethod.post));
      expect(form.action, equals(Uri.parse('https://example.com/session')));

      // A GET carries its fields in the query, replacing the action's own.
      expect(
        page.form('form.search')!.fill({'q': 'widgets'}).url,
        equals(Uri.parse('https://example.com/search?q=widgets')),
      );

      // A page with no form says so.
      expect(HttpResponse.text('<p>none</p>').form(), isNull);
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

      cli
        ..flag('force', alias: 'f', desc: 'Overwrite')
        ..option('concurrency', alias: 'c', desc: 'Workers', def: '4')
        ..option('offset', desc: 'Offset')
        ..flag('cache', desc: 'Cache');

      expect(cli.has('force'), isTrue);
      expect(cli.get('concurrency', 0), equals(8));
      expect(cli.get('offset', 0), equals(-5));
      expect(cli.no('cache'), isTrue);
      expect(cli.list(), equals(['file.txt']));

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

        final maps = await io.csv.maps(path);
        expect(maps.length, equals(2));
        expect(maps[0]['name'], equals('Alice'));

        final grid = await io.csv.matrix(path);
        expect(grid.length, equals(3));
        expect(grid[0], equals(['name', 'role']));

        final streamed = await io.csv.records(path).toList();
        expect(streamed.length, equals(2));

        final cells = await io.csv.rows(path).toList();
        expect(cells.first, equals(['name', 'role']));

        // Excel and RFC 4180 want CRLF, which format and write both take.
        expect(
          io.csv.format([
            {'a': '1'},
          ], newline: '\r\n'),
          equals('a\r\n1\r\n'),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test(
      'All markdown code snippets with main() compile cleanly under dart analyze',
      () async {
        final docsDir = dart_io.Directory('docs');
        final mdFiles =
            docsDir.listSync().whereType<dart_io.File>().toList()
              ..add(dart_io.File('README.md'));

        final tempDir = dart_io.Directory('.dart_tool/doc_snippets');
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        tempDir.createSync(recursive: true);

        try {
          // Every snippet is written out first and analyzed in one pass. One
          // `dart analyze` per snippet spent most of a minute starting the
          // analyzer over and over, which is what put this test over its
          // timeout as the docs grew.
          final written = <String, dart_io.File>{};
          for (final mdFile in mdFiles) {
            final doc = mdFile.uri.pathSegments.last.replaceAll('.md', '');
            final matches = RegExp(
              r'```dart(.*?)```',
              dotAll: true,
            ).allMatches(mdFile.readAsStringSync());

            for (final match in matches) {
              final snippet = match.group(1)!.trim();
              // Only snippets that are whole programs can be analyzed.
              if (!snippet.contains('void main(')) continue;

              var code = snippet;
              if (!code.contains('package:dart_toolkit/')) {
                code = "import 'package:dart_toolkit/dart_toolkit.dart';\n$code";
              }
              final file = dart_io.File(
                '${tempDir.path}/${doc}_snippet_${written.length + 1}.dart',
              )..writeAsStringSync(code);
              written['$doc #${written.length + 1}'] = file;
            }
          }

          expect(
            written,
            hasLength(greaterThanOrEqualTo(10)),
            reason: 'Should have found at least 10 main() programs in the docs',
          );

          final result = await dart_io.Process.run('dart', [
            'analyze',
            ...written.values.map((file) => file.path),
          ], workingDirectory: dart_io.Directory.current.path);

          expect(
            result.exitCode,
            equals(0),
            reason:
                'A documentation snippet does not analyze cleanly.\n'
                'Snippets: ${written.keys.join(', ')}\n'
                'Files are kept in ${tempDir.path} for inspection.\n'
                '${result.stdout}\n${result.stderr}',
          );
        } finally {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
