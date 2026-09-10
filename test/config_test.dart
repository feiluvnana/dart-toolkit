import 'package:dart_toolkit/dart_toolkit.dart';
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
      // The reason JSON moved out of `util`: one family, one spelling.
      expect(format.json.parse('{"a":1}').number('a'), equals(1));
      expect(format.yaml.parse('a: 1').number('a'), equals(1));
      expect(format.toml.parse('a = 1').number('a'), equals(1));

      expect(format.json.format({'a': 1}, indent: 0), equals('{"a":1}'));
      expect(format.yaml.format({'a': 1}).trim(), equals('a: 1'));
      expect(format.toml.format({'a': 1}).trim(), equals('a = 1'));
    });

    test('all three read a file, and a missing one is empty', () async {
      final dir = io.temp('dt_formats_');
      try {
        io.write(io.join(dir.path, 'a.json'), '{"n": 1}');
        io.write(io.join(dir.path, 'a.yaml'), 'n: 1');
        io.write(io.join(dir.path, 'a.toml'), 'n = 1');

        expect(
          (await format.json.read(io.join(dir.path, 'a.json'))).number('n'),
          1,
        );
        expect(
          (await format.yaml.read(io.join(dir.path, 'a.yaml'))).number('n'),
          1,
        );
        expect(
          (await format.toml.read(io.join(dir.path, 'a.toml'))).number('n'),
          1,
        );

        for (final ext in const ['json', 'yaml', 'toml']) {
          final missing = io.join(dir.path, 'absent.$ext');
          final doc = switch (ext) {
            'json' => await format.json.read(missing),
            'yaml' => await format.yaml.read(missing),
            _ => await format.toml.read(missing),
          };
          expect(doc.empty, isTrue, reason: ext);
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('tool holds formats only, never an executable', () {
      // `tool.git`, `tool.gh` and `tool.docker` were all tried and removed:
      // wrapping a binary is `system.run` plus arguments, and a script that
      // wants one already has the whole of it there.
      expect(format.zip, isA<ZipAccessor>());
      expect(format.json, isA<JsonAccessor>());
      expect(format.yaml, isA<YamlAccessor>());
      expect(format.toml, isA<TomlAccessor>());
    });
  });

  group('format.yaml', () {
    test('parse gives the same cursor JSON does', () {
      final doc = format.yaml.parse(_yaml);
      expect(doc.text('name'), equals('dart_toolkit'));
      expect(doc.text('version'), equals('3.2.0'));
      expect(doc.text('environment.sdk'), equals('^3.7.0'));
      expect(doc.at('dependencies').texts().list, equals(['html', 'http']));
      expect(doc.flag('flags.strict'), isTrue);
      expect(doc.number('flags.retries'), equals(3));
      expect(doc.at('notes').empty, isTrue);
    });

    test('the cursor holds plain maps, so it re-encodes as JSON', () {
      final doc = format.yaml.parse(_yaml);
      expect(doc.raw, isA<Map<String, Object?>>());
      expect(format.json.format(doc.raw, indent: 0), contains('"name"'));
    });

    test('jsonpath works over a YAML document too', () {
      expect(
        format.yaml.parse(_yaml).jsonpath(r'$..sdk').sift((n) => n.text()).list,
        equals(['^3.7.0']),
      );
    });

    test('text that is not YAML is the empty cursor', () {
      expect(format.yaml.parse('a:\n b\n  - c: :').empty, isTrue);
    });

    test('format writes block style, quoting what would read back wrong', () {
      final text = format.yaml.format({
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
      final back = format.yaml.parse(text);
      expect(back.text('version'), equals('1.0'));
      expect(back.text('on'), equals('yes'));
      expect(back.number('nested.deep.x'), equals(1));
    });

    test('read is the file door, and a missing file is empty', () async {
      final dir = io.temp('dt_yaml_');
      try {
        final path = io.join(dir.path, 'c.yaml');
        io.write(path, _yaml);
        expect(
          (await format.yaml.read(path)).text('name'),
          equals('dart_toolkit'),
        );
        expect(
          (await format.yaml.read(io.join(dir.path, 'absent.yaml'))).empty,
          isTrue,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('it reads this repository own pubspec', () async {
      final pubspec = await format.yaml.read('pubspec.yaml');
      expect(pubspec.text('name'), equals('dart_toolkit'));
      expect(pubspec.at('dependencies').count, greaterThan(3));
    });
  });

  group('format.toml', () {
    test('parse, spelled the same as yaml', () {
      final doc = format.toml.parse(_toml);
      expect(doc.text('package.name'), equals('widget'));
      expect(doc.text('package.version'), equals('1.4.2'));
      expect(doc.text('dependencies.serde'), equals('1.0'));
      expect(doc.text('bin[0].name'), equals('widget'));
    });

    test('text that is not TOML is the empty cursor', () {
      expect(format.toml.parse('[[[not toml').empty, isTrue);
    });

    test('format writes a document back, and refuses a non-map', () {
      final text = format.toml.format({
        'package': {'name': 'widget', 'version': '1.0.0'},
      });
      expect(format.toml.parse(text).text('package.name'), equals('widget'));
      // A non-map used to come back as an empty string, so
      // `io.write(path, format.toml.format(rows))` wrote a blank file and
      // reported success. Reading gives the empty cursor; writing throws.
      expect(
        () => format.toml.format(['not', 'a', 'map']),
        throwsArgumentError,
      );
      expect(() => format.toml.format('scalar'), throwsArgumentError);
      expect(() => format.toml.format(null), throwsArgumentError);
    });

    test('read is the file door, and a missing file is empty', () async {
      final dir = io.temp('dt_toml_');
      try {
        final path = io.join(dir.path, 'Cargo.toml');
        io.write(path, _toml);
        expect(
          (await format.toml.read(path)).text('package.name'),
          equals('widget'),
        );
        expect(
          (await format.toml.read(io.join(dir.path, 'absent.toml'))).empty,
          isTrue,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
