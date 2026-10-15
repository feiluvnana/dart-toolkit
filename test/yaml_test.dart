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

  test('an alias bomb or deep nesting is a ContentException, quickly', () {
    var bomb = 'a0: &a0 [x, x, x, x, x, x, x, x, x, x]\n';
    for (var i = 1; i < 9; i++) {
      bomb += 'a$i: &a$i [${List.filled(10, '*a${i - 1}').join(', ')}]\n';
    }
    final sw = Stopwatch()..start();
    expect(
      () => Yaml.parse(bomb),
      throwsA(isA<ContentException>().having((e) => e.message, 'message', contains('aliases'))),
    );
    expect(sw.elapsedMilliseconds, lessThan(2000)); // was 36 s and GBs
    expect(() => Yaml.parse('${'[' * 20000}${']' * 20000}'), throwsA(isA<ContentException>()));
    expect(Yaml.parse('a: &x [1, 2]\nb: *x').$('b').length, 2); // ordinary aliases still resolve
  });
}
