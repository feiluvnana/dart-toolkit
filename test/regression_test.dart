import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// One test per bug the fourth audit reproduced, so each stays fixed.
void main() {
  group('core', () {
    test('to<num>() parses numeric strings like to<double>() does', () {
      expect(JsonDocument('3.5').to<num>(), equals(3.5));
      expect(JsonDocument('3.5').to<double>(), equals(3.5));
      expect(JsonDocument('7').to<int>(), equals(7));
      expect(JsonDocument({'a': 1}).to<String>(), equals('{"a":1}'));
    });

    test(r'$..[0] applies the bracket to every descendant', () {
      final j = JsonDocument({
        'a': [10, 20],
        'b': {
          'c': [30],
        },
      });
      expect(j.$(r'$..[0]').map((d) => d.raw), equals([10, 30]));
      expect(j.$(r'$..a[0]').map((d) => d.raw), equals([10]));
    });

    test(r'doc[-1] and $[-1] agree', () {
      final j = JsonDocument([1, 2, 3]);
      expect(j[-1].raw, equals(3));
      expect(j.$(r'$[-1]').first.raw, equals(3));
    });

    test('Either keeps the stack trace of the failure it caught', () async {
      final outcome = await Either.tryCatch(() async => _boom());
      try {
        outcome.unwrap();
        fail('should throw');
      } catch (_, st) {
        expect(st.toString(), contains('_boom'));
      }
    });
  });

  group('html', () {
    test('Element.lines decodes entities and splits at <br>', () {
      final doc = HtmlDocument.parse('<p id="x">A &amp; B &lt;c&gt;<br>D\nE<br></p>');
      expect(doc.$('#x').first.lines, equals(['A & B <c>', 'D', 'E']));
    });
  });

  group('http', () {
    test('Uri / joins a segment, treating the base as a directory', () {
      expect(('https://x.com/api'.url / 'users').toString(), equals('https://x.com/api/users'));
      expect(('https://x.com/api/'.url / 'users').toString(), equals('https://x.com/api/users'));
      expect(('https://x.com/api'.url / '/root').toString(), equals('https://x.com/root'));
    });

    test('leaving a downloadAll loop stops the transfers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var served = 0;
      server.listen((req) async {
        served++;
        req.response.headers.contentLength = 4;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        req.response.add([1, 2, 3, 4]);
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));
      final dir = Path(Directory.systemTemp.createTempSync('dl_break_').path);
      addTearDown(() => dir.delete(recursive: true));

      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      final pairs = [for (var i = 0; i < 12; i++) (url: base / '$i', path: dir / '$i.bin')];
      await for (final p in pairs.downloadAll(concurrency: 2)) {
        if (p.completed >= 1) break;
      }
      final atBreak = served;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(served, lessThanOrEqualTo(atBreak + 2), reason: 'only the in-flight requests may finish');
    });

    test('a session timeout fails a stalled server instead of hanging', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {}); // never answers
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/');
      await expectLater(
        Http.session(() => url.get(), timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('session headers reach every request that does not set them', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..write(req.headers.value('user-agent'))
          ..close();
      });
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/');
      final ua = await Http.session(() async => (await url.get()).text, headers: {'user-agent': 'toolkit-test'});
      expect(ua, equals('toolkit-test'));
    });
  });

  group('async', () {
    test('Stream.parallelize holds the source while the consumer is paused', () async {
      var produced = 0;
      final source = StreamController<int>();
      final out = source.stream
          .map((i) {
            produced++;
            return i;
          })
          .parallelize((i) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return i;
          }, concurrency: 2);
      final sub = out.listen((_) {});
      source
        ..add(1)
        ..add(2);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sub.pause();
      for (var i = 3; i <= 20; i++) {
        source.add(i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(produced, lessThanOrEqualTo(4), reason: 'nothing pulled on a paused consumer\'s behalf');
      sub.resume();
      await source.close();
      await sub.asFuture<void>();
      expect(produced, equals(20));
    });

    test('throttle rejects the combination that emits nothing', () {
      expect(() => Stream<int>.empty().throttle(1.ms, leading: false), throwsArgumentError);
    });
  });

  group('archive', () {
    test('extractToSync refuses an entry that escapes the destination', () async {
      final tmp = Path(Directory.systemTemp.createTempSync('zipslip_').path);
      addTearDown(() => tmp.delete(recursive: true));
      final zip = tmp / 'evil.zip';
      await zip.writeBytes(ZipEncoder().encode(Archive()..addFile(ArchiveFile.string('../evil.txt', 'pwned'))));
      expect(() => zip.extractToSync(tmp / 'dest'), throwsA(isA<FileSystemException>()));
      expect((tmp / 'evil.txt').existsSync(), isFalse);
    });
  });

  group('cli', () {
    test('a ✓ cell is one column wide, so table borders stay aligned', () {
      final buf = StringBuffer();
      ConsoleIo.out = buf;
      Ansi.enabled = false;
      try {
        Console.table(
          headers: ['a', 'b'],
          rows: [
            ['✓ ok', 'x'],
            ['plain', 'y'],
          ],
        );
      } finally {
        ConsoleIo.reset();
        Ansi.enabled = null;
      }
      final widths = buf.toString().trimRight().split('\n').map((l) => l.runes.length).toSet();
      expect(widths.length, equals(1));
    });

    test('Logger.warn goes to stderr with Logger.error', () {
      final err = StringBuffer();
      ConsoleIo.err = err;
      try {
        Logger.warn('careful');
      } finally {
        ConsoleIo.reset();
      }
      expect(err.toString(), contains('careful'));
    });
  });
}

Object _boom() => throw StateError('boom');
