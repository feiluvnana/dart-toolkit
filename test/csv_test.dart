import 'dart:convert';

import 'package:dart_toolkit/csv.dart';
import 'package:test/test.dart';

void main() {
  streaming();
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

void streaming() {
  test('a blank line is no record (regression: became [""])', () {
    expect(Csv.parse('a,b\n\n1,2\r\n\r\n'), [
      ['a', 'b'],
      ['1', '2'],
    ]);
    expect(Csv.records('k\n\nv\n'), [
      {'k': 'v'},
    ]);
    expect(Csv.parse('a\n""\n'), [
      ['a'],
      [''],
    ]);
    expect(() => Csv.parse('a', sep: ''), throwsArgumentError);
  });

  test('reader.rows() streams rows across chunk boundaries', () async {
    const text = '﻿a,"b ""q"""\r\n"multi\nline",2\r\n\r\nx,y';
    final whole = Csv.parse(text);
    final bytes = utf8.encode(text);
    // Every split point: quotes, CRLF and the BOM may straddle chunks.
    for (var cut = 0; cut <= bytes.length; cut++) {
      final r = _Chunks([bytes.sublist(0, cut), bytes.sublist(cut)]);
      expect(await r.rows().toList(), whole, reason: 'cut at $cut');
    }
    expect(await Future<Reader>.value(Reader.of(utf8.encode('1;2'))).rows(sep: ';').toList(), [
      ['1', '2'],
    ]);
    await expectLater(_Chunks([utf8.encode('"open')]).rows().toList(), throwsA(isA<ContentException>()));
  });
}

final class _Chunks with Reader {
  _Chunks(this._parts);
  final List<List<int>> _parts;
  @override
  Stream<List<int>> stream() => Stream.fromIterable(_parts);
}
