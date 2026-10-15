import 'package:dart_toolkit/csv.dart';
import 'package:test/test.dart';

void main() {
  test('parse: quotes, "" escapes, CRLF and LF, embedded newlines, BOM', () {
    expect(Csv.parse('﻿a,b\r\n"x, y","say ""hi"""\n"two\nlines",\n'), [
      ['a', 'b'],
      ['x, y', 'say "hi"'],
      ['two\nlines', ''],
    ]);
    expect(Csv.parse(''), isEmpty);
    expect(Csv.parse('a;b', sep: ';'), [
      ['a', 'b'],
    ]);
    expect(Csv.parse('""'), [
      [''],
    ]);
  });

  test('an unterminated quote is a ContentException; a bad sep an ArgumentError', () {
    expect(() => Csv.parse('"open'), throwsA(isA<ContentException>()));
    expect(() => Csv.parse('a', sep: '"'), throwsArgumentError);
  });

  test('records key rows by the header; encode round-trips', () {
    expect(Csv.records('name,n\nann,1\nbob\n'), [
      {'name': 'ann', 'n': '1'},
      {'name': 'bob'},
    ]);
    final rows = [
      ['a,b', 'q"', null, ' pad', 3],
      ['line\nbreak', '', 'x', 'y', 1.5],
    ];
    final text = Csv.encode(rows);
    expect(text, '"a,b","q""",," pad",3\r\n"line\nbreak",,x,y,1.5\r\n');
    expect(Csv.parse(text), [
      for (final r in rows) [for (final c in r) '${c ?? ''}'],
    ]);
  });

  test('reader.csv() parses any Reader', () async {
    expect(await Reader.of('a,b\n1,2'.codeUnits).csv(), [
      ['a', 'b'],
      ['1', '2'],
    ]);
  });
}
