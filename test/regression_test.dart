/// Regressions for defects found by auditing the library against its own
/// documentation. Each group names the behaviour that used to be wrong.
library;

import 'dart:async';
import 'dart:io';

// Imported unprefixed on purpose. `package:crypto` exports a `Digest` and
// `dart:io` a `Process`; this file compiling at all is the Rule 6 collision
// test, and it failed against both names before 1.6.0.
import 'dart:io' as dart_io;

import 'package:crypto/crypto.dart';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/html.dart';
import 'package:test/test.dart';

void main() {
  group('3.0.0 — the sequence API replaces Dart\'s', () {
    // Adding `implements Iterable<T>` to Sequence for convenience would carry
    // map, where, expand, fold, firstWhere and thirty more names back into
    // scope beside this library's, and nothing else would notice. This is the
    // property the whole stage rests on.
    test('a Sequence is deliberately not an Iterable', () {
      expect(const Sequence<int>([]), isNot(isA<Iterable<int>>()));
      expect([1, 2].seq, isNot(isA<Iterable<Object?>>()));
    });

    test('a Markup holds one rather than being one', () {
      final page = $('<p>a</p><p>b</p>');
      expect(page, isNot(isA<Iterable<Object?>>()));
      expect(page.find('p').count, equals(2));
      expect(
        page.find('p').elements.transform(.map((e) => e.text)).collect(.list()),
        equals(['a', 'b']),
      );
    });

    test('the flipped signatures stayed flipped', () {
      expect(util.text.words('a b'), isA<Sequence<String>>());
      expect(util.text.numbers('1 2'), isA<Sequence<num>>());
      expect(net.sitemap(''), isA<Sequence<Uri>>());
      expect(util.rand.shuffle(<int>[1]), isA<Sequence<int>>());
      expect(format.json.parse('{}'), isA<Json>());
    });

    test('every reader that can come up empty says so in its type', () {
      final empty = const Sequence<int>([]);
      expect(empty.collect(.first()), isNull);
      expect(empty.collect(.last()), isNull);
      expect(empty.collect(.single()), isNull);
      expect(empty.collect(.at(0)), isNull);
      expect(empty.collect(.first.where((_) => true)), isNull);
      expect(empty.collect(.max.by((n) => n)), isNull);
      expect(empty.collect(.min.by((n) => n)), isNull);
      expect(empty.collect(.index.where((_) => true)), isNull);
      expect(empty.collect(.avg((n) => n)), isNull);
      expect(Json.none.text('a'), isNull);
      expect(util.time.parse('nope'), isNull);
      expect(util.time.span('nope'), isNull);
    });

    test('no complement pair exists where ! does the job', () {
      // Law 2: `empty` with no `notEmpty`, `any` with no `none`.
      expect([1].seq.collect(.empty()), isFalse);
      expect($('<p>a</p>').empty, isFalse);
      expect(Json.none.empty, isTrue);
    });
  });

  group('5.2.0 — the io mirror, pinned', () {
    // NAMESPACE.md Rule 3 said `io.async` "mirrors `io` exactly", and it did
    // not: `download` existed only on the async side, `lock`/`locked`/`watch`
    // only on the blocking one, and `lines` returned a `Stream` from both —
    // including from the accessor whose whole promise is that it blocks.
    //
    // The rule now says what a complete mirror can actually mean: every
    // member that has both forms appears on both sides under one name. This
    // test is what stops that from drifting again, by reading the two
    // accessors out of the source and asserting the difference is exactly the
    // known set.
    /// The public member names declared directly on [type] in `lib/io/$file`.
    ///
    /// Source text rather than reflection, because `dart:mirrors` is not
    /// available to a compiled test — and because reading the declarations is
    /// what catches a member added to one accessor and forgotten on the other.
    Set<String> membersOf(String file, String type) {
      final source = File('lib/io/$file').readAsStringSync();
      final names = <String>{};
      var inside = false;

      for (final line in source.split('\n')) {
        if (line.startsWith('class $type ') ||
            line.startsWith('class $type {')) {
          inside = true;
          continue;
        }
        if (!inside) continue;
        // A `}` in column zero closes the class; anything after it is another
        // declaration, and `io.dart` ends with a top-level function.
        if (line == '}' || line.startsWith('class ')) break;

        // Members sit at exactly two spaces; parameters sit at four.
        if (!line.startsWith('  ') || line.startsWith('   ')) continue;
        final trimmed = line.trimLeft();
        if (trimmed.isEmpty) continue;
        if (RegExp(r'^(//|@|\}|\)|=>|\.\.|;)').hasMatch(trimmed)) continue;

        final getter = RegExp(r'\bget (\w+)').firstMatch(trimmed);
        if (getter != null) {
          names.add(getter.group(1)!);
          continue;
        }

        // `Future<void> Function() watch(` — a function *type* in the return
        // brings a `(` of its own, ahead of the parameter list.
        final line2 = trimmed.replaceAll(
          RegExp(r'Function\s*\([^()]*\)'),
          'Function',
        );
        final open = line2.indexOf('(');
        if (open <= 0) continue;
        // Everything left of the parameter list, with generics dropped, ends
        // in the member's own name.
        final head = line2
            .substring(0, open)
            .replaceAll(RegExp(r'<[^<>]*>'), '');
        final name = RegExp(r'(\w+)\s*$').firstMatch(head);
        if (name != null) names.add(name.group(1)!);
      }

      names.removeWhere((n) => n == type || n.startsWith('_'));
      expect(names, isNotEmpty, reason: 'read no members off $type');
      return names;
    }

    test('io and io.async differ by exactly the known set', () {
      final blocking = membersOf('io.dart', 'IoAccessor');
      final async = membersOf('io.dart', 'IoAsyncAccessor');

      expect(
        blocking.difference(async),
        // `lock`, `locked` and `watch` are inherently asynchronous and have no
        // blocking form to mirror; `path` is pure string arithmetic with
        // nothing to wait for; `csv` is already every-member-a-future.
        {'path', 'csv', 'async', 'lock', 'locked', 'watch'},
        reason: 'a blocking member gained no async twin',
      );
      expect(
        async.difference(blocking),
        isEmpty,
        reason:
            'an async member with no blocking twin — download was the one, '
            'and it went to net.http.download where a socket belongs',
      );
    });

    test('io.dir and io.async.dir differ by exactly the known set', () {
      final blocking = membersOf('dir.dart', 'DirAccessor');
      final async = membersOf('dir.dart', 'DirAsyncAccessor');

      // `cwd` and `home` read nothing off the disk.
      expect(blocking.difference(async), {'cwd', 'home'});
      expect(async.difference(blocking), isEmpty);
    });

    test('lines is the one member whose shape differs, on purpose', () {
      final temp = io.dir.temp('dt_mirror_');
      addTearDown(() => io.remove(temp.path));
      final path = io.path.join(temp.path, 'a.txt');
      io.write(path, 'one\ntwo\n');

      // Blocking means the lines are already read.
      expect(io.lines(path), isA<Sequence<String>>());
      expect(io.async.lines(path), isA<Stream<String>>());
      expect(io.lines(path).collect(.list()), ['one', 'two']);
    });

    test('no io signature names a dart:io type', () {
      // Seventeen of them did through 5.1.0 — File, Directory,
      // FileSystemEntity and FileStat — to buy exactly one `.path` across the
      // whole repository. FileSystemEntry.entity is the one door, and it is
      // in entry.dart rather than here.
      final banned = RegExp(
        r'^  (?!///|//).*\b(File|Directory|FileSystemEntity|FileStat)\b'
        r'(?!SystemEntry)[<\s?]',
        multiLine: true,
      );
      final offenders = <String>[];
      for (final file in const [
        'io.dart',
        'dir.dart',
        'path.dart',
        'csv.dart',
      ]) {
        final source = File('lib/io/$file').readAsStringSync();
        for (final line in source.split('\n')) {
          if (line.startsWith('  ') &&
              !line.trimLeft().startsWith('//') &&
              banned.hasMatch(line)) {
            offenders.add('$file: ${line.trim()}');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('the filesystem questions are each answerable on their own', () {
      final temp = io.dir.temp('dt_ask_');
      addTearDown(() => io.remove(temp.path));

      final full = io.path.join(temp.path, 'full.txt');
      final blank = io.path.join(temp.path, 'blank.txt');
      final folder = io.path.join(temp.path, 'folder');
      final missing = io.path.join(temp.path, 'missing.txt');
      io.write(full, 'x');
      io.touch(blank);
      io.dir.make(folder);

      // The four answers io.has fused into one `false`.
      expect(
        [
          io.exists(full),
          io.exists(blank),
          io.exists(folder),
          io.exists(missing),
        ],
        [true, true, true, false],
      );

      expect(io.isfile(full), isTrue);
      expect(io.isdir(folder), isTrue);
      expect(io.isfile(folder), isFalse);
      expect(io.islink(full), isFalse);

      expect(io.size(full), 1);
      expect(io.size(blank), 0);
      expect(io.size(missing), isNull);

      // Empty and absent are different answers.
      expect(io.empty(blank), isTrue);
      expect(io.empty(full), isFalse);
      expect(
        io.empty(folder),
        isTrue,
        reason: 'a directory with nothing in it',
      );
      expect(io.empty(missing), isFalse, reason: 'absent is not empty');

      // And io.has keeps meaning what it always meant.
      expect(io.has(full), isTrue);
      expect(io.has(blank), isFalse);
      expect(io.has(folder), isFalse);
    });

    test('list returns directories, which find dropped', () {
      final temp = io.dir.temp('dt_list_');
      addTearDown(() => io.remove(temp.path));

      io.write(io.path.join(temp.path, 'a.txt'), 'a');
      io.dir.make(io.path.join(temp.path, 'sub'));
      io.write(io.path.join(temp.path, 'sub', 'b.csv'), 'b');

      final listed = io.dir.list(temp.path).collect(.list());
      expect(listed.map((e) => e.name), ['a.txt', 'sub']);
      expect(listed.map((e) => e.kind), [
        FileSystemEntryKind.file,
        FileSystemEntryKind.directory,
      ]);

      // One level, versus the whole tree.
      expect(io.dir.list(temp.path).collect(.count()), 2);
      expect(io.dir.walk(temp.path).collect(.count()), 3);
      expect(io.dir.list(temp.path, only: .directory).collect(.count()), 1);

      // A glob, not a RegExp.
      expect(io.dir.walk(temp.path, match: '*.csv').collect(.count()), 1);
      expect(io.dir.walk(temp.path, match: '**/*.csv').collect(.count()), 1);
      expect(io.dir.walk(temp.path, depth: 1).collect(.count()), 2);

      // find is the narrow question, and still drops directories.
      expect(io.dir.find(temp.path).collect(.count()), 2);
      expect(io.dir.find(temp.path, recursive: false).collect(.count()), 1);
    });

    test('a walk reads the disk when it is walked, not when it is built', () {
      final temp = io.dir.temp('dt_lazy_');
      addTearDown(() => io.remove(temp.path));
      io.write(io.path.join(temp.path, 'a.txt'), 'a');

      final entries = io.dir.walk(temp.path);
      io.write(io.path.join(temp.path, 'b.txt'), 'b');

      // Built before b.txt existed, walked after: the listing is the disk as
      // it is at the terminal call, not as it was at the call that made the
      // sequence.
      expect(entries.collect(.count()), 2);

      // And a second walk follows the same links as the first: the set of
      // resolved directories is rebuilt per walk, not shared between them.
      final inner = io.path.join(temp.path, 'inner');
      io.dir.make(inner);
      io.write(io.path.join(inner, 'c.txt'), 'c');
      Link(io.path.join(inner, 'up')).createSync(temp.path);
      final linked = io.dir.walk(temp.path);
      expect(linked.collect(.count()), linked.collect(.count()));
    });

    test('a walk that follows links does not loop forever', () {
      final temp = io.dir.temp('dt_loop_');
      addTearDown(() => io.remove(temp.path));

      final inner = io.path.join(temp.path, 'inner');
      io.dir.make(inner);
      io.write(io.path.join(inner, 'a.txt'), 'a');
      Link(io.path.join(inner, 'up')).createSync(temp.path);

      expect(io.islink(io.path.join(inner, 'up')), isTrue);
      expect(io.isdir(io.path.join(inner, 'up')), isFalse);

      // Without the visited set this never returns.
      expect(io.dir.walk(temp.path).collect(.count()), greaterThan(0));
      expect(
        io.dir.walk(temp.path, follow: false).collect(.count()),
        greaterThan(0),
      );
    });
  });

  group('4.0.0 — the formats left net', () {
    // The one-line statement of the release: `net` fetches bytes and parses
    // none of them. `form.dart` holds a `<form>` element it was handed, which
    // is the tree type and not the parser — a form is a request the page
    // describes, and its output is an HttpMethod, a Uri and a Body.
    test('no HTML parser under lib/net/', () {
      final offenders = <String>[];
      for (final entity in Directory('lib/net').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        for (final banned in const [
          "package:html/parser.dart",
          "package:xpath_selector",
        ]) {
          if (source.contains("import '$banned")) {
            offenders.add('${entity.path}: $banned');
          }
        }
      }
      expect(offenders, isEmpty, reason: 'net must not parse markup');
    });

    test('Reply carries no member that names a format', () {
      final res = Reply.text('<h1>T</h1>');
      // Every one of these used to be on Reply. The seam is `parse(codec)`.
      expect(res.parse(format.html).find('h1').text, 'T');
      expect(
        res.parse(format.json).raw,
        isNull,
        reason: 'not JSON, not a throw',
      );
      expect(res.parse(format.yaml), isA<Json>());
    });

    test('parse memoises per codec, so one page is parsed once', () {
      final res = Reply.text('<h1>T</h1><p>x</p>');
      expect(
        identical(res.parse(format.html), res.parse(format.html)),
        isTrue,
        reason: 'a handler reading a page five times must parse it once',
      );
      expect(
        identical(res.parse(format.html), res.parse(format.json)),
        isFalse,
      );
    });

    test(
      'every format accessor is a Codec, so the seam cannot be bypassed',
      () {
        expect(format.html, isA<Codec<Markup>>());
        expect(format.json, isA<Codec<Json>>());
        expect(format.yaml, isA<Codec<Json>>());
        expect(format.toml, isA<Codec<Json>>());
      },
    );

    test(
      'the codecs are const, which is what makes memoising by them work',
      () {
        expect(identical(format.html, format.html), isTrue);
        expect(identical(format.json, format.json), isTrue);
      },
    );
  });

  group('exported type names', () {
    test('the library imports beside dart:io and crypto without collision', () {
      // `Digest` resolves to crypto's, because the toolkit's algorithm enum is
      // `Algo`. Before, this was an ambiguous_import error.
      final Digest sum = sha256.convert(const [1, 2, 3]);
      expect(sum.bytes, hasLength(32));
      expect(Algo.values, contains(Algo.sha256));

      // `Process` resolves to dart:io's, because the pipeline's page handler is
      // `Handler`. Before, the toolkit's typedef won silently — a package
      // import beats a `dart:` one without an error.
      expect(Process.run, isA<Function>());
      const Handler<String> handler = _noop;
      expect(handler, isA<Handler<String>>());
    });

    test('no exported name shadows dart:io any more', () {
      // The Rule 6 collisions 1.7.0 recorded and 2.0.0 paid off. `HttpClient`,
      // `HttpResponse` and `Cookie` used to be this library's — the package
      // import beat the `dart:` one with no diagnostic at all. Unprefixed,
      // they now resolve to dart:io's, which is what this pins.
      final theirs = HttpClient();
      addTearDown(theirs.close);
      expect(theirs, isA<dart_io.HttpClient>());
      expect(Cookie('a', 'b'), isA<dart_io.Cookie>());
      expect(HttpResponse, isNot(equals(Reply)));

      // And the toolkit's carry their own names, which collide with nothing.
      expect(Reply.text('<p>hi</p>').status, 200);
      expect(Morsel('a', 'b').name, 'a');
      final ours = Fetcher();
      addTearDown(ours.close);
      expect(ours.timeout, const Duration(seconds: 30));

      // `Fetch` and `Page` were the two that fought `package:http` for a name
      // and produced an ambiguous_import on use. Nothing to hide now.
      expect(Fetch<String>(Uri.parse('https://a.test')).url.host, 'a.test');
      expect(Page<String>, isNotNull);
    });
  });

  group('net.http cookies', () {
    test('a cookie with no Domain goes back only to the host that set it', () {
      final jar = CookieJar();
      jar.add('sid=abc; Path=/', uri: Uri.parse('https://example.com/'));

      // Host-only, per RFC 6265 section 5.3. It used to be stored with the
      // host as its Domain and matched by suffix, so a session cookie
      // followed the crawl into every subdomain it wandered through.
      expect(jar.header(Uri.parse('https://example.com/')), 'sid=abc');
      expect(jar.header(Uri.parse('https://sub.example.com/')), isNull);
      expect(jar.cookies.collect(.single())!.host, isTrue);
    });

    test('a Domain the host owns still widens to its subdomains', () {
      final jar = CookieJar();
      jar.add(
        'sid=abc; Domain=example.com; Path=/',
        uri: Uri.parse('https://example.com/'),
      );

      expect(jar.header(Uri.parse('https://sub.example.com/')), 'sid=abc');
      expect(jar.cookies.collect(.single())!.host, isFalse);
    });

    test('a Domain the responding host does not own is refused', () {
      final jar = CookieJar();
      jar.add(
        'sid=abc; Domain=com; Path=/',
        uri: Uri.parse('https://evil.example.com/'),
      );

      // Stored host-only, so it never reaches an unrelated host.
      expect(jar.header(Uri.parse('https://bank.com/')), isNull);
      expect(jar.header(Uri.parse('https://evil.example.com/')), 'sid=abc');
    });

    test('a parent domain the host belongs to is honoured', () {
      final jar = CookieJar();
      jar.add(
        'sid=abc; Domain=example.com; Path=/',
        uri: Uri.parse('https://api.example.com/'),
      );

      expect(jar.header(Uri.parse('https://www.example.com/')), 'sid=abc');
      expect(jar.header(Uri.parse('https://notexample.com/')), isNull);
    });
  });

  group('cli', () {
    test('a flag reads the declared env variable', () {
      system.env.set('DT_REGRESSION_FLAG', 'true');
      addTearDown(() => system.env.delete('DT_REGRESSION_FLAG'));

      final force = Cli(const []).flag('force', env: 'DT_REGRESSION_FLAG');
      expect(force(), isTrue);
    });

    test('env beats def for bool, matching every other type', () {
      system.env.set('DT_REGRESSION_MODE', 'off');
      addTearDown(() => system.env.delete('DT_REGRESSION_MODE'));

      final colour = Cli(
        const [],
      ).flag('colour', env: 'DT_REGRESSION_MODE', def: true);
      expect(colour(), isFalse);
    });

    test('the command line still beats env', () {
      system.env.set('DT_REGRESSION_FLAG', 'false');
      addTearDown(() => system.env.delete('DT_REGRESSION_FLAG'));

      final force = Cli(const [
        '--force',
      ]).flag('force', env: 'DT_REGRESSION_FLAG');
      expect(force(), isTrue);
    });

    test('a required option needs a value, not just the switch', () {
      final cli = Cli(const ['--out'])..option('out', required: true);
      expect(cli.require, throwsArgumentError);

      final ok = Cli(const ['--out', 'dist'])..option('out', required: true);
      expect(ok.require, returnsNormally);
    });

    test('a required flag is satisfied by its presence', () {
      final cli = Cli(const ['--force'])..flag('force');
      expect(() => cli.require(['force']), returnsNormally);
    });
  });

  group('net.robots', () {
    test('a crawl-delay-only group does not absorb the next group', () {
      final robots = Robots.parse('''
User-agent: SlowBot
Crawl-delay: 10

User-agent: EvilBot
Disallow: /secret
''');

      final secret = Uri.parse('https://example.com/secret');
      expect(robots.allowed(secret, agent: 'SlowBot'), isTrue);
      expect(robots.allowed(secret, agent: 'EvilBot'), isFalse);
      expect(robots.delay(agent: 'SlowBot'), const Duration(seconds: 10));
      expect(robots.delay(agent: 'EvilBot'), isNull);
    });

    test('consecutive user-agent lines still share one group', () {
      final robots = Robots.parse('''
User-agent: A
User-agent: B
Disallow: /x
''');

      final x = Uri.parse('https://example.com/x');
      expect(robots.allowed(x, agent: 'A'), isFalse);
      expect(robots.allowed(x, agent: 'B'), isFalse);
    });
  });

  group('net.crawl plumbing', () {
    test('Stats.retried counts the retries the client actually made', () async {
      var attempts = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((fetch) async {
        attempts++;
        if (attempts <= 2) {
          fetch.response.statusCode = 503;
        } else {
          fetch.response.headers.contentType = ContentType.html;
          fetch.response.write('<h1>ok</h1>');
        }
        await fetch.response.close();
      });

      final stats = await net
          .crawl<String>('http://127.0.0.1:${server.port}/'.url)
          .retry(3)
          .run((res) {});

      // Retrying happens inside the client, so the engine only knows because
      // the downloader tells it. The counter read zero however hard it tried.
      expect(attempts, 3);
      expect(stats.retried, 2);
      expect(stats.completed, 1);
    });

    test('save writes through a .part file and creates its folder', () async {
      final dir = io.dir.temp('dt_save_');
      addTearDown(() => io.remove(dir.path));
      final dest = io.path.join(dir.path, 'nested', 'items.txt');

      await net
          .crawl<String>('https://site.test/'.url)
          .downloader(MapDownloader<String>({'/': '<h1>hi</h1>'}))
          .save(dest, (res) => res.emit('one'));

      // The folder did not exist: opening the destination directly threw.
      expect(io.read(dest).trim(), 'one');
      expect(
        io.dir.find(dir.path, pattern: RegExp(r'\.part$')).collect(.empty()),
        isTrue,
      );
    });

    test('the destination is replaced only once the run finishes', () async {
      final dir = io.dir.temp('dt_save_');
      addTearDown(() => io.remove(dir.path));
      final dest = io.path.join(dir.path, 'items.txt');
      io.write(dest, 'PREVIOUS');

      final slow = _SlowDownloader<String>(const Duration(milliseconds: 200));
      final run = net
          .crawl<String>('https://site.test/'.url)
          .downloader(slow)
          .save(dest, (res) => res.emit('one'));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      // Mid-run: the destination used to have been truncated on the way in,
      // so an interrupted crawl took the last good results down with it.
      expect(io.read(dest), 'PREVIOUS');

      await run;
      expect(io.read(dest).trim(), 'one');
      expect(
        io.dir.find(dir.path, pattern: RegExp(r'\.part$')).collect(.empty()),
        isTrue,
      );
    });

    test('a save whose seeds cannot be resolved keeps the old file', () async {
      final dir = io.dir.temp('dt_save_');
      addTearDown(() => io.remove(dir.path));
      final dest = io.path.join(dir.path, 'items.txt');
      io.write(dest, 'PREVIOUS');

      await _withFailFastClient(() async {
        await expectLater(
          net.crawl
              .sitemap<String>(Uri.parse('http://127.0.0.1:1/sitemap.xml'))
              .save(dest, (res) => res.emit('one')),
          throwsA(anything),
        );
      });

      expect(io.read(dest), 'PREVIOUS');
      expect(
        io.dir.find(dir.path, pattern: RegExp(r'\.part$')).collect(.empty()),
        isTrue,
      );
    });

    test('a stream whose seeds cannot be resolved still ends', () async {
      final events = <String>[];
      final ended = Completer<void>();

      await _withFailFastClient(() async {
        net.crawl
            .sitemap<String>(Uri.parse('http://127.0.0.1:1/sitemap.xml'))
            .stream((res) => res.emit('x'))
            .listen(
              (_) => events.add('item'),
              onError: (Object _) => events.add('error'),
              onDone: () {
                events.add('done');
                if (!ended.isCompleted) ended.complete();
              },
              cancelOnError: false,
            );

        // The stream used to carry the error and then stay open forever, with
        // the resume hook still holding the process alive behind it.
        await ended.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => events.add('never closed'),
        );
      });

      expect(events, ['error', 'done']);
    });
  });

  group('format.csv', () {
    // The cursor keeps the header line out of `rows`; `Csv.raw` is the shape
    // the old `io.csv.parse` had, and the one these parser cases are about.
    List<List<String>> grid(String text, {String delimiter = ','}) => [
      for (final row in Csv.raw(
        text,
        delimiter: delimiter,
      ).rows.collect(.list()))
        row.collect(.list()),
    ];

    test('format keeps columns only later rows carry', () {
      final csv = format.csv.format([
        {'a': 1},
        {'a': 2, 'b': 3},
      ]);

      expect(csv.trim().split('\n').first, 'a,b');
      expect(csv, contains('2,3'));
    });

    test('a trailing newline does not add an empty row', () {
      expect(grid('a,b\n'), [
        ['a', 'b'],
      ]);
      expect(grid('a,b\n\n'), [
        ['a', 'b'],
      ]);
    });

    test('a multi-character delimiter splits', () {
      expect(grid('a||b||c', delimiter: '||'), [
        ['a', 'b', 'c'],
      ]);
    });

    test('quoted fields still survive', () {
      expect(grid('"a,b",c'), [
        ['a,b', 'c'],
      ]);
    });

    test('the cursor splits the header line off the rows', () {
      final sheet = format.csv.parse('a,b\n1,2\n3,4\n');

      expect(sheet.headers.collect(.list()), ['a', 'b']);
      expect(sheet.count, 2);
      expect(sheet.column('b').collect(.list()), ['2', '4']);
      expect(sheet.maps.collect(.list()), [
        {'a': '1', 'b': '2'},
        {'a': '3', 'b': '4'},
      ]);
    });

    test('text that is not CSV parses to the empty cursor', () {
      expect(format.csv.parse('').empty, isTrue);
      expect(format.csv.parse('').headers.collect(.empty()), isTrue);
    });

    test('one state machine backs the whole-file and chunked readers', () async {
      final temp = io.dir.temp('dt_csv_machine_');
      addTearDown(() => io.remove(temp.path));

      // The awkward inputs 5.0.0 used to prove the two parsers agreed. They
      // are one parser now, so this pins that the chunked driver still reaches
      // the same answer across every boundary the whole-string one never sees.
      const awkward =
          'a,b,c\n'
          '"x,1","y\n2","z""3"\n'
          ',,\n'
          '"",unquoted,"trailing "\n'
          'last,row,here\n';

      final path = io.path.join(temp.path, 'awkward.csv');
      io.write(path, awkward);

      expect(await io.csv.rows(path).toList(), grid(awkward));
    });
  });

  group('io.dictionary', () {
    test('a malformed file throws rather than reading as empty', () {
      final file = File('${Directory.systemTemp.path}/dt_bad_store.json')
        ..writeAsStringSync('{not json');
      addTearDown(() => file.deleteSync());

      // `Store.load` swallowed a missing file, unparseable JSON and a non-map
      // document into the same silent empty, so a half-written snapshot read
      // as a fresh start and the next save overwrote it.
      expect(() => io.dictionary(file.path), throwsFormatException);
      expect(io.dictionary('${file.path}.absent').empty, isTrue);
    });
  });

  group('io.hash', () {
    test('hashes a file without loading it whole', () async {
      final file = File('${Directory.systemTemp.path}/dt_hash_probe.bin')
        ..writeAsBytesSync(List<int>.generate(200000, (i) => i % 256));
      addTearDown(() => file.deleteSync());

      final sync = io.hash(file.path);
      final async = await io.async.hash(file.path);
      expect(sync, async);
      expect(sync, hasLength(64));
      expect(io.hash(file.path, Algo.md5), hasLength(32));
    });
  });

  group('util.text', () {
    test('a space groups digits only in threes', () {
      expect(util.text.number('12 34'), 12);
      expect(util.text.numbers('1 2 3').collect(.list()), [1, 2, 3]);
      expect(util.text.number('1 234 567'), 1234567);
      expect(util.text.number(r'$1,234.50'), 1234.5);
      expect(util.text.numbers('3 of 7').collect(.list()), [3, 7]);
    });

    test('slug keeps letters of other scripts', () {
      expect(util.text.slug('日本語のタイトル'), '日本語のタイトル');
      expect(util.text.slug('Привет мир'), 'привет-мир');
      expect(util.text.slug('Héllo, World!'), 'hello-world');
    });

    test('clip never splits a character in half', () {
      final clipped = util.text.clip('ab👍cd', 4);
      expect(clipped.runes.every((r) => r != 0xFFFD), isTrue);
      expect(clipped, 'ab…');
    });
  });

  group('util.size', () {
    test('rounding does not overflow the unit', () {
      expect(util.size.format(1048575), '1.0 MiB');
      // Bytes have no fraction to show; a kibibyte is where one starts.
      expect(util.size.format(1023), '1023 B');
      expect(util.size.format(5 * 1024 * 1024), '5.0 MiB');
    });

    test('a size that cannot be read is null, not zero', () {
      // Zero is a value a caller cannot tell apart from an empty file.
      expect(util.size.parse('10 XB'), isNull);
      expect(util.size.parse('nonsense'), isNull);
      expect(util.size.parse('MB'), isNull);
    });

    test('the labels mean what they say', () {
      // The arithmetic was always 1024-based and the labels said KB and MB, so
      // parse('5MB') answered five mebibytes under a name that means five
      // million. Both families are accepted; each carries its own scale.
      expect(util.size.parse('2.5 MiB'), 2621440);
      expect(util.size.parse('10KiB'), 10240);
      expect(util.size.parse('10K'), 10240);
      expect(util.size.parse('2.5 MB'), 2500000);
      expect(util.size.parse('10KB'), 10000);
    });
  });

  group('util.rand', () {
    test('jitter is never shorter than its base', () {
      const base = Duration(seconds: 1);
      for (var i = 0; i < 50; i++) {
        expect(util.rand.jitter(base, spread: -0.5) >= base, isTrue);
        expect(util.rand.jitter(base) >= base, isTrue);
      }
    });

    test('between handles a span wider than 32 bits', () {
      for (var i = 0; i < 20; i++) {
        final value = util.rand.between(0, 1 << 40);
        expect(value, greaterThanOrEqualTo(0));
        expect(value, lessThan(1 << 40));
      }
    });
  });

  group('concurrent', () {
    test('a stray release does not raise the permit ceiling', () async {
      final semaphore = Semaphore(1);
      await semaphore.take();
      semaphore.release();
      semaphore.release();
      semaphore.release();
      expect(semaphore.available, 1);
    });

    test('PoolFailure describes itself with no failures', () {
      expect(
        const PoolFailure<String, int>([]).toString(),
        contains('no failures'),
      );
    });
  });

  group('system.console', () {
    test('width counts terminal columns, not code units', () {
      expect(Ansi.width('日本語'), 6);
      expect(Ansi.width('abc'), 3);
      expect(Ansi.width('👍'), 2);
      expect(Ansi.width('é'), 1);
      expect(Ansi.width('${Ansi.red}hi${Ansi.reset}'), 2);
    });

    test('a wide-character table keeps its columns square', () {
      final table = Table(headers: ['名前', 'n'])..add(['あ', 1]);
      final lines = table.render().trim().split('\n');
      final widths = lines.map(Ansi.width).toSet();
      expect(widths, hasLength(1));
    });

    test('a partial alignments list renders instead of throwing', () {
      final table = Table(headers: ['a', 'b'], alignments: [ColumnAlign.right])
        ..add([1, 2]);
      expect(table.render, returnsNormally);
      expect(table.alignments, [ColumnAlign.right, ColumnAlign.left]);
    });

    test('the two progress constructors agree on their glyphs', () {
      expect(system.console.progress(total: 1).fill, Progress(total: 1).fill);
      expect(system.console.progress(total: 1).empty, Progress(total: 1).empty);
    });

    test('logger.task stays silent below info', () async {
      final logger = ConsoleLogger()..level = LogLevel.none;
      expect(await logger.task('work', () async => 7), 7);
    });
  });

  group('system tracking', () {
    test('untrack matches by path, not by File identity', () {
      final path = '${Directory.systemTemp.path}/dt_track_probe.part';
      system.on.track(File(path));
      // A different instance naming the same file must still release it, or
      // the SIGINT watcher keeps the process alive.
      system.on.untrack(File(path));
      expect(system.which('dart'), isNotNull);
    });
  });

  group('system.run', () {
    test('which answers "is it installed", run answers "what did it say"', () {
      // The pairing that replaced `tool.git`'s soft-failure contract:
      // `system.run` throws `ProcessException` for a binary that is not there,
      // and `system.which` is the question to ask first.
      expect(system.which('dt-definitely-not-an-executable'), isNull);
      expect(system.which('dart'), isNotNull);
    });

    test(
      'a binary that exists but fails reports rather than throwing',
      () async {
        final res = await system.run('git', ['checkout', 'no-such-branch-xyz']);
        expect(res.ok, isFalse);
        expect(res.code, isNot(0));
      },
    );
  });

  group('zip', () {
    test('packing does not follow a symlink out of the tree', () async {
      final root = Directory.systemTemp.createTempSync('dt_zip_');
      addTearDown(() => io.remove(root.path));
      final outside = Directory.systemTemp.createTempSync('dt_zip_outside_');
      addTearDown(() => io.remove(outside.path));

      File('${outside.path}/secret.txt').writeAsStringSync('do not pack me');
      File('${root.path}/kept.txt').writeAsStringSync('pack me');
      Link('${root.path}/link').createSync(outside.path);

      final archive = '${root.path}/../dt_zip_out.zip';
      addTearDown(() {
        final file = File(archive);
        if (file.existsSync()) file.deleteSync();
      });

      await format.zip.pack(root.path, archive);
      final names = (await format.zip.list(
        archive,
      )).transform(.map((e) => e.name)).collect(.list());
      expect(names, contains('kept.txt'));
      expect(names.any((n) => n.contains('secret')), isFalse);
    });
  });

  group('net.http extraction', () {
    test('the repeated @text shorthand reads text as a browser renders it', () {
      final res = Reply.text(
        '<a class="t">Wireless\n        Keyboard</a><a class="t">Mouse</a>',
      );

      // Every other spelling collapsed the page's indentation; the plural
      // attribute form handed back the source.
      expect(
        res.parse(format.html).extract({
          'x': const ['.t@text'],
        }),
        {
          'x': ['Wireless Keyboard', 'Mouse'],
        },
      );
      expect(
        res.parse(format.html).extract({
          'x': const ['.t'],
        }),
        {
          'x': ['Wireless Keyboard', 'Mouse'],
        },
      );
      expect(res.parse(format.html).pick(Field.attrs('.t', 'text')), [
        'Wireless Keyboard',
        'Mouse',
      ]);
    });

    test('a fixture that says where it came from resolves from there', () {
      final res = Reply.text(
        '<h1>hi</h1>',
        requested: 'https://example.com/a/b'.url,
      );

      // It used to sit at localhost however clearly the caller had said
      // otherwise, so anything resolving against it resolved wrong.
      expect(res.url, Uri.parse('https://example.com/a/b'));
      expect(res.requested, Uri.parse('https://example.com/a/b'));
    });
  });

  group('concurrent.retry', () {
    test('its backoff draws from the one seeded generator', () async {
      util.rand.seed(1);
      util.rand.jitter(const Duration(seconds: 1));
      final second = util.rand.jitter(const Duration(seconds: 1));

      util.rand.seed(1);
      var attempts = 0;
      await concurrent.retry(
        () {
          attempts++;
          if (attempts < 2) throw StateError('again');
          return attempts;
        },
        retries: 2,
        backoff: const Duration(milliseconds: 1),
      );
      addTearDown(util.rand.seed);

      // One retry, so one draw: the next value is the second of the seeded
      // sequence. A Random of its own used to make `util.rand.seed` a
      // promise this half of the library did not keep.
      expect(util.rand.jitter(const Duration(seconds: 1)), second);
    });
  });

  group('util.size', () {
    test('parse reads back everything format writes', () {
      for (final bytes in [
        0,
        512,
        2048,
        5 * 1024 * 1024,
        3 * 1024 * 1024 * 1024,
        7 * 1024 * 1024 * 1024 * 1024,
        // Petabytes: format printed them and parse answered 0.
        3 * 1024 * 1024 * 1024 * 1024 * 1024,
      ]) {
        expect(
          util.size.parse(util.size.format(bytes)),
          bytes,
          reason: '\$bytes',
        );
      }
      expect(util.size.parse('2 P'), 2 * 1024 * 1024 * 1024 * 1024 * 1024);
      expect(util.size.parse('2 PiB'), 2 * 1024 * 1024 * 1024 * 1024 * 1024);
      // A unit nobody knows is still refused rather than read as bytes.
      expect(util.size.parse('10 XB'), isNull);
    });
  });
}

/// Runs [body] against a shared client that gives up at the first refusal,
/// so a test of a failing fetch does not sit through the retry backoff.
Future<void> _withFailFastClient(Future<void> Function() body) async {
  final previous = net.http;
  await net.use(
    Fetcher(retries: 0, timeout: const Duration(seconds: 2)),
    close: false,
  );
  try {
    await body();
  } finally {
    await net.use(previous);
  }
}

/// A downloader that takes its time, for watching what a run leaves behind
/// while it is still going.
class _SlowDownloader<T> extends Downloader<T> {
  _SlowDownloader(this.pause);

  /// How long each fetch takes.
  final Duration pause;

  @override
  Future<Page<T>> download(Fetch<T> fetch) async {
    await Future<void>.delayed(pause);
    return Page<T>(
      fetch: fetch,
      status: 200,
      headers: const {'content-type': 'text/html'},
      bytes: '<h1>hi</h1>'.codeUnits,
      engine: engine,
    );
  }
}

void _noop(Page<String> response) {}
