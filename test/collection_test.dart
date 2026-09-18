import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Collections', () {
    test('chunk', () {
      final items = [1, 2, 3, 4, 5];
      expect(
        items.chunk(2).toList(),
        equals([
          [1, 2],
          [3, 4],
          [5],
        ]),
      );
    });

    test('zip and unzip', () {
      final a = [1, 2, 3];
      final b = ['a', 'b', 'c'];
      final zipped = a.zip(b).toList();
      expect(zipped, equals([(1, 'a'), (2, 'b'), (3, 'c')]));

      final (unA, unB) = zipped.unzip;
      expect(unA, equals(a));
      expect(unB, equals(b));
    });

    test('groupBy, countBy, distinctBy', () {
      final words = ['apple', 'apricot', 'banana', 'avocado'];
      expect(
        words.groupBy((w) => w[0]),
        equals({
          'a': ['apple', 'apricot', 'avocado'],
          'b': ['banana'],
        }),
      );
      expect(words.countBy((w) => w[0]), equals({'a': 3, 'b': 1}));
      expect(words.distinctBy((w) => w[0]).toList(), equals(['apple', 'banana']));
    });

    test('sorted, sortedBy, sortedByDescending', () {
      final nums = [3, 1, 4, 2];
      expect(nums.sorted(), equals([1, 2, 3, 4]));
      expect(nums, equals([3, 1, 4, 2])); // non-mutating

      final words = ['banana', 'apple', 'pie'];
      expect(words.sortedBy((w) => w.length), equals(['pie', 'apple', 'banana']));
      expect(words.sortedBy((String w) => w.length, descending: true), equals(['banana', 'apple', 'pie']));
    });

    test('sum, average, maxBy, minBy', () {
      final items = [10, 20, 30];
      expect(items.sum(), equals(60));
      expect(items.average(), equals(20.0));
      expect(items.maxBy((x) => x), equals(30));
      expect(items.minBy((x) => x), equals(10));
    });

    test('List elementAtOrNull and shuffled', () {
      final list = ['alpha', 'beta'];
      expect(list.elementAtOrNull(0), equals('alpha'));
      expect(list.elementAtOrNull(5), isNull);
      // The SDK member rejects a negative index rather than returning null,
      // which the deleted `getOrNull` accepted.
      expect(() => list.elementAtOrNull(-1), throwsRangeError);
      expect(list.shuffled().length, equals(2));
    });

    test('Map mergeWith', () {
      final m1 = {'a': 1, 'b': 2};
      final m2 = {'b': 3, 'c': 4};
      final merged = m1.mergeWith(m2, (v1, v2) => v1 + v2);
      expect(merged, equals({'a': 1, 'b': 5, 'c': 4}));
    });
  });

  group('collection', () {
    test('partition and indexBy', () {
      final (even, odd) = [1, 2, 3, 4, 5].partition((n) => n.isEven);
      expect(even, [2, 4]);
      expect(odd, [1, 3, 5]);
      expect(['aa', 'b', 'cc'].indexBy((s) => s.length), {2: 'cc', 1: 'b'});
    });

    test('distinct, windowed, takeLast, skipLast, none, flattened', () {
      expect([3, 1, 3, 2, 1].distinct, [3, 1, 2]);
      expect([1, 2, 3, 4].windowed(2).toList(), [
        [1, 2],
        [2, 3],
        [3, 4],
      ]);
      expect([1, 2, 3, 4, 5].windowed(2, step: 2).toList(), [
        [1, 2],
        [3, 4],
      ]);
      expect([1, 2, 3, 4, 5].windowed(2, step: 2, partial: true).toList(), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect([1, 2, 3, 4].takeLast(2), [3, 4]);
      expect([1, 2, 3, 4].skipLast(3), [1]);
      expect([1, 2].takeLast(5), [1, 2]);
      expect([1, 3].none((n) => n.isEven), isTrue);
      expect(
        [
          [1],
          [2, 3],
          <int>[],
        ].flattened.toList(),
        [1, 2, 3],
      );
    });

    test('records, toMap, where, mapValues, mapKeys, inverted', () {
      final m = {'a': 1, 'b': 2, 'c': 3};
      expect(m.records.toList(), [('a', 1), ('b', 2), ('c', 3)]);
      expect(m.records.toMap(), m);
      expect(m.where((k, v) => v.isOdd), {'a': 1, 'c': 3});
      expect(m.mapValues((v) => v * 10), {'a': 10, 'b': 20, 'c': 30});
      expect(m.mapKeys((k) => k.toUpperCase()), {'A': 1, 'B': 2, 'C': 3});
      expect(m.inverted, {1: 'a', 2: 'b', 3: 'c'});
      for (final (k, v) in m.records) {
        expect(m[k], v);
      }
    });

    test('a query chain reads as one sentence', () {
      final tracks = [(disc: 1, n: 2, s: 300), (disc: 1, n: 1, s: 200), (disc: 2, n: 1, s: 100)];
      final byDisc = tracks.groupBy((t) => t.disc).mapValues((ts) => ts.sortedBy((t) => t.n).map((t) => t.n).toList());
      expect(byDisc, {
        1: [1, 2],
        2: [1],
      });
      expect(tracks.groupBy((t) => t.disc).mapValues((ts) => ts.sum((t) => t.s)), {1: 500, 2: 100});
    });
  });
}
