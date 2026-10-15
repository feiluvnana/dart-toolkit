import 'package:dart_toolkit/yaml.dart';
import 'package:test/test.dart';

void main() {
  test('a document reads like Json: maps, lists, scalars, anchors', () {
    final doc = Yaml.parse('''
name: app
version: 1.2.3
base: &b {retries: 2}
jobs:
  test: {settings: *b, steps: [a, b]}
  1: numeric key
''');
    expect(doc.$('version').text(), '1.2.3');
    expect(doc.$('jobs.test.steps').asList<String>(), ['a', 'b']);
    expect(doc.$('jobs.test.settings.retries').or(0), 2);
    expect(doc.$('jobs.1').text(), 'numeric key');
  });

  test('a parse error is a ContentException naming the line', () {
    expect(
      () => Yaml.parse('a: [1, 2\nb: c', from: 'ci.yml'),
      throwsA(
        isA<ContentException>().having((e) => e.message, 'message', startsWith('invalid YAML in ci.yml at line')),
      ),
    );
  });

  test('reader.yaml() with or: for a missing source', () async {
    expect((await Reader.of('k: v'.codeUnits).yaml()).$('k').text(), 'v');
  });
}
