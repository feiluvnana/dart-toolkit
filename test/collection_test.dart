import 'dart:io';

import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/formats.dart';
import 'package:test/test.dart';

void main() {
  group('Sequence', () {
    final words = ['apple', 'apricot', 'banana', 'avocado'];

    test('is an Iterable that keeps the chain lazy and typed', () {
      var pulled = 0;
      final s = [1, 2, 3, 4, 5, 6].sequence
          .map((n) {
            pulled++;
            return n * 2;
          })
          .where((n) => n > 4)
          .take(2);
      expect(s, isA<Iterable<int>>());
      expect(pulled, 0);
      expect(s.toList(), [6, 8]);
      expect(pulled, 4);
      expect([for (final n in s) n], [6, 8]);
      expect(s.sequence, same(s));
    });

    test('shape: distinct, chunk, windowed, pairwise, zip, cartesian, interleave, scan, takeLast, skipLast', () {
      expect([3, 1, 3, 2, 1].sequence.distinct.toList(), [3, 1, 2]);
      expect(words.sequence.distinctBy((w) => w[0]).toList(), ['apple', 'banana']);
      expect([1, 2, 3, 4, 5].sequence.chunk(2).toList(), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect([1, 2, 3, 4].sequence.windowed(2).toList(), [
        [1, 2],
        [2, 3],
        [3, 4],
      ]);
      expect([1, 2, 3, 4, 5].sequence.windowed(2, step: 2, partial: true).toList(), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect([1, 2, 3].sequence.pairwise.toList(), [(1, 2), (2, 3)]);
      expect([1, 2, 3].sequence.zip(['a', 'b']).toList(), [(1, 'a'), (2, 'b')]);
      expect([1, 2].sequence.cartesian(['a', 'b']).toList(), [(1, 'a'), (1, 'b'), (2, 'a'), (2, 'b')]);
      expect([1, 3, 5].sequence.interleave([2, 4]).toList(), [1, 2, 3, 4, 5]);
      expect([1, 2, 3].sequence.scan(0, (a, b) => a + b).toList(), [1, 3, 6]);
      expect([1, 2, 3, 4].sequence.takeLast(2).toList(), [3, 4]);
      expect([1, 2, 3, 4].sequence.skipLast(3).toList(), [1]);
      expect([1, 2, 3].sequence.reversed.toList(), [3, 2, 1]);
      expect([1, 2, 3].sequence.whereNot((n) => n.isEven).toList(), [1, 3]);
      expect(
        [
          [1],
          [2, 3],
        ].sequence.flattened.toList(),
        [1, 2, 3],
      );
      expect(Sequence.range(3).toList(), [0, 1, 2]);
      expect(Sequence.range(2, 8, 3).toList(), [2, 5]);
    });

    test('sortedBy … thenBy equals a compound comparator, and is stable', () {
      final pairs = [(1, 'b'), (2, 'a'), (1, 'a'), (2, 'b'), (1, 'a')];
      expect(pairs.sequence.sortedBy((p) => p.$1).thenBy((p) => p.$2).toList(), [
        (1, 'a'),
        (1, 'a'),
        (1, 'b'),
        (2, 'a'),
        (2, 'b'),
      ]);
      expect(pairs.sequence.sortedBy((p) => p.$1, descending: true).thenBy((p) => p.$2, descending: true).first, (
        2,
        'b',
      ));
      expect(words.sequence.sorted.first, 'apple');
      expect([3, 1, 2].sequence.sortedDescending.toList(), [3, 2, 1]);
      expect([3, 1, 2].sequence.max, 3);
      expect(<int>[].sequence.min, isNull);
      expect(words.sequence.sortedBy((w) => w.length).thenWith((a, b) => b.compareTo(a)).toList(), [
        'apple',
        'banana',
        'avocado',
        'apricot',
      ]);
      final random = [for (var i = 0; i < 2000; i++) (i * 7919 % 13, i * 104729 % 17, i)];
      final a = random.sequence.sortedBy((r) => r.$1).thenBy((r) => r.$2, descending: true).toList();
      final b = random.toList()
        ..sort(
          (x, y) => x.$1 != y.$1
              ? x.$1.compareTo(y.$1)
              : x.$2 != y.$2
              ? y.$2.compareTo(x.$2)
              : x.$3.compareTo(y.$3),
        );
      expect(a, b);
    });

    test('sets keep the left order', () {
      expect([1, 2, 3].sequence.union([3, 4, 1]).toList(), [1, 2, 3, 4]);
      expect([1, 2, 3, 2].sequence.intersect([2, 3, 9]).toList(), [2, 3]);
      expect([1, 2, 3].sequence.except([2]).toList(), [1, 3]);
    });

    test('joins index the right side once', () {
      final songs = [(href: '/1', title: 'One'), (href: '/2', title: 'Two'), (href: '/3', title: 'Three')];
      final pages = [(href: '/1', size: 10), (href: '/2', size: 20), (href: '/2', size: 21)];
      expect(
        songs.sequence
            .innerJoin(pages, on: (s) => s.href, to: (p) => p.href, (s, p) => '${s.title}:${p.size}')
            .toList(),
        ['One:10', 'Two:20', 'Two:21'],
      );
      expect(
        songs.sequence
            .leftJoin(pages, on: (s) => s.href, to: (p) => p.href, (s, p) => '${s.title}:${p?.size}')
            .toList(),
        ['One:10', 'Two:20', 'Two:21', 'Three:null'],
      );
      expect(songs.sequence.groupJoin(pages, on: (s) => s.href, to: (p) => p.href, (s, ps) => ps.length).toList(), [
        1,
        2,
        0,
      ]);
    });

    test('groupBy, countBy, indexBy, partition, numbers', () {
      expect(words.sequence.groupBy((w) => w[0]).toMap(), {
        'a': ['apple', 'apricot', 'avocado'],
        'b': ['banana'],
      });
      expect(words.sequence.countBy((w) => w[0]).toMap(), {'a': 3, 'b': 1});
      expect(
        words.sequence.groupBy((w) => w[0]).mapValues((g) => g.length).sortedByValue(descending: true).keys.first,
        'a',
      );
      expect(['aa', 'b', 'cc'].sequence.indexBy((s) => s.length), {2: 'cc', 1: 'b'});
      final (even, odd) = [1, 2, 3, 4, 5].sequence.partition((n) => n.isEven);
      expect(even, [2, 4]);
      expect(odd, [1, 3, 5]);
      expect([10, 20, 30].sequence.sum, 60);
      expect([1.5, 2.5].sequence.sum, 4.0);
      expect(words.sequence.sumBy((w) => w.length), 25);
      expect([10, 20, 30].sequence.average, 20.0);
      expect(words.sequence.averageBy((w) => w.length), 6.25);
      expect(<int>[].sequence.average, isNull);
      expect(words.sequence.maxBy((w) => w.length), 'apricot');
      expect(words.sequence.minBy((w) => w.length), 'apple');
      expect([3, 9, 1].sequence.minMax((n) => n), (1, 9));
      expect([1, 3].sequence.none((n) => n.isEven), isTrue);
    });

    test('a Map is a Sequence of records and comes back as a Map', () {
      final m = {'a': 1, 'b': 2, 'c': 3};
      expect(m.sequence.toList(), [('a', 1), ('b', 2), ('c', 3)]);
      expect(m.sequence.where((p) => p.$2.isOdd).toMap(), {'a': 1, 'c': 3});
      expect(m.sequence.mapValues((v) => v * 10).toMap(), {'a': 10, 'b': 20, 'c': 30});
      expect(m.sequence.mapKeys((k) => k.toUpperCase()).toMap(), {'A': 1, 'B': 2, 'C': 3});
      expect(m.sequence.inverted.toMap(), {1: 'a', 2: 'b', 3: 'c'});
      expect(m.sequence.followedBy({'b': 5}.sequence).toMap((a, b) => a + b), {'a': 1, 'b': 7, 'c': 3});
      expect(m.sequence.sortedByValue(descending: true).keys.toList(), ['c', 'b', 'a']);
      final (ks, vs) = m.sequence.unzip;
      expect(ks, ['a', 'b', 'c']);
      expect(vs, [1, 2, 3]);
      for (final (k, v) in m.sequence) {
        expect(m[k], v);
      }
    });
  });

  group('Table', () {
    final t = Table.rows([
      {'disc': 1, 'n': 2, 'title': 'B', 'size': '1,200'},
      {'disc': 1, 'n': 1, 'title': 'A', 'size': 800},
      {'disc': 2, 'n': 1, 'title': 'C', 'size': 9.5},
    ]);

    test('columns, rows, typed reads', () {
      expect(t.columns, ['disc', 'n', 'title', 'size']);
      expect(t.length, 3);
      expect(t.rows[0].number('size'), 1200);
      expect(t.rows[0].get<int>('size'), 1200);
      expect(t.rows[0].numberOrNull('title'), isNull);
      expect(() => t.rows[0].number('title'), throwsStateError);
      expect(() => t['nope'], throwsArgumentError);
      expect(() => t.orderBy('nope'), throwsArgumentError);
      expect(t.numbers('size'), [1200, 800, 9.5]);
      expect(t.texts('title'), ['B', 'A', 'C']);
      expect(t.rows[2].text('title'), 'C');
      expect(t['n'], [2, 1, 1]);
      expect(Table.records([1, 2], (n) => {'n': n, 'sq': n * n})['sq'], [1, 4]);
    });

    test('where, orderBy … thenBy, select, rename, derive, drop, distinct, take', () {
      expect(t.where((r) => r['disc'] == 1)['title'], ['B', 'A']);
      expect(t.orderBy('disc').thenBy('n')['title'], ['A', 'B', 'C']);
      expect(t.orderBy('size', descending: true)['title'], ['B', 'A', 'C']); // '1,200' reads as 1200
      expect(t.select(['title', 'n']).columns, ['title', 'n']);
      expect(t.rename({'n': 'track'}).columns, ['disc', 'track', 'title', 'size']);
      expect(t.derive('kb', (r) => r.number('size') / 1000)['kb'], [1.2, 0.8, 0.0095]);
      expect(t.drop(['size', 'title']).columns, ['disc', 'n']);
      expect(t.distinct(['disc']).length, 2);
      expect(t.take(1).length, 1);
      expect(t.skip(2).length, 1);
    });

    test('groupBy folds, pivot, join', () {
      expect(t.groupBy('disc').count().rows, [
        {'disc': 1, 'count': 2},
        {'disc': 2, 'count': 1},
      ]);
      expect(t.groupBy('disc').sum('size')['size'], [2000, 9.5]);
      expect(t.groupBy('disc').agg({'size': Agg.max, 'title': Agg.list}).rows.first, {
        'disc': 1,
        'size': '1,200',
        'title': ['B', 'A'],
      });
      expect(t.groupBy('disc').aggWith({'first': (rows) => rows.first['title']})['first'], ['B', 'C']);
      final p = t.pivot(rows: 'disc', column: 'title', value: 'size');
      expect(p.columns, ['disc', 'B', 'A', 'C']);
      expect(p.rows.first, {'disc': 1, 'B': 1200, 'A': 800, 'C': 0});
      final formats = Table.rows([
        {'disc': 1, 'format': 'flac'},
        {'disc': 3, 'format': 'mp3'},
      ]);
      expect(t.join(formats, on: 'disc')['format'], ['flac', 'flac']);
      expect(t.leftJoin(formats, on: 'disc')['format'], ['flac', 'flac', null]);
      final clash = Table.rows([
        {'disc': 2, 'title': 'other'},
      ]);
      expect(t.join(clash, on: 'disc').columns, ['disc', 'n', 'title', 'size', 'title_2']);
    });

    test('CSV round trip with quotes and newlines; JSON; HTML; save', () async {
      const csv = 'name,note\n"Smith, J","said ""hi""\nthen left"\nLee,\n';
      final parsed = Table.csv(csv);
      expect(parsed.columns, ['name', 'note']);
      expect(parsed.rows, [
        {'name': 'Smith, J', 'note': 'said "hi"\nthen left'},
        {'name': 'Lee', 'note': ''},
      ]);
      expect(Table.csv(parsed.toCsv()).rows, parsed.rows);
      expect(t.toCsv().split('\n').first, 'disc,n,title,size');

      final json = '[{"a": 1, "b": "x"}, {"a": 2}]'.json;
      expect(json.table.columns, ['a', 'b']);
      expect(json.table.rows, [
        {'a': 1, 'b': 'x'},
        {'a': 2},
      ]);
      expect('{"items": [{"a": 1}]}'.json.$(r'$.items[*]').table.length, 1);

      final html =
          '<table><tr><th>Title</th><th>Size</th></tr><tr><td>A</td><td>10</td></tr><tr><td>B</td><td>20</td></tr></table>'
              .html;
      expect(html.$('table').table.columns, ['Title', 'Size']);
      expect(html.$('table').table.orderBy('Size', descending: true)['Title'], ['B', 'A']);
      expect('<table><tr><td>x</td><td>y</td></tr></table>'.html.$('table').table.columns, ['c1', 'c2']);

      final dir = Directory.systemTemp.createTempSync('tbl_');
      try {
        await t.saveCsv('${dir.path}/out.csv');
        expect(Table.csv(File('${dir.path}/out.csv').readAsStringSync()).length, 3);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('Table immutability and input validation', () {
    test('a table cannot be edited through its rows', () {
      final t = Table(
        ['x'],
        [
          {'x': 1},
        ],
      );
      expect(() => t.rows.first['x'] = 99, throwsUnsupportedError);
      expect(t['x'].first, 1);
    });

    test('rows stay frozen through the operations that build new ones', () {
      final t = Table(
        ['x'],
        [
          {'x': 1},
        ],
      );
      for (final derived in [
        t.select(['x']),
        t.derive('y', (r) => 2),
        t.rename({'x': 'z'}),
      ]) {
        expect(() => derived.rows.first[derived.columns.first] = 0, throwsUnsupportedError);
      }
    });

    test('a separator longer than one character is refused, not silently truncated', () {
      expect(() => Table.csv('a||b\n1||2\n', separator: '||'), throwsArgumentError);
      expect(
        () => Table(
          ['a'],
          [
            {'a': 1},
          ],
        ).toCsv(separator: '||'),
        throwsArgumentError,
      );
      expect(Table.csv('a;b\n1;2\n', separator: ';').columns, ['a', 'b']);
    });
  });
}
