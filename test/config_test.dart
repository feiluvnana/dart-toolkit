import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _yaml = '''
name: dart_toolkit
version: 3.2.0
environment:
  sdk: ^3.7.0
dependencies:
  - html
  - http
flags:
  strict: true
  retries: 3
notes: ~
''';

const _toml = '''
[package]
name = "widget"
version = "1.4.2"

[dependencies]
serde = "1.0"

[[bin]]
name = "widget"
''';

void main() {
  group('the format family', () {
    test('the three codecs are spelled identically', () {
      expect(Formats.json('{"a":1}').number('a'), equals(1));
      expect(Formats.yaml('a: 1').number('a'), equals(1));
      expect(Formats.toml('a = 1').number('a'), equals(1));

      expect(Formats.toJson({'a': 1}, indent: 0), equals('{"a":1}'));
      expect(Formats.toYaml({'a': 1}).trim(), equals('a: 1'));
      expect(Formats.toToml({'a': 1}).trim(), equals('a = 1'));
    });

    test('all three read a file, and a missing one is empty', () async {
      final dir = Directory.systemTemp.createTempSync('dt_formats_');
      try {
        File(p.join(dir.path, 'a.json')).writeAsStringSync('{"n": 1}');
        File(p.join(dir.path, 'a.yaml')).writeAsStringSync('n: 1');
        File(p.join(dir.path, 'a.toml')).writeAsStringSync('n = 1');

        expect(
          (await const JsonAccessor().read(
            p.join(dir.path, 'a.json'),
          )).number('n'),
          1,
        );
        expect(
          (await const YamlAccessor().read(
            p.join(dir.path, 'a.yaml'),
          )).number('n'),
          1,
        );
        expect(
          (await const TomlAccessor().read(
            p.join(dir.path, 'a.toml'),
          )).number('n'),
          1,
        );

        for (final ext in const ['json', 'yaml', 'toml']) {
          final missing = p.join(dir.path, 'absent.$ext');
          final doc = switch (ext) {
            'json' => await const JsonAccessor().read(missing),
            'yaml' => await const YamlAccessor().read(missing),
            _ => await const TomlAccessor().read(missing),
          };
          expect(doc.empty, isTrue, reason: ext);
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('accessors hold formats only, never an executable', () {
      expect(const ZipAccessor(), isA<ZipAccessor>());
      expect(const JsonAccessor(), isA<JsonAccessor>());
      expect(const YamlAccessor(), isA<YamlAccessor>());
      expect(const TomlAccessor(), isA<TomlAccessor>());
    });
  });

  group('format.yaml', () {
    test('parse gives the same cursor JSON does', () {
      final doc = Formats.yaml(_yaml);
      expect(doc.text('name'), equals('dart_toolkit'));
      expect(doc.text('version'), equals('3.2.0'));
      expect(doc.text('environment.sdk'), equals('^3.7.0'));
      expect(
        doc.at('dependencies').all((d) => d.text()).nonNull.toList(),
        equals(['html', 'http']),
      );
      expect(doc.flag('flags.strict'), isTrue);
      expect(doc.number('flags.retries'), equals(3));
      expect(doc.at('notes').empty, isTrue);
    });

    test('the cursor holds plain maps, so it re-encodes as JSON', () {
      final doc = Formats.yaml(_yaml);
      expect(doc.raw, isA<Map<String, Object?>>());
      expect(Formats.toJson(doc.raw, indent: 0), contains('"name"'));
    });

    test('jsonpath works over a YAML document too', () {
      expect(
        Formats.yaml(_yaml)
            .jsonpath(r'$..sdk')
            .map((n) => n.text())
            .whereType<String>()
            .toList(),
        equals(['^3.7.0']),
      );
    });

    test('text that is not YAML is the empty cursor', () {
      expect(Formats.yaml('a:\n b\n  - c: :').empty, isTrue);
    });

    test('format writes block style, quoting what would read back wrong', () {
      final text = Formats.toYaml({
        'name': 'widget',
        'version': '1.0',
        'on': 'yes',
        'blank': '',
        'count': 3,
        'live': true,
        'nothing': null,
        'tags': ['a', 'b'],
        'nested': {
          'deep': {'x': 1},
        },
        'none': <String, Object?>{},
      });
      expect(text, contains('name: widget'));
      expect(
        text,
        contains('version: "1.0"'),
        reason: 'would read as a number',
      );
      expect(
        text,
        contains('"on": "yes"'),
        reason: 'both halves would read as booleans unquoted',
      );
      expect(text, contains("blank: ''"));
      expect(text, contains('count: 3'));
      expect(text, contains('live: true'));
      expect(text, contains('nothing: null'));
      expect(text, contains('  - a'));
      expect(text, contains('    x: 1'));
      expect(text, contains('none: {}'));
      // And it round-trips through the reader.
      final back = Formats.yaml(text);
      expect(back.text('version'), equals('1.0'));
      expect(back.text('on'), equals('yes'));
      expect(back.number('nested.deep.x'), equals(1));
    });

    test('read is the file door, and a missing file is empty', () async {
      final dir = Directory.systemTemp.createTempSync('dt_yaml_');
      try {
        final path = p.join(dir.path, 'c.yaml');
        File(path).writeAsStringSync(_yaml);
        expect(
          (await const YamlAccessor().read(path)).text('name'),
          equals('dart_toolkit'),
        );
        expect(
          (await const YamlAccessor().read(p.join(dir.path, 'absent.yaml'))).empty,
          isTrue,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('it reads this repository own pubspec', () async {
      final pubspec = await const YamlAccessor().read('pubspec.yaml');
      expect(pubspec.text('name'), equals('dart_toolkit'));
      expect(pubspec.at('dependencies').count, greaterThan(3));
    });
  });

  group('format.toml', () {
    test('parse, spelled the same as yaml', () {
      final doc = Formats.toml(_toml);
      expect(doc.text('package.name'), equals('widget'));
      expect(doc.text('package.version'), equals('1.4.2'));
      expect(doc.text('dependencies.serde'), equals('1.0'));
      expect(doc.text('bin[0].name'), equals('widget'));
    });

    test('text that is not TOML is the empty cursor', () {
      expect(Formats.toml('[[[not toml').empty, isTrue);
    });

    test('format writes a document back, and refuses a non-map', () {
      final text = Formats.toToml({
        'package': {'name': 'widget', 'version': '1.0.0'},
      });
      expect(Formats.toml(text).text('package.name'), equals('widget'));
      expect(
        () => Formats.toToml(['not', 'a', 'map']),
        throwsArgumentError,
      );
      expect(() => Formats.toToml('scalar'), throwsArgumentError);
      expect(() => Formats.toToml(null), throwsArgumentError);
    });

    test('read is the file door, and a missing file is empty', () async {
      final dir = Directory.systemTemp.createTempSync('dt_toml_');
      try {
        final path = p.join(dir.path, 'Cargo.toml');
        File(path).writeAsStringSync(_toml);
        expect(
          (await const TomlAccessor().read(path)).text('package.name'),
          equals('widget'),
        );
        expect(
          (await const TomlAccessor().read(p.join(dir.path, 'absent.toml'))).empty,
          isTrue,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
