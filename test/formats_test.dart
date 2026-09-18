// ignore_for_file: experimental_member_use
import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/formats.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' as reference;

/// Every format decodes to a JsonDocument, so `$`, `[]` and `to<T>()` are the same for all.
void main() {
  group('yaml', () {
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

    test('matches package:yaml on the whole document', () {
      final ours = doc.yaml.raw;
      final theirs = _plain(reference.loadYaml(doc));
      expect(_show(ours), equals(_show(theirs)));
    });

    test('the query API is the JSON one', () {
      final y = doc.yaml;
      expect(y['name'].to<String>(), 'dart_toolkit');
      expect(y.$(r'$.dependencies.*').length, 2);
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
      expect('---\na: 1\n---\nb: 2\n'.yaml.raw, [
        {'a': 1},
        {'b': 2},
      ]);
      expect(''.yaml.raw, isNull);
      expect('- 1\n- 2'.yaml.raw, [1, 2]);
      expect(() => 'a:\n  b: 1\n c: 2'.yaml, throwsFormatException);
    });

    test('toYaml round-trips through both parsers', () {
      final out = doc.yaml.toYaml();
      expect(_show(out.yaml.raw), _show(doc.yaml.raw));
      expect(_show(_plain(reference.loadYaml(out))), _show(doc.yaml.raw));
      expect(
        '{"a": "yes", "b": "1", "c": "x: y", "d": [1, {"e": null}]}'.json.toYaml(),
        'a: "yes"\nb: "1"\nc: "x: y"\nd:\n  - 1\n  - e: null\n',
      );
    });
  });

  group('toml', () {
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
      expect(t.$(r'$.items[*].name').map((d) => d.raw).toList(), ['a', 'b']);
    });

    test('errors name the line', () {
      expect(
        () => 'a = 1\na = 2'.toml,
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('line 2'))),
      );
      expect(() => 'a = "open'.toml, throwsFormatException);
      expect(() => 'a = nope'.toml, throwsFormatException);
    });
  });

  group('ini', () {
    test('sections, comments, quotes, dotted keys, types', () {
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
      expect(i['debug'].raw, true);
      expect(i['name'].raw, 'Key Box');
      expect(i['server']['host'].raw, 'localhost');
      expect(i['server']['port'].to<int>(), 8080);
      expect(i['server']['tls']['enabled'].raw, false);
      expect(i['server']['tls']['cert'].raw, 'a;b');
    });
  });

  group('table formats', () {
    final t = Table.rows([
      {'name': 'a|b', 'n': 1},
      {'name': 'c', 'n': 20},
    ]);

    test('tsv, ndjson and markdown round-trip or render', () {
      expect(Table.tsv(t.toTsv()).rows, [
        {'name': 'a|b', 'n': '1'},
        {'name': 'c', 'n': '20'},
      ]);
      expect(t.toNdjson(), '{"name":"a|b","n":1}\n{"name":"c","n":20}\n');
      expect(Table.ndjson(t.toNdjson()).rows, t.rows);
      expect(t.toMarkdown(), '| name | n |\n| --- | ---: |\n| a\\|b | 1 |\n| c | 20 |\n');
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
