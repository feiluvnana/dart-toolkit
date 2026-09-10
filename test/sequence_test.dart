import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/html.dart';
import 'package:test/test.dart';

typedef Row = ({String host, int score, num cost});

Row _row(String host, int score, num cost) => (
  host: host,
  score: score,
  cost: cost,
);

void main() {
  final rows =
      [
        _row('a.com', 3, 1.5),
        _row('b.com', 9, 4.0),
        _row('a.com', 5, 2.5),
        _row('c.com', 1, 0.5),
      ].seq;

  group('Sequence shaping', () {
    test('to, sift and nonnull replace map and mapNotNull', () {
      expect([1, 2, 3].seq.to((n) => n * 2).list, equals([2, 4, 6]));
      expect(['1', 'x', '3'].seq.sift(int.tryParse).list, equals([1, 3]));
      expect(<int?>[1, null, 3].seq.nonnull.list, equals([1, 3]));
    });

    test('keep and omit say which side survives', () {
      expect([1, 2, 3, 4].seq.keep((n) => n.isEven).list, equals([2, 4]));
      expect([1, 2, 3, 4].seq.omit((n) => n.isEven).list, equals([1, 3]));
    });

    test('only filters by type', () {
      expect(<Object>[1, 'a', 2].seq.only<int>().list, equals([1, 2]));
    });

    test('flat both flattens and expands', () {
      expect([1, 2].seq.flat((n) => [n, n * 10]).list, equals([1, 10, 2, 20]));
      expect(
        [
          [1, 2],
          [3],
        ].seq.flat<int>().list,
        equals([1, 2, 3]),
      );
      expect(() => [1].seq.flat<int>().list, throwsStateError);
    });

    test('unique keeps the first of each', () {
      expect([1, 2, 1, 3].seq.unique().list, equals([1, 2, 3]));
      expect(
        rows.unique((r) => r.host).to((r) => r.host).list,
        equals(['a.com', 'b.com', 'c.com']),
      );
    });

    test('sort never mutates the source and order takes a comparator', () {
      final source = [3, 1, 2];
      expect(source.seq.sort().list, equals([1, 2, 3]));
      expect(source, equals([3, 1, 2]), reason: 'sort must copy');
      expect(rows.sort((r) => r.score).first?.score, equals(1));
      expect(
        [3, 1, 2].seq.order((a, b) => b.compareTo(a)).list,
        equals([3, 2, 1]),
      );
    });

    test('head, tail, skip, trim and flip', () {
      final n = [1, 2, 3, 4, 5].seq;
      expect(n.head(2).list, equals([1, 2]));
      expect(n.tail(2).list, equals([4, 5]));
      expect(n.skip(3).list, equals([4, 5]));
      expect(n.trim(3).list, equals([1, 2]));
      expect(n.flip.list, equals([5, 4, 3, 2, 1]));
      expect(n.head(0).list, isEmpty);
      expect(n.tail(99).list, equals([1, 2, 3, 4, 5]));
      expect(n.trim(99).list, isEmpty);
    });

    test('until and after split on a predicate', () {
      final n = [1, 2, 3, 1].seq;
      expect(n.until((v) => v < 3).list, equals([1, 2]));
      expect(n.after((v) => v < 3).list, equals([3, 1]));
    });

    test('chunks batches, with the last one short', () {
      expect(
        [1, 2, 3, 4, 5].seq.chunks(2).to((c) => c.list).list,
        equals([
          [1, 2],
          [3, 4],
          [5],
        ]),
      );
      expect([1].seq.chunks(0).list, isEmpty);
    });

    test('windows slides, and windows(2) is zipWithNext', () {
      expect(
        [1, 2, 3, 4].seq.windows(2).to((w) => w.list).list,
        equals([
          [1, 2],
          [2, 3],
          [3, 4],
        ]),
      );
      expect(
        [1, 2, 3, 4, 5].seq.windows(2, step: 2).to((w) => w.list).list,
        equals([
          [1, 2],
          [3, 4],
        ]),
      );
      expect(
        [1, 2, 3].seq.windows(2, step: 2, partial: true).to((w) => w.list).list,
        equals([
          [1, 2],
          [3],
        ]),
      );
    });

    test('zip and unzip go through records', () {
      final zipped = [1, 2, 3].seq.zip(['a', 'b'].seq);
      expect(zipped.list, equals([(1, 'a'), (2, 'b')]));
      final (numbers, letters) = zipped.unzip;
      expect(numbers.list, equals([1, 2]));
      expect(letters.list, equals(['a', 'b']));
    });

    test('pairs carries the index', () {
      expect(
        ['a', 'b'].seq.pairs.to((p) => '${p.$1}${p.$2}').list,
        equals(['0a', '1b']),
      );
    });

    test('scan runs the fold, also peeks without leaving the chain', () {
      expect(
        [1, 2, 3].seq.scan(0, (total, n) => total + n).list,
        equals([0, 1, 3, 6]),
      );
      final seen = <int>[];
      expect([1, 2].seq.also(seen.add).list, equals([1, 2]));
      expect(seen, equals([1, 2]));
    });

    test('plus, minus, union, common and or', () {
      final a = [1, 2, 3].seq;
      final b = [3, 4].seq;
      expect(a.plus(b).list, equals([1, 2, 3, 3, 4]));
      expect(a.minus(b).list, equals([1, 2]));
      expect(a.union(b).list, equals([1, 2, 3, 4]));
      expect(a.common(b).list, equals([3]));
      expect(const Sequence<int>([]).or(b).list, equals([3, 4]));
      expect(a.or(b).list, equals([1, 2, 3]));
    });

    test('shaping is lazy: only what is asked for is computed', () {
      var calls = 0;
      final head = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].seq
          .to((n) {
            calls++;
            return n;
          })
          .keep((n) => n.isOdd)
          .head(2);
      expect(calls, isZero, reason: 'nothing runs until the chain is walked');
      expect(head.list, equals([1, 3]));
      expect(calls, equals(3), reason: 'stops as soon as two survive');
    });
  });

  group('Sequence reducing', () {
    test('count, empty and has', () {
      expect(rows.count(), equals(4));
      expect(rows.count((r) => r.host == 'a.com'), equals(2));
      expect(const Sequence<int>([]).empty, isTrue);
      expect([1].seq.empty, isFalse);
      expect([1, 2].seq.has(2), isTrue);
      expect([1, 2].seq.has(9), isFalse);
    });

    test('the five readers are nullable rather than throwing', () {
      final empty = const Sequence<int>([]);
      expect(empty.first, isNull);
      expect(empty.last, isNull);
      expect(empty.sole, isNull);
      expect(empty.at(0), isNull);
      expect(empty.find((n) => true), isNull);
      expect([1, 2].seq.sole, isNull, reason: 'two is not exactly one');
      expect([7].seq.sole, equals(7));
      expect([1, 2, 3].seq.at(1), equals(2));
      expect([1, 2, 3].seq.at(-1), isNull);
      expect([1, 2, 3].seq.at(9) ?? 0, isZero, reason: '?? replaces getOrElse');
    });

    test('find, findlast and index', () {
      final n = [1, 2, 3, 4].seq;
      expect(n.find((v) => v.isEven), equals(2));
      expect(n.findlast((v) => v.isEven), equals(4));
      expect(n.index((v) => v.isEven), equals(1));
      expect(n.index((v) => v > 99), isNull);
    });

    test('any and all, with no none', () {
      expect([1, 2].seq.any((n) => n.isEven), isTrue);
      expect([1, 3].seq.any((n) => n.isEven), isFalse);
      expect([2, 4].seq.all((n) => n.isEven), isTrue);
      expect(const Sequence<int>([]).all((n) => false), isTrue);
    });

    test('fold, sum and avg', () {
      expect([1, 2, 3].seq.fold(0, (t, n) => t + n), equals(6));
      expect(rows.sum((r) => r.cost), equals(8.5));
      expect(rows.avg((r) => r.score), closeTo(4.5, 1e-9));
      expect(const Sequence<int>([]).avg((n) => n), isNull);
      expect(const Sequence<int>([]).sum((n) => n), isZero);
      expect([1, 2].seq.sum((n) => n), equals(3), reason: 'selector required');
    });

    test('best and worst', () {
      expect(rows.best((r) => r.score)?.score, equals(9));
      expect(rows.worst((r) => r.score)?.score, equals(1));
      expect(const Sequence<Row>([]).best((r) => r.score), isNull);
    });

    test('group, keyed, tally and split', () {
      final byHost = rows.group((r) => r.host);
      expect(byHost.keys.toList(), equals(['a.com', 'b.com', 'c.com']));
      expect(byHost['a.com']!.count(), equals(2));

      final Map<String, Row> latest = rows.keyed((r) => r.host);
      expect(latest['a.com']?.score, equals(5), reason: 'last wins');
      expect(rows.keyed((r) => r.host, (r) => r.score)['b.com'], equals(9));

      expect(
        rows.tally((r) => r.host),
        equals({'a.com': 2, 'b.com': 1, 'c.com': 1}),
      );

      final (high, low) = rows.split((r) => r.score >= 5);
      expect(high.count(), equals(2));
      expect(low.count(), equals(2));
    });

    test('join is a summary printer', () {
      final n = [1, 2, 3, 4].seq;
      expect(n.join(', '), equals('1, 2, 3, 4'));
      expect(
        n.join(', ', prefix: '[', suffix: ']', limit: 2),
        equals('[1, 2, …]'),
      );
      expect(n.join('-', of: (v) => 'x$v'), equals('x1-x2-x3-x4'));
    });

    test('each replaces for-in, list and set convert', () {
      final seen = <int>[];
      [1, 2].seq.each(seen.add);
      expect(seen, equals([1, 2]));
      expect([1, 2, 2].seq.list, equals([1, 2, 2]));
      expect([1, 2, 2].seq.set, equals({1, 2}));
    });

    test('cast views the elements as another type', () {
      expect(<Object>[1, 2].seq.cast<int>().list, equals([1, 2]));
    });
  });

  group('Sequence entry points', () {
    test('.seq brings an iterable in and Map.seq gives records', () {
      expect([1, 2].seq, isA<Sequence<int>>());
      expect({'a': 1}.seq.list, equals([('a', 1)]));
    });

    test('the daily-report shape is one expression', () {
      final spend = rows
          .group((r) => r.host)
          .seq
          .to((e) => (host: e.$1, spend: e.$2.sum((r) => r.cost)))
          .sort((e) => e.host);
      expect(spend.to((e) => e.host).list, equals(['a.com', 'b.com', 'c.com']));
      expect(spend.first?.spend, equals(4.0));
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
      expect(page.find('li').elements.count(), equals(2));
      expect(
        page.find('li').elements.to((e) => e.text).list,
        equals(['a', 'b']),
      );
    });
  });
}
