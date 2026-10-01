import 'dart:io';

import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/core.dart';
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
      expect(Table.rows([1, 2].map((n) => {'n': n, 'sq': n * n}))['sq'], [1, 4]);
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
        await t.save('${dir.path}/out.csv');
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

  group('sorting extracts each key once', () {
    test('sortedBy and thenBy call the selector once per element, not per comparison', () {
      final items = [for (var i = 0; i < 500; i++) 'item-${(i * 7) % 500}'];
      var primary = 0;
      var secondary = 0;
      final sorted = items.sequence
          .sortedBy((e) {
            primary++;
            return e.length;
          })
          .thenBy((e) {
            secondary++;
            return e;
          })
          .toList();

      expect(primary, items.length, reason: 'one extraction per element');
      expect(secondary, items.length);
      expect(
        sorted,
        equals(
          [...items]..sort((a, b) {
            final byLength = a.length.compareTo(b.length);
            return byLength != 0 ? byLength : a.compareTo(b);
          }),
        ),
      );
    });

    test('equal keys keep their original order', () {
      final pairs = [(1, 'a'), (0, 'b'), (1, 'c'), (0, 'd'), (1, 'e')];
      expect(pairs.sequence.sortedBy((p) => p.$1).map((p) => p.$2).toList(), ['b', 'd', 'a', 'c', 'e']);
    });

    test('descending, sortedWith and the pair sorts agree with the eager equivalents', () {
      final nums = [5, 1, 4, 1, 3];
      expect(nums.sequence.sortedBy((n) => n, descending: true).toList(), [5, 4, 3, 1, 1]);
      expect(nums.sequence.sortedWith((a, b) => b.compareTo(a)).toList(), [5, 4, 3, 1, 1]);
      final m = {'b': 2, 'a': 3, 'c': 1};
      expect(m.sequence.sortedByKey().keys.toList(), ['a', 'b', 'c']);
      expect(m.sequence.sortedByValue(descending: true).keys.toList(), ['a', 'b', 'c']);
    });
  });

  group('Table reads a column once', () {
    test('a column is validated once per call, and an unknown one still throws', () {
      final t = Table(
        ['n', 'name'],
        [
          for (var i = 0; i < 50; i++) {'n': '$i', 'name': 'row$i'},
        ],
      );
      expect(t.texts('name').length, 50);
      expect(t.numbers('n').last, 49);
      expect(t['name'].first, 'row0');
      expect(() => t.texts('nope'), throwsArgumentError);
      expect(() => t['nope'], throwsArgumentError);
      expect(() => t.numbers('nope'), throwsArgumentError);
    });

    test('orderBy and thenBy sort by the same rule as before, numbers as numbers', () {
      final t = Table(
        ['size', 'name'],
        [
          {'size': '1,200', 'name': 'b'},
          {'size': '900', 'name': 'a'},
          {'size': '1,200', 'name': 'a'},
          {'size': null, 'name': 'z'},
        ],
      );
      expect(t.orderBy('size').texts('name'), ['a', 'b', 'a', 'z'], reason: 'null last');
      expect(t.orderBy('size').thenBy('name').texts('name'), ['a', 'a', 'b', 'z']);
      expect(t.orderBy('size', descending: true).texts('size'), ['1,200', '1,200', '900', '']);
      expect(t.orderBy('size', descending: true).texts('name').last, 'z', reason: 'null last either way');
    });
  });

  group('audit regressions', () {
    test('a stray quote is a character, not the start of the rest of the file', () {
      final t = Table.csv('size,name\n5" floppy,disk\n3,tape\n4,reel\n');
      expect(t.length, 3);
      expect(t.texts('size'), ['5" floppy', '3', '4']);
      expect(Table.csv('a,b\n"x"y,z\n').rows.single, {'a': 'xy', 'b': 'z'});
    });

    test('a byte-order mark is not part of the first column', () {
      final t = Table.csv('﻿id,name\r\n1,a\r\n');
      expect(t.columns, ['id', 'name']);
      expect(t['id'], ['1']);
    });

    test('CSV rows read like the maps they replaced', () {
      // A repeated header is `a_2`, not a column lost: keyed by name, the first `a` was gone.
      final t = Table.csv('a,b,a\n1,2,3\n4\n\n5,6,7,8\n');
      expect(t.columns, ['a', 'b', 'a_2']);
      expect(t.rows.map((r) => Map.of(r)).toList(), [
        {'a': '1', 'b': '2', 'a_2': '3'},
        {'a': '4', 'b': null, 'a_2': null},
        {'a': '5', 'b': '6', 'a_2': '7'},
      ]);
      expect(() => t.rows.first['a'] = 'x', throwsUnsupportedError);
      expect(t.where((r) => r['b'] == '6').derive('c', (r) => 1).rows.single, {'a': '5', 'b': '6', 'a_2': '7', 'c': 1});
    });

    test('a comma is a thousands separator only where it groups thousands', () {
      final t = Table.csv('v\n"1,200"\n"1,5"\n"12,345.5"\n');
      expect(t.rows.map((r) => r.numberOrNull('v')).toList(), [1200, null, 12345.5]);
    });

    test('Table.read and readRows open a file by its extension, streaming across chunks', () async {
      final dir = Directory.systemTemp.createTempSync('table_');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Long enough for many reads, with quoted newlines and doubled quotes to split mid-record.
      final lines = ['id,note', for (var i = 0; i < 5000; i++) '$i,"line $i\nsays ""hi"", ${'x' * (i % 97)}"'];
      final csv = File('${dir.path}/t.csv')..writeAsStringSync('﻿${lines.join('\r\n')}\r\n');
      final table = await Table.read(csv.path);
      expect(table.length, 5000);
      expect(table.rows[42]['note'], 'line 42\nsays "hi", ${'x' * 42}');
      final streamed = await Table.readRows(csv.path).toList();
      expect(streamed.map(Map.of).toList(), table.rows.map(Map.of).toList());

      File('${dir.path}/t.tsv').writeAsStringSync('a\tb\n1\t2\n');
      expect((await Table.read('${dir.path}/t.tsv')).rows.single, {'a': '1', 'b': '2'});
      File('${dir.path}/t.ndjson').writeAsStringSync('{"a":1}\n\n{"a":2}\n');
      expect((await Table.read('${dir.path}/t.ndjson'))['a'], [1, 2]);
      expect(await Table.readRows('${dir.path}/t.ndjson').map((r) => r['a']).toList(), [1, 2]);
      File('${dir.path}/t.json').writeAsStringSync('[{"a":1},{"a":2}]');
      expect((await Table.read('${dir.path}/t.json'))['a'], [1, 2]);
    });

    test('a sorted sequence reads its source when it is read, as every other step does', () {
      final list = [3, 1, 2];
      final sorted = list.sequence.sortedBy((x) => x);
      expect(sorted.toList(), [1, 2, 3]);
      list.add(0);
      expect(sorted.toList(), [0, 1, 2, 3]);
      expect(sorted.where((x) => x > 0).toList(), [1, 2, 3]);
    });

    test('windowed does not hold its source, so an endless one works', () {
      expect(Sequence.range(1 << 40).windowed(3, step: 2).take(2).toList(), [
        [0, 1, 2],
        [2, 3, 4],
      ]);
      expect([1, 2, 3, 4, 5, 6, 7].sequence.windowed(2, step: 3, partial: true).toList(), [
        [1, 2],
        [4, 5],
        [7],
      ]);
    });

    test('a sum of nums that are ints is an int', () {
      expect(<num>[1, 2].sequence.sum, isA<int>());
      expect(<num>[1, 2.5].sequence.sum, 3.5);
      expect(<double>[].sequence.sum, isA<double>());
      expect(<int>[].sequence.sum, 0);
    });
  });

  group('CSV and Table, the second audit', () {
    test('a quote never closed is a FormatException naming its line', () {
      expect(
        () => Table.csv('a,b\n1,"open\n2,3\n'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('line 2'))),
      );
    });

    test('readRows fails on an unclosed quote too, and a huge quoted cell streams', () async {
      final dir = Directory.systemTemp.createTempSync('csv_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bad = File('${dir.path}/bad.csv')..writeAsStringSync('a\n"never closed\n');
      await expectLater(Table.readRows(bad.path).toList(), throwsA(isA<FormatException>()));

      // One cell of 8 MB spans ~128 chunks; rescanning it on every chunk was quadratic.
      final big = File('${dir.path}/big.csv')..writeAsStringSync('a,b\n"${'x' * (8 << 20)}",1\n2,3\n');
      final rows = await Table.readRows(big.path).toList();
      expect(rows.map((r) => r['b']), ['1', '3']);
      expect((rows.first['a']! as String).length, 8 << 20);
    });

    test('a blank line is no record, before the header or after; "" is a row', () {
      final t = Table.csv('\n\nname\n""\nx\n\n');
      expect(t.columns, ['name']);
      expect(t['name'], ['', 'x']);
    });

    test('a one-column table of empty cells survives toCsv and back', () {
      final t = Table.cells(
        ['v'],
        [
          [''],
          [null],
          ['x'],
        ],
      );
      final back = Table.csv(t.toCsv());
      expect(back.length, 3);
      expect(back['v'], ['', '', 'x']);
    });

    test('duplicate headers are suffixed, and the table writes back without losing a column', () {
      final t = Table.csv('id,id,id\n1,2,3\n');
      expect(t.columns, ['id', 'id_2', 'id_3']);
      expect(Table.csv(t.toCsv()).rows.single, {'id': '1', 'id_2': '2', 'id_3': '3'});
    });

    test('show prints a missing cell blank, not null', () {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);
      Table(
        ['a', 'b'],
        [
          {'a': 1},
        ],
      ).show();
      expect(out.toString(), isNot(contains('null')));
    });

    test('select names a column that is not there', () {
      final t = Table.rows([
        {'name': 'a'},
      ]);
      expect(() => t.select(['nmae']), throwsArgumentError);
    });

    test('numbers are decimal: 0x10, NaN and Infinity are not', () {
      final t = Table.csv('v\n0x10\nNaN\nInfinity\n1e3\n-2.5\n');
      expect(t.rows.map((r) => r.numberOrNull('v')).toList(), [null, null, null, 1000, -2.5]);
      expect(() => t.numbers('v'), throwsStateError);
    });

    test('orderBy(…).take(n) is the first n of the full sort, stable, nulls last', () {
      final t = Table.rows([
        for (var i = 0; i < 1000; i++) {'k': i % 37 == 0 ? null : (i * 7919) % 101, 'i': i},
      ]);
      for (final desc in [false, true]) {
        final full = t.orderBy('k', descending: desc).thenBy('i').rows;
        expect(t.orderBy('k', descending: desc).thenBy('i').take(10).rows, full.take(10).toList());
        expect(t.orderBy('k', descending: desc).take(5).rows, t.orderBy('k', descending: desc).rows.take(5).toList());
      }
      expect(t.orderBy('k').take(0).rows, isEmpty);
    });

    test('Table.save writes the format its extension names, and Table.read reads it back', () async {
      final dir = Directory.systemTemp.createTempSync('save_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = Table.rows([
        {'a': 1, 'b': 'x'},
        {'a': 2, 'b': 'y'},
      ]);
      for (final ext in ['csv', 'tsv', 'json', 'ndjson']) {
        final path = '${dir.path}/t.$ext';
        await t.save(path);
        final back = await Table.read(path);
        expect(back.columns, ['a', 'b'], reason: ext);
        expect(back.texts('b'), ['x', 'y'], reason: ext);
      }
      await t.save('${dir.path}/t.md');
      expect(File('${dir.path}/t.md').readAsStringSync(), startsWith('| a | b |'));
    });
  });

  group('Sorted pays only for what it is asked', () {
    test('take(n) and first equal the full sort; length does not sort', () {
      expect([5, 3, 9, 1, 7, 2, 8, 4, 6, 0].sequence.sorted.take(3).toList(), [0, 1, 2]);
      expect([5, 3, 9, 1, 7, 2, 8, 4, 6, 0].sequence.sortedBy((e) => e).take(3).toList(), [0, 1, 2]);
      var extracted = 0;
      final items = [for (var i = 0; i < 5000; i++) (i * 7919) % 1009];
      final sorted = items.sequence.sortedBy((e) {
        extracted++;
        return e;
      });
      expect(sorted.length, 5000);
      expect(sorted.isEmpty, isFalse);
      expect(extracted, 0, reason: 'length and isEmpty need no order');
      final full = sorted.toList();
      expect(sorted.take(10).toList(), full.take(10).toList());
      expect(sorted.first, full.first);
      expect(items.sequence.sortedBy((e) => e, descending: true).take(3).toList(), full.reversed.take(3).toList());
      expect(<int>[].sequence.sorted.take(3).toList(), isEmpty);
      expect(() => <int>[].sequence.sorted.first, throwsStateError);
    });

    test('it still reads the source afresh each time', () {
      final source = [3, 1, 2];
      final sorted = source.sequence.sorted;
      expect(sorted.first, 1);
      source.add(0);
      expect(sorted.first, 0);
      expect(sorted.length, 4);
    });
  });
}
