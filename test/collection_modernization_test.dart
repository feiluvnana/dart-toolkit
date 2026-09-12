import 'dart:async';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Iterables helper', () {
    test('Iterables.of filters out nulls', () {
      expect(Iterables.of(1, null, 2, null, 3).toList(), equals([1, 2, 3]));
    });

    test('Iterables.range produces integer sequences', () {
      expect(Iterables.range(0, 5).toList(), equals([0, 1, 2, 3, 4]));
      expect(Iterables.range(0, 10, 2).toList(), equals([0, 2, 4, 6, 8]));
      expect(Iterables.range(5, 0, -1).toList(), equals([5, 4, 3, 2, 1]));
      expect(() => Iterables.range(0, 5, 0), throwsArgumentError);
    });

    test('Iterables.generate creates elements by index', () {
      expect(Iterables.generate(3, (i) => 'item-$i').toList(), equals([
        'item-0',
        'item-1',
        'item-2',
      ]));
    });

    test('Iterables.iterate generates from seed', () {
      final powers = Iterables.iterate(
        1,
        (n) => n * 2,
        whileCondition: (n) => n <= 16,
      );
      expect(powers.toList(), equals([1, 2, 4, 8, 16]));
    });

    test('Iterables.repeat repeats element', () {
      expect(Iterables.repeat('x', 3).toList(), equals(['x', 'x', 'x']));
    });

    test('Iterables.concat chains iterables', () {
      expect(
        Iterables.concat([
          [1, 2],
          [3, 4],
        ]).toList(),
        equals([1, 2, 3, 4]),
      );
    });

    test('Iterables.zip pairs elements', () {
      expect(
        Iterables.zip([1, 2, 3], ['a', 'b'], (a, b) => '$a$b').toList(),
        equals(['1a', '2b']),
      );
    });

    test('Iterables.interleave interleaves alternatingly', () {
      expect(
        Iterables.interleave([1, 3, 5], [2, 4]).toList(),
        equals([1, 2, 3, 4, 5]),
      );
    });

    test('Iterables.partition splits into matching and non-matching', () {
      final (evens, odds) = Iterables.partition([1, 2, 3, 4, 5], (n) => n.isEven);
      expect(evens, equals([2, 4]));
      expect(odds, equals([1, 3, 5]));
    });

    test('Iterables.cartesian produces Cartesian product', () {
      expect(
        Iterables.cartesian(['a', 'b'], [1, 2]).toList(),
        equals([('a', 1), ('a', 2), ('b', 1), ('b', 2)]),
      );
    });
  });

  group('IterableExtensions', () {
    test('filter and flatMap and mapNotNull', () {
      expect([1, 2, 3, 4].filter((n) => n.isEven).toList(), equals([2, 4]));
      expect(
        ['1', 'x', '3'].mapNotNull(int.tryParse).toList(),
        equals([1, 3]),
      );
      expect(
        [1, 2].flatMap((n) => [n, n * 10]).toList(),
        equals([1, 10, 2, 20]),
      );
    });

    test('sorted, sortedBy, sortedByDescending', () {
      expect([3, 1, 2].sorted(), equals([1, 2, 3]));
      expect([3, 1, 2].sorted((a, b) => b.compareTo(a)), equals([3, 2, 1]));

      final users = [('Bob', 30), ('Alice', 25), ('Charlie', 35)];
      expect(
        users.sortedBy((u) => u.$2).map((u) => u.$1).toList(),
        equals(['Alice', 'Bob', 'Charlie']),
      );
      expect(
        users.sortedByDescending((u) => u.$2).map((u) => u.$1).toList(),
        equals(['Charlie', 'Bob', 'Alice']),
      );
    });

    test('distinct and unique', () {
      expect([1, 2, 1, 3, 2].distinct().toList(), equals([1, 2, 3]));
      expect([1, 2, 1, 3, 2].unique().toList(), equals([1, 2, 3]));

      final words = ['apple', 'apricot', 'banana', 'blueberry'];
      expect(
        words.distinct((w) => w[0]).toList(),
        equals(['apple', 'banana']),
      );
    });

    test('chunk and window', () {
      expect(
        [1, 2, 3, 4, 5].chunk(2).toList(),
        equals([
          [1, 2],
          [3, 4],
          [5],
        ]),
      );
      expect(
        [1, 2, 3, 4].window(2).toList(),
        equals([
          [1, 2],
          [2, 3],
          [3, 4],
        ]),
      );
      expect(
        [1, 2, 3, 4].window(2, step: 2).toList(),
        equals([
          [1, 2],
          [3, 4],
        ]),
      );
    });

    test('zip, concat, intersect, minus, reversed, tap', () {
      expect([1, 2].zip(['a', 'b']).toList(), equals([(1, 'a'), (2, 'b')]));
      expect([1, 2].zipWith(['a', 'b'], (a, b) => '$a$b').toList(), equals(['1a', '2b']));
      expect([1, 2].concat([3, 4]).toList(), equals([1, 2, 3, 4]));
      expect([1, 2, 3].intersect([2, 3, 4]), equals({2, 3}));
      expect([1, 2, 3].minus([2, 4]), equals([1, 3]));
      expect([1, 2, 3].reversed.toList(), equals([3, 2, 1]));

      final tapped = <int>[];
      final result = [1, 2, 3].tap(tapped.add).toList();
      expect(result, equals([1, 2, 3]));
      expect(tapped, equals([1, 2, 3]));
    });

    test('NullableIterableExtensions nonNull and whereNotNull', () {
      final list = <int?>[1, null, 2, null, 3];
      expect(list.nonNull.toList(), equals([1, 2, 3]));
      expect(list.whereNotNull().toList(), equals([1, 2, 3]));
    });

    test('IterableTerminals: count, sum, average, max, min, maxBy, minBy, toMap, associateBy, groupBy', () {
      expect([1, 2, 3, 4].count((n) => n.isEven), equals(2));
      expect([1, 2, 3].sum(), equals(6));
      expect([('a', 10), ('b', 20)].sum((item) => item.$2), equals(30));
      expect([2, 4, 6].average(), equals(4.0));
      expect(<int>[].average(), isNull);
      expect([3, 1, 4, 2].max(), equals(4));
      expect([3, 1, 4, 2].min(), equals(1));
      expect(<int>[].max(), isNull);
      expect(<int>[].min(), isNull);

      final items = [('a', 1), ('b', 9), ('c', 5)];
      expect(items.maxBy((e) => e.$2), equals(('b', 9)));
      expect(items.minBy((e) => e.$2), equals(('a', 1)));

      expect(
        items.toMap(key: (e) => e.$1, value: (e) => e.$2),
        equals({'a': 1, 'b': 9, 'c': 5}),
      );
      expect(
        items.associateBy((e) => e.$1),
        equals({'a': ('a', 1), 'b': ('b', 9), 'c': ('c', 5)}),
      );

      final grouped = [1, 2, 3, 4, 5, 6].groupBy((n) => n % 2 == 0 ? 'even' : 'odd');
      expect(grouped['even'], equals([2, 4, 6]));
      expect(grouped['odd'], equals([1, 3, 5]));
    });
  });

  group('Maps helper & MapExtensions', () {
    test('Maps.fromPairs and Maps.fromIterable', () {
      expect(Maps.fromPairs([('a', 1), ('b', 2)]), equals({'a': 1, 'b': 2}));
      expect(
        Maps.fromIterable([1, 2], key: (n) => 'k$n', value: (n) => n * 10),
        equals({'k1': 10, 'k2': 20}),
      );
    });

    test('Maps.groupBy and Maps.groupByValues', () {
      final words = ['apple', 'apricot', 'banana'];
      expect(
        Maps.groupBy(words, (w) => w[0]),
        equals({
          'a': ['apple', 'apricot'],
          'b': ['banana'],
        }),
      );
      expect(
        Maps.groupByValues(words, keyOf: (w) => w[0], valueOf: (w) => w.length),
        equals({
          'a': [5, 7],
          'b': [6],
        }),
      );
    });

    test('Maps.merge with onConflict', () {
      final merged = Maps.merge(
        [
          {'a': 1, 'b': 2},
          {'b': 20, 'c': 3},
        ],
        onConflict: (existing, incoming) => existing + incoming,
      );
      expect(merged, equals({'a': 1, 'b': 22, 'c': 3}));
    });

    test('Maps.zip and Maps.invert', () {
      expect(Maps.zip(['a', 'b'], [1, 2]), equals({'a': 1, 'b': 2}));
      expect(
        Maps.invert({'a': 1, 'b': 1, 'c': 2}),
        equals({
          1: ['a', 'b'],
          2: ['c'],
        }),
      );
    });

    test('Maps.diff', () {
      final a = {'x': 1, 'y': 2, 'z': 3};
      final b = {'y': 20, 'z': 3, 'w': 4};
      final diff = Maps.diff(a, b);
      expect(diff.hasChanges, isTrue);
      expect(diff.added, equals({'w': 4}));
      expect(diff.removed, equals({'x': 1}));
      expect(diff.changed, equals({'y': (2, 20)}));
      expect(diff.unchanged, equals({'z': 3}));
    });

    test('MapExtensions: filter, filterKeys, filterValues, mapKeys, mapValues', () {
      final map = {'a': 1, 'b': 2, 'c': 3};
      expect(map.filter((k, v) => v.isOdd), equals({'a': 1, 'c': 3}));
      expect(map.filterKeys((k) => k != 'b'), equals({'a': 1, 'c': 3}));
      expect(map.filterValues((v) => v > 1), equals({'b': 2, 'c': 3}));
      expect(map.mapValues((k, v) => v * 10), equals({'a': 10, 'b': 20, 'c': 30}));
      expect(map.mapKeys((k, v) => k.toUpperCase()), equals({'A': 1, 'B': 2, 'C': 3}));
    });

    test('MapExtensions: pick, omit, merge, sortedByKey, sortedByValue, pairs, invert', () {
      final map = {'b': 2, 'a': 3, 'c': 1};
      expect(map.pick(['a', 'b']), equals({'b': 2, 'a': 3}));
      expect(map.omit(['b']), equals({'a': 3, 'c': 1}));
      expect(map.sortedByKey().keys.toList(), equals(['a', 'b', 'c']));
      expect(map.sortedByValue().values.toList(), equals([1, 2, 3]));
      expect(map.pairs.toList(), equals([('b', 2), ('a', 3), ('c', 1)]));
      expect(map.invert(), equals({2: ['b'], 3: ['a'], 1: ['c']}));
    });

    test('SlottedMap on Map<String, Object?>', () {
      const idSlot = Slot<int>('id');
      const nameSlot = Slot<String>('name');

      final data = <String, Object?>{};
      data.write(idSlot, 42);
      data.write(nameSlot, 'Dart');

      expect(data.read(idSlot), equals(42));
      expect(data.read(nameSlot), equals('Dart'));
      expect(data.holds(idSlot), isTrue);

      data.drop(idSlot);
      expect(data.holds(idSlot), isFalse);
      expect(data.read(idSlot), isNull);
    });
  });

  group('Streams helper & StreamExtensions', () {
    test('Streams.generate, Streams.concat, Streams.merge', () async {
      var count = 0;
      final gen = Streams.generate(() async {
        count++;
        return count <= 3 ? count : null;
      });
      expect(await gen.toList(), equals([1, 2, 3]));

      final s1 = Stream.fromIterable([1, 2]);
      final s2 = Stream.fromIterable([3, 4]);
      expect(await Streams.concat([s1, s2]).toList(), equals([1, 2, 3, 4]));

      final m1 = Stream.fromIterable([1, 3]);
      final m2 = Stream.fromIterable([2, 4]);
      final merged = await Streams.merge([m1, m2]).toList();
      expect(merged..sort(), equals([1, 2, 3, 4]));
    });

    test('Streams.combineLatest and Streams.zip', () async {
      final a = StreamController<int>();
      final b = StreamController<String>();

      final combined = Streams.combineLatest(a.stream, b.stream, (x, y) => '$x$y');
      final events = <String>[];
      combined.listen(events.add);

      a.add(1);
      b.add('a');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      a.add(2);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      b.add('b');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, containsAll(['1a', '2a', '2b']));

      final z1 = Stream.fromIterable([1, 2]);
      final z2 = Stream.fromIterable(['x', 'y', 'z']);
      expect(
        await Streams.zip(z1, z2, (x, y) => '$x$y').toList(),
        equals(['1x', '2y']),
      );
    });

    test('Streams.race emits winner', () async {
      final fast = Stream.fromIterable([100]);
      final slow = Stream.periodic(Duration(milliseconds: 50), (_) => 200);
      expect(await Streams.race([fast, slow]).first, equals(100));
    });

    test('StreamExtensions: filter, mapNotNull, flatMap, distinctBy, chunk, recover, tap', () async {
      final s = Stream.fromIterable([1, 2, 3, 4]);
      expect(await s.filter((n) => n.isEven).toList(), equals([2, 4]));

      final s2 = Stream.fromIterable(['1', 'bad', '3']);
      expect(await s2.mapNotNull(int.tryParse).toList(), equals([1, 3]));

      final s3 = Stream.fromIterable([1, 2]);
      expect(
        await s3.flatMap((n) => Stream.fromIterable([n, n * 10])).toList(),
        equals([1, 10, 2, 20]),
      );

      final s4 = Stream.fromIterable([1, 1, 2, 2, 3, 1]);
      expect(await s4.distinctBy().toList(), equals([1, 2, 3, 1]));

      final s5 = Stream.fromIterable([1, 2, 3, 4, 5]);
      expect(
        await s5.chunk(2).toList(),
        equals([
          [1, 2],
          [3, 4],
          [5],
        ]),
      );

      final errStream = Stream<int>.error(Exception('boom')).recover((_) => 999);
      expect(await errStream.first, equals(999));

      final tapped = <int>[];
      await Stream.fromIterable([1, 2]).tap(tapped.add).toList();
      expect(tapped, equals([1, 2]));
    });

    test('NullableStreamExtensions nonNull and whereNotNull', () async {
      final s = Stream<int?>.fromIterable([1, null, 2, null, 3]);
      expect(await s.nonNull.toList(), equals([1, 2, 3]));

      final s2 = Stream<int?>.fromIterable([1, null, 2, null, 3]);
      expect(await s2.whereNotNull().toList(), equals([1, 2, 3]));
    });

    test('StreamTerminals: count, firstOrNull, lastOrNull', () async {
      expect(await Stream.fromIterable([1, 2, 3, 4]).count((n) => n.isEven), equals(2));
      expect(await Stream.fromIterable([1, 2, 3]).firstOrNull, equals(1));
      expect(await Stream<int>.empty().firstOrNull, isNull);
      expect(await Stream.fromIterable([1, 2, 3]).lastOrNull, equals(3));
      expect(await Stream<int>.empty().lastOrNull, isNull);
    });
  });

  group('Modern Naming & Effective Dart checks', () {
    test('Ansi colors use brightRed, bgBlack, bgColor256, bgRgb, bgHex', () {
      expect(Ansi.brightRed, isNotEmpty);
      expect(Ansi.bgBlack, isNotEmpty);
      expect(Ansi.bgColor256(123), contains('123'));
      expect(Ansi.bgRgb(10, 20, 30), contains('10;20;30'));
      expect(Ansi.bgHex('#ffffff'), isNotEmpty);

      final prev = Ansi.enabled;
      addTearDown(() => Ansi.enabled = prev);
      Ansi.enabled = true;

      expect('hello'.brightRed(), contains(Ansi.brightRed));
      expect('hello'.bgBlack(), contains(Ansi.bgBlack));
    });

    test('TableStyle uses topLeft, topRight, etc.', () {
      const style = TableStyle(
        topLeft: '1',
        topRight: '2',
        bottomLeft: '3',
        bottomRight: '4',
        horizontal: '-',
        vertical: '|',
        cross: '+',
        topDivider: '5',
        bottomDivider: '6',
        leftDivider: '7',
        rightDivider: '8',
      );
      expect(style.topLeft, equals('1'));
      expect(style.topRight, equals('2'));
      expect(style.topDivider, equals('5'));
    });

    test('Table.addAll accepts Iterable', () {
      final table = Table(headers: ['Col 1', 'Col 2']);
      table.addAll([
        ['A', 'B'],
        ['C', 'D'],
      ]);
      expect(table.render(), contains('Col 1'));
    });

    test('Morsel httpOnly', () {
      final cookie = Morsel('session', 'abc', httpOnly: true);
      expect(cookie.httpOnly, isTrue);
    });
  });
}
