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
      expect(page.$('p').count, equals(2));
      expect(
        page.$('p').elements.transform(.map((e) => e.text)).collect(.list()),
        equals(['a', 'b']),
      );
    });

    test('the flipped signatures stayed flipped', () {
      expect(util.text.words('a b'), isA<Sequence<String>>());
      expect(util.text.numbers('1 2'), isA<Sequence<num>>());
      expect(format.sitemap.parse(''), isA<Sequence<Uri>>());
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

  group('5.4.0 — the rule that sorts the vocabulary', () {
    // > A Transformer can emit before its source ends. A Collector needs the
    // > end.
    //
    // Six operations were on the wrong side of it through 5.3.0 — sort,
    // sort.by, sort.using, flip, take.last and skip.last — and nobody
    // noticed, because with one container both sides end in the same call. A
    // second container is what makes the rule observable, so this pins it the
    // way 4.0.0 pinned *no HTML parser under lib/net/*.
    Stream<int> counting(int n, void Function() tick) async* {
      for (var i = 0; i < n; i++) {
        tick();
        yield i;
      }
    }

    test('every pipe emits before its source is exhausted', () async {
      Flow<int> others() => const [0, 1, 2].flow;
      final steps = <String, Pipe<int, Object?> Function()>{
        'map': () => Pipe.map((int n) => n),
        'map.nonnull': () => Pipe.map.nonnull((int n) => n),
        'map.async': () => Pipe.map.async((int n) async => n, size: 2),
        'where': () => Pipe.where((int n) => true),
        'where.type': () => Pipe.where.type<int>(),
        'where.async': () => Pipe.where.async((int n) async => true, size: 2),
        'flat.map': () => Pipe.flat.map((int n) => Sequence([n])),
        'flat.async': () => Pipe.flat.async((int n) => [n].flow),
        'cast': () => Pipe.cast<int>(),
        'unique': () => Pipe.unique<int>(),
        'unique.by': () => Pipe.unique.by((int n) => n),
        'take.first': () => Pipe.take.first<int>(10),
        'take.when': () => Pipe.take.when((int n) => true),
        'skip.first': () => Pipe.skip.first<int>(1),
        'skip.when': () => Pipe.skip.when((int n) => false),
        'enumerate': () => Pipe.enumerate<int>(),
        'chunk': () => Pipe.chunk<int>(2),
        'tap': () => Pipe.tap((int n) {}),
        'timeout': () => Pipe.timeout<int>(const Duration(seconds: 30)),
        'handle': () => Pipe.handle<int>((e, s) {}),
        'zip': () => Pipe.zip<int, int>(others()),
        'plus': () => Pipe.plus<int>(others()),
        'minus': () => Pipe.minus<int>(const [-1].flow),
        'common': () => Pipe.common<int>(others()),
        'or': () => Pipe.or<int>(others()),
        'merge': () => Pipe.merge<int>(Flow<int>.empty()),
      };

      for (final MapEntry(key: name, value: make) in steps.entries) {
        var produced = 0;
        final first = await counting(
          1000,
          () => produced++,
        ).flow.transform(make()).collect(.first());

        expect(first, isNotNull, reason: '$name produced nothing');
        expect(
          produced,
          lessThan(1000),
          reason: '$name held its whole source; it belongs on Pour',
        );
      }
    });

    test('the six that need the end are transformers on a sequence', () {
      // On a Sequence each of these is a Transformer<int, int>, so a chain
      // never changes container. On a Flow they are Pours, handing back a
      // Sequence — `flow.transform(.sort.by(f))` does not compile, which is the
      // refusal, and the next test is the other half of the pin.
      final source = [3, 1, 2].seq;
      expect(source.transform(.sort()).collect(.list()), equals([1, 2, 3]));
      expect(
        source.transform(.sort.by((n) => -n)).collect(.list()),
        equals([3, 2, 1]),
      );
      expect(
        source
            .transform(.sort.using((a, b) => b.compareTo(a)))
            .collect(.list()),
        equals([3, 2, 1]),
      );
      expect(source.transform(.flip()).collect(.list()), equals([2, 1, 3]));
      expect(source.transform(.take.last(2)).collect(.list()), equals([1, 2]));
      expect(source.transform(.skip.last(2)).collect(.list()), equals([3]));
    });

    test('the same six are pours on a flow, handing back a sequence', () async {
      Flow<int> source() => const [3, 1, 2].flow;
      expect(
        (await source().collect(.sort())).collect(.list()),
        equals([1, 2, 3]),
      );
      expect(
        (await source().collect(.sort.by((n) => -n))).collect(.list()),
        equals([3, 2, 1]),
      );
      expect(
        (await source().collect(
          .sort.using((a, b) => b.compareTo(a)),
        )).collect(.list()),
        equals([3, 2, 1]),
      );
      expect(
        (await source().collect(.flip())).collect(.list()),
        equals([2, 1, 3]),
      );
      expect(
        (await source().collect(.take.last(2))).collect(.list()),
        equals([1, 2]),
      );
      expect(
        (await source().collect(.skip.last(2))).collect(.list()),
        equals([3]),
      );
    });

    test('sort is still usable where it never could be — downstream', () {
      final grouped = [3, 1, 4, 2].seq.collect(
        .group.into((n) => n.isEven, Transformer.sort<int>().into(.seq())),
      );
      expect(grouped.get(true)?.collect(.list()), equals([2, 4]));
      expect(grouped.get(false)?.collect(.list()), equals([1, 3]));
    });

    test('one pipeline crosses containers only through Pipe.of', () async {
      final cleanup = Transformer.where<int>((n) => n > 1)
          .then(Transformer.unique<int>())
          .then(Transformer.sort.using((a, b) => b.compareTo(a)));

      expect([3, 1, 2, 3].seq.transform(cleanup).collect(.list()), [3, 2]);
      expect(
        await [3, 1, 2, 3].flow.transform(Pipe.of(cleanup)).collect(.list()),
        [3, 2],
      );
    });

    test('a sequence and a flow answer identically', () async {
      final source = [3, 1, 2, 1, 5];
      expect(
        await source.flow.transform(.unique()).collect(.list()),
        equals(source.seq.transform(.unique()).collect(.list())),
      );
      expect(
        await source.flow.transform(.enumerate()).collect(.list()),
        equals(source.seq.transform(.enumerate()).collect(.list())),
      );
      expect(
        (await source.flow.collect(.count.by((n) => n.isEven))).map,
        equals(source.seq.collect(.count.by((n) => n.isEven)).map),
      );
      expect(
        await <int>[].flow.transform(.or(const [9].flow)).collect(.list()),
        equals(
          <int>[].seq.transform(.or(const Sequence([9]))).collect(.list()),
        ),
      );
    });

    test('a collect asks for no more of the source than it needs', () async {
      final stoppers = <String, Pour<int, Object?>>{
        'first': Pour.first<int>(),
        'first.where': Pour.first.where((int n) => n == 0),
        'single': Pour.single<int>(),
        'single.where': Pour.single.where((int n) => n < 2),
        'at': Pour.at<int>(0),
        'any': Pour.any((int n) => true),
        'all': Pour.all((int n) => false),
        'has': Pour.has<int>(0),
        'index.of': Pour.index.of<int>(0),
        'index.where': Pour.index.where((int n) => true),
        'empty': Pour.empty<int>(),
      };

      for (final MapEntry(key: name, value: step) in stoppers.entries) {
        var produced = 0;
        await counting(1000, () => produced++).flow.collect(step);
        expect(
          produced,
          lessThan(1000),
          reason: '$name walked its whole source',
        );
      }
    });

    test(
      'a flow is consumed once, whichever kind of stream backs it',
      () async {
        // The three behaviours Dart gives a second listen — a StateError, an
        // IOException, and silence — become one message, thrown when the second
        // pipeline is built rather than when it is listened to. Nothing here
        // ever listens.
        void once<T>(String kind, Flow<T> Function() make) {
          final claimed = isA<StateError>().having(
            (e) => e.message,
            'message',
            'This flow has already been consumed.',
          );

          final shaped = make()..transform(Pipe.map<T, T>((x) => x));
          expect(
            () {
              shaped.collect(Pour.count<T>());
            },
            throwsA(claimed),
            reason: kind,
          );
          expect(() => shaped.stream, throwsA(claimed), reason: kind);

          final left = make();
          left.stream;
          expect(
            () {
              left.transform(Pipe.map<T, T>((x) => x));
            },
            throwsA(claimed),
            reason: kind,
          );
        }

        // Never listened to, so it is never closed either: closing an
        // unlistened single-subscription controller waits for a subscriber.
        final controller = StreamController<int>();
        final file = File('${Directory.systemTemp.path}/dt_flow_once.txt')
          ..writeAsStringSync('a\nb\n');
        addTearDown(file.deleteSync);

        once('controller', () => controller.stream.flow);
        once('empty', Flow<int>.empty);

        // And the documented exception: a source that can honestly be read
        // again is a `Flow.of`, so a second terminal reads it again rather
        // than throwing. `io.async`'s listings and readers are all of these,
        // which is what makes the mirror with the blocking side a real one —
        // through 5.4.0 the two were documented as differing only by the
        // `await`, and that was true of one terminal and false of two.
        Future<void> twice<T>(String kind, Flow<T> Function() make) async {
          final flow = make();
          expect(await flow.collect(.count()), isNonZero, reason: kind);
          expect(await flow.collect(.count()), isNonZero, reason: kind);
          expect(
            await flow.transform(.take.first(1)).collect(.count()),
            equals(1),
            reason: kind,
          );
        }

        await twice('file', () => io.async.lines(file.path));
        await twice('iterable', () => [1, 2].flow);
        await twice('sequence', () => const Sequence([1, 2]).flow);
        await twice('walk', () => io.async.dir.walk(file.parent.path));
      },
    );

    test('a flow stops the source it no longer needs', () async {
      var produced = 0;
      final three = await counting(1000, () => produced++).flow
          .transform(.where((n) => n.isEven))
          .transform(.take.first(3))
          .collect(.list());

      expect(three, equals([0, 2, 4]));
      expect(produced, equals(5));
    });

    test('a crawl that is asked for one item fetches one page', () async {
      var fetched = 0;
      final first =
          await (net.crawl([Fetch('https://site.test/'.url)].seq)
                ..concurrent(1)
                ..using(
                  _pages(const {
                    'https://site.test/': '<span>Alpha</span><span>Beta</span>',
                  }, tick: () => fetched++),
                ))
              .flow
              .transform(
                .flat.map((res) => res.parse(format.html).$('span').texts),
              )
              .collect(.first());

      expect(first, equals('Alpha'));
      expect(fetched, equals(1));
    });

    test(
      'the escape hatch streams, because it can only take a stream',
      () async {
        // `Pipe.fn` takes a closure over a Stream, so there is nothing left to
        // buffer. `Transformer.fn` took one over an Iterable and an optional
        // `pour:`, and without the second it held the whole source on a flow —
        // the one place the streaming rule was a promise rather than a proof.
        var produced = 0;
        await counting(
          10,
          () => produced++,
        ).flow.transform(.fn((xs) => xs.map((n) => n))).collect(.first());
        expect(produced, equals(1));
      },
    );

    test(
      'a transformer reaches a flow through Pipe.of, and it buffers',
      () async {
        expect(
          await [1, 2, 3].flow.transform(Pipe.of(_Doubled())).collect(.list()),
          equals([2, 4, 6]),
        );

        // The adapter is the documented buffer: it has an Iterable-shaped
        // operation to feed, so it has to have all of it.
        var produced = 0;
        await counting(
          10,
          () => produced++,
        ).flow.transform(Pipe.of(_Doubled())).collect(.first());
        expect(produced, equals(10));
      },
    );
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
        // nothing to wait for. `csv` was a fourth entry through 5.4.0,
        // because every member of it was already a future or a stream from
        // the accessor that promises to block; it is a real mirror now.
        {'path', 'async', 'lock', 'locked', 'watch'},
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

    test('io.dir and io.async.dir are a mirror with no exceptions', () {
      final blocking = membersOf('dir.dart', 'DirAccessor');
      final async = membersOf('dir.dart', 'DirAsyncAccessor');

      // `cwd` and `home` were the two exceptions through 5.5.0, and they
      // read nothing off the disk — which is `io.path`'s whole membership
      // rule, so 6.0.0 moved them and the exception list is empty.
      expect(blocking.difference(async), isEmpty);
      expect(async.difference(blocking), isEmpty);
    });

    test('io.csv and io.async.csv are a mirror too', () {
      final blocking = membersOf('csv.dart', 'CsvFileAccessor');
      final async = membersOf('csv.dart', 'CsvFileAsyncAccessor');

      expect(blocking, equals({'rows', 'records', 'write'}));
      expect(blocking.difference(async), isEmpty);
      expect(async.difference(blocking), isEmpty);
    });

    test(
      'mirrored collection members differ in shape by rule: Sequence vs Flow',
      () async {
        final temp = io.dir.temp('dt_mirror_');
        addTearDown(() => io.remove(temp.path));
        final path = io.path.join(temp.path, 'a.txt');
        io.write(path, 'one\ntwo\n');

        // The general rule, not a special case: same name both sides, the
        // blocking one a Sequence and the async one a Flow.
        expect(io.lines(path), isA<Sequence<String>>());
        expect(io.async.lines(path), isA<Flow<String>>());
        expect(io.lines(path).collect(.list()), ['one', 'two']);
        expect(await io.async.lines(path).collect(.list()), ['one', 'two']);

        expect(io.dir.list(temp.path), isA<Sequence<FileSystemEntry>>());
        expect(io.async.dir.list(temp.path), isA<Flow<FileSystemEntry>>());
        expect(io.dir.walk(temp.path), isA<Sequence<FileSystemEntry>>());
        expect(io.async.dir.walk(temp.path), isA<Flow<FileSystemEntry>>());
        expect(io.dir.glob('${temp.path}/*'), isA<Sequence<FileSystemEntry>>());
        expect(
          io.async.dir.glob('${temp.path}/*'),
          isA<Flow<FileSystemEntry>>(),
        );

        expect(
          (await io.async.dir.list(temp.path).collect(.list())).map(
            (e) => e.name,
          ),
          ['a.txt'],
        );
      },
    );

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

      expect((io.stat(full)?.isfile ?? false), isTrue);
      expect((io.stat(folder)?.isdir ?? false), isTrue);
      expect((io.stat(folder)?.isfile ?? false), isFalse);
      expect((io.stat(full)?.islink ?? false), isFalse);

      expect(io.stat(full)?.size, 1);
      expect(io.stat(blank)?.size, 0);
      expect(io.stat(missing)?.size, isNull);

      // Empty and absent are different answers, and each kind is asked the
      // member that costs what it costs — `io.empty` fused the two.
      expect(io.stat(blank)!.empty, isTrue);
      expect(io.stat(full)!.empty, isFalse);
      expect(
        io.dir.empty(folder),
        isTrue,
        reason: 'a directory with nothing in it',
      );
      expect(io.stat(missing), isNull, reason: 'absent is not empty');

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
      expect(io.dir.walk(temp.path, only: .file).collect(.count()), 2);
      expect(
        io.dir.walk(temp.path, only: .file, depth: 1).collect(.count()),
        1,
      );
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

      expect((io.stat(io.path.join(inner, 'up'))?.islink ?? false), isTrue);
      expect((io.stat(io.path.join(inner, 'up'))?.isdir ?? false), isFalse);

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
      expect(res.parse(format.html).$('h1').text, 'T');
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

      // `Process` resolves to dart:io's. The toolkit's `Handler` typedef —
      // which used to fight it — is gone with the router: a crawl's `next`
      // is a plain function type, written where it is used.
      expect(Process.run, isA<Function>());
      const Sequence<Fetch> Function(Reply) next = _noNext;
      expect(next, isA<Sequence<Fetch> Function(Reply)>());
      expect(next(Reply.text('x')).collect(.empty()), isTrue);
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

      // `Fetch` fought `package:http` for a name and produced an
      // ambiguous_import on use. `Page` is gone entirely — it folded into
      // `Reply` in 6.0.0, because everything it added was the request it
      // came from or a call on an engine.
      expect(Fetch(Uri.parse('https://a.test')).url.host, 'a.test');
      expect(Reply.text('x').fetch, isA<Fetch>());
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

  group('format.robots', () {
    test('a crawl-delay-only group does not absorb the next group', () {
      final robots = format.robots.parse('''
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
      final robots = format.robots.parse('''
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
    test('the client counts the retries it actually made', () async {
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

      final client = Fetcher(retries: 3, backoff: 1.ms);
      addTearDown(client.close);
      final crawl = net.crawl(
        [Fetch('http://127.0.0.1:${server.port}/'.url)].seq,
      )..using(client.call);
      final stats = await crawl.run();

      // Retrying happens inside the client, below any scheduler, so the
      // count lives on the client. `Stats.retried` read zero however hard
      // the downloader tried, because nothing told the engine.
      expect(attempts, 3);
      expect(client.retried, 2);
      expect(stats.fetched, 1);
    });

    test('pouring a crawl writes through a staging file and creates its '
        'folder', () async {
      final dir = io.dir.temp('dt_save_');
      addTearDown(() => io.remove(dir.path));
      final dest = io.path.join(dir.path, 'nested', 'items.txt');

      await io.async.lines.write(
        dest,
        (net.crawl([Fetch('https://site.test/'.url)].seq)
              ..using(_pages(const {'/': '<h1>hi</h1>'})))
            .flow
            .transform(.map((res) => 'one')),
      );

      // The folder did not exist: opening the destination directly threw.
      expect(io.read(dest).trim(), 'one');
      expect(io.dir.walk(dir.path, match: '*.part*').collect(.empty()), isTrue);
    });

    test('the destination is replaced only once the run finishes', () async {
      final dir = io.dir.temp('dt_save_');
      addTearDown(() => io.remove(dir.path));
      final dest = io.path.join(dir.path, 'items.txt');
      io.write(dest, 'PREVIOUS');

      final run = io.async.lines.write(
        dest,
        (net.crawl([Fetch('https://site.test/'.url)].seq)
              ..using(_slow(const Duration(milliseconds: 200))))
            .flow
            .transform(.map((res) => 'one')),
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));
      // Mid-run: the destination used to have been truncated on the way in,
      // so an interrupted crawl took the last good results down with it.
      expect(io.read(dest), 'PREVIOUS');

      await run;
      expect(io.read(dest).trim(), 'one');
      expect(io.dir.walk(dir.path, match: '*.part*').collect(.empty()), isTrue);
    });

    test('a pour whose setup fails keeps the old file', () async {
      final dir = io.dir.temp('dt_save_');
      addTearDown(() => io.remove(dir.path));
      final dest = io.path.join(dir.path, 'items.txt');
      io.write(dest, 'PREVIOUS');
      final state = io.path.join(dir.path, 'crawl.state');
      io.write(state, '{not json');

      await expectLater(
        io.async.lines.write(
          dest,
          (net.crawl([Fetch('https://site.test/'.url)].seq)
                ..resume(state)
                ..using(_pages(const {'/': '<h1>hi</h1>'})))
              .flow
              .transform(.map((res) => 'one')),
        ),
        throwsA(anything),
      );

      expect(io.read(dest), 'PREVIOUS');
      expect(io.dir.walk(dir.path, match: '*.part*').collect(.empty()), isTrue);
    });

    test('a flow whose setup fails still ends', () async {
      final dir = io.dir.temp('dt_save_');
      addTearDown(() => io.remove(dir.path));
      final state = io.path.join(dir.path, 'crawl.state');
      io.write(state, '{not json');

      final events = <String>[];
      final ended = Completer<void>();

      (net.crawl([Fetch('https://site.test/'.url)].seq)
            ..resume(state)
            ..using(_pages(const {'/': '<h1>hi</h1>'})))
          .flow
          .stream
          .listen(
            (_) => events.add('item'),
            onError: (Object _) => events.add('error'),
            onDone: () {
              events.add('done');
              if (!ended.isCompleted) ended.complete();
            },
            cancelOnError: false,
          );

      // The flow used to carry the error and then stay open forever, with
      // the resume hook still holding the process alive behind it.
      await ended.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => events.add('never closed'),
      );

      expect(events, ['error', 'done']);
    });
  });

  group('format.csv', () {
    // The cursor keeps the header line out of `rows`; `Csv.raw` is the shape
    // the old `io.csv.parse` had, and the one these parser cases are about.
    List<List<String>> grid(String text, {String delimiter = ','}) => [
      ...Csv.raw(text, delimiter: delimiter).rows.collect(.list()),
    ];

    test('format keeps columns only later rows carry', () {
      final csv = format.csv.format(
        [
          {'a': 1},
          {'a': 2, 'b': 3},
        ].seq,
      );

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

      expect(await io.async.csv.rows(path).collect(.list()), grid(awkward));
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
        const PoolFailure<String, int>(
          Sequence<Settled<int>>([]),
          Sequence<String>([]),
        ).toString(),
        contains('no failures'),
      );
    });
  });

  group('system.console', () {
    test('width counts terminal columns, not code units', () {
      expect('日本語'.width, 6);
      expect('abc'.width, 3);
      expect('👍'.width, 2);
      expect('é'.width, 1);
      expect('${Ansi.red}hi${Ansi.reset}'.width, 2);
    });

    test('a wide-character table keeps its columns square', () {
      final table = Table(headers: ['名前', 'n'])..add(['あ', 1]);
      final lines = table.render().trim().split('\n');
      final widths = lines.map((line) => line.width).toSet();
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
        fetch: Fetch('https://example.com/a/b'.url),
      );

      // It used to sit at localhost however clearly the caller had said
      // otherwise, so anything resolving against it resolved wrong.
      expect(res.url, Uri.parse('https://example.com/a/b'));
      expect(res.fetch.url, Uri.parse('https://example.com/a/b'));
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

  // ==========================================================================

  group('5.5.0 — io, fixed and overhauled', () {
    late FileSystemEntry temp;
    setUp(() => temp = io.dir.temp('dt_550_'));
    tearDown(() => io.remove(temp.path));
    String at(String name) => io.path.join(temp.path, name);

    test('copying a tree keeps a link a link', () {
      // `Directory.list(recursive: true)` and a branch on `is Directory` /
      // `is File`: a link to a file was dereferenced into a second copy of
      // the content, and a link to a directory matched neither branch and
      // vanished without a word. `Entries.walk` has the three kinds.
      final source = at('tree');
      io.write(io.path.join(source, 'a.txt'), 'A');
      io.write(io.path.join(source, 'sub', 'b.txt'), 'B');
      io.dir.link(io.path.join(source, 'link.txt'), 'a.txt');
      io.dir.link(io.path.join(source, 'sub', 'loop'), '..');

      final copy = at('copy');
      io.copy(source, copy);

      expect(io.read(io.path.join(copy, 'a.txt')), equals('A'));
      expect(io.read(io.path.join(copy, 'sub', 'b.txt')), equals('B'));
      expect(
        (io.stat(io.path.join(copy, 'link.txt'))?.islink ?? false),
        isTrue,
      );
      expect(io.dir.target(io.path.join(copy, 'link.txt')), equals('a.txt'));
      expect(
        (io.stat(io.path.join(copy, 'sub', 'loop'))?.islink ?? false),
        isTrue,
      );
      expect(io.dir.target(io.path.join(copy, 'sub', 'loop')), equals('..'));
    });

    test('moving a directory onto a directory throws instead of merging', () {
      final from = at('from');
      final onto = at('onto');
      io.write(io.path.join(from, 'a.txt'), 'A');
      io.write(io.path.join(onto, 'b.txt'), 'B');

      // `rename` refuses this, and the blanket `on FileSystemException` used
      // to catch the refusal and fall back to copy-and-delete — merging the
      // two trees and deleting the source, silently.
      expect(() => io.move(from, onto), throwsA(isA<FileSystemException>()));
      expect(io.exists(io.path.join(from, 'a.txt')), isTrue);
      expect(io.exists(io.path.join(onto, 'a.txt')), isFalse);
      expect(io.exists(io.path.join(onto, 'b.txt')), isTrue);
    });

    test('a move that is not a cross-device move is not a copy', () async {
      // The fallback used to swallow every failure, so a vanished source
      // became a partial copy rather than the error it is.
      expect(
        () => io.move(at('missing'), at('dest')),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        io.async.move(at('missing'), at('dest')),
        throwsA(isA<FileSystemException>()),
      );
      expect(io.exists(at('dest')), isFalse);
    });

    test('concurrent writes to one path do not share a staging file', () async {
      // The staging path was `'$path$part'` with no disambiguator, and
      // `atomic` deleted an existing one before writing. Two writers to one
      // path took each other's file out, and the loser failed with an
      // internal `.part` path in the message.
      final path = at('race.txt');
      final outcomes = await Future.wait([
        for (var i = 0; i < 8; i++) io.async.write(path, 'writer-$i'),
      ]);

      expect(outcomes, hasLength(8));
      expect(io.read(path), startsWith('writer-'));
      expect(io.dir.walk(temp.path, match: '*.part').collect(.empty()), isTrue);
    });

    test('entry.empty answers from the stat, and never from the disk', () {
      final file = at('e.txt');
      io.touch(file);
      final dir = io.dir.make(at('d'));

      expect(io.stat(file)!.empty, isTrue);
      // A directory is not answerable from one stat, so it reads false here
      // and has its own member — `FileSystemEntry.empty` used to call
      // `listSync` inside a getter, which made `io.async.empty` block.
      expect(io.stat(dir.path)!.empty, isFalse);
      expect(io.dir.empty(dir.path), isTrue);

      io.touch(io.path.join(dir.path, 'x'));
      expect(io.dir.empty(dir.path), isFalse);
      // Each kind is asked its own member, which is what the cost is.
      expect(io.stat(file)!.empty, isTrue);
      expect(io.dir.empty(dir.path), isFalse);
      expect(io.stat(at('nothing')), isNull);
    });

    test('io.async.dir.empty does not block', () async {
      final dir = io.dir.make(at('d'));
      expect(await io.async.dir.empty(dir.path), isTrue);
      io.touch(io.path.join(dir.path, 'x'));
      expect(await io.async.dir.empty(dir.path), isFalse);
    });

    test(
      'sweep takes its listing before the first delete, on both sides',
      () async {
        // The flow rewrite made the async twin delete under a live recursive
        // listing — the one thing the blocking twin's own doc says a lazy walk
        // cannot be asked to survive.
        for (var i = 0; i < 12; i++) {
          io.write(at('deep/$i/file.part'), 'x');
          io.write(at('deep/$i/keep.txt'), 'x');
        }
        expect(
          await io.async.dir.sweep(at('deep'), match: '*.part'),
          equals(12),
        );
        expect(
          io.dir.walk(at('deep'), match: '*.part').collect(.empty()),
          isTrue,
        );
        expect(io.dir.walk(at('deep'), match: '*.txt').collect(.count()), 12);

        // And it defaults to the whole tree now, matching the member it is
        // built from rather than contradicting it.
        expect(io.dir.sweep(at('deep'), match: '*.txt'), equals(12));
      },
    );

    test('sweep leaves directories alone unless asked for them', () {
      io.write(at('p/one/a.txt'), 'x');
      io.dir.make(at('p/two'));

      expect(io.dir.sweep(at('p')), equals(1));
      expect((io.stat(at('p/one'))?.isdir ?? false), isTrue);
      // Deepest first, so a directory is emptied before it goes and nothing
      // is counted twice.
      expect(io.dir.sweep(at('p'), only: .directory), equals(2));
      expect(io.dir.list(at('p')).collect(.empty()), isTrue);
    });

    test('io.lines is a view, not a snapshot', () {
      final path = at('log.txt');
      io.write(path, 'one\ntwo\nthree\n');
      final lines = io.lines(path);

      // Nothing read at construction, and a walk that stops early stops
      // reading. It wrapped `readAsLinesSync`, so the whole file was a List
      // before the Sequence existed.
      expect(lines.collect(.first()), equals('one'));
      io.write(path, 'four\n');
      expect(lines.collect(.list()), equals(['four']));
    });

    test(
      'io.chunks reads a file in pieces, lazily, on both accessors',
      () async {
        final path = at('blob.bin');
        io.bytes.write(path, List<int>.generate(1000, (i) => i % 256));

        expect(io.chunks(path, size: 256).collect(.count()), equals(4));
        expect(
          io.chunks(path, size: 256).collect(.first())?.length,
          equals(256),
        );
        expect(
          io.chunks(path).collect(.fold(0, (n, c) => n + c.length)),
          equals(1000),
        );
        expect(
          await io.async.chunks(path, size: 256).collect(.count()),
          equals(4),
        );
        expect(() => io.chunks(path, size: 0), throwsArgumentError);
      },
    );

    test('lines.write is the general form save and pipe were', () async {
      final path = at('hosts.txt');
      io.lines.write(path, ['a.com', 'b.com'].seq);
      expect(io.read(path), equals('a.com\nb.com\n'));

      final streamed = at('streamed.txt');
      await io.async.lines.write(streamed, ['c.com', 'd.com'].flow);
      expect(io.read(streamed), equals('c.com\nd.com\n'));

      // Atomic: nothing at the destination until the flow ends.
      expect(io.dir.walk(temp.path, match: '*.part').collect(.empty()), isTrue);
    });

    test('Flow.dump writes a JSON array without ever holding one', () async {
      final path = at('rows.json');
      await [
        {'host': 'a.com'},
        {'host': 'b.com'},
      ].flow.dump(path);

      final back = await format.json.read(path);
      expect(back.count, equals(2));
      expect(back.at('0.host').text(), equals('a.com'));

      final empty = at('empty.json');
      await Flow<int>.empty().dump(empty);
      expect((await format.json.read(empty)).count, isZero);
    });

    test('io.temp is the file beside io.dir.temp', () {
      final scratch = io.temp('dt_scratch_');
      addTearDown(() => io.remove(io.path.dirname(scratch.path)));

      expect((io.stat(scratch.path)?.isfile ?? false), isTrue);
      expect(io.stat(scratch.path)!.empty, isTrue);
      expect(io.temp('dt_scratch_').path, isNot(equals(scratch.path)));
    });

    test('append.open holds one descriptor for a run of appends', () async {
      final path = at('run.log');
      final log = io.append.open(path);
      for (var i = 0; i < 500; i++) {
        log.write('line $i\n');
      }
      await log.close();

      expect(io.lines(path).collect(.count()), equals(500));
      expect(io.lines(path).collect(.first()), equals('line 0'));
      // Idempotent, so a `finally` after an early close is not an error.
      await log.close();
      expect(() => log.write('x'), throwsStateError);
    });

    test('link creates one and target reads it back', () async {
      final real = at('real.txt');
      io.write(real, 'hello');

      io.dir.link(at('latest'), 'real.txt');
      expect((io.stat(at('latest'))?.islink ?? false), isTrue);
      expect(io.dir.target(at('latest')), equals('real.txt'));
      expect(io.read(at('latest')), equals('hello'));
      // The raw target, not the resolved one, and null for anything else.
      expect(io.dir.target(real), isNull);

      // Replacing a link is fine; replacing a file is not.
      io.dir.link(at('latest'), 'real.txt');
      expect(await io.async.dir.target(at('latest')), equals('real.txt'));
      expect(() => io.dir.link(real, 'x'), throwsA(isA<FileSystemException>()));
    });

    test('io.dir.size sums a tree where io.size cannot', () async {
      io.write(at('s/a.txt'), '12345');
      io.write(at('s/deep/b.txt'), '123');
      io.dir.link(at('s/link.txt'), 'a.txt');

      expect(io.stat(at('s'))?.size, isZero, reason: 'a directory has no size');
      // Links count as nothing, so a tree that links twice to one file is
      // not counted twice.
      expect(io.dir.size(at('s')), equals(8));
      expect(await io.async.dir.size(at('s')), equals(8));
    });

    test('io.csv is a mirror, and pipe is gone', () async {
      final path = at('people.csv');
      io.csv.write(
        path,
        [
          {'name': 'Ada', 'role': 'admin'},
          {'name': 'Bob', 'role': 'user'},
        ].seq,
      );

      expect(io.csv.rows(path).collect(.count()), equals(3));
      expect(io.csv.records(path).collect(.count()), equals(2));
      expect(io.csv.records(path).collect(.first())?['name'], equals('Ada'));

      expect(await io.async.csv.rows(path).collect(.count()), equals(3));
      expect(await io.async.csv.records(path).collect(.count()), equals(2));

      final streamed = at('streamed.csv');
      await io.async.csv.write(
        streamed,
        [
          {'name': 'Cy', 'role': 'admin'},
        ].flow,
      );
      expect(io.csv.records(streamed).collect(.first())?['name'], equals('Cy'));
    });

    test('a blocking csv read is a lazy view', () {
      final path = at('big.csv');
      io.csv.write(
        path,
        [
          for (var i = 0; i < 200; i++) {'n': '$i'},
        ].seq,
      );

      // A Sequence, so it can be walked twice and a walk can stop early.
      final records = io.csv.records(path);
      expect(records.collect(.first())?['n'], equals('0'));
      expect(records.collect(.count()), equals(200));
      expect(
        records.transform(.take.first(3)).collect(.list()).length,
        equals(3),
      );
    });
  });

  group('5.5.0 — the two vocabularies', () {
    test('a pipe has the operations a transformer never could', () async {
      // Every one of these had no spelling at all through 5.4.0.
      expect(
        await [1, 2, 3].flow.transform(.tap((_) {})).collect(.list()),
        equals([1, 2, 3]),
      );
      expect(
        await [
          1,
          2,
          3,
        ].flow.transform(.map.async((n) async => n * 2)).collect(.list()),
        equals([2, 4, 6]),
      );
      expect(
        await [
          1,
          2,
          3,
          4,
        ].flow.transform(.where.async((n) async => n.isEven)).collect(.list()),
        equals([2, 4]),
      );
      expect(
        await [
          1,
          2,
        ].flow.transform(.flat.async((n) => [n, n].flow)).collect(.list()),
        equals([1, 1, 2, 2]),
      );
      expect(
        await Stream<int>.error(
          StateError('x'),
        ).flow.transform(.handle((e, s) {})).collect(.list()),
        isEmpty,
      );
    });

    test('a pipe takes a flow as its operand, which nothing could', () async {
      expect(
        await [1, 2, 3].flow.transform(.zip(['a', 'b'].flow)).collect(.list()),
        equals([(1, 'a'), (2, 'b')]),
      );
      expect(
        await [1, 2].flow.transform(.plus([3].flow)).collect(.list()),
        equals([1, 2, 3]),
      );
      expect(
        await [1, 2, 3].flow.transform(.minus([2].flow)).collect(.list()),
        equals([1, 3]),
      );
      expect(
        await [
          1,
          2,
          3,
        ].flow.transform(.common([2, 3, 4].flow)).collect(.list()),
        equals([2, 3]),
      );
      expect(
        await <int>[].flow.transform(.or([9].flow)).collect(.list()),
        equals([9]),
      );
      expect(
        (await [1, 3].flow.transform(.merge([2].flow)).collect(.set())),
        equals({1, 2, 3}),
      );
    });

    test('chunk.time closes a batch on the clock', () async {
      final controller = StreamController<int>();
      final batches = controller.stream.flow
          .transform(.chunk.time(40.ms))
          .collect(.list());

      controller
        ..add(1)
        ..add(2);
      await util.time.wait(90.ms);
      controller.add(3);
      await util.time.wait(90.ms);
      await controller.close();

      final got = await batches;
      expect(got.length, greaterThanOrEqualTo(2));
      expect(got.expand((b) => b.collect(.list())).toList(), equals([1, 2, 3]));
      // An idle window emits nothing rather than an empty batch.
      expect(got.every((b) => !b.collect(.empty())), isTrue);
    });

    test('debounce keeps the last of a burst, throttle the first', () async {
      final controller = StreamController<int>();
      final quiet = controller.stream.flow
          .transform(.debounce(50.ms))
          .collect(.list());

      controller
        ..add(1)
        ..add(2)
        ..add(3);
      await util.time.wait(120.ms);
      controller.add(4);
      await controller.close();

      expect(await quiet, equals([3, 4]));

      final fast = StreamController<int>();
      final capped = fast.stream.flow
          .transform(.throttle(50.ms))
          .collect(.list());
      fast
        ..add(1)
        ..add(2);
      await util.time.wait(80.ms);
      fast.add(3);
      await fast.close();
      expect(await capped, equals([1, 3]));
    });

    test('timeout fails a flow that goes quiet', () async {
      final controller = StreamController<int>();
      final out = controller.stream.flow
          .transform(.timeout(30.ms))
          .collect(.list());
      controller.add(1);
      await expectLater(out, throwsA(isA<TimeoutException>()));
      await controller.close();
    });

    test('Pour.foreach awaits, where Collector.foreach cannot', () async {
      // The commonest silent mistake in a streaming script: a
      // `Future`-returning closure is assignable to a `void` function type,
      // so `foreach` compiled, started every call and awaited none.
      final done = <int>[];
      await [1, 2, 3].flow.collect(
        .foreach((n) async {
          await util.time.wait(1.ms);
          done.add(n);
        }),
      );
      expect(done, equals([1, 2, 3]), reason: 'awaited, and in order');
    });

    test('Flow.nonnull is the twin Sequence always had', () async {
      final flow = <int?>[1, null, 2].flow;
      expect(await flow.nonnull.collect(.list()), equals([1, 2]));
    });

    test('flat infers its element type from the receiver', () {
      // `Transformer<Never, B>` type-checked against any sequence, inferred
      // nothing, and threw StateError at runtime on elements that were not
      // iterable. It has the static type it always had.
      final groups = [
        [1, 2].seq,
        [3].seq,
      ].seq;
      expect(groups.transform(.flat()).collect(.list()), equals([1, 2, 3]));
      expect(Transformer.flat<int>(), isA<Transformer<Sequence<int>, int>>());
      expect(Pipe.flat<int>(), isA<Pipe<Sequence<int>, int>>());
    });
  });

  group('6.0.0 — the mirrors, pinned', () {
    /// The public member names declared directly on [type] in [path].
    ///
    /// Source text rather than reflection, because `dart:mirrors` is not
    /// available to a compiled test — and because reading the declarations is
    /// what catches a member added to one side and forgotten on the other.
    Set<String> membersOf(String path, String type) {
      final source = File(path).readAsStringSync();
      final names = <String>{};
      var inside = false;

      for (final line in source.split('\n')) {
        if (RegExp('^(final |abstract )?class $type[ {<]').hasMatch(line)) {
          inside = true;
          continue;
        }
        if (!inside) continue;
        if (line == '}' ||
            RegExp(r'^(final |abstract )?class ').hasMatch(line)) {
          break;
        }
        if (!line.startsWith('  ') || line.startsWith('   ')) continue;
        final trimmed = line.trimLeft();
        if (trimmed.isEmpty) continue;
        if (RegExp(
          r'^(//|@|\}|\)|=>|\.\.|;|static |const )',
        ).hasMatch(trimmed)) {
          continue;
        }

        final getter = RegExp(r'\bget (\w+)').firstMatch(trimmed);
        if (getter != null) {
          names.add(getter.group(1)!);
          continue;
        }
        // `final List<String> raw;` — a field is a member too.
        final field = RegExp(r'^final [\w<>,?\s]+ (\w+);').firstMatch(trimmed);
        if (field != null) {
          names.add(field.group(1)!);
          continue;
        }
        // A constructor is not a member of the vocabulary.
        if (trimmed.startsWith('$type(') || trimmed.startsWith('$type.')) {
          continue;
        }
        final open = trimmed.indexOf('(');
        if (open <= 0) continue;
        // `Cli _parsed = Cli(const []);` — an initialiser, not a signature.
        if (trimmed.substring(0, open).contains('=')) continue;
        final head = trimmed
            .substring(0, open)
            .replaceAll(RegExp(r'<[^<>]*>'), '');
        final name = RegExp(r'(\w+)\s*$').firstMatch(head);
        if (name != null) names.add(name.group(1)!);
      }

      names.removeWhere((n) => n == type || n.startsWith('_'));
      expect(names, isNotEmpty, reason: 'read no members off $type');
      return names;
    }

    test('Cli and CliAccessor are a mirror with two named exceptions', () {
      final reader = membersOf('lib/cli/parse.dart', 'Cli');
      final accessor = membersOf('lib/cli/cli.dart', 'CliAccessor');

      // A handler's parameter is *called* `cli`, so the vocabulary has to
      // read the same inside a handler and outside one. Eight forwarders are
      // a mirror rather than eight flat shortcuts — once a test says so.
      // It was nine until 6.2.0 deleted `help` from both sides.
      //
      // `switches` was on `Cli` only through 5.5.0, which sent a script
      // outside a handler through `cli.parsed.switches`: a third spelling of
      // a member that has one.
      expect(
        reader.difference(accessor),
        isEmpty,
        reason: 'a member of Cli with no twin on CliAccessor',
      );
      expect(
        accessor.difference(reader),
        // A `Cli` cannot parse itself into existence, so these two have no
        // twin by construction. Rule 3 calls them *members with no twin*.
        {'parse', 'parsed'},
        reason: 'an accessor member with no twin on Cli',
      );
    });

    test('every Ansi code has an extension member of the same name', () {
      final source = File('lib/system/console/ansi.dart').readAsStringSync();

      final codes = <String>{
        for (final m in RegExp(
          r'static const String (\w+) =',
        ).allMatches(source))
          m.group(1)!,
      }..remove('reset');

      final start = source.indexOf('extension AnsiStringExtension on String {');
      final members = <String>{
        for (final m in RegExp(
          r'^  String (\w+)\(\) =>',
          multiLine: true,
        ).allMatches(source.substring(start)))
          m.group(1)!,
      };

      // 76 names with three duplicate spellings and four holes through 5.5.0:
      // `black`, `bgblack`, `bgmagenta` and `bgwhite` had a constant and no
      // member, so `'x'.red()` worked and `'x'.black()` did not, with nothing
      // to say why. Adding a colour is two edits, and forgetting one fails
      // the build now.
      expect(codes, isNotEmpty);
      expect(
        codes.difference(members),
        isEmpty,
        reason: 'a code with no extension member',
      );
      expect(
        members.difference(codes),
        isEmpty,
        reason: 'an extension member with no code',
      );
    });

    test('no doc comment names a member that no longer exists', () {
      // The second time a rename left a dangling reference: `Pool.flow`'s doc
      // pointed at `Flow.run` for two releases after `Pipe.map.async`
      // replaced it. Cheap to pin.
      const gone = [
        'Flow.run',
        'Downloader',
        'HttpDownloader',
        'MapDownloader',
        'DownloaderEvents',
        'Deduplicator',
        'Snapshot',
        'CrawlBuilder',
        'CrawlEvents',
        'EngineEvents',
        'QueueAccess',
        'PathResolver',
        'Ansi.strip',
        'Ansi.width',
        'system.exit',
        'io.save',
        'io.dir.cwd',
        'io.dir.home',
        'util.hash.encode',
        'format.zip.read',
        'format.html.query',
      ];

      final offenders = <String>[];
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        var line = 0;
        for (final text in file.readAsStringSync().split('\n')) {
          line++;
          final trimmed = text.trimLeft();
          if (!trimmed.startsWith('///')) continue;
          for (final name in gone) {
            // A bracket reference or a code span — a sentence that merely
            // says the old name was deleted is the point of this sweep.
            if (trimmed.contains('[$name]')) {
              offenders.add('${file.path}:$line names [$name]');
            }
          }
        }
      }

      expect(offenders, isEmpty);
    });
  });

  group('6.0.0 — the crawl terminals', () {
    test('a flow that nobody collects fetches nothing', () async {
      var fetched = 0;
      (net.crawl([Fetch('https://site.test/'.url)].seq)..using(
            _pages(const {
              'https://site.test/': '<h1>x</h1>',
            }, tick: () => fetched++),
          ))
          .flow;

      // The engine used to be armed in the method body, so building a flow
      // and dropping it still fetched a page. `Pool.flow` had guarded this
      // with `onListen` since 5.3.0.
      await util.time.wait(60.ms);
      expect(fetched, isZero);
    });

    test('collecting the flow is what starts the crawl', () async {
      var fetched = 0;
      final out =
          await (net.crawl([Fetch('https://site.test/'.url)].seq)..using(
                _pages(const {
                  'https://site.test/': '<h1>x</h1>',
                }, tick: () => fetched++),
              ))
              .flow
              .transform(.map((res) => res.parse(format.html).$('h1').text))
              .collect(.list());

      expect(out, equals(['x']));
      expect(fetched, equals(1));
    });

    test(
      'the flow is the vocabulary, so items and gather are steps on it',
      () async {
        final crawl = net.crawl([Fetch('https://site.test/'.url)].seq)
          ..using(_pages(const {'/': '<h1>One</h1><h1>Two</h1>'}));

        // `items()` was `.collect(.list())`; `gather(map)` was
        // `.transform(.flat.map(map)).collect(.seq())`, and neither needs a
        // member of its own.
        final out = await crawl.flow
            .transform(.flat.map((res) => res.parse(format.html).$('h1').texts))
            .collect(.seq());

        expect(out, isA<Sequence<String>>());
        expect(out.collect(.list()), equals(['One', 'Two']));
      },
    );

    test('next hands back a Sequence, the one rule for a callback', () {
      final res = Reply.text(
        '<a href="/b">b</a>',
        fetch: Fetch('https://s.test/'.url),
      );
      final Sequence<Fetch> next = res
          .parse(format.html)
          .$('a')
          .attrs('href')
          .transform(.map(res.follow));
      expect(next.collect(.count()), 1);
    });
  });

  group('6.1.0 — nothing unasked, and one knob per question', () {
    // `Fetcher()` retried twice and sent a Chrome User-Agent, neither asked
    // for. Against a host dropping TLS handshakes that read as the library
    // being slower than `package:http`: one returned the failure, the other
    // spent 11 seconds hiding it.
    test('a fresh client retries nothing and sends no headers', () {
      final bare = Fetcher();
      expect(bare.retries, 0);
      expect(bare.redirects, 0);
      expect(bare.headers, isEmpty);
      expect(bare.cache, isNull);
      expect(bare.limiter, isNull);
      expect(bare.jar, isNull);
    });

    test('the browser headers have a name now', () {
      final scraper = Fetcher.browser();
      expect(scraper.headers['User-Agent'], contains('Chrome/'));
      expect(scraper.headers['Accept'], contains('text/html'));
      expect(scraper.retries, 0, reason: 'a name, not a bundle of defaults');
      expect(
        Fetcher.browser(
          headers: const {'Accept': 'application/json'},
        ).headers['Accept'],
        'application/json',
        reason: 'merged over, not replacing the pair',
      );
    });

    // `retry: bool` decided whether `retries: int` applied, and
    // `redirect: bool` whether `redirects: int` did — the `times:`/`retries:`
    // pair Rule 5 deleted from `concurrent.retry`, twice over and in two
    // types. Both bools are gone; the int answers on its own.
    test('one parameter per question, and the null means inherit', () {
      final client = Fetcher(retries: 3, redirects: 4);
      expect(client.retries, 3);
      expect(client.redirects, 4);
      // The surviving spellings, named rather than called: the analyzer is
      // the assertion, and a returning `retry:` or `redirect:` breaks it.
      Future<Reply> override() => client.send(
        .get,
        'https://example.invalid/'.url,
        redirects: 2,
        retries: 1,
      );
      expect(override, isA<Function>());
    });

    // A 302 handed back is this client reporting what the server said. The
    // limit of 5 that used to follow it was a number nobody chose.
    test('a redirect is an answer until a caller asks for the hop', () async {
      final server = await net.serve(
        0,
        (req) async => switch (req.path) {
          '/from' => Served.redirect('/to'.url),
          _ => const Served.text('arrived'),
        },
      );
      try {
        final url = 'http://localhost:${server.port}/from'.url;
        final held = await net.http.send(.get, url);
        expect(held.status, 302);
        expect(held.headers['location'], '/to');

        final hopped = await net.http.send(.get, url, redirects: 1);
        expect(hopped.status, 200);
        expect(hopped.body, 'arrived');

        await expectLater(
          net.http.send(.get, url, redirects: 0).then((res) => res.status),
          completion(302),
          reason: 'zero hops is the default spelled out, not an error',
        );
      } finally {
        await server.close(force: true);
      }
    });

    // `concurrent.retry(fn, retries: 0)` is `fn()` under a name that promises
    // otherwise, so this is the one number the library will not invent.
    test('concurrent.retry requires the number it counts in', () async {
      var calls = 0;
      await expectLater(
        concurrent.retry(
          () {
            calls++;
            if (calls < 3) throw StateError('not yet');
            return calls;
          },
          retries: 2,
          backoff: 1.ms,
        ),
        completion(3),
      );
      // `times:` stood beside `retries:` on the function under the accessor
      // until now, holding the same number one larger, and resolved silently
      // in favour of whichever was read first.
      calls = 0;
      await expectLater(
        concurrentRetry(
          () {
            calls++;
            throw StateError('never');
          },
          retries: 1,
          backoff: 1.ms,
        ),
        throwsStateError,
      );
      expect(calls, 2, reason: 'retries: 1 is two attempts');
    });

    // `onProgress` was the library's one camelCase parameter, beside
    // `onretry` and `onchange` in the same signature's neighbourhood.
    // `find`/`xpath` were the methods and `$` an opt-in extension on `String`,
    // on the reasoning that a script should not be forced to see an
    // identifier called `$`. That argument only ever covered the global: a
    // method named `$` adds nothing to any scope.
    test('\$ is the selector, and find is gone', () {
      final page = format.html.parse(
        '<ul><li class="track" data-id="1"><a href="/t/1">One</a></li></ul>',
      );
      expect(page.$('.track a').text, 'One');
      expect(page.$('.track').attr('data-id'), '1');
      expect(page.$('.track').$('a').attrs('href').collect(.list()), ['/t/1']);
      expect(page.$xpath('//a').attr('href'), '/t/1');
    });

    test('format.html parses and selects in one call', () {
      const markup = '<li class="track">One</li>';
      expect(format.html.$(markup, '.track').text, 'One');
      expect(format.html.$xpath(markup, '//li').text, 'One');
      // The selector is required, which is what keeps it from being a second
      // spelling of `parse`: one parses, the other parses and selects.
      expect(format.html.parse(markup).$('.track').text, 'One');
    });

    test('the top-level functions stay opt-in, and carry the same names', () {
      const markup = '<li class="track">One</li>';
      expect($(markup, '.track').text, 'One');
      expect($(markup).$('.track').text, 'One');
      expect($xpath(markup, '//li').text, 'One');
    });

    test('download names its callback the way the others do', () {
      Future<FileSystemEntry> call(String to) => net.http.download(
        'https://example.invalid/x'.url,
        to,
        onprogress: (received, total) {},
        retries: 0,
      );
      expect(call, isA<Function>());
    });
  });

  group('6.2.0 — the helper sweep', () {
    // Forty-odd members that were a second reading of something the library
    // already answered. Each test below is the survivor answering it.

    test('one verb, and the method is an argument', () async {
      final server = await net.serve(
        0,
        (req) async => Served.text('${req.method.wire} ${req.path}'),
      );
      try {
        final base = 'http://localhost:${server.port}';
        expect((await net.http.send(.get, '$base/a'.url)).body, 'GET /a');
        expect((await net.http.send(.head, '$base/a'.url)).status, 200);
        expect(
          (await net.http.send(
            .post,
            '$base/b'.url,
            body: Body.json({'x': 1}),
          )).body,
          'POST /b',
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('the kind questions are the entry stat already returns', () {
      final dir = io.dir.temp('dt_kind_');
      addTearDown(() => io.remove(dir.path));
      final file = io.path.join(dir.path, 'a.txt');
      io.write(file, 'x');

      expect(io.stat(file)?.isfile, isTrue);
      expect(io.stat(file)?.isdir, isFalse);
      expect(io.stat(file)?.islink, isFalse);
      expect(io.stat(file)?.size, 1);
      expect(io.stat(file)?.empty, isFalse);
      expect(io.stat(io.path.join(dir.path, 'nope')), isNull);
      // `io.exists` stays: it is the one question the entry cannot answer,
      // because there is no entry.
      expect(io.exists(file), isTrue);
    });

    test('a cursor reads the first match, and elements reads the rest', () {
      final page = format.html.parse(
        '<ul><li class="a" data-id="1">one</li><li class="b">two</li></ul>',
      );
      expect(page.$('li').text, 'one two');
      expect(page.$('li').attr('data-id'), '1');
      // The plurals that stayed, because a scraper writes them.
      expect(page.$('li').texts.collect(.list()), ['one', 'two']);
      expect(page.$('li').attrs('data-id').collect(.list()), ['1']);
      // The ones that went, spelled as the map they always were.
      expect(
        page
            .$('li')
            .elements
            .transform(.map((e) => e.innerHtml))
            .collect(.list()),
        ['one', 'two'],
      );
      // `not`, `has` and `data` were a selector, a selector and a prefix.
      expect(page.$('li').matching(':not(.a)').text, 'two');
      expect(page.$('li').matching('.a').empty, isFalse);
      expect(page.$('li').attr('data-id'), '1');
    });

    test('the singular of a plural is first, on both cursors', () {
      final page = format.html.parse('<p class="r">a</p><p class="r">b</p>');
      expect(page.all('.r', (row) => row.text).collect(.first()), 'a');
      final doc = format.json.parse('[{"n": 1}, {"n": 2}]');
      expect(doc.all((item) => item.number('n')).collect(.first()), 1);
      expect(doc.all((item) => item.text('n')).nonnull.collect(.list()), [
        '1',
        '2',
      ]);
    });

    test('add is one row or many, and neither has a capital in it', () {
      final table = Table(headers: ['a', 'b'])
        ..add(['1', '2'])
        ..add.all(
          [
            ['3', '4'],
            ['5', '6'],
          ].seq,
        );
      final drawn = table.render();
      for (final cell in ['1', '3', '5']) {
        expect(drawn, contains(cell));
      }
    });

    test('no public member of this library is camelCase', () {
      // `Table.addAll`, `Cli.usageExit` and `Field.readAll` were the last
      // three. `lib/src` internals are exempt: they are not exported.
      final exported = <String>[
        'lib/cli',
        'lib/collection',
        'lib/concurrent',
        'lib/format',
        'lib/io',
        'lib/net',
        'lib/system',
        'lib/util',
        'lib/src/codec.dart',
        'lib/src/csv.dart',
        'lib/src/extensions.dart',
        'lib/src/json.dart',
        'lib/src/method.dart',
        'lib/src/markup.dart',
      ];
      // dart:core interface members and third-party members being called.
      const exempt = {
        'toString',
        'hashCode',
        'isEmpty',
        'isNotEmpty',
        'iterator',
        'noSuchMethod',
        'toJson',
      };
      final member = RegExp(
        r'^  (?:static\s+)?(?:const\s+|final\s+|late\s+)?'
        r'[A-Za-z_][\w<>,?\[\] .]*\s+(?:get\s+)?([a-z]+[A-Z]\w*)\s*[({=;]',
      );

      final offenders = <String>[];
      for (final path in exported) {
        final entity = FileSystemEntity.isDirectorySync(path)
            ? Directory(path).listSync(recursive: true).whereType<File>()
            : [File(path)];
        for (final file in entity) {
          if (!file.path.endsWith('.dart')) continue;
          var line = 0;
          for (final text in file.readAsStringSync().split('\n')) {
            line++;
            final match = member.firstMatch(text);
            final name = match?.group(1);
            if (name == null || exempt.contains(name)) continue;
            offenders.add('${file.path}:$line declares $name');
          }
        }
      }

      expect(offenders, isEmpty);
    });

    test('the util one-liners are dart:core, spelled as dart:core', () {
      final when = DateTime.utc(2024, 3, 1, 12);
      expect(when.toUtc().toIso8601String(), startsWith('2024-03-01T12:00'));
      expect(when.millisecondsSinceEpoch, greaterThan(0));
      expect((Stopwatch()..start()).isRunning, isTrue);
      expect(util.hash.sha('abc').substring(0, 8).length, 8);
      expect(
        util.rand
            .shuffle([1, 2, 3])
            .transform(.take.first(2))
            .collect(.count()),
        2,
      );
      expect(util.text.betweens('a=1;a=2;', 'a=', ';').collect(.first()), '1');
    });

    test('the deleted names are gone from every doc comment', () {
      const gone = [
        'Markup.one',
        'Markup.values',
        'Markup.htmls',
        'Markup.outers',
        'Markup.data',
        'Markup.dataset',
        'Markup.has',
        'Markup.each',
        'Markup.not',
        'Markup.xpathvalues',
        'Json.one',
        'Json.texts',
        'io.size',
        'io.empty',
        'io.isfile',
        'io.isdir',
        'io.islink',
        'Appender.line',
        'Dictionary.invert',
        'Table.addAll',
        'Table.length',
        'Cli.help',
        'Cli.usageExit',
        'Field.readAll',
        'Asked.json',
        'CookieJar.length',
        'ConsoleWriter.table',
        'util.hash.short',
        'util.rand.some',
        'util.time.iso',
        'util.time.epoch',
        'util.time.clock',
        'util.text.between',
      ];

      final offenders = <String>[];
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        var line = 0;
        for (final text in file.readAsStringSync().split('\n')) {
          line++;
          final trimmed = text.trimLeft();
          if (!trimmed.startsWith('///')) continue;
          for (final name in gone) {
            if (trimmed.contains('[$name]')) {
              offenders.add('${file.path}:$line names [$name]');
            }
          }
        }
      }

      expect(offenders, isEmpty);
    });
  });

  group('6.3.0 — the seam', () {
    // Every read in this library hands back a `Sequence`, and through 6.2.0
    // every writer took an `Iterable` or a `List`. Since `Sequence` is
    // deliberately not an `Iterable`, nothing the library read could be
    // handed to anything the library wrote without leaving the vocabulary
    // through `collect(.list())` — including a codec's own round trip.

    test('format.csv round-trips its own cursor', () {
      final sheet = format.csv.parse('a,b\n1,2\n3,4\n');
      expect(format.csv.format(sheet.maps), 'a,b\n1,2\n3,4\n');
      expect(format.csv.cells(sheet.rows), '1,2\n3,4\n');
    });

    test('format.sitemap round-trips its own parse', () {
      final urls = format.sitemap.parse(
        '<urlset><url><loc>https://a.test/</loc></url></urlset>',
      );
      expect(format.sitemap.format(urls), contains('https://a.test/'));
      expect(
        format.sitemap.parse(format.sitemap.format(urls)).collect(.list()),
        urls.collect(.list()),
      );
    });

    test('Csv.rows spells a row the way io.csv.rows always did', () {
      final sheet = format.csv.parse('a,b\n1,2\n');
      final row = sheet.rows.collect(.first())!;
      // A List, so a cell is read by position rather than collected out.
      expect(row[1], '2');
      expect(sheet.rows.collect(.list()), [
        ['1', '2'],
      ]);
    });

    test(
      'a pool takes what a read hands back, and settles without a Pool',
      () async {
        final sheet = format.csv.parse('a,b\n1,2\n');
        expect(
          (await concurrent.run(
            sheet.headers,
            (h) async => h.toUpperCase(),
          )).collect(.list()),
          ['A', 'B'],
        );
        final settled = await concurrent.settle(
          sheet.headers,
          (h) async => h == 'a' ? throw StateError('no') : h,
        );
        expect(settled.collect(.count()), 2);
        expect(settled.collect(.first()), isA<Broke<String>>());
        expect(settled.collect(.last()), isA<Done<String>>());
      },
    );

    test('a crawl is seeded by what a crawl produces', () async {
      final seeds = [
        'https://a.test/',
        'https://b.test/',
      ].seq.transform(.map((u) => Fetch(u.url)));
      final crawl = net.crawl(seeds, _noNext)
        ..using(_pages({'https://a.test/': 'A', 'https://b.test/': 'B'}));
      expect((await crawl.flow.collect(.count())), 2);
      // `accept` takes the same shape, so a parsed column of types fits.
      expect(
        net.crawl(seeds, _noNext).accept(const Sequence(['text/html'])),
        isA<Crawl>(),
      );
    });

    test('a table is built from a parsed grid', () {
      final sheet = format.csv.parse('a,b\n1,2\n');
      final table = Table(headers: sheet.headers.collect(.list()))
        ..add.all(sheet.rows);
      expect(table.render(), contains('1'));
    });

    test('util.size.format takes the num that collect(.sum) returns', () {
      final sizes = [1024, 1024].seq;
      expect(util.size.format(sizes.collect(.sum((n) => n))), '2.0 KiB');
      expect(util.size.format(1536.9), '1.5 KiB');
      expect(util.size.format(0.4), '0 B');
    });

    test('tap watches a sequence go past, as it always did a flow', () {
      final seen = <int>[];
      final kept = [1, 2, 3].seq
          .transform(.tap(seen.add))
          .transform(.where((n) => n.isOdd))
          .collect(.list());
      expect(kept, [1, 3]);
      expect(seen, [1, 2, 3]);
      // Lazy, like every other step: nothing ran before the terminal did.
      final untouched = <int>[];
      [1, 2].seq.transform(.tap(untouched.add));
      expect(untouched, isEmpty);
    });

    test('a Sequence parameter typed as a supertype still works', () {
      // `collect` takes a `Collector<T, R>`, and Dart checks that parameter
      // against the *reified* T — so a `Sequence<String>` reaching a
      // `Sequence<Object?>` parameter threw at runtime from code that
      // compiled. Every widening site in the library goes through
      // `.cast()` first, which is a `Transformer<Never, R>` and passes.
      expect(_howMany(['a', 'b'].seq), 2);
      expect(
        format.csv.cells(
          [
            ['x'],
          ].seq,
        ),
        'x\n',
      );
    });
  });
}

int _howMany(Sequence<Object?> items) =>
    items.transform(.cast<Object?>()).collect(.count());

/// A crawl that follows nothing, for the pin that `Handler` is gone.
Sequence<Fetch> _noNext(Reply res) => const Sequence<Fetch>([]);

/// A transport that takes its time, for watching what a run leaves behind
/// while it is still going.
Send _slow(Duration pause) => (fetch) async {
  await Future<void>.delayed(pause);
  return Reply.text('<h1>hi</h1>', fetch: fetch);
};

/// A transformer that supplies only `run`, the way one written before 5.4.0
/// would — the default `pour` is what carries it onto a flow.
final class _Doubled extends Transformer<int, int> {
  _Doubled() : super(_twice);

  static Iterable<int> _twice(Iterable<int> items) => items.map((n) => n * 2);
}

/// An in-memory transport, so a crawl in this file never reaches a socket.
///
/// A closure over a map, and a counter it captures — which is what
/// `MapDownloader` was an exported class for.
Send _pages(Map<String, String> bodies, {void Function()? tick}) =>
    (fetch) async {
      tick?.call();
      final body = bodies['${fetch.url}'] ?? bodies[fetch.url.path];
      return Reply.text(
        body ?? '404',
        fetch: fetch,
        status: body == null ? 404 : 200,
      );
    };
