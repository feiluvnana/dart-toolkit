// How the parts plug together: every producer gives a value, a Task, a Batch or a
// Stream, and every consumer takes them, across modules.
import 'dart:io';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/process.dart';
import 'package:dart_toolkit/torrent.dart';
import 'package:dart_toolkit/tui.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

void main() {
  group('conversions on String', () {
    test('text becomes the library type it names', () {
      expect('{"hello": "world"}'.json['hello'].to<String>(), 'world');
      expect('hello: world\nnumber: 42'.yaml['number'].to<int>(), 42);
      expect('title = "T"'.toml['title'].to<String>(), 'T');
      expect('[s]\nkey = val'.ini['s']['key'].to<String>(), 'val');
      expect('<a href="/x">y</a>'.html.$('a').texts, ['y']);
      expect('https://a.b/c'.url.host, 'a.b');
      expect('a/b.txt'.path.name, 'b.txt');
      expect('42'.to<int>(), 42);
      expect(Bencode.decode('d4:spami42ee'.codeUnits), {'spam': 42});
      expect(Torrent.parse('magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=Test').name, 'Test');
    });

    test('checked text goes wherever its text does', () async {
      final dir = tempDir();
      await (dir / 'a.mp3').writeText('');
      expect([await for (final f in dir.files(only: '*.mp3'.glob)) f.name], ['a.mp3']);
      expect('<p><a>x</a></p>'.html.$('p a'.css).texts, ['x']);
      expect(Hash.sha256.text('hello').matches(Hash.sha256.text('hello').hex.hex), isTrue);
    });
  });

  group('a Task from any module', () {
    test('awaits as its value, settles without throwing, and joins parallelize', () async {
      final dir = tempDir();
      final files = [
        for (final n in ['a', 'b', 'c']) await (dir / '$n.txt').writeText(n),
      ];
      final digests = await files.parallelize((f) => Hash.sha256.file(f)).toMap();
      expect(digests.values.map((d) => d.hex), [
        for (final n in ['a', 'b', 'c']) Hash.sha256.text(n).hex,
      ]);
      expect(await (dir / 'missing').readText().then((_) => 'read', onError: (Object e) => '$e'), contains('missing'));
      expect(await Shell.run('dart --version').settled, isA<Done<Object?, ShellResult>>());
    });

    test('a save works on the Future of any Saveable', () async {
      final dir = tempDir();
      final saved = await Future.value('{"a": 1}'.json).save('$dir/out.json');
      expect((await Doc.read(saved))['a'].to<int>(), 1);
    });

    test('the result of one stage feeds the next: archive, then unarchive, then hash', () async {
      final dir = tempDir();
      await (dir / 'src').mkdir();
      await (dir / 'src' / 'f.txt').writeText('x');
      final zip = await (dir / 'src').archive(to: '$dir/src.zip');
      final out = await zip.unarchive(into: '$dir/out');
      final back = await (out / 'f.txt').readText();
      expect(back, 'x');
    });
  });

  group('a Batch from any module', () {
    test('a pool maps like parallelize, and a display takes its tally', () async {
      final pool = Pool(_Echo.new, concurrency: 2);
      addTearDown(pool.close);
      final batch = pool.map([1, 2, 3]);
      final tally = Tally.batch(batch);
      expect(await batch, [1, 2, 3]);
      await batch.settled;
      expect(tally.count, 3);
      expect(Board(tally).render(40), isNotEmpty);
    });

    test('Http.scope holds until a batch started inside it has finished (X-17)', () async {
      final fake = Client.fake((request) => Response('ok ${request.url.path}', 200));
      final pages = await Http.scope(
        () => [
          for (final p in ['/a', '/b']) Uri.parse('https://x.test$p'),
        ].parallelize((u) => u.get().text),
        client: fake,
      );
      expect(pages, ['ok /a', 'ok /b']);
    });
  });

  group('the shared model', () {
    test('a Status from any producer reads the same in a switch', () async {
      final statuses = await [1]
          .parallelize(
            (i) => Task.run('t', (work) {
              work.amount(1, total: 2, unit: Unit.items);
              return i;
            }),
          )
          .settled;
      final words = [
        for (final s in statuses)
          switch (s) {
            Done(:final value, fresh: true) => 'got $value',
            Done() => 'had it',
            Failed(:final error) => 'failed: $error',
            Stopped(:final reason) || Skipped(:final reason) => reason,
            Running() || Waiting() || Paused() || Warned() => 'busy',
          },
      ];
      expect(words, ['got 1']);
    });

    test('one Palette themes both UIs', () {
      const palette = Palette.ascii;
      expect(const ConsoleTheme(palette: palette).palette, palette);
      expect(const TuiTheme(palette: palette).palette, palette);
    });

    test('Path statics need only core', () async {
      expect(await Path.cwd.exists(), isTrue);
      expect(await Path.temp.isDir(), isTrue);
      expect(await Path.tempDir((dir) async => (dir / 'x').writeText('ok').then((f) => f.exists())), isTrue);
      expect(Directory(Path.home).existsSync(), isTrue);
    });
  });
}

final class _Echo extends Worker<int, int> {
  @override
  int run(int item, Work work) => item;
}
