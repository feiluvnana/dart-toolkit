/// Proves the claim the README makes about co-imports.
///
/// Through 8.1.0 this package put `get`, `post`, `put`, `patch`, `delete`,
/// `head`, `readBytes` and `Response` in global scope, and the README
/// instructed readers to write an eight-name `hide` clause to import
/// `package:http` beside it. One name is left.
library;

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' hide Response;
import 'package:test/test.dart';

void main() {
  test(
    'imports beside package:http and package:collection with one hide',
    () async {
      // package:http's names are untouched by this package now.
      expect(Client, isNotNull);
      expect(IterableExtensions([3, 1, 2]).sorted(), [1, 2, 3]);
      expect([3, 1, 2].chunk(2).length, 2);

      final dir = SyncPath.tempDir('interop_');
      try {
        final file = dir / 'a.json';
        await file.writeJson({'n': 1});
        expect((await file.readJson()).number('n'), 1);
        expect(file.ext, '.json');
        expect(await file.hash(.md5), isNotEmpty);

        final res = Response.text(
          '<h1>Hi</h1>',
          fetch: Fetch('https://x.test'.url),
        );
        expect(res.$('h1').text, 'Hi');
        expect(res.pick(.text('h1')), 'Hi');
      } finally {
        dir.sync.delete();
      }
    },
  );
}
