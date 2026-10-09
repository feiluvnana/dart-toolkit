import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/native.dart';
import 'package:dart_toolkit/scrape.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

/// Answers a ranged GET of [body] as a server that takes ranges does, with [etag].
void _ranged(HttpRequest r, List<int> body, {String etag = '"v1"'}) {
  final range = r.headers.value('range');
  r.response.headers
    ..set('etag', etag)
    ..set('accept-ranges', 'bytes');
  final match = range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
  final ifRange = r.headers.value('if-range');
  if (match == null || (ifRange != null && ifRange != etag)) {
    r.response
      ..contentLength = body.length
      ..add(body);
    return;
  }
  final from = int.parse(match[1]!);
  final to = match[2]!.isEmpty ? body.length - 1 : int.parse(match[2]!);
  r.response
    ..statusCode = 206
    ..headers.set('content-range', 'bytes $from-$to/${body.length}')
    ..contentLength = to - from + 1
    ..add(body.sublist(from, to + 1));
}

void main() {
  late String dir;
  setUp(() => dir = tempDir());

  group('a download', () {
    test('is a Task of the file written, named by its folder and name', () async {
      final (_, base) = await serve((r) => r.response.write('payload'));
      final task = (base / 'a').download(to: '$dir/sub/one.txt');
      expect(task.label, 'sub/one.txt');
      expect(await task, '$dir/sub/one.txt');
      expect(File('$dir/sub/one.txt').readAsStringSync(), 'payload');
      expect(File('$dir/sub/one.txt.part').existsSync(), isFalse);
    });

    test('takes exactly one of to: and into:, and checks its settings at the call', () {
      final url = Uri.parse('http://x/a');
      expect(() => url.download(), throwsArgumentError);
      expect(() => url.download(to: 'a', into: 'b'), throwsArgumentError);
      expect(() => url.download(to: 'a', segments: 0), throwsArgumentError);
      expect(() => url.download(to: 'a', accept: 'image'), throwsArgumentError);
      expect(() => Checksum(Hash.sha256, 'not hex'), throwsFormatException);
    });

    test('a non-2xx is a StatusException, and nothing is left behind', () async {
      final (_, base) = await serve((r) {
        r.response
          ..statusCode = 404
          ..write('gone');
      });
      await expectLater(
        (base / 'gone').download(to: '$dir/gone'),
        throwsA(isA<StatusException>().having((e) => e.response.text, 'body', 'gone')),
      );
      expect(Directory(dir).listSync(), isEmpty);
    });

    test('takes its modified time from Last-Modified', () async {
      final (_, base) = await serve((r) {
        r.response.headers.set('last-modified', 'Wed, 21 Oct 2015 07:28:00 GMT');
        r.response.write('x');
      });
      final file = await (base / 'a').download(to: '$dir/a');
      expect(File(file).lastModifiedSync().toUtc(), DateTime.utc(2015, 10, 21, 7, 28));
    });

    test('never exists half-written under its own name', () async {
      final seen = <bool>[];
      final (_, base) = await serve((r) async {
        r.response.contentLength = 2;
        r.response.write('a');
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        seen.add(File('$dir/f').existsSync());
        r.response.write('b');
      });
      await (base / 'f').download(to: '$dir/f');
      expect(seen, [false]);
      expect(File('$dir/f').readAsStringSync(), 'ab');
    });
  });

  group('into: a folder', () {
    test('the name is the server\'s: Content-Disposition, then the URL that answered', () async {
      final (_, base) = await serve((r) {
        switch (r.uri.path) {
          case '/export':
            r.response.headers.set('content-disposition', 'attachment; filename="report ${r.uri.query}.csv"');
          case '/moved':
            r.response
              ..statusCode = 302
              ..headers.set('location', '/files/real.bin');
            return;
        }
        r.response.write('x');
      });
      expect(await (base / 'export?id=1').download(into: dir), '$dir/report id=1.csv');
      expect(await (base / 'export?id=2').download(into: dir), '$dir/report id=2.csv');
      expect(await (base / 'moved').download(into: dir), '$dir/real.bin');
    });

    test('a URL with a query string is asked, never skipped on the URL\'s name', () async {
      // The regression: `export?id=1` and `?id=2` both "skipped" to one unrelated file `export`.
      var asked = 0;
      final (_, base) = await serve((r) {
        asked++;
        r.response.headers.set('content-disposition', 'attachment; filename="${r.uri.queryParameters['id']}.csv"');
        r.response.write('x');
      });
      File('$dir/export').writeAsStringSync('unrelated');
      await (base / 'export?id=1').download(into: dir);
      expect(asked, 1);
      expect(File('$dir/1.csv').existsSync(), isTrue);
    });

    test('a URL naming no file, answered with no name, is a MissingException', () async {
      final (_, base) = await serve((r) => r.response.write('x'));
      await expectLater(base.download(into: dir), throwsA(isA<MissingException>()));
    });
  });

  group('conflict', () {
    late Uri base;
    var asked = 0;
    setUp(() async {
      asked = 0;
      (_, base) = await serve((r) {
        asked++;
        if (r.headers.value('if-modified-since') case final since?) {
          if (HttpDate.parse(since).isAfter(DateTime.utc(2020))) {
            r.response.statusCode = 304;
            return;
          }
        }
        r.response.headers.set('last-modified', 'Wed, 01 Jan 2020 00:00:00 GMT');
        r.response.write('new');
      });
    });

    test('skip, the default, leaves a file there unasked: Done(fresh: false)', () async {
      File('$dir/a.txt').writeAsStringSync('old');
      final task = (base / 'a.txt').download(into: dir);
      final settled = await task.settled;
      expect(settled, isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse));
      expect(asked, 0);
      expect(File('$dir/a.txt').readAsStringSync(), 'old');
    });

    test('overwrite replaces, rename writes beside, fail refuses', () async {
      File('$dir/a.txt').writeAsStringSync('old');
      await (base / 'a.txt').download(to: '$dir/a.txt', conflict: Conflict.overwrite);
      expect(File('$dir/a.txt').readAsStringSync(), 'new');
      expect(await (base / 'a.txt').download(to: '$dir/a.txt', conflict: Conflict.rename), '$dir/a (1).txt');
      await expectLater(
        (base / 'a.txt').download(to: '$dir/a.txt', conflict: Conflict.fail),
        throwsA(isA<PathExistsException>()),
      );
    });

    test('newer asks the server: a 304 is Done(fresh: false), a newer file replaces', () async {
      final file = File('$dir/a.txt')..writeAsStringSync('old');
      file.setLastModifiedSync(DateTime.utc(2021));
      final kept = await (base / 'a.txt').download(to: file.path, conflict: Conflict.newer).settled;
      expect(kept, isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse));
      expect(file.readAsStringSync(), 'old');
      file.setLastModifiedSync(DateTime.utc(2019));
      await (base / 'a.txt').download(to: file.path, conflict: Conflict.newer);
      expect(file.readAsStringSync(), 'new');
    });

    test('two downloads wanting one name get the policy\'s answer, not an error', () async {
      // The regression: the second of two URLs the server gives one name failed.
      final (_, same) = await serve((r) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        r.response.headers.set('content-disposition', 'attachment; filename="same.txt"');
        r.response.write(r.uri.path);
      });
      final files = await [same / 'a', same / 'b'].parallelize((u) => u.download(into: dir, conflict: Conflict.rename));
      expect(files.toSet(), {'$dir/same.txt', '$dir/same (1).txt'});
      expect({for (final f in files) File(f).readAsStringSync()}, {'/a', '/b'});
    });
  });

  group('what was asked for', () {
    test('an HTML page where the name says otherwise is a FormatException, unless it is .html', () async {
      final (_, base) = await serve((r) {
        r.response.headers.contentType = ContentType.html;
        r.response.write('<html>error</html>');
      });
      await expectLater(
        (base / 'report.pdf').download(to: '$dir/report.pdf'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('HTML'))),
      );
      expect(File('$dir/report.pdf').existsSync(), isFalse);
      expect(await (base / 'page.html').download(into: dir), '$dir/page.html');
    });

    test('accept: is the media type the answer must be', () async {
      final (_, base) = await serve((r) {
        r.response.headers.contentType = r.uri.path.endsWith('png') ? ContentType('image', 'png') : ContentType.text;
        r.response.write('x');
      });
      expect(await (base / 'a.png').download(into: dir, accept: 'image/'), '$dir/a.png');
      await expectLater((base / 'b.txt').download(into: dir, accept: 'image/'), throwsFormatException);
    });

    test('a checksum is verified as the step verifying; a wrong one fails and leaves nothing', () async {
      if (await Native.check() case final check when !check.isAvailable) return markTestSkipped('$check');
      final (_, base) = await serve((r) => r.response.write('payload'));
      final good = Hash.sha256.text('payload').hex;
      final task = (base / 'f').download(to: '$dir/f', checksum: Checksum(Hash.sha256, good.toUpperCase()));
      final steps = task.statuses
          .map(
            (s) => switch (s) {
              Running(:final step) => step,
              _ => null,
            },
          )
          .toList();
      await task;
      expect(await steps, contains('verifying'));
      await expectLater(
        (base / 'g').download(to: '$dir/g', checksum: Checksum(Hash.sha256, '00' * 32)),
        throwsA(isA<ChecksumException>().having((e) => e, 'is a FormatException', isA<FormatException>())),
      );
      expect(File('$dir/g').existsSync(), isFalse);
      expect(File('$dir/g.part').existsSync(), isFalse);
    });
  });

  group('resuming', () {
    final body = List.generate(100000, (i) => i % 253);

    test('a cut transfer keeps its .part, and the next run carries on with a Range', () async {
      var n = 0;
      final ranges = <String?>[];
      final (_, base) = await serve((r) async {
        ranges.add(r.headers.value('range'));
        if (n++ == 0) return cut(r, body.sublist(0, 30000), length: body.length);
        _ranged(r, body);
      });
      final to = '$dir/f.bin';
      await Http.scope(retry: Retry.none, () async {
        await expectLater((base / 'f').download(to: to), throwsA(anything));
      });
      expect(File('$to.part').lengthSync(), 30000);
      await (base / 'f').download(to: to);
      expect(ranges, [null, 'bytes=30000-']);
      expect(File(to).readAsBytesSync(), body);
    });

    test('the scope\'s retry carries one call on from where the cut left it, a retry step shown', () async {
      var n = 0;
      final ranges = <String?>[];
      final (_, base) = await serve((r) async {
        ranges.add(r.headers.value('range'));
        if (n++ == 0) return cut(r, body.sublist(0, 30000), length: body.length);
        _ranged(r, body);
      });
      final steps = await Http.scope(retry: const Retry(2, backoff: Duration(milliseconds: 1)), () async {
        final download = (base / 'f').download(to: '$dir/f');
        final steps = download.statuses
            .map(
              (s) => switch (s) {
                Running(:final step) => step,
                _ => null,
              },
            )
            .toList();
        await download;
        return steps;
      });
      expect(steps, contains('retry 1/2'));
      expect(ranges, [null, 'bytes=30000-']);
      expect(File('$dir/f').readAsBytesSync(), body);
    });

    test('a file that changed is fetched again whole, never spliced', () async {
      var n = 0;
      final v2 = List.filled(100000, 0x42);
      final (_, base) = await serve((r) async {
        if (n++ == 0) return cut(r, body.sublist(0, 40000), length: body.length);
        _ranged(r, v2, etag: '"v2"');
      });
      await Http.scope(retry: Retry.none, () async {
        await expectLater((base / 'f').download(to: '$dir/f'), throwsA(anything));
      });
      await (base / 'f').download(to: '$dir/f');
      expect(File('$dir/f').readAsBytesSync(), v2);
      expect(File('$dir/f.part.if-range').existsSync(), isFalse);
    });

    test('a 416 for a part that is already the whole file completes it', () async {
      final (_, base) = await serve((r) {
        r.response
          ..statusCode = 416
          ..headers.set('content-range', 'bytes */${body.length}');
      });
      File('$dir/h.part').writeAsBytesSync(body);
      await (base / 'h').download(to: '$dir/h');
      expect(File('$dir/h').readAsBytesSync(), body);
    });

    test('a stopped download keeps its .part, or deletes it with resume: false', () async {
      // Ten bytes of a hundred, then silence: written on the socket, past dart:io's buffering.
      final (_, base) = await serve((r) async {
        r.response.contentLength = 100;
        final socket = await r.response.detachSocket();
        socket.add(List.filled(10, 1));
        await socket.flush();
        await Future<void>.delayed(const Duration(seconds: 2));
        socket.destroy();
      });
      for (final resume in [true, false]) {
        final to = '$dir/$resume.bin';
        final task = (base / 'x').download(to: to, resume: resume);
        await task.statuses.firstWhere(
          (s) => switch (s) {
            Running(:final received) => received > 0,
            _ => false,
          },
        );
        task.cancel('enough');
        expect(await task.settled, isA<Stopped<Object?, Path>>());
        expect(File('$to.part').existsSync(), resume, reason: 'resume: $resume');
      }
    });
  });

  group('segments', () {
    final file = Uint8List.fromList([for (var i = 0; i < (3 << 20) + 123; i++) (i * 31 + i ~/ 7) & 0xff]);

    test('a ranged file comes in parts, into one file', () async {
      final asked = <String>[];
      final (_, base) = await serve((r) {
        asked.add(r.headers.value('range') ?? 'all');
        _ranged(r, file);
      });
      await (base / 'f.bin').download(to: '$dir/f.bin', segments: 3);
      expect(File('$dir/f.bin').readAsBytesSync(), file);
      expect(asked.where((a) => a.startsWith('bytes=')), hasLength(2), reason: 'the first answer is the first part');
      expect(File('$dir/f.bin.part.ranges').existsSync(), isFalse);
    });

    test('a server without ranges is one stream', () async {
      final (_, base) = await serve((r) => r.response.add(file));
      await (base / 'f.bin').download(to: '$dir/f.bin', segments: 3);
      expect(File('$dir/f.bin').readAsBytesSync(), file);
    });
  });

  group('many', () {
    test('are parallelize, each its own row; a rerun skips what is there', () async {
      var asked = 0;
      final (_, base) = await serve((r) {
        asked++;
        r.response.write(r.uri.path);
      });
      final urls = [for (var i = 0; i < 5; i++) base / 'f$i.txt'];
      final files = await urls.parallelize((u) => u.download(into: dir));
      expect(files, [for (var i = 0; i < 5; i++) '$dir/f$i.txt']);
      final again = await urls.parallelize((u) => u.download(into: dir)).settled;
      expect(
        again.every(
          (s) => switch (s) {
            Done(:final fresh) => !fresh,
            _ => false,
          },
        ),
        isTrue,
      );
      expect(asked, 5);
    });

    test('straight from a crawl\'s items', () async {
      final (_, base) = await serve((r) {
        if (r.uri.path == '/') {
          r.response.headers.contentType = ContentType.html;
          r.response.write('<a href="/a.bin">a</a><a href="/b.bin">b</a>');
        } else {
          r.response.write(r.uri.path);
        }
      });
      final crawl = base.crawl<Uri>(onResponse: (c) => c.html.$('a').links.forEach(c.emit));
      final files = await crawl.items.parallelize((u) => u.download(into: dir));
      expect(files.toSet(), {'$dir/a.bin', '$dir/b.bin'});
    });
  });

  test('a paused job keeps its download\'s part for later; a removed one leaves nothing', () async {
    final started = Completer<void>();
    final (_, base) = await serve((r) async {
      r.response
        ..contentLength = 1 << 20
        ..headers.set('etag', '"v1"');
      r.response.add(Uint8List(1024));
      await r.response.flush();
      if (!started.isCompleted) started.complete();
      await Future<void>.delayed(const Duration(seconds: 30));
    });
    final dir = tempDir();
    final pool = Pool(() => _Fetch(dir), concurrency: 2);
    addTearDown(pool.close);
    Future<void> partShows(String name) async {
      for (var i = 0; i < 100 && !File('$dir/$name.part').existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    final paused = pool.add(base.resolve('kept.bin'));
    await started.future;
    await partShows('kept.bin');
    paused.pause();
    await paused.statuses.firstWhere((s) => s is Paused);
    expect(File('$dir/kept.bin.part').existsSync(), isTrue, reason: 'a pause keeps the part');

    final removed = pool.add(base.resolve('gone.bin'));
    await partShows('gone.bin');
    removed.remove();
    await removed.settled;
    expect(File('$dir/gone.bin.part').existsSync(), isFalse, reason: 'a removal forgets the part');
  });
}

final class _Fetch extends Worker<Uri, Path> {
  final String dir;
  _Fetch(this.dir);

  @override
  Future<Path> run(Uri item, Work work) => item.download(into: dir);
}
