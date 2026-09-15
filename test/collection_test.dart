import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Collections', () {
    test('chunk and window', () {
      final items = [1, 2, 3, 4, 5];
      expect(
        items.chunk(2).toList(),
        equals([
          [1, 2],
          [3, 4],
          [5],
        ]),
      );
      expect(
        items.window(3).toList(),
        equals([
          [1, 2, 3],
          [2, 3, 4],
          [3, 4, 5],
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

    test('sum, average, maxByOrNull, minByOrNull', () {
      final items = [10, 20, 30];
      expect(items.sum(), equals(60));
      expect(items.average(), equals(20.0));
      expect(items.maxByOrNull((x) => x), equals(30));
      expect(items.minByOrNull((x) => x), equals(10));
    });

    test('Collections static helper', () {
      expect(
        Collections.flatten([
          [1, 2],
          [3, 4],
        ]),
        equals([1, 2, 3, 4]),
      );
      expect(
        Collections.interleave([
          [1, 2],
          [3, 4],
        ]).toList(),
        equals([1, 3, 2, 4]),
      );
    });
  });
}
