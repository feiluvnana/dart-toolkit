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

  test('a parse error is a ContentException naming the source and line', () async {
    expect(
      () => Yaml.parse('a: 1\nb: [1, 2\nc: d'),
      throwsA(isA<ContentException>().having((e) => e.message, 'message', startsWith('invalid YAML at line 3'))),
    );
    await expectLater(
      _Src('a: b: c', const Origin(path: 'ci.yml')).yaml(),
      throwsA(
        isA<ContentException>().having((e) => e.message, 'message', startsWith('invalid YAML in ci.yml at line 1')),
      ),
    );
  });

  test('a URL source is redacted in the error (regression: token shown)', () async {
    await expectLater(
      _Src('a: [', const Origin(url: 'https://u:p@x.com/c.yml?token=T')).yaml(),
      throwsA(
        isA<ContentException>().having(
          (e) => e.message,
          'message',
          allOf(startsWith('invalid YAML in https://x.com/c.yml?token=***'), isNot(contains('u:p'))),
        ),
      ),
    );
  });

  test('a multi-document stream reads its first document (regression: threw)', () {
    expect(Yaml.parse('a: 1\n---\nb: 2\n').$('a').or(0), 1);
    expect(Yaml.parse('--- \nfirst: 1\n...\n---\nsecond: [').$('first').or(0), 1);
    expect(Yaml.parse('%YAML 1.2\n---\nk: v').$('k').text(), 'v');
    expect(Yaml.parse('').value<Object>(), isNull);
    expect(Yaml.parse('# only a comment\n').value<Object>(), isNull);
  });

  test('core schema scalars, quoting and tags', () {
    final d = Yaml.parse('''
n: [~, null, Null, NULL]
b: [true, False, TRUE, yes]
i: [12, -3, +4, 0x1F, 0o17, 012]
f: [1.5, .5, 1e3, -.inf, 1.]
s: ["12", '0x1F', !!str 7, ! 8, 2001-12-14, 1.2.3]
t: [!!int "42", !!float 1]
''');
    expect(d.$('n').map((e) => e.value<Object>()), [null, null, null, null]);
    expect(d.$('b').map((e) => e.value<Object>()), [true, false, true, 'yes']);
    expect(d.$('i').asList<int>(), [12, -3, 4, 31, 15, 12]);
    expect(d.$('f').map((e) => e.value<double>()), [1.5, 0.5, 1000.0, double.negativeInfinity, 1.0]);
    expect(d.$('s').asList<String>(), ['12', '0x1F', '7', '8', '2001-12-14', '1.2.3']);
    expect(d.$('t').asList<num>(), [42, 1.0]);
  });

  test('block scalars: literal, folded, chomping, indentation', () {
    final d = Yaml.parse('''
lit: |
  a
   b

  c
fold: >
  one
  two

  three
    more
  four
strip: |-
  x

keep: |+
  y

ind: |2
    two extra
  base
seq:
  - |
    in a list
end: 1
''');
    expect(d.$('lit').text(), 'a\n b\n\nc\n');
    expect(d.$('fold').text(), 'one two\nthree\n  more\nfour\n');
    expect(d.$('strip').text(), 'x');
    expect(d.$('keep').text(), 'y\n\n');
    expect(d.$('ind').text(), '  two extra\nbase\n');
    expect(d.$('seq.0').text(), 'in a list\n');
    expect(d.$('end').or(0), 1);
  });

  test('flow collections, quoted folding, escapes, comments, complex keys', () {
    final d = Yaml.parse('''
flow: {a: [1, {b: c}], 'd': "e", f, "g":2}   # comment
multi: [a, b
  c, d]
pairs: [k: v, x]
dq: "tab\\t \\u00e9 \\x41 \\
  joined"
sq: 'it''s
  folded

  para'
plain: this is
  folded # not part
url: http://e.com:8080/x#frag
? [a, b]
: seq key
''');
    expect(d.$('flow.a.1.b').text(), 'c');
    expect(d.$('flow.d').text(), 'e');
    expect(d.$('flow').asMap<Object?>()['f'], isNull);
    expect(d.$('flow.g').or(0), 2);
    expect(d.$('multi').asList<String>(), ['a', 'b c', 'd']);
    expect(d.$('pairs.0.k').text(), 'v');
    expect(d.$('dq').text(), 'tab\t é A joined');
    expect(d.$('sq').text(), "it's folded\npara");
    expect(d.$('plain').text(), 'this is folded');
    expect(d.$('url').text(), 'http://e.com:8080/x#frag');
    expect(d.$(r'[a, b]').text(), 'seq key');
  });

  test('block structure: compact nesting, sequences under keys, CRLF', () {
    final d = Yaml.parse('key:\r\n- a\r\n- b: 1\r\n  c: 2\r\n- - x\r\n  - y\r\nother:\r\n  deep:\r\n    v: 3\r\n');
    expect(d.$('key.0').text(), 'a');
    expect(d.$('key.1.c').or(0), 2);
    expect(d.$('key.2').asList<String>(), ['x', 'y']);
    expect(d.$('other.deep.v').or(0), 3);
  });

  test('syntax errors name the line: duplicates, tabs, bad indentation, aliases', () {
    void bad(String text, int line, String what) => expect(
      () => Yaml.parse(text),
      throwsA(
        isA<ContentException>().having((e) => e.message, 'message', allOf(contains('line $line'), contains(what))),
      ),
      reason: text,
    );
    bad('a: 1\na: 2', 2, 'duplicate');
    bad('a:\n\t- b', 2, 'tab');
    bad('a: 1\n  b: 2', 2, '":"');
    bad('a: *nope', 1, 'alias');
    bad('a: "open', 1, 'unterminated');
    bad('x: @y', 1, '"@"');
    bad('a: "\\q"', 1, 'escape');
    // B6: exactly n hex digits (int.parse took a sign); no lone surrogate.
    bad(r'a: "\x+1"', 1, 'escape');
    bad(r'a: "\u 041"', 1, 'escape');
    bad(r'a: "\ud83d"', 1, 'surrogate');
    bad(r'a: "\ude00"', 1, 'surrogate');
    bad(r'a: "\ud83d\u0041"', 1, 'surrogate');
  });

  test('B6: a surrogate pair escape is one code point', () {
    expect(Yaml.parse(r'a: "\ud83d\ude00 \x41\u00e9"').$('a').text(), '\u{1F600} A\u00e9');
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

  test('a one-line flow document (minified JSON) parses in linear time (B6)', () {
    String doc(int n) => '[${List.generate(n, (i) => '{"id": $i, "name": "item $i", "tags": ["a", "b"]}').join(', ')}]';
    final small = doc(1000), big = doc(4000);
    Yaml.parse(small); // warm up
    final sw = Stopwatch()..start();
    expect(Yaml.parse(small).length, 1000);
    final t1 = sw.elapsedMicroseconds;
    sw.reset();
    expect(Yaml.parse(big).length, 4000);
    final t4 = sw.elapsedMicroseconds;
    expect(t4, lessThan(t1 * 9 + 20000), reason: '4x the input took ${t4 / t1}x the time'); // quadratic: 16x
    expect(t4, lessThan(1000000)); // was 7 s at 230 KB
  });
}

final class _Src with Reader {
  _Src(this._text, this._origin);
  final String _text;
  final Origin _origin;
  @override
  Origin origin() => _origin;
  @override
  Stream<List<int>> stream() => Stream.value(_text.codeUnits);
}
