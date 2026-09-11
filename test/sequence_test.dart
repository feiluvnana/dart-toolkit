import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/html.dart';
import 'package:test/test.dart';

typedef Row = ({String host, int score, num cost});

Row _row(String host, int score, num cost) =>
    (host: host, score: score, cost: cost);

void main() {
  final rows = [
    _row('a.com', 3, 1.5),
    _row('b.com', 9, 4.0),
    _row('a.com', 5, 2.5),
    _row('c.com', 1, 0.5),
  ].seq;

  group('Sequence shaping', () {
    test('map, map.nonnull and nonnull replace map and mapNotNull', () {
      expect(
        [1, 2, 3].seq.transform(.map((n) => n * 2)).collect(.list()),
        equals([2, 4, 6]),
      );
      expect(
        [
          '1',
          'x',
          '3',
        ].seq.transform(.map.nonnull(int.tryParse)).collect(.list()),
        equals([1, 3]),
      );
      expect(<int?>[1, null, 3].seq.nonnull.collect(.list()), equals([1, 3]));
    });

    test('where is both sides, because ! works on a filter', () {
      expect(
        [1, 2, 3, 4].seq.transform(.where((n) => n.isEven)).collect(.list()),
        equals([2, 4]),
      );
      // `omit` existed because `keep` was not a filter's ordinary name and
      // `!keep(t)` read as nonsense. Rule 4's ! test applies now.
      expect(
        [1, 2, 3, 4].seq.transform(.where((n) => !n.isEven)).collect(.list()),
        equals([1, 3]),
      );
    });

    test('where.type filters by type', () {
      expect(
        <Object>[1, 'a', 2].seq.transform(.where.type<int>()).collect(.list()),
        equals([1, 2]),
      );
    });

    test('flat flattens and flat.map expands', () {
      expect(
        [1, 2].seq.transform(.flat.map((n) => [n, n * 10])).collect(.list()),
        equals([1, 10, 2, 20]),
      );
      expect(
        [
          [1, 2],
          [3],
        ].seq.transform(.flat<int>()).collect(.list()),
        equals([1, 2, 3]),
      );
      expect(
        () => [1].seq.transform(.flat<int>()).collect(.list()),
        throwsStateError,
      );
    });

    test('unique and unique.by keep the first of each', () {
      expect(
        [1, 2, 1, 3].seq.transform(.unique()).collect(.list()),
        equals([1, 2, 3]),
      );
      expect(
        rows
            .transform(.unique.by((r) => r.host))
            .transform(.map((r) => r.host))
            .collect(.list()),
        equals(['a.com', 'b.com', 'c.com']),
      );
    });

    test(
      'sort never mutates the source, and sort.using takes a comparator',
      () {
        final source = [3, 1, 2];
        expect(source.seq.collect(.sort()).collect(.list()), equals([1, 2, 3]));
        expect(source, equals([3, 1, 2]), reason: 'sort must copy');
        expect(
          rows.collect(.sort.by((r) => r.score)).collect(.first())?.score,
          equals(1),
        );
        expect(
          [
            3,
            1,
            2,
          ].seq.collect(.sort.using((a, b) => b.compareTo(a))).collect(.list()),
          equals([3, 2, 1]),
        );
      },
    );

    test('take, skip and flip read as opposites', () {
      final n = [1, 2, 3, 4, 5].seq;
      expect(n.transform(.take.first(2)).collect(.list()), equals([1, 2]));
      expect(n.collect(.take.last(2)).collect(.list()), equals([4, 5]));
      expect(n.transform(.skip.first(3)).collect(.list()), equals([4, 5]));
      expect(n.collect(.skip.last(3)).collect(.list()), equals([1, 2]));
      expect(n.collect(.flip()).collect(.list()), equals([5, 4, 3, 2, 1]));
      expect(n.transform(.take.first(0)).collect(.list()), isEmpty);
      expect(
        n.collect(.take.last(99)).collect(.list()),
        equals([1, 2, 3, 4, 5]),
      );
      expect(n.collect(.skip.last(99)).collect(.list()), isEmpty);
    });

    test('take.when and skip.when split on a predicate', () {
      final n = [1, 2, 3, 1].seq;
      expect(
        n.transform(.take.when((v) => v < 3)).collect(.list()),
        equals([1, 2]),
      );
      expect(
        n.transform(.skip.when((v) => v < 3)).collect(.list()),
        equals([3, 1]),
      );
    });

    test('chunk batches, with the last one short', () {
      expect(
        [1, 2, 3, 4, 5].seq
            .transform(.chunk(2))
            .transform(.map((c) => c.collect(.list())))
            .collect(.list()),
        equals([
          [1, 2],
          [3, 4],
          [5],
        ]),
      );
      expect([1].seq.transform(.chunk(0)).collect(.list()), isEmpty);
    });

    test('zip and unzip go through records', () {
      final zipped = [1, 2, 3].seq.transform(.zip(['a', 'b'].seq));
      expect(zipped.collect(.list()), equals([(1, 'a'), (2, 'b')]));
      final (numbers, letters) = zipped.unzip;
      expect(numbers.collect(.list()), equals([1, 2]));
      expect(letters.collect(.list()), equals(['a', 'b']));
    });

    test('enumerate carries the index', () {
      expect(
        ['a', 'b'].seq
            .transform(.enumerate())
            .transform(.map((p) => '${p.$1}${p.$2}'))
            .collect(.list()),
        equals(['0a', '1b']),
      );
    });

    // A sequence is a recipe, not a result: nothing is walked until a
    // terminal call asks, and a second terminal call asks again. This was a
    // snapshot in 5.1.0 — the constructor copied, every step copied, and the
    // three reads below cost three walks rather than seven. What that cost
    // was every source walked in full, however little of it was wanted.
    test('a shaping callback does not run until the sequence is walked', () {
      var calls = 0;
      final shaped = [1, 2, 3].seq.transform(
        .map((n) {
          calls++;
          return n * 2;
        }),
      );
      expect(calls, isZero, reason: 'built, not walked');

      expect(shaped.collect(.list()), equals([2, 4, 6]));
      expect(calls, equals(3));
    });

    test('every terminal call walks again', () {
      var calls = 0;
      final shaped = [1, 2, 3].seq.transform(
        .where((n) {
          calls++;
          return true;
        }),
      );

      shaped.collect(.count());
      shaped.collect(.list());
      shaped.collect(.first());
      expect(calls, equals(7), reason: 'three, three, and one that stops');
    });

    test('a sequence follows its source', () {
      final source = [1, 2, 3];
      final held = source.seq;
      source.add(4);
      expect(held.collect(.count()), equals(4));
      expect(held.collect(.list()), equals([1, 2, 3, 4]));
    });

    test('the empty sequence is a const', () {
      expect(const Sequence<int>([]).collect(.empty()), isTrue);
      expect(const Sequence<int>([]).collect(.count()), isZero);
    });

    test('plus, minus, common and or', () {
      final a = [1, 2, 3].seq;
      final b = [3, 4].seq;
      expect(a.transform(.plus(b)).collect(.list()), equals([1, 2, 3, 3, 4]));
      expect(a.transform(.minus(b)).collect(.list()), equals([1, 2]));
      expect(
        a.transform(.plus(b)).transform(.unique()).collect(.list()),
        equals([1, 2, 3, 4]),
      );
      expect(a.transform(.common(b)).collect(.list()), equals([3]));
      expect(
        const Sequence<int>([]).transform(.or(b)).collect(.list()),
        equals([3, 4]),
      );
      expect(a.transform(.or(b)).collect(.list()), equals([1, 2, 3]));
    });

    // What laziness buys, pinned: a walk goes no further than the reader
    // does, so `take.first(2)` after a `map` over eleven elements maps three
    // of them and stops.
    test('a walk stops where the reader stops', () {
      var calls = 0;
      final head = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].seq
          .transform(
            .map((n) {
              calls++;
              return n;
            }),
          )
          .transform(.where((n) => n.isOdd))
          .transform(.take.first(2));
      expect(calls, isZero, reason: 'nothing walked yet');
      expect(head.collect(.list()), equals([1, 3]));
      expect(calls, equals(3), reason: 'as far as the second odd one, no more');
    });

    // A step that reads its other side eagerly — zip, plus, minus, common —
    // still does not run until the walk does.
    test('an eager step is still deferred to the walk', () {
      var walked = 0;
      final other = [9, 8, 7].seq.transform(
        .map((n) {
          walked++;
          return n;
        }),
      );
      final zipped = [1, 2, 3].seq.transform(.zip(other));
      expect(walked, isZero);
      expect(zipped.collect(.count()), equals(3));
      expect(walked, equals(3));
    });
  });

  group('Sequence reducing', () {
    test('count, empty and has', () {
      expect(rows.collect(.count()), equals(4));
      expect(rows.collect(.count.where((r) => r.host == 'a.com')), equals(2));
      expect(const Sequence<int>([]).collect(.empty()), isTrue);
      expect([1].seq.collect(.empty()), isFalse);
      expect([1, 2].seq.collect(.has(2)), isTrue);
      expect([1, 2].seq.collect(.has(9)), isFalse);
    });

    test('the five readers are nullable rather than throwing', () {
      final empty = const Sequence<int>([]);
      expect(empty.collect(.first()), isNull);
      expect(empty.collect(.last()), isNull);
      expect(empty.collect(.single()), isNull);
      expect(empty.collect(.at(0)), isNull);
      expect(empty.collect(.first.where((n) => true)), isNull);
      expect(
        [1, 2].seq.collect(.single()),
        isNull,
        reason: 'two is not exactly one',
      );
      expect([7].seq.collect(.single()), equals(7));
      expect([1, 2, 3].seq.collect(.at(1)), equals(2));
      expect([1, 2, 3].seq.collect(.at(-1)), isNull);
      expect(
        [1, 2, 3].seq.collect(.at(9)) ?? 0,
        isZero,
        reason: '?? replaces getOrElse',
      );
    });

    test('first.where and index.where', () {
      final n = [1, 2, 3, 4].seq;
      expect(n.collect(.first.where((v) => v.isEven)), equals(2));
      // `findlast` was `flip.find` under a second name.
      expect(
        n.collect(.flip()).collect(.first.where((v) => v.isEven)),
        equals(4),
      );
      expect(n.collect(.index.where((v) => v.isEven)), equals(1));
      expect(n.collect(.index.where((v) => v > 99)), isNull);
    });

    test('any and all, with no none', () {
      expect([1, 2].seq.collect(.any((n) => n.isEven)), isTrue);
      expect([1, 3].seq.collect(.any((n) => n.isEven)), isFalse);
      expect([2, 4].seq.collect(.all((n) => n.isEven)), isTrue);
      expect(const Sequence<int>([]).collect(.all((n) => false)), isTrue);
    });

    test('fold, sum and avg', () {
      expect([1, 2, 3].seq.collect(.fold(0, (t, n) => t + n)), equals(6));
      expect(rows.collect(.sum((r) => r.cost)), equals(8.5));
      expect(rows.collect(.avg((r) => r.score)), closeTo(4.5, 1e-9));
      expect(const Sequence<int>([]).collect(.avg((n) => n)), isNull);
      expect(const Sequence<int>([]).collect(.sum((n) => n)), isZero);
      expect(
        [1, 2].seq.collect(.sum((n) => n)),
        equals(3),
        reason: 'selector required',
      );
    });

    test('max.by and min.by', () {
      expect(rows.collect(.max.by((r) => r.score))?.score, equals(9));
      expect(rows.collect(.min.by((r) => r.score))?.score, equals(1));
      expect(const Sequence<Row>([]).collect(.max.by((r) => r.score)), isNull);
    });

    test('group, associate, count.by and split', () {
      final byHost = rows.collect(.group.by((r) => r.host));
      expect(byHost.keys.collect(.list()), equals(['a.com', 'b.com', 'c.com']));
      expect(byHost.get('a.com')!.collect(.count()), equals(2));

      final Dictionary<String, Row> latest = rows.collect(
        .associate.by((r) => r.host),
      );
      expect(latest.get('a.com')?.score, equals(5), reason: 'last wins');
      expect(
        rows
            .transform(.map((r) => (r.host, r.score)))
            .collect(.dict())
            .get('b.com'),
        equals(9),
      );

      expect(
        rows.collect(.count.by((r) => r.host)).map,
        equals({'a.com': 2, 'b.com': 1, 'c.com': 1}),
      );

      final (high, low) = rows.collect(.split((r) => r.score >= 5));
      expect(high.collect(.count()), equals(2));
      expect(low.collect(.count()), equals(2));
    });

    test('group.into reduces every bucket in the same pass', () {
      expect(
        rows.collect(.group.into((r) => r.host, .sum((r) => r.cost))).map,
        equals({'a.com': 4.0, 'b.com': 4.0, 'c.com': 0.5}),
      );
      expect(
        rows
            .collect(.group.into((r) => r.host, .max.by((r) => r.score)))
            .get('a.com')
            ?.score,
        equals(5),
      );
      // count.by is this, in one line, and is what a script actually writes.
      expect(
        rows.collect(.group.into((r) => r.host, .count())).map,
        equals(rows.collect(.count.by((r) => r.host)).map),
      );
    });

    test('join is a summary printer', () {
      final n = [1, 2, 3, 4].seq;
      expect(n.collect(.join(', ')), equals('1, 2, 3, 4'));
      expect(
        n.collect(.join(', ', prefix: '[', suffix: ']', limit: 2)),
        equals('[1, 2, …]'),
      );
      expect(n.collect(.join('-', of: (v) => 'x$v')), equals('x1-x2-x3-x4'));
    });

    test('foreach replaces for-in, list and set convert', () {
      final seen = <int>[];
      [1, 2].seq.collect(.foreach(seen.add));
      expect(seen, equals([1, 2]));
      expect([1, 2, 2].seq.collect(.list()), equals([1, 2, 2]));
      expect([1, 2, 2].seq.collect(.set()), equals({1, 2}));
    });

    test('cast views the elements as another type', () {
      expect(
        <Object>[1, 2].seq.transform(.cast<int>()).collect(.list()),
        equals([1, 2]),
      );
    });
  });

  group('Sequence entry points', () {
    test('.seq brings an iterable in and .dict brings a map in', () {
      expect([1, 2].seq, isA<Sequence<int>>());
      expect({'a': 1}.dict.pairs.collect(.list()), equals([('a', 1)]));
    });

    test('the daily-report shape is one expression', () {
      final spend = rows
          .collect(.group.into((r) => r.host, .sum((r) => r.cost)))
          .pairs
          .transform(.map((e) => (host: e.$1, spend: e.$2)))
          .collect(.sort.by((e) => e.host));
      expect(
        spend.transform(.map((e) => e.host)).collect(.list()),
        equals(['a.com', 'b.com', 'c.com']),
      );
      expect(spend.collect(.first())?.spend, equals(4.0));
    });

    test('toString stays short for a long sequence', () {
      expect([1, 2, 3, 4, 5].seq.toString(), contains('…'));
    });
  });

  group('the flip', () {
    test('the library hands back sequences, not lists', () {
      expect(util.text.words('one two'), isA<Sequence<String>>());
      expect(util.text.numbers('1 2'), isA<Sequence<num>>());
      expect(util.text.betweens('[a][b]', '[', ']'), isA<Sequence<String>>());
      expect(net.sitemap('https://example.com/a'), isA<Sequence<Uri>>());
      expect(util.rand.shuffle([1, 2]), isA<Sequence<int>>());
      expect(util.rand.some([1, 2], 1), isA<Sequence<int>>());
      expect(net.robots('User-agent: *').agents, isA<Sequence<String>>());
    });

    test('a Markup holds a Sequence rather than being an Iterable', () {
      final page = $('<ul><li>a</li><li>b</li></ul>');
      expect(page.find('li').count, equals(2));
      expect(page.find('li').empty, isFalse);
      expect(page.find('x').empty, isTrue);
      expect(page.find('li').elements.collect(.count()), equals(2));
      expect(
        page
            .find('li')
            .elements
            .transform(.map((e) => e.text))
            .collect(.list()),
        equals(['a', 'b']),
      );
    });
  });

  group('operations as values', () {
    test('then joins two transformers into one', () {
      final cleanup = Transformer.where<Row>((r) => r.score > 1)
          .then(Transformer.unique.by((r) => r.host))
          .into(Collector.sort.by((r) => r.host));

      // One definition, two uses — the thing a method chain cannot offer.
      expect(
        rows.collect(cleanup).transform(.map((r) => r.host)).collect(.list()),
        equals(['a.com', 'b.com']),
      );
      expect(rows.collect(cleanup).collect(.count()), equals(2));
    });

    test('into gives a transformer an ending, making it a collector', () {
      final hosts = Transformer.map<Row, String>(
        (r) => r.host,
      ).into(Collector.list());

      expect(hosts, isA<Collector<Row, List<String>>>());
      expect(rows.collect(hosts), equals(['a.com', 'b.com', 'a.com', 'c.com']));
    });

    test('Collector.then finishes a named collector', () {
      final Collector<Row, String> summary = Collector.count<Row>().then(
        (n) => '$n rows',
      );
      expect(rows.collect(summary), equals('4 rows'));
    });

    test(
      'an operation runs against a plain list, with no Sequence in sight',
      () {
        expect(
          Transformer.map<int, String>((n) => 'n$n').run(const [1, 2]).toList(),
          equals(['n1', 'n2']),
        );
        expect(Collector.count<int>().run(const [1, 2, 3]), equals(3));
      },
    );

    test('a result type from anywhere but a lambda gets named', () {
      // Documented in both class doc comments: `fold` takes R from a value and
      // `then` changes it, so neither can be inferred through a shorthand.
      final int viaContext = rows.collect(.fold(0, (t, r) => t + r.score));
      final viaArguments = rows.collect(
        .fold<Row, int>(0, (t, r) => t + r.score),
      );

      expect(viaContext, equals(18));
      expect(viaArguments, equals(18));
    });

    test('fn is the door in a closed set', () {
      expect(
        [
          3,
          1,
          2,
        ].seq.transform(.fn((xs) => xs.toList()..sort())).collect(.list()),
        equals([1, 2, 3]),
      );
      expect([1, 2, 3].seq.collect(.fn((xs) => xs.length * 10)), equals(30));
    });

    test('a subclass composes with the built-ins on equal footing', () {
      expect(
        rows.transform(Dearer(2)).transform(.take.first(1)).collect(.list()),
        equals([_row('b.com', 9, 4.0)]),
      );
      expect(
        rows
            .collect(Dearer(2).into(Collector.sort.by((r) => r.cost)))
            .collect(.list()),
        equals([_row('a.com', 5, 2.5), _row('b.com', 9, 4.0)]),
      );
    });

    test('a caller can be handed an operation it knows nothing about', () {
      int howMany(Sequence<Row> source, Transformer<Row, Row> shape) =>
          source.transform(shape).collect(.count());

      expect(howMany(rows, Transformer.take.first(2)), equals(2));
      expect(howMany(rows, Dearer(2)), equals(2));
    });
  });

  group('Flow', () {
    test('the same two doors a sequence has', () async {
      final flow = [
        1,
        2,
        3,
        4,
      ].flow.transform(.where((n) => n.isEven)).transform(.map((n) => n * 10));

      expect(flow, isA<Flow<int>>());
      expect(await flow.collect(.list()), equals([20, 40]));
    });

    test('collect gives a Future where a sequence gives the value', () async {
      expect([1, 2, 3].flow.collect(.count()), isA<Future<int>>());
      expect(await [1, 2, 3].flow.collect(.count()), equals(3));
      expect(await [1, 2, 3].flow.collect(.first()), equals(1));
      expect(await <int>[].flow.collect(.first()), isNull);
      expect(await Flow<int>.empty().collect(.count()), isZero);
    });

    test('.flow is the seam, from all three sides', () async {
      expect([1, 2].flow, isA<Flow<int>>());
      expect([1, 2].seq.flow, isA<Flow<int>>());
      expect(Stream<int>.fromIterable([1, 2]).flow, isA<Flow<int>>());
      expect(await [1, 2].seq.flow.collect(.list()), equals([1, 2]));
    });

    test('a sequence crosses to a flow and back', () async {
      final held = await rows.flow
          .transform(.where((r) => r.cost > 1))
          .collect(.seq());

      expect(held, isA<Sequence<Row>>());
      expect(held.collect(.count()), equals(3));
      expect(await held.flow.collect(.count()), equals(3));
    });

    test('.seq stays lazy at the seam', () async {
      var walked = 0;
      final source = [1, 2, 3].seq.transform(
        .map((n) {
          walked++;
          return n;
        }),
      );

      final flow = source.flow.transform(.take.first(1));
      expect(walked, isZero, reason: 'nothing walked at the seam');
      expect(await flow.collect(.list()), equals([1]));
      expect(walked, equals(1));
    });

    test('stream is the one word at the boundary, and the way back', () async {
      final out = await [
        1,
        2,
        3,
      ].flow.stream.where((n) => n.isOdd).flow.collect(.list());

      expect(out, equals([1, 3]));
    });

    test('an error in the source comes out of the collect', () {
      expect(
        Stream<int>.error(StateError('bad')).flow.collect(.list()),
        throwsStateError,
      );
    });

    test('every named collector answers the same on both', () async {
      final n = [3, 1, 4, 1, 5];
      Future<void> same<R>(String name, Collector<int, R> step) async {
        expect(
          await n.flow.collect(step),
          equals(n.seq.collect(step)),
          reason: name,
        );
      }

      await same('count', Collector.count<int>());
      await same('count.where', Collector.count.where((int v) => v.isOdd));
      await same('empty', Collector.empty<int>());
      await same('has', Collector.has(4));
      await same('any', Collector.any((int v) => v > 4));
      await same('all', Collector.all((int v) => v > 0));
      await same('first', Collector.first<int>());
      await same('last', Collector.last<int>());
      await same('single.where', Collector.single.where((int v) => v == 4));
      await same('at', Collector.at<int>(2));
      await same('index.of', Collector.index.of(1));
      await same('max.by', Collector.max.by((int v) => v));
      await same('min.by', Collector.min.by((int v) => v));
      await same('fold', Collector.fold<int, int>(0, (t, v) => t + v));
      await same('sum', Collector.sum((int v) => v));
      await same('avg', Collector.avg((int v) => v));
      await same('join', Collector.join<int>(', ', limit: 3));
      await same('list', Collector.list<int>());
      await same('set', Collector.set<int>());
      await same('foreach', Collector.foreach((int _) {}));

      // The ones whose result is a collection compare through their contents.
      expect(
        (await n.flow.collect(.group.by((v) => v.isEven))).keys.collect(.set()),
        equals(n.seq.collect(.group.by((v) => v.isEven)).keys.collect(.set())),
      );
      expect(
        (await n.flow.collect(.associate.by((v) => v))).map,
        equals(n.seq.collect(.associate.by((v) => v)).map),
      );
      expect(
        (await n.flow.collect(.split((v) => v.isOdd))).$1.collect(.list()),
        equals(n.seq.collect(.split((v) => v.isOdd)).$1.collect(.list())),
      );
      expect(
        (await n.flow.collect(.sort())).collect(.list()),
        equals(n.seq.collect(.sort()).collect(.list())),
      );
    });

    test('a named pipeline runs on a sequence, a flow, or neither', () async {
      final cleanup = Transformer.where<Row>(
        (r) => r.cost > 1,
      ).then(Transformer.unique.by((r) => r.host));

      expect(rows.transform(cleanup).collect(.count()), equals(2));
      expect(await rows.flow.transform(cleanup).collect(.count()), equals(2));
      expect(cleanup.run(rows.collect(.list())).length, equals(2));
      expect(
        await cleanup.pour(Stream.fromIterable(rows.collect(.list()))).length,
        equals(2),
      );
    });

    test('into composes both halves, ending in a collector', () async {
      final top = Transformer.where<Row>(
        (r) => r.cost > 1,
      ).into(Collector.sort.by((r) => r.cost));

      expect(rows.collect(top).collect(.first())?.host, equals('a.com'));
      expect(
        (await rows.flow.collect(top)).collect(.first())?.host,
        equals('a.com'),
      );
    });

    test('then on a collector composes both halves too', () async {
      final summary = Collector.count<int>().then((n) => '$n rows');

      expect([1, 2].seq.collect(summary), equals('2 rows'));
      expect(await [1, 2].flow.collect(summary), equals('2 rows'));
    });

    test('chunk is the bulk shape, a batch at a time', () async {
      final batches = await [
        1,
        2,
        3,
        4,
        5,
      ].flow.transform(.chunk(2)).collect(.list());

      expect(batches.length, equals(3));
      expect(batches.first.collect(.list()), equals([1, 2]));
      expect(batches.last.collect(.list()), equals([5]));
    });

    test('toString does not consume', () {
      final flow = [1, 2].flow;
      expect(flow.toString(), equals('Flow<int>'));
      flow.stream;
      expect(flow.toString(), contains('consumed'));
    });
  });

  group('Dictionary', () {
    test('reading is nullable and has tells absent from null', () {
      final d = Dictionary<String, int?>(const {'a': 1, 'b': null});

      expect(d.get('a'), equals(1));
      expect(d.get('b'), isNull);
      expect(d.get('c'), isNull);
      expect(d.has('b'), isTrue);
      expect(d.has('c'), isFalse);
      expect(d.count, equals(2));
      expect(d.empty, isFalse);
      expect(const Dictionary<String, int>.empty().empty, isTrue);
    });

    test('ensure and update cover the first write and every one after', () {
      final seen = Dictionary<String, int>();

      seen.update('a.com', (n) => (n ?? 0) + 1);
      seen.update('a.com', (n) => (n ?? 0) + 1);
      expect(seen.get('a.com'), equals(2));

      final bucket = Dictionary<String, List<int>>();
      bucket.ensure('a', () => <int>[]).add(1);
      bucket.ensure('a', () => <int>[]).add(2);
      expect(bucket.get('a'), equals([1, 2]));
    });

    test('set, delete, clear and merge', () {
      final d = Dictionary<String, int>(const {'a': 1});
      d.set('b', 2);
      d.merge(Dictionary(const {'b': 3, 'c': 4}));
      expect(d.map, equals({'a': 1, 'b': 3, 'c': 4}));

      d.delete('a');
      expect(d.has('a'), isFalse);
      d.clear();
      expect(d.empty, isTrue);
    });

    test('it is a snapshot: the source cannot change underneath it', () {
      final source = <String, int>{'a': 1};
      final d = source.dict;
      source['b'] = 2;
      expect(d.count, equals(1));
      expect(d.map, isNot(same(source)));
    });

    test('keys, values, pairs and invert cross into the other collection', () {
      final d = Dictionary<String, int>(const {'a': 1, 'b': 2});

      expect(d.keys, isA<Sequence<String>>());
      expect(d.keys.collect(.list()), equals(['a', 'b']));
      expect(d.values.collect(.list()), equals([1, 2]));
      expect(d.pairs.collect(.list()), equals([('a', 1), ('b', 2)]));
      expect(d.invert().map, equals({1: 'a', 2: 'b'}));
    });

    test('transform and collect run the same vocabulary over records', () {
      final d = Dictionary<String, int>(const {'a': 1, 'b': 2, 'c': 3});

      expect(d.collect(.count()), equals(3));
      expect(d.collect(.sum((e) => e.$2)), equals(6));
      expect(
        d.transform(.where((e) => e.$2.isOdd)).map,
        equals({'a': 1, 'c': 3}),
      );
      expect(
        d.transform(.map((e) => (e.$1.toUpperCase(), e.$2 * 2))).map,
        equals({'A': 2, 'B': 4, 'C': 6}),
      );
    });

    test('Collector.dict is the way back in from pairs', () {
      expect(
        rows.transform(.map((r) => (r.host, r.score))).collect(.dict()).map,
        equals({'a.com': 5, 'b.com': 9, 'c.com': 1}),
        reason: 'last record to claim a key wins',
      );
    });

    test('toString stays short for a long dictionary', () {
      expect(
        Dictionary(const {'a': 1, 'b': 2, 'c': 3, 'd': 4, 'e': 5}).toString(),
        contains('…'),
      );
    });
  });

  group('Slotted', () {
    const cursor = Slot<int>('cursor');
    const label = Slot<String>('label');

    test('typed keys read and write on any string-keyed dictionary', () {
      final bag = Dictionary<String, Object?>();

      bag.write(cursor, 120);
      bag.write(label, 'run');

      expect(bag.read(cursor), equals(120));
      expect(bag.read(label), equals('run'));
      expect(bag.holds(cursor), isTrue);

      bag.drop(cursor);
      expect(bag.holds(cursor), isFalse);
      expect(bag.read(cursor), isNull);
    });

    test('a value that is not the shape the slot names reads as null', () {
      final bag = Dictionary<String, Object?>()..write(label, 'dark');
      expect(bag.read(const Slot<int>('label')), isNull);
    });

    test('calling a slot gives the pair a dictionary takes', () {
      final bag = Dictionary<String, Object?>.of([cursor(7), label('x')]);
      expect(bag.read(cursor), equals(7));
      expect(bag.read(label), equals('x'));
    });
  });
}

/// A user-defined transformer, for the subclassing test.
final class Dearer extends Transformer<Row, Row> {
  Dearer(num floor) : super((rows) => rows.where((r) => r.cost > floor));
}
