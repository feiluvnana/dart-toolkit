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

/// A downloader that fails every request, for testing what a crawl reports.
class _Broken<T> extends Downloader<T> {
  @override
  Future<Page<T>> download(Fetch<T> fetch) async =>
      throw StateError('boom for ${fetch.url}');
}

Directory _temp(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) io.remove(dir.path);
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
      expect(res.parse(format.html).find('.name').text, 'Wireless Keyboard');
      expect(res.parse(format.html).find('.price').text, r'$49.99');
      expect(res.parse(format.html).find('.tags li').texts.collect(.list()), [
        'usb',
        'bluetooth',
      ]);
    });

    test('extract and pick read it the same way', () {
      final res = Reply.text(page);
      // One text reader behind all three, so they cannot drift apart.
      expect(
        res.parse(format.html).extract({'name': '.name'})['name'],
        'Wireless Keyboard',
      );
      expect(
        res.parse(format.html).pick(Field.text('.name')),
        'Wireless Keyboard',
      );
      expect(res.parse(format.html).pick(Field.texts('.tags li')), [
        'usb',
        'bluetooth',
      ]);
      expect(
        res.parse(format.html).extract({'name': '.name@text'})['name'],
        'Wireless Keyboard',
      );
    });

    test('a repeated sub-object reads it the same way too', () {
      final res = Reply.text(page);
      final data = res.parse(format.html).extract({
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
        res.parse(format.html).find('.code').text,
        'line one\n  indented two',
      );
      expect(
        res.parse(format.html).pick(Field.text('.code')),
        'line one\n  indented two',
      );
    });

    test('a textarea keeps its whitespace as well', () {
      const html = '<form><textarea>  keep\n  me  </textarea></form>';
      expect($(html).find('textarea').text, 'keep\n  me');
    });

    test('an element nested inside a pre is still preformatted', () {
      const html = '<pre><code>a\n  b</code></pre>';
      expect($(html, 'code').text, 'a\n  b');
    });

    test('zero-width characters go, as util.text.clean drops them', () {
      const html = '<main><p>caf​é</p></main>';
      expect($(html, 'p').text, 'café');
    });
  });

  group('which pages failed', () {
    test('a failure names the fetch it happened on', () async {
      final lost = <Failure<String>>[];

      final stats = await net
          .crawl<String>('https://example.com/a'.url)
          .downloader(_Broken<String>())
          .on
          .error(lost.add)
          .run((res) {});

      expect(stats.failed, 1);
      // The count alone left nothing to retry or report.
      expect(lost.single.fetch?.url.toString(), 'https://example.com/a');
      expect(lost.single.error, isA<StateError>());
      expect(lost.single.stack, isNotNull);
    });

    test('a handler that throws names the page it was handling', () async {
      final lost = <Failure<String>>[];

      await net
          .crawl<String>('https://example.com/page'.url)
          .downloader(MapDownloader<String>({'/page': '<h1>hi</h1>'}))
          .on
          .error(lost.add)
          .run((res) => throw StateError('handler blew up'));

      expect(lost.single.fetch?.url.path, '/page');
    });

    test('the failed fetches can be queued again as they were', () async {
      final lost = <Failure<String>>[];
      await net
          .crawl<String>('https://example.com/a'.url)
          .downloader(_Broken<String>())
          .on
          .error(lost.add)
          .run((res) {});

      final served = <String>[];
      await net.crawl
          .seed<String>([for (final failure in lost) ?failure.fetch])
          .downloader(MapDownloader<String>({'/a': '<h1>second try</h1>'}))
          .run((res) => served.add(res.parse(format.html).find('h1').text));

      expect(served, ['second try']);
    });

    test('a failure is unfinished work, so a snapshot keeps it', () async {
      final dir = _temp('dt_fail_');
      final path = '${dir.path}/crawl.state';

      await net
          .crawl<String>('https://example.com/a'.url)
          .downloader(_Broken<String>())
          .resume(path)
          .run((res) {});

      // Nothing was handled, so there is a position left to resume from.
      expect(File(path).existsSync(), isTrue);
      final saved = jsonDecode(File(path).readAsStringSync()) as Map;
      expect((saved['pending'] as List).map((r) => (r as Map)['url']), [
        'https://example.com/a',
      ]);
    });

    test('toString says which page and why', () {
      final failure = Failure<String>(
        StateError('nope'),
        StackTrace.empty,
        Fetch<String>(Uri.parse('https://example.com/x')),
      );
      expect(failure.toString(), contains('https://example.com/x'));
      expect(failure.toString(), contains('nope'));
    });
  });

  group('crawl events chain', () {
    test('every handler hands the builder back', () async {
      final seen = <String>[];

      final stats = await net
          .crawl<String>('https://example.com/a'.url)
          .concurrent(1)
          .on
          .start(() => seen.add('start'))
          .on
          .progress((res) => seen.add('progress'))
          .on
          .item((item) => seen.add('item'))
          .on
          .done((stats) => seen.add('done'))
          .limit(1)
          .downloader(MapDownloader<String>({'/a': '<h1>hi</h1>'}))
          .collect((res) => res.emit(res.parse(format.html).find('h1').text));

      expect(seen, ['start', 'item', 'progress', 'done']);
      expect(stats.collect(.list()), ['hi']);
    });
  });

  group('io.csv.pipe', () {
    test('writes a stream of maps without holding it', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/out.csv';

      await io.csv.pipe(
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

      await io.csv.pipe(
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

      await io.csv.pipe(
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

      await io.csv.pipe(
        path,
        Stream.fromIterable([
          {'name': 'Alice, Chief'},
        ]),
        newline: '\r\n',
      );

      expect(File(path).readAsStringSync(), 'name\r\n"Alice, Chief"\r\n');
      // And it reads back as one row.
      expect((await format.csv.read(path)).maps.collect(.list()), [
        {'name': 'Alice, Chief'},
      ]);
    });

    test(
      'an empty stream with declared headers writes an empty table',
      () async {
        final dir = _temp('dt_pipe_');
        final path = '${dir.path}/out.csv';

        await io.csv.pipe(path, const Stream.empty(), headers: ['a', 'b']);

        expect(File(path).readAsStringSync(), 'a,b\n');
      },
    );

    test('a stream that fails leaves no half-written file', () async {
      final dir = _temp('dt_pipe_');
      final path = '${dir.path}/out.csv';

      await expectLater(
        io.csv.pipe(
          path,
          Stream<Map<String, String>>.error(StateError('mid-crawl')),
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

      await io.csv.pipe(
        path,
        net
            .crawl<Map<String, Object?>>('https://shop.test/list'.url)
            .downloader(
              MapDownloader<Map<String, Object?>>({
                '/list':
                    '<div class="p"><h2>\n  Wireless\n  Keyboard\n</h2>'
                    '<span class="c">49.99</span></div>'
                    '<div class="p"><h2>Mouse</h2>'
                    '<span class="c">19.99</span></div>',
              }),
            )
            .stream((res) {
              for (final card
                  in res
                      .parse(format.html)
                      .find('.p')
                      .elements
                      .collect(.list())) {
                res.emit({
                  'name': card.query.find('h2').text,
                  'price': card.query.find('.c').text,
                });
              }
            }),
        headers: ['name', 'price'],
      );

      expect((await format.csv.read(path)).maps.collect(.list()), [
        {'name': 'Wireless Keyboard', 'price': '49.99'},
        {'name': 'Mouse', 'price': '19.99'},
      ]);
    });
  });

  group('piped stdin', () {
    test('piped says whether there is input to read', () {
      // A bool either way; under a test runner stdin is not a keyboard.
      expect(system.console.reader.piped, isA<bool>());
    });

    test('lines reads what was piped into a script', () async {
      final dir = Directory('output/stdin_test');
      dir.createSync(recursive: true);
      addTearDown(() => io.remove(dir.path));

      // Run a real script with real piped input: that is the use case.
      File('${dir.path}/tool.dart').writeAsStringSync('''
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  print('piped=\${system.console.reader.piped}');
  await for (final line in system.console.reader.lines) {
    print('got \${line.trim()}');
  }
  print('done');
  await system.console.reader.close();
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
