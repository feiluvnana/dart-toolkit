import 'dart:convert';
import 'dart:io' show Directory, PathNotFoundException;

import 'package:dart_toolkit/csv.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:test/test.dart';

import 'support/io.dart';

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

  test('encode round-trips', () {
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

  test('csv(or:) answers a missing source; without it a missing one throws', () async {
    final missing = Fs.file('${Directory.systemTemp.path}/no-such-dir-x9/seen.csv');
    expect(await missing.csv(or: const []), isEmpty);
    await expectLater(missing.csv(), throwsA(isA<PathNotFoundException>()));
  });
}

void streaming() {
  test('a blank line is no record (regression: became [""])', () {
    expect(Csv.parse('a,b\n\n1,2\r\n\r\n'), [
      ['a', 'b'],
      ['1', '2'],
    ]);
    expect(Csv.parse('a\n""\n'), [
      ['a'],
      [''],
    ]);
    expect(() => Csv.parse('a', sep: ''), throwsArgumentError);
  });

  test('encode writes a lone empty cell as "" so the row round-trips (B21)', () {
    expect(
      Csv.encode([
        ['a'],
        [''],
        [null],
        ['b'],
      ]),
      'a\r\n""\r\n""\r\nb\r\n',
    );
    expect(
      Csv.parse(
        Csv.encode([
          ['a'],
          [''],
          ['b'],
        ]),
      ),
      [
        ['a'],
        [''],
        ['b'],
      ],
    );
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

  test('response.rows() honours the charset like csv() (regression: always UTF-8)', () async {
    final (_, url) = await serve((r) {
      r.response
        ..headers.set('content-type', 'text/csv; charset=windows-1252')
        ..add(latin1.encode('caf\u00e9,1\r\n"a\r\nb",2\r\n'))
        ..close();
    });
    final http = Http.client();
    addTearDown(http.close);
    final want = [
      ['caf\u00e9', '1'],
      ['a\r\nb', '2'],
    ];
    expect(await http.get(url).csv(), want);
    expect(await http.get(url).rows().toList(), want);
  });
}

final class _Chunks with Reader {
  _Chunks(this._parts);
  final List<List<int>> _parts;
  @override
  Stream<List<int>> stream() => Stream.fromIterable(_parts);
}
