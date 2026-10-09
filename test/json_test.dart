import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/src/message.dart' show Response, StatusException;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' as reference;

import 'support.dart';

/// [message] of the FormatException a call throws.
Matcher _format(Object message) => throwsA(isA<FormatException>().having((e) => e.message, 'message', message));

/// [message] of the MissingException a call throws.
Matcher _missing(Object message) => throwsA(isA<MissingException>().having((e) => e.message, 'message', message));

void main() {
  group('typed JsonPath', () {
    test('a JsonPath is checked when made and goes where one does', () {
      final doc = Doc.parse('{"items": [{"id": 1}, {"id": 2}]}', DocFormat.json);
      expect(doc.$(r'$.items[*].id'.jsonPath).to<List<int>>(), [1, 2]);
      expect(doc.$('items[*].id'.jsonPath).to<List<int>>(), [1, 2], reason: 'the root\'s \$ may go unwritten');
      expect(() => JsonPath(r'$.items['), throwsFormatException);
    });
  });

  group('Doc', () {
    group('reading', () {
      test('[] takes a String key or an int index, negative from the end, as \$[-1] does', () {
        final doc = '{"a": [1, 2, 3]}'.json;
        expect(doc['a'][0].to<int>(), 1);
        expect(doc['a'][-1].to<int>(), 3);
        expect(doc['a'][-1].raw, doc.$(r'$.a[-1]').single.raw);
        expect(doc['missing'].raw, isNull);
        expect(doc['a'][99].raw, isNull);
        expect(() => doc[3.5], throwsArgumentError);
      });

      test('below a value that is not a map or a list is a FormatException saying what is there (FMT-11)', () {
        final doc = '{"a": "x", "n": 1, "l": [1]}'.json;
        expect(() => doc['a']['b'], _format(r'Invalid JSON at $.a: a String, not a map'));
        expect(() => doc['n'][0], _format(r'Invalid JSON at $.n: an int, not a list'));
        expect(() => doc['l']['k'], _format(r'Invalid JSON at $.l: a list, not a map'));
        expect(() => doc['gone']['deeper'].to<int>(), _missing(r'Missing $.gone.deeper'));
      });

      test('a leading byte-order mark is not part of any document', () {
        const bom = '\u{FEFF}';
        expect('${bom}a: 1\nb: 2'.yaml.raw, {'a': 1, 'b': 2});
        expect('${bom}a = 1'.toml.raw, {'a': 1});
        expect('$bom{"a": 1}'.json.raw, {'a': 1});
        expect('$bom[s]\na = 1'.ini.raw, {
          's': {'a': '1'},
        });
      });

      test('to reads text with format: and decimal:, and lists of dates and durations', () {
        final doc =
            '{"d": "08/10/2026", "p": "1.234,5", "ds": ["2026-10-08", "Sun, 06 Nov 1994 08:49:37 GMT"], "ts": ["3:45", "PT1M", 90], "m": {"a": "1s"}}'
                .json;
        expect(doc['d'].to<DateTime>(format: 'dd/MM/yyyy'), DateTime.utc(2026, 10, 8));
        expect(doc['p'].to<double>(decimal: ','), 1234.5);
        expect(doc['ds'].to<List<DateTime>>(), [DateTime.utc(2026, 10, 8), DateTime.utc(1994, 11, 6, 8, 49, 37)]);
        expect(doc['ts'].to<List<Duration>>(), [
          const Duration(minutes: 3, seconds: 45),
          const Duration(minutes: 1),
          const Duration(seconds: 90),
        ]);
        expect(doc['m'].to<Map<String, Duration>>(), {'a': const Duration(seconds: 1)});
        expect(() => '["3:45", "soon"]'.json.to<List<Duration>>(), _format(contains(r'$[1]')));
      });

      test('to<num> keeps an int an int and a double a double, and reads text', () {
        final d = '{"i": 3, "f": 2.5, "s": "1,200", "x": "x"}'.json;
        expect(d['i'].to<num>(), isA<int>().having((n) => n, 'n', 3));
        expect(d['f'].to<num>(), 2.5);
        expect(d['s'].to<num>(), 1200);
        expect(() => d['x'].to<num>(), _format(r'Invalid JSON at $.x: "x", not a num'));
      });

      test('to<T>() is the value, a MissingException where there is none, or a FormatException that says where', () {
        final d = '{"tags":["a","b"],"n":1.7,"i":2.0,"s":"12","m":{"x":1,"y":2},"no":null}'.json;
        expect(d['tags'].to<List<String>>(), ['a', 'b']);
        expect(d['m'].to<Map<String, int>>(), {'x': 1, 'y': 2});
        expect(d['i'].to<int>(), 2);
        expect(d['s'].to<int>(), 12);
        expect(() => d['n'].to<int>(), _format(r'Invalid JSON at $.n: a double, not an int'));
        expect(() => d['tags'].to<List<int>>(), _format(contains(r'$.tags[0]')));
        expect(() => d['missing'].to<bool>(), _missing(r'Missing $.missing'));
        expect(() => d['no'].to<bool>(), throwsA(isA<MissingException>()));
        expect((() => d['missing'].to<bool>()).orNull, isNull);
        expect((() => d['no'].to<int>()).or(7), 7);
        // a value that is there and reads as no bool is a broken value, which nothing answers
        expect(() => d['n'].to<bool>(), throwsFormatException);
        expect(() => (() => d['n'].to<bool>()).orNull, throwsFormatException);
        expect((() => d['no'].to<String>()).orNull, isNull);
        expect(d['no'].to<String?>(), isNull);
      });

      test('a blank value is absence, as in Row and Env (FMT-3)', () {
        final d = '{"port": "", "name": "  "}'.json;
        expect(d['port'].to(or: 8080), 8080);
        expect(d['name'].to(or: 'anon'), 'anon');
        expect(d['port'].to<int?>(), isNull);
        expect(() => d['port'].to<int>(), _missing(r'Missing $.port'));
      });

      test('to<String>() refuses a list or a map, and reads a number or a bool as text (FMT-1, FMT-2)', () {
        final d = '{"tags": ["x"], "m": {"a": 1}, "n": 42, "b": true}'.json;
        expect(() => d['tags'].to<String>(), _format(r'Invalid JSON at $.tags: a list, not a String'));
        expect(() => d['m'].to<String>(), _format(r'Invalid JSON at $.m: a map, not a String'));
        expect(d['n'].to<String>(), '42');
        expect(d['b'].to<String>(), 'true');
        expect(d['tags'].to<Object>(), ['x']);
      });

      test('to(or:) types the reading by its default; a present value wins, a wrong one throws', () {
        final d = '{"n": 3, "s": "12", "word": "eighty", "no": null}'.json;
        final port = d['port'].to(or: 8080);
        expect(port, isA<int>());
        expect(port, 8080);
        expect(d['no'].to(or: 'none'), 'none');
        expect(d['n'].to(or: 0), 3);
        expect(d['s'].to(or: 0), 12);
        expect(() => d['word'].to(or: 0), throwsFormatException);
        final Object? wide = d['missing'].to(or: 5);
        expect(wide, 5);
      });

      test('or answers only an absence: a value that is there but does not read throws', () {
        final ini = 'debug = maybe\nport = 80x\non = yes'.ini;
        expect(() => (() => ini['debug'].to<bool>()).or(false), throwsFormatException);
        expect(() => (() => ini['port'].to<int>()).or(8080), throwsFormatException);
        expect((() => ini['on'].to<bool>()).or(false), isTrue);
        expect((() => ini['nope'].to<bool>()).or(false), isFalse);
        expect((() => const Doc(1.5).to<Object>()).or(0), 1.5);
        expect(() => (() => const Doc(1.5).to<int>()).or(0), throwsFormatException);
      });

      test('to<DateTime> reads ISO 8601 text', () {
        final doc = '{"t": "2026-10-01T12:30:00Z", "d": "2026-10-01", "bad": "soon"}'.json;
        expect(doc['t'].to<DateTime>(), DateTime.utc(2026, 10, 1, 12, 30));
        expect(doc['d'].to<DateTime>(), DateTime.utc(2026, 10, 1));
        expect(() => doc['bad'].to<DateTime>(), throwsFormatException);
        expect((() => doc['missing'].to<DateTime>()).orNull, isNull);
      });

      test('to<int> refuses a double past int64; to<DateTime> wants a real ISO date', () {
        expect(() => const Doc(1e300).to<int>(), throwsFormatException);
        expect(() => const Doc(9223372036854775808.0).to<int>(), throwsFormatException);
        expect(const Doc(-9223372036854775808.0).to<int>(), -9223372036854775807 - 1);
        for (final bad in ['2024-02-30', '2023-02-29', '2024-13-45T25:61:61', '2024-01-01T24:00', '12345678']) {
          expect(() => Doc(bad).to<DateTime>(), throwsFormatException, reason: bad);
        }
        expect(const Doc('2024-02-29 03:04').to<DateTime>(), DateTime.utc(2024, 2, 29, 3, 4));
      });

      test('a failure names the path and the file, however the value was reached', () async {
        final doc = '{"a": [{"b c": "x"}], "items": [{"id": "q"}]}'.json;
        expect(() => doc['a'][0]['b c'].to<int>(), _format(r'''Invalid JSON at $.a[0]['b c']: "x", not an int'''));
        expect(() => doc.$(r'$..id').first.to<int>(), _format(startsWith(r'Invalid JSON at $($..id)[0]: "q"')));
        expect(
          () => doc['items'].$(r'$[*].id').first.to<int>(),
          _format(startsWith(r'Invalid JSON at $.items$($[*].id)[0]:')),
        );
        expect(
          () => doc['items'].list.first.map['id']!.to<bool>(),
          _format(startsWith(r'Invalid JSON at $.items[0].id:')),
        );
        expect(
          () => '{"m": {"k": "x"}}'.json['m'].to<Map<String, int>>(),
          _format(r'Invalid JSON at $.m.k: "x", not an int'),
        );
        final file = '${tempDir()}/config.yaml';
        File(file).writeAsStringSync('server:\n  host: x\n');
        final cfg = await Doc.read(file);
        expect(() => cfg['server']['port'].to<int>(), _missing('Missing \$.server.port in $file'));
        expect(
          () => cfg['server']['host']['x'],
          _format('Invalid YAML in $file at \$.server.host: a String, not a map'),
        );
      });

      test('list, map and table: absent is Missing, another shape a FormatException (FMT-10, FMT-12)', () {
        final d = '{"rows": [{"a": 1}, {"a": 2}], "s": "x", "bad": [{"a": 1}, 2]}'.json;
        expect(d['rows'].table.values<int>('a'), [1, 2]);
        expect(() => d['s'].table, _format(r'Invalid JSON at $.s: a String, not a list'));
        expect(() => d['bad'].table, _format(r'Invalid JSON at $.bad[1]: an int, not a map'));
        expect(() => d['none'].table, _missing(r'Missing $.none'));
        expect(() => d['s'].list, _format(r'Invalid JSON at $.s: a String, not a list'));
        expect(() => d['rows'].map, _format(r'Invalid JSON at $.rows: a list, not a map'));
        expect(() => d['none'].map, throwsA(isA<MissingException>()));
      });

      test('toString is a short view, not the encoder', () {
        expect('${'{"a": 1}'.json}', 'Doc({"a":1})');
        expect('${Doc({'k': 'x' * 100})}', hasLength(lessThan(70)));
      });
    });

    group('JSONPath', () {
      test('a selection is an Iterable of documents', () {
        final d = '{"items": [{"id": 1}, {"id": 2}, {"id": 3}]}'.json;
        expect([for (final id in d.$('items[*].id')) id.to<int>()], [1, 2, 3]);
        expect(d.$('items[*].id').where((x) => x.to<int>() > 1).map((x) => x.raw), [2, 3]);
        expect(d.$('items[*].id').last.to<int>(), 3);
        expect(() => d.$('nope').last, _missing(r'Missing $(nope)'));
      });

      test(r'$ returns a selection: first, single, list, to (FMT-1)', () {
        final d = '{"name": "x", "items": [{"id": 1}, {"id": 2}]}'.json;
        expect(d.$(r'$.name').single.to<String>(), 'x');
        expect(() => d.$(r'$.name').to<String>(), _format(contains('a list, not a String')));
        expect(d.$(r'$.items[*].id').to<List<int>>(), [1, 2]);
        expect(d.$(r'$.items[*].id').first.to<int>(), 1);
        expect(d.$(r'$.items[*].id').map((x) => x.raw), [1, 2]);
        expect(d.$(r'$.items[*].id').length, 2);
        expect(() => d.$(r'$.items[*].id').single, _format(contains('2 matches, not one')));
        expect(() => d.$(r'$.nope').first, _missing(r'Missing $($.nope)'));
        expect(d.$(r'$.nope').isEmpty, isTrue);
      });

      test(r'$..[0] applies to the node and every descendant', () {
        final d = '{"a": [1, 2], "b": {"c": [3, [4, 5]]}}'.json;
        expect(d.$(r'$..[0]').to<List<int>>(), [1, 3, 4]);
        expect('[[1, 2], [3]]'.json.$(r'$..[0]').map((x) => x.raw), [
          [1, 2],
          1,
          3,
        ]);
      });

      test('slices and unions, with or without the leading \$; a filter or a stray ] is a FormatException', () {
        final d = '{"l":[0,1,2,3,4,5],"a":1,"x.y":2}'.json;
        List<Object?> q(String e) => d.$(e).to<List<Object?>>();
        expect(q(r'$.l[1:4]'), [1, 2, 3]);
        expect(q(r'$.l[::-2]'), [5, 3, 1]);
        expect(q(r'$.l[-2:]'), [4, 5]);
        expect(q(r'$.l[0,2]'), [0, 2]);
        expect(q(r"$['a','x.y']"), [1, 2]);
        expect(() => d.$(r'$.l[?(@ > 1)]'), throwsFormatException);
        expect(q('l[0]'), [0]);
        expect(q('..a'), [1]);
        expect(() => d.$(r'$.l]'), throwsFormatException, reason: 'was the key "l]"');
        expect(() => d.$(r'$.a.b]'), throwsFormatException);
      });

      test('.. walks any depth jsonDecode reads, in document order', () {
        final deep = '${'{"a":' * 50000}1${'}' * 50000}'.json;
        expect(deep.$(r'$..a'), hasLength(50000));
        final d = '{"a":{"id":1,"b":[{"id":2},{"c":{"id":3}}]},"id":4}'.json;
        expect(d.$(r'$..id').to<List<int>>(), [4, 1, 2, 3]);
        expect(d.$(r'$..*'), hasLength(9));
      });
    });

    group('editing', () {
      test('a Doc nested in another is written as its value, and add appends', () {
        final doc = '{"name":"x","n":1,"l":[1,2]}'.json;
        final edited = Doc({...doc.map, 'port': 9090});
        expect(jsonDecode(edited.encode(DocFormat.json)), {
          'name': 'x',
          'n': 1,
          'l': [1, 2],
          'port': 9090,
        });
        expect(jsonEncode({'k': doc['name']}), '{"k":"x"}');
        expect(Doc({'k': doc['l']}).encode(DocFormat.yaml), 'k:\n  - 1\n  - 2\n');
        doc['l'].add(3);
        doc['l'].add(const Doc(4));
        expect(doc['l'].to<List<int>>(), [1, 2, 3, 4]);
      });

      test('a wrong shape for an edit is a FormatException naming where; nothing there is Missing (FMT-10)', () {
        final doc = '{"name":"x","l":[1]}'.json;
        expect(() => doc['name'].add(1), _format(r'Invalid JSON at $.name: a String, not a list'));
        expect(() => doc['l']['k'] = 1, _format(r'Invalid JSON at $.l: a list, not a map'));
        expect(() => doc['name'][0] = 1, _format(r'Invalid JSON at $.name: a String, not a list'));
        expect(() => doc['name'].remove('k'), _format(r'Invalid JSON at $.name: a String, not a map'));
        expect(() => doc['gone']['k'] = 1, _missing(r'Missing $.gone'));
        expect(() => doc['gone'].add(1), _missing(r'Missing $.gone'));
        expect(() => doc['l'][5] = 1, throwsRangeError);
      });

      test('[]= sets, and remove answers the removed value as a Doc', () {
        final doc = '{"server": {"port": 8080, "tags": ["a", "b"]}}'.json;
        doc['server']['port'] = 9000;
        doc['server']['tags'][0] = 'first';
        doc['server']['ssl'] = true;
        expect(doc['server']['port'].raw, 9000);
        expect(doc['server']['tags'][0].raw, 'first');
        final removed = doc['server'].remove('ssl');
        expect(removed, isA<Doc>());
        expect(removed.to<bool>(), isTrue);
        expect(doc['server']['ssl'].raw, isNull);
        expect(doc['server']['tags'].remove(-1).to<String>(), 'b');
        expect(doc['server']['tags'].list, hasLength(1));
        expect(() => doc['server'].remove('nothing').to<int>(), _missing(r'Missing $.server.nothing'));
      });
    });

    group('merge', () {
      test('maps merge all the way down, the other wins, lists and nulls replace, neither changes', () {
        final defaults =
            '{"server": {"host": "0.0.0.0", "port": 80, "tls": {"on": false}}, "tags": [1, 2], "debug": true}'.json;
        final user = 'server:\n  port: 8080\n  tls:\n    cert: a.pem\ntags: [3]\ndebug:\n'.yaml;
        final local = '[server]\nhost = "127.0.0.1"\n'.toml;
        final config = defaults.merge(user).merge(local);
        expect(config.raw, {
          'server': {
            'host': '127.0.0.1',
            'port': 8080,
            'tls': {'on': false, 'cert': 'a.pem'},
          },
          'tags': [3],
          'debug': null,
        });
        expect(defaults['server']['port'].to<int>(), 80);
        config['server']['tls']['on'] = true;
        config['tags'].add(4);
        expect(defaults['server']['tls']['on'].to<bool>(), isFalse);
        expect(user['tags'].raw, [3]);
        expect(defaults.merge(const Doc({'debug': false}))['debug'].to<bool>(), isFalse);
        expect(defaults.merge(const Doc([1])).raw, [1]);
        expect('a = 1\n[s]\nb = 2\n'.ini.merge('[s]\nc = 3\n'.ini).raw, {
          'a': '1',
          's': {'b': '2', 'c': '3'},
        });
      });

      test('merging nothing changes nothing: an empty local.yaml keeps the defaults (FMT-4)', () {
        final defaults = '{"a": 1, "b": {"c": 2}}'.json;
        expect(defaults.merge(''.yaml).raw, defaults.raw);
        expect(defaults.merge(const Doc(null)).raw, defaults.raw);
      });

      test('a deep document merges on a stack', () {
        Object? deep(int n, Object? leaf) {
          Object? v = leaf;
          for (var i = 0; i < n; i++) {
            v = {'a': v};
          }
          return v;
        }

        var at = Doc(deep(20000, 1)).merge(Doc(deep(20000, 2)));
        for (var i = 0; i < 20000; i++) {
          at = at['a'];
        }
        expect(at.to<int>(), 2);
      });
    });

    group('files', () {
      test('read reads JSON, YAML, TOML and INI by extension; another is an ArgumentError (FMT-7)', () async {
        final dir = tempDir();
        Future<String> write(String name, String text) async => (await File('$dir/$name').writeAsString(text)).path;
        expect((await Doc.read(await write('a.json', '{"x":1}')))['x'].raw, 1);
        expect((await Doc.read(await write('a.YML', 'x: 2')))['x'].raw, 2);
        expect((await Doc.read(await write('a.toml', 'x = 3')))['x'].raw, 3);
        expect((await Doc.read(await write('a.conf', 'x = 4')))['x'].to<int>(), 4);
        expect(() => Doc.read('$dir/a.txt'), throwsArgumentError);
        expect(() => '{}'.json.save('$dir/settings'), throwsArgumentError);
      });

      test('a file that does not parse is a FormatException naming it and the line', () async {
        final file = '${tempDir()}/bad.toml';
        File(file).writeAsStringSync('a = 1\nb = = 2\n');
        await expectLater(
          Doc.read(file),
          throwsA(isA<FormatException>().having((e) => '$e', 'text', contains('bad.toml'))),
        );
        await expectLater(
          Doc.read(file),
          throwsA(isA<FormatException>().having((e) => '$e', 'text', contains('line 2'))),
        );
        expect(() => 'a = = 1'.toml, _format(startsWith('Invalid TOML, line 1: ')));
      });

      test('an INI that is not UTF-8 reads as Windows-1252; a UTF-16 one by its mark (FMT-18)', () async {
        final dir = tempDir();
        File('$dir/ansi.ini').writeAsBytesSync([...latin1.encode('[s]\nname = caf'), 0xe9, 0x20, 0x80]);
        expect((await Doc.read('$dir/ansi.ini'))['s']['name'].raw, 'café €');
        final utf16 = [
          0xff,
          0xfe,
          for (final u in 'k = ü'.codeUnits) ...[u & 0xff, u >> 8],
        ];
        File('$dir/wide.ini').writeAsBytesSync(utf16);
        expect((await Doc.read('$dir/wide.ini'))['k'].raw, 'ü');
        File('$dir/bad.json').writeAsBytesSync([0x22, 0xe9, 0x22]);
        await expectLater(Doc.read('$dir/bad.json'), throwsA(isA<FormatException>()));
      });

      test('every format saves, and reads back (FMT-8, FMT-16)', () async {
        final dir = tempDir();
        final doc =
            '{"name": "x y", "port": 8080, "on": true, "list": [1, 2.5], "srv": {"host": "h", "tls": {"on": false}}}'
                .json;
        await expectLater(
          doc.save('$dir/a/out.json'),
          throwsA(isA<PathNotFoundException>()),
          reason: 'save makes no folders',
        );
        Directory('$dir/a').createSync();
        for (final ext in ['json', 'yaml', 'toml']) {
          final path = await doc.save('$dir/a/out.$ext');
          expect(path, isA<Path>());
          expect(path, '$dir/a/out.$ext');
          expect((await Doc.read(path)).raw, doc.raw, reason: ext);
        }
        final ini = 'name = x y\nport = 8080\n[srv]\nhost = h\n[srv.tls]\non = no\n'.ini;
        expect((await Doc.read(await ini.save('$dir/out.ini'))).raw, ini.raw);
        expect(
          await File('$dir/a/out.json').readAsString(),
          '${const JsonEncoder.withIndent('  ').convert(doc.raw)}\n',
        );
      });

      test(
        'save is a Task under a conflict policy: overwrite by default, skip leaves the file (Done fresh: false)',
        () async {
          final dir = tempDir();
          final file = File('$dir/a.json')..writeAsStringSync('old');
          await '{"a": 1}'.json.save(file.path);
          expect(file.readAsStringSync(), '{\n  "a": 1\n}\n');
          final skipped = '{"a": 2}'.json.save(file.path, conflict: Conflict.skip);
          expect(await skipped.settled, isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse));
          expect(file.readAsStringSync(), contains('1'));
          await expectLater('{}'.json.save(file.path, conflict: Conflict.fail), throwsA(isA<PathExistsException>()));
          expect(await '{}'.json.save(file.path, conflict: Conflict.rename), '$dir/a (1).json');
          expect(() => '{}'.json.save(file.path, conflict: Conflict.newer), throwsArgumentError);
        },
      );

      test('a YAML stream saves every document (FMT-5); parseAll reads each (FMT-6)', () async {
        const text = 'a: 1\n---\nb: 2\n';
        final stream = text.yaml;
        expect(stream.raw, {'a': 1}, reason: 'a stream reads as its first document');
        final path = await stream.save('${tempDir()}/s.yaml');
        expect(Doc.parseAll(await File(path).readAsString(), DocFormat.yaml).map((d) => d.raw), [
          {'a': 1},
          {'b': 2},
        ]);
        expect(() => stream.encode(DocFormat.json), _format(contains('a YAML stream of 2 documents')));
        expect(Doc.parseAll('{"a": 1}', DocFormat.json).single.raw, {'a': 1});
      });

      test('save replaces a file atomically, keeps an odd mode, and follows a link', () async {
        final dir = tempDir();
        final doc = '{"a": 1}'.json;
        final plain = File('$dir/plain.json')..writeAsStringSync('old');
        final private = File('$dir/private.json')..writeAsStringSync('old');
        await Process.run('chmod', ['600', private.path]);
        final link = Link('$dir/link.json')..createSync(plain.path);

        await doc.save(plain.path);
        await doc.save(private.path);
        await doc.save(link.path);

        expect(plain.readAsStringSync(), '{\n  "a": 1\n}\n');
        expect(private.readAsStringSync(), '{\n  "a": 1\n}\n');
        expect(private.statSync().mode & 0x1ff, 0x180, reason: 'mode 600 stays');
        expect(FileSystemEntity.isLinkSync(link.path), isTrue, reason: 'the link still points at plain.json');
        expect(Directory(dir).listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')), isEmpty);
      }, testOn: '!windows');
    });

    group('encode', () {
      test('TOML writes tables under headers and arrays of tables; a null has no TOML form', () {
        final doc = Doc({
          'title': 'a "q"',
          'n': 1,
          'srv': {
            'host': 'h',
            'tls': {'on': true},
          },
          'items': [
            {'id': 1},
            {'id': 2},
          ],
          'mixed': [1, 'x'],
          'odd key': 1.5,
        });
        final toml = doc.encode(DocFormat.toml);
        expect(toml.toml.raw, doc.raw);
        expect(toml, contains('[[items]]'));
        expect(toml, contains('[srv.tls]'));
        expect(
          () => const Doc({'a': null}).encode(DocFormat.toml),
          _format(r'Invalid TOML at $.a: null has no TOML form'),
        );
        expect(() => const Doc([1]).encode(DocFormat.toml), _format(r'Invalid TOML at $: a list, not a map'));
      });

      test('INI writes sections and quotes what would not read back; a list has no INI form', () {
        final doc = Doc({
          'a': ' padded ',
          'b': 'x ; y',
          's': {'k': 'v', 'empty': null},
        });
        expect(doc.encode(DocFormat.ini).ini.raw, {
          'a': ' padded ',
          'b': 'x ; y',
          's': {'k': 'v', 'empty': ''},
        });
        expect(
          () => const Doc({
            'l': [1],
          }).encode(DocFormat.ini),
          _format(r'Invalid INI at $.l: a list has no INI form'),
        );
      });

      test('a response body that is not JSON names its URL; an HTML page says so (FMT-15)', () {
        final page = Response(
          '<html>error</html>',
          502,
          headers: {'content-type': 'text/html'},
          url: Uri.parse('https://api.test/v1'),
        );
        expect(() => page.json, _format('Invalid JSON in https://api.test/v1: the body is HTML (text/html), not JSON'));
        final bad = Response('{"a": ', 200, url: Uri.parse('https://api.test/v2'));
        expect(() => bad.json, _format(startsWith('Invalid JSON in https://api.test/v2, line 1: ')));
        expect(Response('{"a": 1}', 404).json['a'].to<int>(), 1, reason: 'a response value reads whatever its status');
        expect(Future.value(Response('{}', 404)).json, throwsA(isA<StatusException>()));
      });
    });
  });

  group('yaml', () {
    test("an apostrophe inside a plain scalar opens no string, so a comment after it is one", () {
      const text = "a: rock 'n roll # c\nb: [rock 'n roll] # c\nc: x 'y #z'\nd: 'quoted' # c\ne: !!str 'x'";
      expect(text.yaml.raw, {
        'a': "rock 'n roll",
        'b': ["rock 'n roll"],
        'c': "x 'y",
        'd': 'quoted',
        'e': 'x',
      });
      expect(text.yaml.raw, reference.loadYaml(text));
    });

    const doc = '''
# a pubspec-shaped document
name: dart_toolkit
version: 0.0.4
environment:
  sdk: ^3.10.0
dependencies:
  path: ^1.9.0
  empty:
flags: [fast, --verbose, 'quoted, comma']
matrix: {os: linux, count: 3, ok: true}
steps:
  - uses: actions/checkout@v4
  - name: Test
    run: |
      dart pub get
      dart test
    if: \${{ always() }}
  - [nested, list]
  -
    - deep
notes: >
  folded text
  on two lines
anchor: &base {a: 1, b: 2}
alias: *base
quoted: "line\\nbreak \\"q\\""
single: 'it''s'
numbers: [0x1F, 1e3, -.inf, .nan, 007, 1_000]
nulls: [~, null, ""]
url: https://example.com/a:b#c
time: 12:30:00
multi: this is one
  plain scalar
''';

    Object? y(String s) => s.yaml.raw;

    test('matches package:yaml on the whole document', () {
      final ours = doc.yaml.raw;
      final theirs = _plain(reference.loadYaml(doc));
      expect(_show(ours), equals(_show(theirs)));
    });

    test('the query API is the JSON one', () {
      final y = doc.yaml;
      expect(y['name'].to<String>(), 'dart_toolkit');
      expect(y.$(r'$.dependencies.*'), hasLength(2));
      expect(y['steps'][1]['run'].to<String>(), 'dart pub get\ndart test\n');
      expect(y['notes'].to<String>(), 'folded text on two lines\n');
      expect(y['matrix']['count'].to<int>(), 3);
      expect(y['alias']['b'].to<int>(), 2);
      expect(y['numbers'].list.map((d) => d.raw).take(2).toList(), [31, 1000.0]);
      expect(y['nulls'].list.map((d) => d.raw).toList(), [null, null, '']); // "" is text, not null
      expect(y['url'].raw, 'https://example.com/a:b#c');
      expect(y['multi'].raw, 'this is one plain scalar');
    });

    test('several documents, empty input, bad indentation', () {
      final stream = '---\na: 1\n---\nb: 2\n'.yaml;
      expect(stream.raw, {'a': 1}, reason: 'a stream reads as its first document');
      expect(Doc.parseAll('---\na: 1\n---\nb: 2\n', DocFormat.yaml).map((d) => d.raw), [
        {'a': 1},
        {'b': 2},
      ]);
      expect(Doc.parseAll('- 1', DocFormat.yaml), hasLength(1), reason: 'a one-item list is not a stream');
      expect(''.yaml.raw, isNull);
      expect(Doc.parseAll('', DocFormat.yaml), isEmpty);
      expect('- 1\n- 2'.yaml.raw, [1, 2]);
      expect(() => 'a:\n  b: 1\n c: 2'.yaml, throwsFormatException);
    });

    test('saved YAML round-trips through both parsers', () {
      final out = _yamlOf(doc.yaml);
      expect(_show(out.yaml.raw), _show(doc.yaml.raw));
      expect(_show(_plain(reference.loadYaml(out))), _show(doc.yaml.raw));
      expect(
        _yamlOf('{"a": "yes", "b": "1", "c": "x: y", "d": [1, {"e": null}]}'.json),
        'a: yes\nb: "1"\nc: "x: y"\nd:\n  - 1\n  - e: null\n', // YAML 1.2: yes is text, so it stays plain
      );
    });

    test('a flow mapping inside a sequence terminates; unterminated flow is a FormatException', () {
      expect(y('[a: 1]'), [
        {'a': 1},
      ]);
      expect(() => y('[a, b'), throwsFormatException);
      expect(y('f: ["[", x]\nnext: 1'), {
        'f': ['[', 'x'],
        'next': 1,
      });
      expect(y('x: &x 1\nl: [*x, 2]'), {
        'x': 1,
        'l': [1, 2],
      });
    });

    test('documents, directives, quotes, escapes, indentation', () {
      expect(Doc.parseAll('--- foo\n--- bar\n', DocFormat.yaml).map((d) => d.raw), ['foo', 'bar']);
      expect(y('%YAML 1.2\n---\na: 1\n'), {'a': 1});
      expect(y(r's: "x \" # y"'), {'s': 'x " # y'});
      expect(y('s: "multi\n  line"'), {'s': 'multi line'});
      expect(y('x: "a\\\n  b"'), {'x': 'ab'});
      expect(y('-   a: 1\n    b: 2'), [
        {'a': 1, 'b': 2},
      ]);
      expect(y(r's: "\U0001F600\b\e\N\_"'), {'s': '😀\b\x1b\u0085 '});
      expect(y('t: !!str 123'), {'t': '123'});
      expect(y('n: 12345678901234567890'), {'n': 12345678901234567890.0});
      expect(y('k${' ' * 20000}: v'), isA<Map<String, Object?>>());
      expect(y('a: !!str\nb: 1'), {'a': '', 'b': 1});
    });

    test('a lone CR ends a line, in YAML and in INI', () {
      expect('a: 1\rb: 2'.yaml.raw, {'a': 1, 'b': 2});
      expect('a=1\rb=2'.ini.raw, {'a': '1', 'b': '2'});
    });

    test('an apostrophe in a plain scalar does not swallow the comment', () {
      expect("name: don't # trailing\n".yaml['name'].to<String>(), "don't");
    });

    test('a duplicate key is an error, in block and flow', () {
      expect(
        () => 'a: 1\na: 2'.yaml,
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('"a" is defined twice'))),
      );
      expect(() => '{a: 1, a: 2}'.yaml, throwsFormatException);
    });

    test('an anchor before a key belongs to the key', () {
      expect('&a b: c\nd: *a'.yaml.raw, {'b': 'c', 'd': 'b'});
      expect('- &x k: v\n  j: w\n- *x'.yaml.raw, [
        {'k': 'v', 'j': 'w'},
        'k',
      ]);
    });

    test('text after a closing quote is an error', () {
      expect(() => 'a: "a" extra'.yaml, throwsFormatException);
      expect('a: "a" # comment'.yaml['a'].raw, 'a');
    });

    test('merge keys, one mapping or a list, with written keys winning', () {
      final d =
          '''
base: &b {x: 1, y: 2}
other: &o {y: 9, z: 3}
one:
  <<: *b
  y: 3
two:
  <<: [*b, *o]
  w: 0
flow: {<<: *o, z: 4}
'''
              .yaml;
      expect(d['one'].raw, {'x': 1, 'y': 3});
      expect(d['two'].raw, {'x': 1, 'y': 2, 'z': 3, 'w': 0});
      expect(d['flow'].raw, {'y': 9, 'z': 4});
      expect(() => 'a:\n  <<: 1'.yaml, throwsFormatException);
    });

    test('only a plain << merges, and saved YAML quotes a << key', () {
      final y = 'a: &a {x: 1}\nb:\n  "<<": *a\n  y: 2\nc: {"<<": 1}';
      expect(_plain(y.yaml.raw), _plain(reference.loadYaml(y)));
      expect(_yamlOf(Doc({'<<': 1})), '"<<": 1\n');
      expect(
        _yamlOf(
          Doc({
            '<<': {'a': 1},
          }),
        ).yaml.raw,
        {
          '<<': {'a': 1},
        },
      );
    });

    test('an anchored or tagged value takes items at its key\'s indent', () {
      for (final y in ['a: &x\n- 1\n- 2\nb: *x', 'a: !!seq\n- 1\nb: 2', '- &x\n- 1']) {
        expect(_plain(y.yaml.raw), _plain(reference.loadYaml(y)), reason: y);
      }
    });

    test('an alias bomb is refused', () {
      final b = StringBuffer('a: &a [x,x,x,x,x,x,x,x,x]\n');
      const ks = 'abcdefgh';
      for (var i = 1; i < ks.length; i++) {
        b.writeln('${ks[i]}: &${ks[i]} [${List.filled(9, '*${ks[i - 1]}').join(',')}]');
      }
      expect(() => b.toString().yaml, throwsFormatException);
      expect('a: &a [1, 2]\nb: *a\nc: *a'.yaml['c'].raw, [1, 2]);
    });

    test('a bad escape is a FormatException naming the line: exactly the hex digits, and no sign', () {
      for (final bad in [r'a: "\u-00e"', r'a: "\UFFFFFFFF"', r'a: "\x+1z"', r'a: "\u12"']) {
        expect(
          () => bad.yaml,
          throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('Invalid YAML, line 1: '))),
          reason: bad,
        );
      }
      expect(r'a: "\x41\u00e9"'.yaml['a'].raw, 'Aé');
    });

    test('nesting deeper than 1000 is a FormatException, not a stack overflow, in YAML and TOML', () {
      for (final deep in [
        '${'[' * 1200}${']' * 1200}',
        '- ' * 20000,
        List.generate(1200, (i) => '${' ' * i}-').join('\n'),
      ]) {
        expect(
          () => deep.yaml,
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('nested deeper than 1000'))),
        );
      }
      expect(() => 'a = ${'[' * 1200}${']' * 1200}'.toml, throwsFormatException);
      expect('a = ${'[' * 900}${']' * 900}'.toml['a'].raw, isA<List<Object?>>());
    });

    test('saved YAML quotes what would not read back', () {
      for (final v in [
        {'k': 'a #b'},
        ['a:'],
        {'k': 'x: y'},
        {'k': ' lead'},
        {'k': '- x'},
        for (final s in ['...', '---', '\x07bell', '\x85nel', '--- \nhello']) {'k': s},
      ]) {
        expect(_yamlOf(Doc(v)).yaml.raw, v, reason: '$v');
      }
    });

    test('a deep document is written on a stack, not the call stack (FMT-20)', () {
      Object? v = 1;
      for (var i = 0; i < 20000; i++) {
        v = i.isEven ? {'a': v} : [v];
      }
      final text = Doc(v).encode(DocFormat.yaml);
      expect(text.split('\n'), hasLength(greaterThan(10000)), reason: 'a map in a list shares its line');
      expect(
        Doc({
          'a': [
            {
              'b': [
                1,
                {'c': 2},
              ],
            },
          ],
        }).encode(DocFormat.yaml).yaml.raw,
        {
          'a': [
            {
              'b': [
                1,
                {'c': 2},
              ],
            },
          ],
        },
      );
    });

    test('a NaN is written as null in JSON', () {
      expect(jsonDecode('a: .nan\nb: [.inf, 1]'.yaml.encode(DocFormat.json)), {
        'a': null,
        'b': [null, 1],
      });
    });

    group('block scalars', () {
      test('a literal block keeps its interior blank lines', () {
        expect('text: |\n  a\n\n  b\n'.yaml['text'].to<String>(), 'a\n\nb\n');
      });

      test('a folded block folds breaks but keeps spacing inside a line', () {
        expect('text: >\n  a  b\n'.yaml['text'].to<String>(), 'a  b\n');
        expect('text: >\n  one\n  two\n'.yaml['text'].to<String>(), 'one two\n');
        expect('text: >\n  one\n\n  two\n'.yaml['text'].to<String>(), 'one\ntwo\n');
      });

      test('chomping: strip, clip and keep', () {
        expect('t: |-\n  a\n'.yaml['t'].to<String>(), 'a');
        expect('t: |\n  a\n'.yaml['t'].to<String>(), 'a\n');
        expect('t: |+\n  a\n\n'.yaml['t'].to<String>(), 'a\n\n');
      });

      test('an indentation indicator, leading blanks and more-indented folds', () {
        expect(y('a: |2\n    x\n'), {'a': '  x\n'});
        expect(y('a: |\n\n  lead\n'), {'a': '\nlead\n'});
        expect(y('a: >\n  one\n  two\n\n  three\n    more\n  four\n'), {'a': 'one two\nthree\n  more\nfour\n'});
      });

      test('trailing spaces stay, an empty block is empty; and +.Inf, a flow key\'s raw text and a ? key', () {
        final doc1 =
            '''
literal: |
  line 1  
  line 2  
folded: >
  line 1  
  line 2  
'''
                .yaml;
        expect(doc1['literal'].raw, 'line 1  \nline 2  \n');
        expect(doc1['folded'].raw, 'line 1 line 2\n');

        final emptyBlock = 'empty: |\nnext: 1'.yaml;
        expect(emptyBlock['empty'].raw, '');

        final inf = 'pos: +.Inf\npos_upper: +.INF'.yaml;
        expect(inf['pos'].raw, double.infinity);
        expect(inf['pos_upper'].raw, double.infinity);

        final flow = '{1.20: val}'.yaml;
        expect(flow.raw, {'1.20': 'val'});

        expect(() => '? a\n: 1'.yaml, throwsFormatException);
      });
    });
  });

  group('toml', () {
    test('dotted keys count toward the 1000-deep bound, as brackets do', () {
      final deep = List.filled(100000, 'a').join('.');
      expect(() => 'x = {$deep = 1}'.toml, _format(contains('nested deeper than 1000')));
      expect(() => '$deep = 1'.toml, _format(contains('nested deeper than 1000')));
      expect(() => '[$deep]'.toml, _format(contains('nested deeper than 1000')));
      expect(
        () => '[${List.filled(600, 'a').join('.')}]\n${List.filled(600, 'b').join('.')} = 1'.toml,
        throwsFormatException,
      );
      expect('${List.filled(900, 'a').join('.')} = 1'.toml.encode(DocFormat.json), isNotEmpty);
    });

    const doc = '''
# comment
title = "TOML \\u00e9 example"
literal = 'C:\\path'
multi = """
line one
line two\\
  continued"""
raw = \'\'\'
keep \\n here\'\'\'
int = 1_000
hex = 0xff
float = -3.5e2
inf = inf
bools = [true, false]
date = 1979-05-27T07:32:00Z
arr = [
  1, 2,
  3,
]
inline = { x = 1, y = "two", z = { deep = true } }
dotted.key.path = 42

[server]
host = "localhost"
port = 8080

[server.tls]
enabled = false

[[items]]
name = "a"
[[items]]
name = "b"
''';

    test('decodes tables, arrays of tables, strings, numbers and inline tables', () {
      final t = doc.toml;
      expect(t['title'].raw, 'TOML é example');
      expect(t['literal'].raw, r'C:\path');
      expect(t['multi'].raw, 'line one\nline twocontinued');
      expect(t['raw'].raw, r'keep \n here');
      expect(r'k = "a\\b\"\t"'.toml['k'].raw, 'a\\b"\t');
      expect(t['int'].raw, 1000);
      expect(t['hex'].raw, 255);
      expect(t['float'].raw, -350.0);
      expect(t['inf'].raw, double.infinity);
      expect(t['bools'].raw, [true, false]);
      expect(t['date'].raw, '1979-05-27T07:32:00Z');
      expect(t['arr'].raw, [1, 2, 3]);
      expect(t['inline']['z']['deep'].raw, true);
      expect(t['dotted']['key']['path'].raw, 42);
      expect(t['server']['port'].to<int>(), 8080);
      expect(t['server']['tls']['enabled'].raw, false);
      expect(t.$(r'$.items[*].name').to<List<String>>(), ['a', 'b']);
    });

    test('errors name the line', () {
      expect(
        () => 'a = 1\na = 2'.toml,
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('line 2'))),
      );
      expect(() => 'a = "open'.toml, throwsFormatException);
      expect(() => 'a = nope'.toml, throwsFormatException);
    });

    test('an integer past 64 bits is an error', () {
      expect(() => 'x = 12345678901234567890'.toml, throwsA(isA<FormatException>()));
    });

    test('numbers: signs, zero, exponents; a leading zero is an error', () {
      expect('a = 0\nb = +0\nc = -17\nd = +99\ne = 0.5\nf = -0.0\ng = 1e3\nh = 0b101\ni = 0o17'.toml.raw, {
        'a': 0,
        'b': 0,
        'c': -17,
        'd': 99,
        'e': 0.5,
        'f': -0.0,
        'g': 1000.0,
        'h': 5,
        'i': 15,
      });
      for (final bad in ['01', '+01', '-007', '01.5', '00e2', '+', '-', '1.', '.5']) {
        expect(() => 'x = $bad'.toml, throwsFormatException, reason: bad);
      }
    });

    test('leading zeros, stray underscores and malformed dates are errors', () {
      for (final bad in [
        'a = 0123',
        'a = 1__0',
        'a = _1',
        'a = 1_',
        'a = 1_.5',
        'a = 01.5',
        'd = 2024-01-01zzz',
        't = 12:30:00abc',
        'd = 2024-13-45',
        'u = 1e_5',
        'u = 1_e5',
        'u = 1.5_e3',
      ]) {
        expect(() => bad.toml, throwsFormatException, reason: bad);
      }
    });

    test('every valid number and date form reads', () {
      final doc =
          ('a = 1_000\nb = 0\nc = 0.5\nd = 0xdead_beef\ne = -0\nf = 1e5\ng = 1979-05-27\n'
                  'h = 1979-05-27T07:32:00Z\ni = 07:32:00\nj = 1979-05-27T00:32:00.999999-07:00')
              .toml;
      expect(doc['a'].raw, 1000);
      expect(doc['d'].raw, 0xdeadbeef);
      expect(doc['h'].raw, '1979-05-27T07:32:00Z');
      expect(doc['j'].raw, '1979-05-27T00:32:00.999999-07:00');
    });

    test('a backslash before a space is an error unless it ends a multi-line line', () {
      expect(() => r'a = "x\ y"'.toml, throwsFormatException);
      expect(() => r'a = """x\ y"""'.toml, throwsFormatException);
      expect('a = """x\\   \n   y"""'.toml['a'].raw, 'xy');
    });

    test('a bad escape is a FormatException naming the line', () {
      for (final bad in [r'a = "\', r'a = "\u00', r'a = "\U40001F600"', r'a = "\uD800"', r'a = "\uZZZZ"']) {
        expect(
          () => bad.toml,
          throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('Invalid TOML, line 1: '))),
          reason: bad,
        );
      }
      expect(r'a = "\u00e9\U0001F600"'.toml['a'].raw, 'é😀');
    });

    test('arrays need commas between elements', () {
      expect(() => 'a = ["x" "y"]'.toml, throwsFormatException);
      expect(() => 'a = [1\n2]'.toml, throwsFormatException);
      expect('a = ["x", "y"]'.toml['a'].raw, ['x', 'y']);
    });

    group('tables are defined once', () {
      test('an array of tables is only one [[a]] made', () {
        expect(() => 'a = [1]\n[[a]]'.toml, throwsFormatException);
        expect(() => 'a = 1\n[[a]]'.toml, throwsFormatException);
        expect('[[a]]\nx = 1\n[[a]]\nx = 2\n[a.b]\ny = 1'.toml.raw, {
          'a': [
            {'x': 1},
            {
              'x': 2,
              'b': {'y': 1},
            },
          ],
        });
      });

      test('redefining, and extending an inline table, are errors', () {
        for (final bad in [
          '[a]\n[a]',
          'a = {b = 1}\na.c = 2',
          'a.b = 1\n[a]',
          '[a.b]\nc = 1\n[a]\nb.d = 2',
          '[t]\nx = {y = 1}\n[t.x.z]',
        ]) {
          expect(() => bad.toml, throwsFormatException, reason: bad);
        }
        // A header's path may be defined by a later header, and a dotted table grown by one.
        expect('[a.b]\n[a]\nx = 1'.toml.raw, {
          'a': {'b': <String, Object?>{}, 'x': 1},
        });
        expect('[f]\napple.color = "r"\n[f.apple.texture]\ns = 1'.toml['f']['apple']['texture']['s'].raw, 1);
      });

      test('a date keeps its inner space and trailing spaces are not the value', () {
        expect('d = 1979-05-27 07:32:00Z   # c\nn = 1    '.toml.raw, {'d': '1979-05-27 07:32:00Z', 'n': 1});
      });
    });
  });

  group('ini', () {
    test('what would not read back as itself is not written: a FormatException naming where', () {
      for (final value in ['a\n# b', 'a\n; b', 'a\n\nb', '\nb', 'a\n  b', ' x\ny', 'a\rb', ''' it's "x"''']) {
        expect(
          () => Doc({'k': value}).encode(DocFormat.ini),
          _format(startsWith(r'Invalid INI at $.k:')),
          reason: value,
        );
      }
      for (final key in ['a.b', ';c', '#c', '[x', ' sp', '']) {
        expect(() => Doc({key: 1}).encode(DocFormat.ini), throwsFormatException, reason: key);
      }
      for (final value in ['a\nb', 'a\n[s]', ' lead', '"q"', 'x = y']) {
        expect(Doc({'k': value}).encode(DocFormat.ini).ini['k'].raw, value, reason: value);
      }
    });

    test('sections, comments, quotes, dotted keys; every value text (FMT-9)', () {
      final i =
          '''
; global
debug = true
name = "Key Box" ; trailing
[server]
host: localhost
port = 8080
[server.tls]
enabled = no
cert = 'a;b'
'''
              .ini;
      expect(i['debug'].raw, 'true');
      expect(i['debug'].to<bool>(), isTrue);
      expect(i['name'].raw, 'Key Box');
      expect(i['server']['host'].raw, 'localhost');
      expect(i['server']['port'].to<int>(), 8080);
      expect(i['server']['tls']['enabled'].raw, 'no');
      expect(i['server']['tls']['enabled'].to<bool>(), isFalse);
      expect(i['server']['tls']['cert'].raw, 'a;b');
    });

    test('text stays as written: no, none and numbers are text a reading types', () {
      final i = 'v = 1.10\nzip = 01234\nhex = 0x10\nn = NaN\nport = 8080\nf = 1.5\n[s] ; comment\nk = v'.ini;
      expect(i.raw, {
        'v': '1.10',
        'zip': '01234',
        'hex': '0x10',
        'n': 'NaN',
        'port': '8080',
        'f': '1.5',
        's': {'k': 'v'},
      });
      final c = 'country = no\nname = none\nempty =\nbare'.ini;
      expect(c['country'].raw, 'no', reason: 'a country code is not a bool');
      expect(c['name'].to<String>(), 'none');
      expect(c['empty'].to(or: 'x'), 'x');
      expect(c['bare'].raw, '');
      expect(() => 'a = 1\n[a]\nb = 2'.ini, throwsFormatException);
    });

    test('an indented line continues the value above it', () {
      final ini =
          '''
[options]
install_requires =
    requests
    urllib3
'''
              .ini;
      expect(ini['options']['install_requires'].raw, 'requests\nurllib3');
    });

    test('an indented [line] continues a value', () {
      expect('x =\n   [1, 2]\ny = 3'.ini.raw, {'x': '[1, 2]', 'y': '3'});
    });

    test('a key that is a table and then a value is a FormatException', () {
      expect(() => 'a.b = 1\na = 2'.ini, throwsFormatException);
    });

    group('properties files', () {
      test('a key that cannot nest stays whole', () {
        expect('log4j.appender.A1=X\nlog4j.appender.A1.layout=Y'.ini.raw, {
          'log4j': {
            'appender': {'A1': 'X'},
          },
          'log4j.appender.A1.layout': 'Y',
        });
        expect('a.b.c = 2\na.b = 1'.ini.raw, {
          'a': {
            'b': {'c': '2'},
          },
          'a.b': '1',
        });
      });

      test('a quoted part of a section name is one name', () {
        expect('["www.example.com"]\nk = v'.ini.raw, {
          'www.example.com': {'k': 'v'},
        });
        expect('[remote "a.b"]\nurl = x'.ini['remote']['a.b']['url'].raw, 'x');
        expect('[My Section]\nk = v'.ini['My Section']['k'].raw, 'v');
      });
    });
  });
}

/// package:yaml's YamlMap/YamlList as plain Dart, for comparison.
Object? _plain(Object? v) => switch (v) {
  reference.YamlMap() => {for (final e in v.entries) '${e.key}': _plain(e.value)},
  reference.YamlList() => [for (final e in v) _plain(e)],
  Map() => {for (final e in v.entries) '${e.key}': _plain(e.value)},
  List() => [for (final e in v) _plain(e)],
  _ => v,
};

/// A stable rendering; NaN never equals itself, so it is spelled out.
String _show(Object? v) => switch (v) {
  Map() => '{${v.entries.map((e) => '${e.key}: ${_show(e.value)}').join(', ')}}',
  List() => '[${v.map(_show).join(', ')}]',
  double() when v.isNaN => 'NaN',
  String() => '"$v"',
  _ => '$v',
};

/// [doc] as YAML, as `save('….yaml')` writes it.
String _yamlOf(Doc doc) => doc.encode(DocFormat.yaml);
