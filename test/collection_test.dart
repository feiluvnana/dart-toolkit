import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/json.dart';
import 'package:test/test.dart';

import 'support.dart';

Table _csv(String text, {String decimal = '.', String? separator}) =>
    Table.parse(text, TableFormat.csv, decimal: decimal, separator: separator);

/// Every cell of [column] as it is.
List<Object?> _raw(Table t, String column) => [for (final r in t.rows) r[column]];

Matcher _format(Object message) => throwsA(isA<FormatException>().having((e) => e.message, 'message', message));

Matcher _missing(Object message) => throwsA(isA<MissingException>().having((e) => e.message, 'message', message));

/// What [t.show] prints.
Future<String> _shown(Table t, {Border? border, Map<String, Align> align = const {}}) async {
  final out = StringBuffer();
  await Io.scope(
    () => t.show(border: border, align: align),
    stdout: out,
    color: false,
  );
  return '$out';
}

void main() {
  group('Table', () {
    final t = Table.rows([
      {'disc': 1, 'n': 2, 'title': 'B', 'size': '1,200'},
      {'disc': 1, 'n': 1, 'title': 'A', 'size': 800},
      {'disc': 2, 'n': 1, 'title': 'C', 'size': 9.5},
    ]);

    test('Table.cells refuses an empty header rather than dropping its column, and numbers repeats', () {
      expect(
        () => Table.cells(
          ['', ''],
          [
            ['Albums', 348],
          ],
        ),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('Invalid header at 0'))),
      );
      expect(() => Table.cells(['name', ' '], []), throwsArgumentError);
      final repeated = Table.cells(
        ['x', 'x'],
        [
          ['a', 1],
        ],
      );
      expect(repeated.columns, ['x', 'x_2']);
      expect(repeated.rows.single, {'x': 'a', 'x_2': 1});
    });

    test('columns, rows, the one typed reading (COL-5)', () {
      expect(t.columns, ['disc', 'n', 'title', 'size']);
      expect(t.length, 3);
      expect(t.rows[0].get<int>('size'), 1200);
      expect(t.rows[0].get<num>('size'), 1200);
      expect(t.rows[2].get<String>('title'), 'C');
      expect(() => t.rows[0].get<num>('title'), throwsFormatException);
      final blank = Table.rows([
        {'a': 1, 'b': null},
      ]).rows.single;
      expect((() => blank.get<num>('b')).orNull, isNull);
      expect(blank.get('b', or: 0), 0);
      expect(blank.get('b', or: 0), isA<int>());
      expect(blank.get('a', or: 0), 1);
      final Object? wide = blank.get('b', or: 5);
      expect(wide, 5, reason: 'absence is checked before an Object? T accepts the blank cell');
      expect(blank.get<String?>('b'), isNull);
      expect(blank.get('b', or: 'none'), 'none');
      expect(() => blank.get<num>('b'), throwsA(isA<MissingException>()));
      expect(() => t.rows[0].get('title', or: 0), throwsFormatException);
      expect(t.values<num>('size'), [1200, 800, 9.5]);
      expect(t.values<String>('title'), ['B', 'A', 'C']);
      expect(Table.rows([1, 2].map((n) => {'n': n, 'sq': n * n})).values<int>('sq'), [1, 4]);
    });

    test('a missing column is Missing column "x" in the file, from a row and from the table (COL-12)', () async {
      expect(() => t.rows[0].get<String>('titel'), _missing('Missing column "titel"'));
      for (final call in [
        () => t.values<num>('nope'),
        () => t.orderBy('nope'),
        () => t.select(['nmae']),
        () => t.drop(['sise']),
        () => t.rename({'nmae': 'title'}),
        () => t.groupBy(['nope']),
        () => t.groupBy(['disc']).agg({'x': Agg.sum('nope')}),
      ]) {
        expect(call, throwsA(isA<MissingException>()));
      }
      final file = '${tempDir()}/sales.csv';
      File(file).writeAsStringSync('a,b\n1,2\n');
      final read = await Table.read(file);
      expect(() => read.values<int>('x'), _missing('Missing column "x" in $file'));
      expect(() => read.where((r) => true).select(['x']), _missing('Missing column "x" in $file'), reason: 'COL-9');
      expect(() => read.rows.single.get<int>('x'), _missing('Missing column "x" in $file'));
    });

    test('values<T> reads a column typed: a blank is absence, values<T?> keeps it', () {
      final v = Table.cells(
        ['v'],
        [
          [1],
          [null],
          [''],
          ['2'],
        ],
      );
      expect(v.values<num?>('v'), [1, null, null, 2]);
      expect(v.values<num?>('v').nonNulls, [1, 2]);
      expect(() => v.values<num>('v'), throwsA(isA<MissingException>()));
      expect(
        () => Table.cells(
          ['v'],
          [
            ['x'],
          ],
        ).values<num>('v'),
        throwsFormatException,
      );
    });

    test('where, orderBy … thenBy, select, rename, derive, drop, distinct, take, skip', () {
      expect(t.where((r) => r['disc'] == 1).values<String>('title'), ['B', 'A']);
      expect(t.orderBy('disc').thenBy('n').values<String>('title'), ['A', 'B', 'C']);
      expect(t.orderBy('size', descending: true).values<String>('title'), ['B', 'A', 'C']);
      expect(t.select(['title', 'n']).columns, ['title', 'n']);
      expect(t.rename({'n': 'track'}).columns, ['disc', 'track', 'title', 'size']);
      expect(t.derive('kb', (r) => r.get<num>('size') / 1000).values<num>('kb'), [1.2, 0.8, 0.0095]);
      expect(t.derive('n', (r) => '#${r['n']}').columns, ['disc', 'n', 'title', 'size'], reason: 'replaced in place');
      expect(t.drop(['size', 'title']).columns, ['disc', 'n']);
      expect(t.distinct(['disc']).length, 2);
      expect(t.take(1).length, 1);
      expect(t.skip(2).length, 1);
      expect(() => t.skip(-1), throwsRangeError);
    });

    test('Agg folds are numbers: min and max a num, empty input null for all four (COL-2, COL-9)', () {
      for (final csv in ['g,v\na,5\na,\na,3\n', 'g,v\na,\na,5\na,3\n']) {
        final g = _csv(csv).groupBy(['g']);
        expect(g.agg({'v': Agg.max('v')}).values<Object>('v'), [5], reason: 'a blank is never the largest');
        expect(g.agg({'v': Agg.min('v')}).values<Object>('v'), [3]);
      }
      final empty = _csv('g,v\na,\na, \n').groupBy(['g']);
      for (final agg in [Agg.sum('v'), Agg.average('v'), Agg.min('v'), Agg.max('v')]) {
        expect(_raw(empty.agg({'v': agg}), 'v'), [null], reason: '$agg');
      }
      expect(_raw(t.groupBy(['disc']).agg({'top': Agg.max('size')}), 'top'), [1200, 9.5]);
    });

    test('groupBy folds, pivot, join, leftJoin', () {
      expect(t.groupBy(['disc']).agg({'count': Agg.count}).rows, [
        {'disc': 1, 'count': 2},
        {'disc': 2, 'count': 1},
      ]);
      expect(t.groupBy(['disc']).agg({'size': Agg.sum('size')}).values<num>('size'), [2000, 9.5]);
      expect(t.groupBy(['disc']).agg({'size': Agg.max('size'), 'title': Agg.list('title')}).rows.first, {
        'disc': 1,
        'size': 1200,
        'title': ['B', 'A'],
      });
      expect(t.groupBy(['disc']).agg({'first': Agg.of((rows) => rows.first['title'])}).values<String>('first'), [
        'B',
        'C',
      ]);
      expect(t.groupBy(['disc']).agg({'total': Agg.sum('size'), 'biggest': Agg.max('size'), 'n': Agg.count}).columns, [
        'disc',
        'total',
        'biggest',
        'n',
      ]);
      expect(t.groupBy(['disc']).agg({'size': Agg.average('size')}).values<num>('size'), [1000, 9.5]);
      expect(t.pivot(rows: 'disc', column: 'title', value: Agg.of((r) => r.length)).rows.first, {
        'disc': 1,
        'B': 1,
        'A': 1,
        'C': 0,
      });
      final p = t.pivot(rows: 'disc', column: 'title', value: Agg.sum('size'));
      expect(p.columns, ['disc', 'B', 'A', 'C']);
      expect(p.rows.first, {'disc': 1, 'B': 1200, 'A': 800, 'C': null});
      final formats = Table.rows([
        {'disc': 1, 'format': 'flac'},
        {'disc': 3, 'format': 'mp3'},
      ]);
      expect(_raw(t.join(formats, on: 'disc'), 'format'), ['flac', 'flac']);
      expect(_raw(t.leftJoin(formats, on: 'disc'), 'format'), ['flac', 'flac', null]);
      final clash = Table.rows([
        {'disc': 2, 'title': 'other'},
      ]);
      expect(t.join(clash, on: 'disc').columns, ['disc', 'n', 'title', 'size', 'title_2']);
      expect(() => t.groupBy([]), throwsArgumentError);
    });

    test("keys compare by value after coercion: '1' is 1 in join, groupBy, distinct and pivot (COL-4)", () {
      final orders = _csv('user,item\n1,a\n2,b\n1.0,c\n');
      final users = Table.rows([
        {'user': 1, 'name': 'ann'},
        {'user': 2, 'name': 'bob'},
      ]);
      expect(_raw(orders.join(users, on: 'user'), 'name'), ['ann', 'bob', 'ann']);
      expect(orders.groupBy(['user']).agg({'n': Agg.count}).values<int>('n'), [2, 1]);
      expect(orders.distinct(['user']).length, 2);
      final p = orders.pivot(rows: 'user', column: 'item', value: Agg.count);
      expect(p.length, 2);
      final blanks = _csv('k,c,v\nx,,1\nx,a,2\n').pivot(rows: 'k', column: 'c', value: Agg.sum('v'));
      expect(blanks.columns, ['k', '(blank)', 'a'], reason: 'a blank pivot value is still a column with a name');
      expect(
        orders.join(users.rename({'user': 'id'}).rename({'id': 'user'}), on: 'user').length,
        3,
        reason: 'keys named apart: rename one',
      );
    });

    test('the decimal mark read from a file is used by every number operation (COL-1)', () async {
      final eu = _csv('g;v\na;1,5\na;2,25\nb;10\n', decimal: ',');
      expect(eu.values<num>('v'), [1.5, 2.25, 10]);
      expect(eu.groupBy(['g']).agg({'s': Agg.sum('v'), 'm': Agg.max('v'), 'a': Agg.average('v')}).rows.first, {
        'g': 'a',
        's': 3.75,
        'm': 2.25,
        'a': 1.875,
      });
      expect(eu.orderBy('v', descending: true).values<String>('v'), ['10', '2,25', '1,5']);
      expect(eu.render(border: Border.none).split('\n')[1], '  a    1,5', reason: 'right-aligned: they are numbers');
      final file = '${tempDir()}/eu.csv';
      File(file).writeAsStringSync('v\n"1,5"\n"2,5"\n');
      final read = await Table.read(file, decimal: ',');
      expect(read.groupBy(['v']).agg({'s': Agg.sum('v')}).values<num>('s'), [1.5, 2.5]);
      expect(() => _csv('v\n1\n', decimal: ';'), throwsArgumentError);
    });

    test('a JSON array, an HTML table and a CSV make one table; save writes it', () async {
      const csv = 'name,note\n"Smith, J","said ""hi""\nthen left"\nLee,\n';
      final parsed = _csv(csv);
      expect(parsed.columns, ['name', 'note']);
      expect(parsed.rows, [
        {'name': 'Smith, J', 'note': 'said "hi"\nthen left'},
        {'name': 'Lee', 'note': ''},
      ]);
      expect(_csv(parsed.encode(TableFormat.csv)).rows, parsed.rows);
      expect(t.encode(TableFormat.csv).split('\n').first, 'disc,n,title,size');

      final json = '[{"a": 1, "b": "x"}, {"a": 2}]'.json;
      expect(Table.rows(json.rows).columns, ['a', 'b']);
      expect(json.rows, [
        {'a': 1, 'b': 'x'},
        {'a': 2},
      ]);

      final html =
          '<table><tr><th>Title</th><th>Size</th></tr><tr><td>A</td><td>10</td></tr><tr><td>B</td><td>20</td></tr></table>'
              .html;
      expect(Table.rows(html.$('table').first.rows).columns, ['Title', 'Size']);
      expect(Table.rows(html.$('table').first.rows).orderBy('Size', descending: true).values<String>('Title'), [
        'B',
        'A',
      ]);

      final dir = tempDir('tbl_');
      expect(await t.save('$dir/out.csv'), '$dir/out.csv');
      expect((await Table.read('$dir/out.csv')).length, 3);
    });

    test('rename refuses to leave two columns one name, and still swaps', () {
      final t = Table.rows([
        {'a': 1, 'b': 2},
      ]);
      expect(() => t.rename({'a': 'b'}), throwsArgumentError);
      expect(t.rename({'a': 'b', 'b': 'a'}).rows.single, {'b': 1, 'a': 2});
    });

    test('render and show: a missing cell blank, numbers right-aligned unless align says, ⏎ for a break', () async {
      expect(
        await _shown(
          Table(
            ['a', 'b'],
            [
              {'a': 1},
            ],
          ),
        ),
        isNot(contains('null')),
      );
      final t = Table.cells(
        ['name', 'n'],
        [
          ['a', 5],
          ['bb', 120],
        ],
      );
      expect((await _shown(t, border: Border.none)).split('\n')[1], '  a        5');
      expect((await _shown(t, border: Border.none, align: {'n': Align.left})).split('\n')[1], '  a      5');
      final broken = Table.cells(
        ['a', 'b'],
        [
          ['one\ntwo', 1],
          ['three', 2],
        ],
      ).render(border: Border.none);
      expect(broken.split('\n').where((l) => l.trim().isNotEmpty), hasLength(3));
      expect(broken, contains('one⏎two'));
      final wide = Table.cells(
        ['text'],
        [
          ['x' * 100],
        ],
      ).render(width: 20);
      expect(wide.split('\n').every((l) => l.length <= 20), isTrue);
      expect(wide, contains('…'));
      expect(() => t.render(align: {'nope': Align.left}), throwsA(isA<MissingException>()));
    });

    test('orderBy(…).take(n) is the first n of the full sort, stable, nulls last', () {
      final t = Table.rows([
        for (var i = 0; i < 1000; i++) {'k': i % 37 == 0 ? null : (i * 7919) % 101, 'i': i},
      ]);
      for (final desc in [false, true]) {
        final full = t.orderBy('k', descending: desc).thenBy('i').rows;
        expect(t.orderBy('k', descending: desc).thenBy('i').take(10).rows, full.take(10).toList());
      }
      expect(t.orderBy('k').take(0).rows, isEmpty);
      expect(() => t.orderBy('k').take(-1), throwsRangeError);
    });

    test('orderBy compares text naturally, ignoring case; numbers before text; blank cells last', () {
      final names = Table.rows([
        {'name': 'Track 10'},
        {'name': 'track 2'},
        {'name': 'Track 1'},
      ]);
      expect(names.orderBy('name').values<String>('name'), ['Track 1', 'track 2', 'Track 10']);
      final mixed = Table.rows([
        {'val': 'alpha'},
        {'val': 10},
        {'val': 'beta'},
        {'val': 2},
      ]);
      expect(mixed.orderBy('val').values<String>('val'), ['2', '10', 'alpha', 'beta']);
      final blanks = _csv('id,score\n1,10\n2,\n3,5\n4,  \n');
      expect(blanks.orderBy('score').values<String>('id'), ['3', '1', '2', '4']);
      expect(blanks.orderBy('score', descending: true).values<String>('id'), ['1', '3', '2', '4']);
    });

    test('where, select, rename, derive, distinct keep the order a later thenBy refines', () {
      final t = Table.rows([
        {'cat': 'b', 'num': 2, 'name': 'two'},
        {'cat': 'a', 'num': 3, 'name': 'three'},
        {'cat': 'a', 'num': 1, 'name': 'one'},
      ]);
      List<String> names(Table t) => t.values<String>('name');
      expect(names(t.orderBy('cat').thenBy('num')), ['one', 'three', 'two']);
      expect(names(t.orderBy('cat').where((r) => r['num'] != 2).thenBy('num')), ['one', 'three']);
      expect(names(t.orderBy('num').where((r) => r['cat'] == 'a').take(1)), ['one']);
      expect(names(t.orderBy('cat').select(['cat', 'num', 'name']).thenBy('num')), ['one', 'three', 'two']);
      expect(names(t.orderBy('cat').rename({'cat': 'category'}).thenBy('num')), ['one', 'three', 'two']);
      expect(names(t.orderBy('cat').derive('d', (r) => 1).thenBy('num')), ['one', 'three', 'two']);
      expect(names(t.orderBy('cat').distinct().thenBy('num')), ['one', 'three', 'two']);
      final ties = Table.rows([
        {'a': 2, 'b': 1, 'i': 0},
        {'a': 1, 'b': 2, 'i': 1},
        {'a': 1, 'b': 1, 'i': 2},
      ]);
      expect(_raw(ties.orderBy('a').derive('a', (r) => -r.get<int>('i')).thenBy('b'), 'i'), [2, 0, 1]);
      expect(_raw(ties.orderBy('a').drop(['a']).thenBy('b'), 'i'), [2, 0, 1]);
    });

    test('join: a name clash takes a fresh suffix, and a blank key matches nothing', () {
      final t1 = Table.rows([
        {'id': 1, 'x': 'left_x', 'x_2': 'left_x2'},
      ]);
      final t2 = Table.rows([
        {'id': 1, 'x': 'right_x'},
      ]);
      expect(t1.join(t2, on: 'id').rows.single, {'id': 1, 'x': 'left_x', 'x_2': 'left_x2', 'x_3': 'right_x'});
      final a = Table.rows([
        {'id': null, 'a': 1},
        {'id': 2, 'a': 2},
      ]);
      final b = Table.rows([
        {'id': null, 'b': 99},
        {'id': 2, 'b': 20},
      ]);
      expect(a.join(b, on: 'id').rows, [
        {'id': 2, 'a': 2, 'b': 20},
      ]);
      expect(a.leftJoin(b, on: 'id').rows, [
        {'id': null, 'a': 1, 'b': null},
        {'id': 2, 'a': 2, 'b': 20},
      ]);
    });

    test('pivot: a value named like the rows column gets a fresh name', () {
      final p = Table.rows([
        {'k': 'x', 'c': 'k', 'v': 1},
        {'k': 'y', 'c': 'z', 'v': 2},
      ]).pivot(rows: 'k', column: 'c', value: Agg.sum('v'));
      expect(p.columns, ['k', 'k_2', 'z']);
      expect(p.rows.first['k_2'], 1);
    });
  });

  group('immutability and input validation', () {
    test('a table cannot be edited through its rows, nor through what it was built from', () {
      final source = {'x': 1};
      final t = Table(['x'], [source]);
      source['x'] = 2;
      expect(t.rows.single['x'], 1);
      expect(() => t.rows.first['x'] = 99, throwsUnsupportedError);
      for (final derived in [
        t.select(['x']),
        t.derive('y', (r) => 2),
        t.rename({'x': 'z'}),
        t.join(t, on: 'x'),
        t.leftJoin(t.derive('y', (r) => 3), on: 'x'),
        t.groupBy(['x']).agg({'n': Agg.count}),
        t.pivot(rows: 'x', column: 'x', value: Agg.sum('x')),
      ]) {
        expect(() => derived.rows.first[derived.columns.first] = 0, throwsUnsupportedError);
      }
    });

    test('a separator is one character, and only CSV takes one (COL-6)', () {
      expect(() => _csv('a||b\n1||2\n', separator: '||'), throwsArgumentError);
      expect(() => Table.cells(['a'], []).encode(TableFormat.csv, separator: '||'), throwsArgumentError);
      expect(_csv('a;b\n1;2\n', separator: ';').columns, ['a', 'b']);
      expect(() => Table.parse('[]', TableFormat.json, separator: ';'), throwsArgumentError);
      expect(() => Table.cells(['a'], []).save('${tempDir()}/t.json', separator: ';'), throwsArgumentError);
      expect(() => Table.read('x.md', separator: ','), throwsArgumentError);
    });

    test('a CSV row is one object however often it is read (COL-10)', () {
      final t = _csv('a\n1\n2\n');
      expect(identical(t.rows[0], t.rows[0]), isTrue);
    });
  });

  group('formats', () {
    final t = Table.rows([
      {'name': 'a|b', 'n': 1},
      {'name': 'c', 'n': 20},
    ]);

    test('tsv, ndjson, json and markdown encode and parse back (COL-7)', () {
      expect(Table.parse(t.encode(TableFormat.tsv), TableFormat.tsv).rows, [
        {'name': 'a|b', 'n': '1'},
        {'name': 'c', 'n': '20'},
      ]);
      expect(t.encode(TableFormat.ndjson), '{"name":"a|b","n":1}\n{"name":"c","n":20}\n');
      expect(Table.parse(t.encode(TableFormat.ndjson), TableFormat.ndjson).rows, t.rows);
      expect(Table.parse(t.encode(TableFormat.json), TableFormat.json).rows, t.rows);
      expect(t.encode(TableFormat.markdown), '| name | n |\n| --- | ---: |\n| a\\|b | 1 |\n| c | 20 |\n');
      expect(Table.parse(t.encode(TableFormat.markdown), TableFormat.markdown).rows, [
        {'name': 'a|b', 'n': '1'},
        {'name': 'c', 'n': '20'},
      ]);
      expect(() => Table.parse('| a |\n| b |', TableFormat.markdown), _format(contains('line 2')));
    });

    test('JSON and NDJSON refuse what is not an object, naming where (COL-11)', () {
      expect(() => Table.parse('[{"a": 1}, 2]', TableFormat.json), _format(contains('element 1 is a number')));
      expect(() => Table.parse('{"a": 1}', TableFormat.json), _format(contains('not an array of objects')));
      expect(() => Table.parse('{"a": 1}\n\n[1]\n', TableFormat.ndjson), _format(contains('line 3')));
    });

    test('a blank header in the middle gets a name by its place; a trailing one is dropped (COL-11)', () {
      expect(_csv('a,,c,\n1,2,3,\n').columns, ['a', 'c2', 'c']);
    });

    test('Table.read reads by extension; another is CSV; a missing file throws', () async {
      final dir = tempDir();
      File('$dir/a.csv').writeAsStringSync('name,n\nx,1\ny,2\n');
      File('$dir/b.tsv').writeAsStringSync('name\tn\nz\t3\n');
      File('$dir/c.json').writeAsStringSync('[{"name": "w", "n": 4}]');
      File('$dir/d.json').writeAsStringSync('{"not": "a list"}');
      File('$dir/e.txt').writeAsStringSync('a;b\n1;2\n');
      File('$dir/f.md').writeAsStringSync('| a |\n|---|\n| 1 |\n');
      expect((await Table.read('$dir/a.csv')).columns, ['name', 'n']);
      expect((await Table.read('$dir/b.tsv')).rows.single.get<String>('name'), 'z');
      expect((await Table.read('$dir/c.json')).rows.single.get<int>('n'), 4);
      expect((await Table.read('$dir/a.csv', separator: ';')).columns, ['name,n']);
      expect((await Table.read('$dir/e.txt')).columns, ['a', 'b']);
      expect((await Table.read('$dir/f.md')).values<int>('a'), [1]);
      await expectLater(
        Table.read('$dir/d.json'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('Invalid JSON in $dir/d.json'))),
      );
      await expectLater(Table.read('$dir/missing.csv'), throwsA(isA<FileSystemException>()));
    });

    test('a CSV that is not UTF-8 reads as Windows-1252; a UTF-16 one by its mark', () async {
      final dir = tempDir();
      File('$dir/ansi.csv').writeAsBytesSync([...latin1.encode('name\ncaf'), 0xe9, 0x0a]);
      expect((await Table.read('$dir/ansi.csv')).values<String>('name'), ['café']);
      File('$dir/wide.tsv').writeAsBytesSync([
        0xff,
        0xfe,
        for (final u in 'a\tb\n1\t2\n'.codeUnits) ...[u, 0],
      ]);
      expect((await Table.read('$dir/wide.tsv')).rows.single, {'a': '1', 'b': '2'});
    });

    test('save writes the format its extension names, as a Task, and read reads it back', () async {
      final dir = tempDir('save_');
      final t = Table.rows([
        {'a': 1, 'b': 'x'},
        {'a': 2, 'b': 'y'},
      ]);
      for (final ext in ['csv', 'tsv', 'json', 'ndjson', 'md']) {
        final path = await t.save('$dir/t.$ext');
        final back = await Table.read(path);
        expect(back.columns, ['a', 'b'], reason: ext);
        expect(back.values<String>('b'), ['x', 'y'], reason: ext);
      }
      final again = t.save('$dir/t.csv', conflict: Conflict.skip);
      expect(await again.settled, isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse));
      await expectLater(t.save('$dir/t.csv', conflict: Conflict.fail), throwsA(isA<PathExistsException>()));
    });

    test('a DateTime is written in ISO 8601; JSON and NDJSON are written over the columns', () {
      final at = Table.rows([
        {'at': DateTime.utc(2026, 1, 1)},
      ]);
      expect(at.encode(TableFormat.csv), 'at\n2026-01-01T00:00:00.000Z\n');
      expect(at.encode(TableFormat.ndjson), '{"at":"2026-01-01T00:00:00.000Z"}\n');
      expect(at.rows.single.get<String>('at'), '2026-01-01T00:00:00.000Z');
      expect(jsonEncode({'t': at}), '{"t":[{"at":"2026-01-01T00:00:00.000Z"}]}');
      final sparse = Table(
        ['a', 'b'],
        [
          {'a': 1},
        ],
      );
      expect(sparse.encode(TableFormat.ndjson), '{"a":1,"b":null}\n');
    });

    test('save writes through a link and keeps an odd mode', () async {
      final dir = tempDir('tk_save');
      File('$dir/real.csv').writeAsStringSync('');
      Link('$dir/out.csv').createSync('$dir/real.csv');
      final one = Table.cells(
        ['a'],
        [
          [1],
        ],
      );
      await one.save('$dir/out.csv');
      expect(FileSystemEntity.isLinkSync('$dir/out.csv'), isTrue);
      expect(File('$dir/real.csv').readAsStringSync(), contains('1'));
      final secret = File('$dir/secret.csv')..writeAsStringSync('');
      Process.runSync('chmod', ['600', secret.path]);
      await one.save(secret.path);
      expect(secret.statSync().mode & 0x1ff, 0x180);
    }, testOn: '!windows');

    test('markdown escapes a pipe, and shows a newline as ⏎ to keep the row whole', () {
      final header = Table.cells(
        ['a|b', 'c\nd'],
        [
          [1, 2],
        ],
      ).encode(TableFormat.markdown).split('\n').first;
      expect(header, r'| a\|b | c⏎d |');
    });
  });

  group('CSV', () {
    test('TSV has no quoting: a quote is a character, and a tab or line break is not written', () {
      final t = Table.parse('title\tyear\n"Friends" pilot\t1994\n"Weird\t1995\n', TableFormat.tsv);
      expect(_raw(t, 'title'), ['"Friends" pilot', '"Weird']);
      expect(Table.parse(t.encode(TableFormat.tsv), TableFormat.tsv).rows, t.rows);
      expect(
        () => Table(
          ['a'],
          [
            {'a': 'x\ny'},
          ],
        ).encode(TableFormat.tsv),
        _format('Invalid TSV at row 1, column "a": a tab or line break has no TSV form'),
      );
      expect(
        Table(
          ['a'],
          [
            {'a': 'x\ty'},
          ],
        ).encode(TableFormat.csv, separator: '\t'),
        'a\n"x\ty"\n',
        reason: 'CSV quotes',
      );
    });

    test('a quote never closed is a FormatException naming its line', () {
      expect(() => _csv('a,b\n1,"open\n2,3\n'), _format(contains('line 2')));
    });

    test('a blank line is no record, before the header or after; "" is a row', () {
      final t = _csv('\n\nname\n""\nx\n\n');
      expect(t.columns, ['name']);
      expect(_raw(t, 'name'), ['', 'x']);
    });

    test('a one-column table of empty cells survives a round trip', () {
      final t = Table.cells(
        ['v'],
        [
          [''],
          [null],
          ['x'],
        ],
      );
      expect(_raw(_csv(t.encode(TableFormat.csv)), 'v'), ['', '', 'x']);
    });

    test('duplicate headers are suffixed, and write back without losing a column', () {
      final t = _csv('id,id,id\n1,2,3\n');
      expect(t.columns, ['id', 'id_2', 'id_3']);
      expect(_csv(t.encode(TableFormat.csv)).rows.single, {'id': '1', 'id_2': '2', 'id_3': '3'});
    });

    test('a stray quote is a character, not the start of the rest of the file', () {
      final t = _csv('size,name\n5" floppy,disk\n3,tape\n4,reel\n');
      expect(t.values<String>('size'), ['5" floppy', '3', '4']);
      expect(_csv('a,b\n"x"y,z\n').rows.single, {'a': 'xy', 'b': 'z'});
    });

    test('a byte-order mark is not part of the first column', () {
      final t = _csv('\u{FEFF}id,name\r\n1,a\r\n');
      expect(t.columns, ['id', 'name']);
      expect(_raw(t, 'id'), ['1']);
    });

    test('CSV rows read like maps: short rows pad, long ones cut', () {
      final t = _csv('a,b,a\n1,2,3\n4\n\n5,6,7,8\n');
      expect(t.columns, ['a', 'b', 'a_2']);
      expect(t.rows.map((r) => Map.of(r)).toList(), [
        {'a': '1', 'b': '2', 'a_2': '3'},
        {'a': '4', 'b': null, 'a_2': null},
        {'a': '5', 'b': '6', 'a_2': '7'},
      ]);
      expect(() => t.rows.first['a'] = 'x', throwsUnsupportedError);
      expect(t.where((r) => r['b'] == '6').derive('c', (r) => 1).rows.single, {'a': '5', 'b': '6', 'a_2': '7', 'c': 1});
    });

    test('a cell error names the file, its line, the column and the fix (COL-11)', () async {
      final file = '${tempDir()}/sales.csv';
      File(file).writeAsStringSync('Category,Amount\nToys,1\n"Books\nand more","1.234,56"\nPens,\n');
      final rows = (await Table.read(file)).rows;
      expect(
        () => rows[1].get<num>('Amount'),
        _format(
          'Invalid CSV in $file, line 3: "1.234,56" in "Amount", not a num; with decimal: \',\' it reads 1234.56',
        ),
      );
      expect(
        () => rows[1].get<int>('Category'),
        _format(contains('line 3: "Books\nand more" in "Category", not an int')),
      );
      expect(() => rows[2].get<num>('Amount'), _missing('Missing "Amount" on line 5 in $file'));
      expect(() => const Row({'a': 'x'}).get<int>('a'), _format('Invalid value: "x" in "a", not an int'));
      expect(() => _csv('a,b\n1,\n').rows.first.get<num>('b'), _missing('Missing "b" on line 2'));
    });
  });

  group('coercion', () {
    test('numbers: plain text parses first; grouped commas, signs and the rest', () {
      final r = Row({
        'big': '1e400',
        'grouped': '-1,234.5',
        'plus': '+1,000',
        'bad': '1,20',
        'trail': '1,000,',
        'lead': ',100',
        'dot': '1,000.',
        'hex': '-0x1',
        'pad': ' 12 ',
      });
      expect(() => r.get<int>('big'), throwsFormatException);
      expect(r.get<num>('grouped'), -1234.5);
      expect(r.get<int>('plus'), 1000);
      for (final c in ['bad', 'trail', 'lead', 'dot', 'hex']) {
        expect(() => r.get<num>(c), throwsFormatException, reason: c);
        expect(() => (() => r.get<num>(c)).or(0), throwsFormatException, reason: c);
      }
      expect(r.get<int>('pad'), 12);
    });

    test('get<int> refuses a fraction rather than truncate, and a nullable T reads as its base', () {
      final r = Row({'p': '19.99', 'n': 2.7, 'w': 3.0, 's': '5', 'f': '4.0', 'hex': '-0X10'});
      expect(() => r.get<int>('p'), throwsFormatException);
      expect(() => r.get<int>('n'), throwsFormatException);
      expect(r.get<int>('w'), 3);
      expect(r.get<int>('f'), 4);
      expect(r.get<int?>('s'), 5);
      expect(r.get<double?>('s'), 5.0);
      expect(r.get<String?>('n'), '2.7');
      expect(() => r.get<num>('hex'), throwsFormatException);
    });

    test('a cell and a Doc coerce alike: one reading policy', () {
      for (final (text, asNum, asInt) in [
        ('0x10', null, null),
        ('NaN', null, null),
        ('Infinity', null, null),
        ('1,200', 1200, 1200),
        ('4.0', 4.0, 4),
        ('99999999999999999999', 1e20, null),
      ]) {
        if (asNum case final want?) {
          expect(Row({'v': text}).get<num>('v'), want, reason: text);
          expect(Doc(text).to<num>(), want, reason: text);
        } else {
          expect(() => Row({'v': text}).get<num>('v'), throwsFormatException, reason: text);
          expect(() => Doc(text).to<num>(), throwsFormatException, reason: text);
        }
        if (asInt case final want?) {
          expect(Row({'v': text}).get<int>('v'), want, reason: text);
          expect(Doc(text).to<int>(), want, reason: text);
        } else {
          expect(() => Row({'v': text}).get<int>('v'), throwsFormatException, reason: text);
          expect(() => Doc(text).to<int>(), throwsFormatException, reason: text);
        }
      }
      expect(() => Row({'d': '2024-02-30'}).get<DateTime>('d'), throwsFormatException, reason: 'no rolling into March');
      expect(Row({'d': ''}).get('d', or: 1), 1);
      expect(const Doc('').to(or: 1), 1, reason: 'blank is absence in both');
    });

    test('get<DateTime> reads ISO 8601 text', () {
      final r = Row({'at': '2024-01-02T03:04:05Z', 'day': '2024-03-01', 'no': 'soon', 'n': 5});
      expect(r.get<DateTime>('at'), DateTime.utc(2024, 1, 2, 3, 4, 5));
      expect(r.get<DateTime>('day'), DateTime.utc(2024, 3, 1));
      expect(() => r.get<DateTime>('no'), throwsFormatException);
      expect(() => r.get<DateTime>('n'), throwsFormatException);
      expect((() => r.get<DateTime>('nowhere')).orNull, isNull);
      final at = DateTime(2020);
      expect(Row({'d': at}).get<DateTime>('d'), same(at));
    });

    test('decimal: reads the cells with that mark; an explicit one on a read wins', () {
      expect(_csv('a\n"1,5"\n', decimal: ',').rows.first.get<num>('a'), 1.5);
      expect(() => _csv('a\n"1,5"\n', decimal: ',').rows.first.get<num>('a', decimal: '.'), throwsFormatException);
    });

    test('a comma is a thousands separator only where it groups thousands', () {
      final t = _csv('v\n"1,200"\n"1,5"\n"12,345.5"\n');
      expect([t.rows[0].get<num>('v'), t.rows[2].get<num>('v')], [1200, 12345.5]);
      expect(() => t.rows[1].get<num>('v'), throwsFormatException);
      expect(t.values<String>('v'), ['1,200', '1,5', '12,345.5']);
    });

    test('numbers are decimal: 0x10, NaN and Infinity are not', () {
      expect(() => _csv('v\n0x10\nNaN\n').values<num>('v'), throwsFormatException);
      expect(_csv('v\n1e3\n-2.5\n').values<num>('v'), [1000, -2.5]);
    });
  });

  group('streaming', () {
    late String tmp;
    setUp(() => tmp = tempDir('table_stream_'));

    test('a streamed failure names the line in the file, past every chunk', () async {
      final nd = '$tmp/x.ndjson';
      File(nd).writeAsStringSync('${'{"i":1,"pad":"${'x' * 40}"}\n' * 200000}{bad\n');
      await expectLater(
        Table.lines(nd).drain<void>(),
        _format(endsWith('x.ndjson, line 200001: Unexpected character')),
      );
      final csv = '$tmp/x.csv';
      File(csv).writeAsStringSync('a,b\n${'1,"q ""x"""\n' * 300000}"open,1\n');
      await expectLater(
        Table.lines(csv).drain<void>(),
        _format(endsWith('x.csv, line 300002: the quote opened here is never closed')),
      );
    });

    test('a streamed TSV has no quoting, and a written one refuses a tab or line break', () async {
      final path = '$tmp/t.tsv';
      File(path).writeAsStringSync('title\tyear\n"Friends" pilot\t1994\n"Weird\t1995\n');
      expect(await Table.lines(path).map((r) => r['title']).toList(), ['"Friends" pilot', '"Weird']);
      await expectLater(
        Stream.value(<String, Object?>{'a': 'x\ty'}).pipe(Table.writer('$tmp/w.tsv')),
        _format('Invalid TSV at row 1, column "a": a tab or line break has no TSV form'),
      );
    });

    test('Table.writer writes the format its extension names, atomically on close (COL-3)', () async {
      // Rows are `Map<String, Object?>`, as a Row is.
      final rows = <Map<String, Object?>>[
        {'a': 1, 'b': 'x'},
        {'a': 2, 'b': 'y'},
      ];
      for (final ext in ['csv', 'tsv', 'ndjson', 'json', 'md']) {
        final path = '$tmp/out.$ext';
        await Stream.fromIterable(rows).pipe(Table.writer(path));
        final back = await Table.read(path);
        expect(back.values<String>('b'), ['x', 'y'], reason: ext);
      }
      expect(File('$tmp/out.json').readAsStringSync(), startsWith('['));
      expect(File('$tmp/out.md').readAsStringSync(), startsWith('| a | b |'));
      await Stream<Row>.empty().pipe(Table.writer('$tmp/empty.json'));
      expect((await Table.read('$tmp/empty.json')).isEmpty, isTrue);
    });

    test('a failing stream leaves the old file whole, and a row with another key is refused', () async {
      final path = '$tmp/keep.csv';
      File(path).writeAsStringSync('a\nold\n');
      Stream<Row> failing() async* {
        yield const Row({'a': 'new'});
        throw StateError('source broke');
      }

      await expectLater(failing().pipe(Table.writer(path)), throwsStateError);
      expect(File(path).readAsStringSync(), 'a\nold\n');
      await expectLater(
        Stream.fromIterable(<Map<String, Object?>>[
          {'a': 1},
          {'a': 2, 'b': 3},
        ]).pipe(Table.writer(path)),
        throwsA(isA<ArgumentError>().having((e) => '$e', 'message', contains('"b"'))),
      );
      expect(File(path).readAsStringSync(), 'a\nold\n');
      expect(Directory(tmp).listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    });

    test('many rows stream through the writer and back through Table.lines', () async {
      final path = '$tmp/many.csv';
      await Stream.fromIterable(<Map<String, Object?>>[
        for (var i = 0; i < 20000; i++) {'n': i, 'text': 'row $i ${'x' * 20}'},
      ]).pipe(Table.writer(path));
      final t = await Table.read(path);
      expect(t.length, 20000);
      expect(t.rows.last.get<int>('n'), 19999);
      expect(await Table.lines(path).length, 20000);
    });

    test('Table.lines decodes a character split across chunks, strictly; JSON and Markdown are refused', () async {
      final pad = (1 << 20) - 'a\n'.length - 1;
      for (final ext in ['csv', 'ndjson']) {
        final path = '$tmp/split.$ext';
        final body = ext == 'csv' ? 'a\n${'x' * pad}é\nz\n' : '{"a":"${'x' * (pad - 6)}é"}\n{"a":"z"}\n';
        File(path).writeAsStringSync(body);
        final want = (await Table.read(path)).rows.map(Map.of).toList();
        expect((await Table.lines(path).toList()).map(Map.of).toList(), want, reason: ext);
        expect(want.first['a'].toString().endsWith('é'), isTrue, reason: ext);
      }
      final bad = '$tmp/bad.csv';
      File(bad).writeAsBytesSync([...utf8.encode('a\n'), 0xff, 0x0a]);
      await expectLater(Table.lines(bad).toList(), throwsA(isA<FormatException>()));
      expect(() => Table.lines('$tmp/t.json'), throwsArgumentError);
      expect(() => Table.lines('$tmp/t.md'), throwsArgumentError);
    });

    test('Table.lines takes decimal: and sniffs the separator, as read does', () async {
      final path = '$tmp/eu.csv';
      File(path).writeAsStringSync('v;w\n1,5;2\n');
      expect((await Table.lines(path, decimal: ',').single).get<num>('v'), 1.5);
      expect(await Table.lines(path).map((r) => r['w']).toList(), ['2']);
    });

    test('Table.read and Table.lines agree across chunks, quoted newlines and doubled quotes', () async {
      final lines = ['id,note', for (var i = 0; i < 5000; i++) '$i,"line $i\nsays ""hi"", ${'x' * (i % 97)}"'];
      final csv = File('$tmp/t.csv')..writeAsStringSync('\u{FEFF}${lines.join('\r\n')}\r\n');
      final table = await Table.read(csv.path);
      expect(table.length, 5000);
      expect(table.rows[42]['note'], 'line 42\nsays "hi", ${'x' * 42}');
      expect((await Table.lines(csv.path).toList()).map(Map.of).toList(), table.rows.map(Map.of).toList());
      File('$tmp/t.ndjson').writeAsStringSync('{"a":1}\n\n{"a":2}\n');
      expect(await Table.lines('$tmp/t.ndjson').map((r) => r['a']).toList(), [1, 2]);
    });

    test('Table.lines fails on an unclosed quote naming the file, and a huge quoted cell streams', () async {
      final bad = File('$tmp/bad.csv')..writeAsStringSync('a\n"never closed\n');
      await expectLater(
        Table.lines(bad.path).toList(),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(bad.path))),
      );
      final big = File('$tmp/big.csv')..writeAsStringSync('a,b\n"${'x' * (8 << 20)}",1\n2,3\n');
      final rows = await Table.lines(big.path).toList();
      expect(rows.map((r) => r['b']), ['1', '3']);
      expect((rows.first['a']! as String).length, 8 << 20);
    });

    test('a streamed row names its file and row', () async {
      final path = '$tmp/s.csv';
      File(path).writeAsStringSync('a\n1\nx\n');
      final rows = await Table.lines(path).toList();
      expect(() => rows[1].get<int>('a'), _format('Invalid CSV in $path, row 2: "x" in "a", not an int'));
      expect(() => rows[0].get<int>('b'), _missing('Missing column "b" in $path'));
    });
  });
}
