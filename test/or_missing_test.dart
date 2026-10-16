// AUDIT E4: on a response, a 404 or 410 is the missing source for every
// whole-value reading's `or:` (json yaml html csv cookies), with or without
// `check:`; other statuses and failures still reach the caller.
import 'dart:io';

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/utils.dart';
import 'package:dart_toolkit/yaml.dart';
import 'package:test/test.dart';

import 'support/io.dart';

void main() {
  late String base;
  setUp(() async {
    (_, base) = await serve((req) {
      final status = switch (req.uri.path) {
        '/404' => 404,
        '/410' => 410,
        '/500' => 500,
        _ => 200,
      };
      req.response
        ..statusCode = status
        ..write(status == 200 ? '{"a": 1}' : '{"error": "nope"}')
        ..close();
    });
  });

  final fallback = Json.of('fallback');

  for (final check in [false, true]) {
    group('check: $check', () {
      late Client c;
      setUp(() => c = Http.client(base: base, check: check, retries: 0));
      tearDown(() => c.close());

      for (final gone in ['/404', '/410']) {
        test('$gone gives or: for json yaml html csv cookies', () async {
          expect(await c.get(gone).json(or: fallback), fallback);
          expect(await c.get(gone).yaml(or: fallback), fallback);
          expect((await c.get(gone).html(or: Html.parse('<p>none'))).text(), 'none');
          expect(await c.get(gone).csv(or: [['x']]), [['x']]);
          final none = Cookies();
          expect(await c.get(gone).cookies(or: none), same(none));
        });
      }

      test('a 200 reads its body with or: given', () async {
        expect((await c.get('/ok').json(or: fallback)).$('a').value<int>(), 1);
      });

      test('a (& probe) chain reads or: on a 404 too', () async {
        expect(await (c.get('/404') & null).json(or: fallback), fallback);
      });
    });
  }

  test('without or:, a 404 body is still the data when the client does not check', () async {
    final c = Http.client(base: base, check: false, retries: 0);
    addTearDown(c.close);
    expect((await (await c.get('/404')).json()).$('error').text(), 'nope');
  });

  test('a 500 is not missing: check: throws through or:', () async {
    final c = Http.client(base: base, retries: 0); // check: by default
    addTearDown(c.close);
    await expectLater(c.get('/500').json(or: fallback), throwsA(isA<HttpStatusException>()));
  });

  test('a missing file gives or: for every reading', () async {
    final f = Fs.file('${Directory.systemTemp.path}/dart_toolkit_missing_${pid}_none');
    expect(await f.json(or: fallback), fallback);
    expect(await f.yaml(or: fallback), fallback);
    expect((await f.html(or: Html.parse('<p>none'))).text(), 'none');
    expect(await f.csv(or: [['x']]), [['x']]);
    expect(await f.text(or: 'x'), 'x');
    expect(await f.bytes(or: [1]), [1]);
  });
}
