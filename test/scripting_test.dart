/// Tests for the parts a real script needs and had to hand-roll. Each group
/// names what used to be missing: scraped text arrived with the page's own
/// indentation in it, a crawl counted its failures without saying which pages
/// they were, results could only reach a CSV by way of memory, and a tool
/// could not read what was piped into it without a loop of its own.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:io' as dart_io;

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/html.dart';
import 'package:test/test.dart';

/// A transport that fails every request, for testing what a crawl reports.
///
/// A function, not a subclass: `Downloader` was four public classes for this.
Future<Reply> broken(Fetch fetch) async =>
    throw StateError('boom for ${fetch.url}');

/// A transport over a map of path to body.
Send serve(Map<String, String> pages) =>
    (fetch) async => Reply.text(
      pages[fetch.url.path] ?? pages['${fetch.url}'] ?? '',
      fetch: fetch,
    );

Directory _temp(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) Files.removeSync(dir.path);
  });
  return dir;
}

void main() {
  group('scraped text reads as text', () {
    // The markup a real page carries: the heading is indented, so its text
    // holds newlines and runs of spaces that a browser collapses before it
    // draws anything.
    const page = '''
      <div class="product">
        <h1 class="name">
          Wireless
          Keyboard
        </h1>
        <span class="price">   \$49.99   </span>
        <ul class="tags"><li>  usb  </li><li>
          bluetooth
        </li></ul>
        <pre class="code">line one
  indented two</pre>
      </div>
    ''';

    test('a selector collapses the page indentation', () {
      final res = Reply.text(page);
      expect(res.parse(Codec.html).$('.name').text, 'Wireless Keyboard');
      expect(res.parse(Codec.html).$('.price').text, r'$49.99');
      expect(res.parse(Codec.html).$('.tags li').texts, [
        'usb',
        'bluetooth',
      ]);
    });

    test('extract and pick read it the same way', () {
      final res = Reply.text(page);
      // One text reader behind all three, so they cannot drift apart.
      expect(
        res.parse(Codec.html).extract({'name': '.name'})['name'],
        'Wireless Keyboard',
      );
      expect(
        res.parse(Codec.html).pick(Field.text('.name')),
        'Wireless Keyboard',
      );
      expect(res.parse(Codec.html).pick(Field.texts('.tags li')), [
        'usb',
        'bluetooth',
      ]);
      expect(
        res.parse(Codec.html).extract({'name': '.name@text'})['name'],
        'Wireless Keyboard',
      );
    });

    test('a repeated sub-object reads it the same way too', () {
      final res = Reply.text(page);
      final data = res.parse(Codec.html).extract({
        'items': [
          '.product',
          {'name': '.name'},
        ],
      });
      expect((data['items']! as List).first, {'name': 'Wireless Keyboard'});
    });

    test('inside a pre the whitespace is the content, and is kept', () {
      final res = Reply.text(page);
      // What <pre> means. Collapsing it would destroy scraped code samples.
      expect(
        res.parse(Codec.html).$('.code').text,
        'line one\n  indented two',
      );
      expect(
        res.parse(Codec.html).pick(Field.text('.code')),
        'line one\n  indented two',
      );
    });

    test('a textarea keeps its whitespace as well', () {
      const html = '<form><textarea>  keep\n  me  </textarea></form>';
      expect($(html).$('textarea').text, 'keep\n  me');
    });

    test('an element nested inside a pre is still preformatted', () {
      const html = '<pre><code>a\n  b</code></pre>';
      expect($(html, 'code').text, 'a\n  b');
    });

    test('zero-width characters go, as Text.clean drops them', () {
      const html = '<main><p>caf​é</p></main>';
      expect($(html, 'p').text, 'café');
    });
  });

  group('which pages failed', () {
    test('settle names the reply it happened on', () async {
      final crawl = Http.crawl([Fetch('https://example.com/a'.url)])
        ..using(broken);

      final outcomes = await crawl.settle.toList();

      expect(crawl.stats.failed, 1);
      // `flow` leaves failures out; `settle` puts them in band, which is what
      // `on.error` and the `Failure` type were for.
      final broke = outcomes
          .whereType<Broke<Reply>>()
          .single;
      expect(broke.error, isA<StateError>());
      expect(broke.stack, isNotNull);
    });

    test('a next that throws is reported the same way', () async {
      final crawl = Http.crawl(
        [Fetch('https://example.com/page'.url)],
        (Reply res) => throw StateError('next blew up'),
      )..using(serve(const {'/page': '<h1>hi</h1>'}));

      final outcomes = await crawl.settle.toList();
      expect(
        outcomes.whereType<Broke<Reply>>().length,
        1,
      );
    });

    test('the failed requests can be queued again as they were', () async {
      // `Settled` does not carry the item — the caller already holds it —
      // and a crawl's position does: a request that failed is unfinished
      // work, so it is still pending.
      final crawl = Http.crawl([Fetch('https://example.com/a'.url)])
        ..using(broken);
      await crawl.run();

      final pending = (crawl.position['pending'] as List)
          .cast<Map<String, Object?>>()
          .map(Fetch.fromJson)
          .toList();
      expect(pending.single.url.toString(), 'https://example.com/a');

      final again = Http.crawl(pending)
        ..using(serve(const {'/a': '<h1>second try</h1>'}));
      final served = await again.flow
          .map((Reply res) => res.parse(Codec.html).$('h1').text)
          .toList();

      expect(served, ['second try']);
    });

    test('a failure is unfinished work, so the resume file keeps it', () async {
      final dir = _temp('dt_fail_');
      final path = '${dir.path}/crawl.state';

      await (Http.crawl([Fetch('https://example.com/a'.url)])
            ..using(broken)
            ..resume(path))
          .run();

      // Nothing was handled, so there is a position left to resume from.
      expect(File(path).existsSync(), isTrue);
      final saved = jsonDecode(File(path).readAsStringSync()) as Map;
      expect((saved['pending'] as List).map((r) => (r as Map)['url']), [
        'https://example.com/a',
      ]);
    });
  });

  group('the crawl terminals replace the event bag', () {
    test(
      'tap is on.progress; the lines around it are start and done',
      () async {
        final seen = <String>[];

        final crawl = Http.crawl([Fetch('https://example.com/a'.url)])
          ..concurrent(1)
          ..limit(1)
          ..using(serve(const {'/a': '<h1>hi</h1>'}));

        seen.add('start');
        final titles = await crawl.flow
            .map((Reply res) {
              seen.add('progress');
              return res.parse(Codec.html).$('h1').text;
            })
            .toList();
        seen.add('done');

        expect(seen, ['start', 'progress', 'done']);
        expect(titles, ['hi']);
        expect(crawl.stats.fetched, 1);
      },
    );
  });

  group('io.csv.pipe', () {
    test('writes a flow of maps without holding it', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/out.csv';

      await Files.writeCsv(
        path,
        Stream.fromIterable([
          {'name': 'Alice', 'role': 'admin'},
          {'name': 'Bob', 'role': 'user'},
        ]),
      );

      expect(
        File(path).readAsStringSync(),
        'name,role\nAlice,admin\nBob,user\n',
      );
    });

    test('takes its columns from the headers it was given', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/out.csv';

      await Files.writeCsv(
        path,
        Stream.fromIterable([
          {'b': '2', 'a': '1'},
        ]),
        headers: ['a', 'b'],
      );

      expect(File(path).readAsStringSync(), 'a,b\n1,2\n');
    });

    test('rows of cells work too', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/out.csv';

      await Files.writeCsv(
        path,
        Stream.fromIterable([
          {'n': 1, 'letter': 'a'},
          {'n': 2, 'letter': 'b'},
        ]),
        headers: ['n', 'letter'],
      );

      expect(File(path).readAsStringSync(), 'n,letter\n1,a\n2,b\n');
    });

    test('quoting and a custom newline are applied as in format', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/out.csv';

      await Files.writeCsv(
        path,
        Stream.fromIterable([
          {'name': 'Alice, Chief'},
        ]),
        newline: '\r\n',
      );

      expect(File(path).readAsStringSync(), 'name\r\n"Alice, Chief"\r\n');
      // And it reads back as one row.
      expect(Formats.csv(File(path).readAsStringSync()).maps, [
        {'name': 'Alice, Chief'},
      ]);
    });

    test('an empty flow with declared headers writes an empty table', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/out.csv';

      await Files.writeCsv(
        path,
        const Stream<Map<String, Object?>>.empty(),
        headers: ['a', 'b'],
      );

      expect(File(path).readAsStringSync(), 'a,b\n');
    });

    test('a flow that fails leaves no half-written file', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/out.csv';

      await expectLater(
        Files.writeCsv(
          path,
          // Through the boundary, deliberately: a source that fails is
          // somebody else's stream, so there is no `Flow.error`.
          Stream<Map<String, Object?>>.error(StateError('mid-crawl')),
        ),
        throwsStateError,
      );

      // The staging file is discarded, and no truncated CSV is left behind.
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.part').existsSync(), isFalse);
    });

    test('a crawl reaches a spreadsheet in one call', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/products.csv';

      await Files.writeCsv(
        path,
        (Http.crawl([Fetch('https://shop.test/list'.url)])..using(
              serve(const {
                '/list':
                    '<div class="p"><h2>\n  Wireless\n  Keyboard\n</h2>'
                    '<span class="c">49.99</span></div>'
                    '<div class="p"><h2>Mouse</h2>'
                    '<span class="c">19.99</span></div>',
              }),
            ))
            .flow
            .expand(
              (Reply res) => res
                  .parse(Codec.html)
                  .all(
                    '.p',
                    (Markup card) => <String, Object?>{
                      'name': card.$('h2').text,
                      'price': card.$('.c').text,
                    },
                  ),
            ),
        headers: ['name', 'price'],
      );

      expect(Formats.csv(File(path).readAsStringSync()).maps, [
        {'name': 'Wireless Keyboard', 'price': '49.99'},
        {'name': 'Mouse', 'price': '19.99'},
      ]);
    });
  });

  group('piped stdin', () {
    test('piped says whether there is input to read', () {
      // A bool either way; under a test runner stdin is not a keyboard.
      expect(System.console.reader.piped, isA<bool>());
    });

    test('lines reads what was piped into a script', () async {
      final dir = Directory('output/stdin_test');
      dir.createSync(recursive: true);
      addTearDown(() => Files.removeSync(dir.path));

      // Run a real script with real piped input: that is the use case.
      File('${dir.path}/tool.dart').writeAsStringSync('''
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  print('piped=\${System.console.reader.piped}');
  await for (final line in System.console.reader.lines) {
    print('got \${line.trim()}');
  }
  print('done');
  await System.console.reader.close();
}
''');

      final process = await dart_io.Process.start('dart', [
        'run',
        '${dir.path}/tool.dart',
      ], workingDirectory: Directory.current.path);
      process.stdin
        ..writeln('https://example.com/a')
        ..writeln('https://example.com/b');
      await process.stdin.close();

      final out = await process.stdout.transform(utf8.decoder).join();
      await process.exitCode;

      expect(out, contains('piped=true'));
      expect(out, contains('got https://example.com/a'));
      expect(out, contains('got https://example.com/b'));
      // Ends at end of input rather than waiting forever.
      expect(out, contains('done'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
