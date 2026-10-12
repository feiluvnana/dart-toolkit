import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

/// A one-shot in-memory [Source] (not a file: its bytes cannot be re-read
/// through a second reader — every reader streams the same bytes anew, but a
/// consumed stream retry would lose them).
final class _BytesSource implements Source {
  final Uint8List bytes;
  _BytesSource(this.bytes);

  @override
  int? get lengthHint => bytes.length;

  @override
  Future<Reader> reader({int from = 0}) async => _BytesReader(bytes.sublist(from));
}

final class _BytesReader implements Reader {
  final Uint8List _bytes;
  int _pos = 0;
  _BytesReader(this._bytes);

  @override
  Future<int> read(Uint8List buf) async {
    if (_pos >= _bytes.length) return 0;
    final n = buf.length < _bytes.length - _pos ? buf.length : _bytes.length - _pos;
    buf.setRange(0, n, _bytes, _pos);
    _pos += n;
    return n;
  }

  @override
  Future<void> close() async {}
}

void main() {
  late io.HttpServer server;
  late List<int> big;
  var flakyHits = 0;
  var flakyPostHits = 0;
  var flakyStreamHits = 0;
  var retryAfterHits = 0;
  final missingPorts = <int>{};
  final helloPorts = <int>{};
  String? lastRange;
  String? lastContentType;
  String? lastBody;
  List<int>? lastBodyBytes;

  setUp(() async {
    big = List.generate(1000, (i) => i & 0xFF);
    flakyHits = 0;
    flakyPostHits = 0;
    flakyStreamHits = 0;
    retryAfterHits = 0;
    missingPorts.clear();
    helloPorts.clear();
    lastRange = lastContentType = lastBody = null;
    lastBodyBytes = null;
    server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/echo') {
        final body = await request.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        lastBodyBytes = body;
        try {
          lastBody = utf8.decode(body);
        } catch (_) {
          lastBody = null;
        }
        lastContentType = request.headers.value('content-type');
        request.response
          ..statusCode = 200
          ..write('ok');
        await request.response.close();
        return;
      }
      if (request.method == 'POST' && path == '/flaky-post') {
        flakyPostHits++;
        await request.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        if (flakyPostHits == 1) {
          request.response.statusCode = 503;
          request.response.write('try again');
        } else {
          request.response.write('recovered');
        }
        await request.response.close();
        return;
      }
      if (request.method == 'POST' && path == '/flaky-stream') {
        flakyStreamHits++;
        await request.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        request.response.statusCode = 503;
        request.response.write('flaky');
        await request.response.close();
        return;
      }
      switch (path) {
        case '/hello':
          helloPorts.add(request.connectionInfo?.remotePort ?? -1);
          request.response.headers.contentType = io.ContentType.text;
          request.response.write('hello');
        case '/missing':
          missingPorts.add(request.connectionInfo?.remotePort ?? -1);
          request.response.statusCode = 404;
          request.response.write('nope');
        case '/big':
          // A resumable file: answers the rest from the Range start.
          lastRange = request.headers.value('range');
          if (lastRange case final range?) {
            final start = int.parse(range.split('=')[1].split('-')[0]);
            request.response.statusCode = 206;
            request.response.headers.set('content-range', 'bytes $start-999/1000');
            request.response.add(big.sublist(start));
          } else {
            request.response.add(big);
          }
        case '/big-full':
          // No resume support: always the whole body, Range or not.
          lastRange = request.headers.value('range');
          request.response.add(big);
        case '/flaky':
          flakyHits++;
          if (flakyHits == 1) {
            request.response.statusCode = 503;
            request.response.write('try again');
          } else {
            request.response.write('recovered');
          }
        case '/retry-after':
          retryAfterHits++;
          if (retryAfterHits == 1) {
            request.response.statusCode = 503;
            request.response.headers.set('retry-after', '1');
            request.response.write('slow down');
          } else {
            request.response.write('recovered');
          }
        case '/hop':
          request.response.statusCode = 302;
          request.response.headers.set('location', '/final?q=1');
        case '/final':
          request.response.write('done');
        case '/stall':
          // Headers and two body bytes now, the rest after 4 s: a 1 s timeout
          // must fire on the stalled body, not complete late.
          try {
            request.response.headers.contentLength = 10;
            request.response.write('hi');
            await request.response.flush();
            await Future<void>.delayed(const Duration(seconds: 4));
            request.response.write('12345678');
            await request.response.close();
          } catch (_) {
            // The client is long gone: nothing left to answer.
          }
          return;
        case '/enc':
          request.response.headers.set('content-encoding', 'gzip');
          request.response.headers.contentLength = 100;
          request.response.write('x' * 100);
        case '/euckr-header':
          request.response.headers.contentType = io.ContentType('text', 'html', charset: 'euc-kr');
          request.response.add([0xC7, 0xD1, 0xB1, 0xDB]); // '한글' in EUC-KR
        case '/sjis-header':
          request.response.headers.contentType = io.ContentType('text', 'html', charset: 'shift_jis');
          request.response.add([0x83, 0x65, 0x83, 0x58, 0x83, 0x67]); // 'テスト' in Shift_JIS
        case '/euckr-meta':
          request.response.headers.set('content-type', 'text/html');
          request.response.add([
            ...utf8.encode('<html><head><meta charset="euc-kr"></head><body>'),
            0xC7,
            0xD1,
            0xB1,
            0xDB,
            ...utf8.encode('</body></html>'),
          ]);
        case '/sjis-meta':
          request.response.headers.set('content-type', 'text/html');
          request.response.add([
            ...utf8.encode('<html><head><meta charset="shift_jis"></head><body>'),
            0x83,
            0x65,
            0x83,
            0x58,
            0x83,
            0x67,
            ...utf8.encode('</body></html>'),
          ]);
        case '/resume416':
          // The whole 1000-byte file is already held: 416 with its total.
          lastRange = request.headers.value('range');
          request.response.statusCode = 416;
          request.response.headers.set('content-range', 'bytes */1000');
        case '/resume-shift':
          // Lies about the offset: the rest starts at 100, not the asked 400.
          lastRange = request.headers.value('range');
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 100-1099/1100');
          request.response.add(List.filled(1000, 7));
        default:
          request.response.statusCode = 404;
          request.response.write('nope');
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String url(String path) => 'http://${server.address.host}:${server.port}$path';

  test('Http.get(u).text() with one await: 200 gives the body', () async {
    expect(await Http.get(url('/hello')).text(), 'hello');
  });

  test('await Http.get(u) gives the Response: status and headers, nothing read yet', () async {
    final resp = await Http.get(url('/hello'));
    expect(resp.status, 200);
    expect(resp.header('content-type'), contains('text/plain'));
    expect(await resp.text(), 'hello');
  });

  test('a non-2xx text() throws HttpException with the status', () async {
    await expectLater(
      Http.get(url('/missing')).text(),
      throwsA(isA<HttpException>().having((e) => e.status, 'status', 404)),
    );
  });

  test('pipe(file, resume: true) asks for the rest with Range', () async {
    final dir = await Dir.temp();
    try {
      final file = dir.file('big.bin');
      await file.write(big.sublist(0, 400));
      final n = await Http.get(url('/big')).pipe(file, resume: true);
      expect(n, 600);
      expect(lastRange, 'bytes=400-');
      expect(await file.bytes(), big);
    } finally {
      await dir.drop();
    }
  });

  test('resume against a server that answers 200 throws HttpException', () async {
    final dir = await Dir.temp();
    try {
      final file = dir.file('big.bin');
      await file.write(big.sublist(0, 400));
      await expectLater(
        Http.get(url('/big-full')).pipe(file, resume: true),
        throwsA(isA<HttpException>().having((e) => e.status, 'status', 200)),
      );
    } finally {
      await dir.drop();
    }
  });

  test('post(form:) sends fields as form content', () async {
    final resp = await Http.post(url('/echo'), form: {'a': '1'});
    expect(resp.status, 200);
    await resp.close();
    expect(lastContentType, contains('application/x-www-form-urlencoded'));
    expect(lastBody, 'a=1');
  });

  test('post(body: File) uploads identical bytes', () async {
    final dir = await Dir.temp();
    try {
      final file = dir.file('up.bin');
      await file.write(big);
      final resp = await Http.post(url('/echo'), body: file);
      expect(resp.status, 200);
      await resp.close();
      expect(lastBodyBytes, big);
    } finally {
      await dir.drop();
    }
  });

  test('more than one body parameter is an ArgumentError', () {
    expect(() => Http.post('http://127.0.0.1/', json: 1, form: {}), throwsArgumentError);
  });

  test('a 503 then 200 is retried', () async {
    expect(await Http.get(url('/flaky')).text(), 'recovered');
    expect(flakyHits, 2);
  });

  group('timeouts, retries, reads, redirects and resume', () {
    test('a body stall throws TimeoutException, not HttpException', () async {
      await expectLater(
        Http.get(url('/stall'), timeout: const Duration(seconds: 1)).text(),
        throwsA(isA<TimeoutException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('error messages name the URL once', () async {
      try {
        await Http.get(url('/missing')).text();
        fail('must throw');
      } on HttpException catch (e) {
        expect(e.toString().split(url('/missing')).length, 2);
      }
    });

    test('a POST is not retried without retry:', () async {
      await expectLater(
        Http.post(url('/flaky-post'), json: {'a': 1}).text(),
        throwsA(isA<HttpException>().having((e) => e.status, 'status', 503)),
      );
      expect(flakyPostHits, 1);
    });

    test('a POST retries with retry: passed explicitly', () async {
      expect(await Http.post(url('/flaky-post'), json: {'a': 1}, retry: 2).text(), 'recovered');
      expect(flakyPostHits, 2);
    });

    test('a POST with a file body retries: the body re-reads', () async {
      final dir = await Dir.temp();
      try {
        final file = dir.file('up.bin');
        await file.write(big);
        expect(await Http.post(url('/flaky-post'), body: file).text(), 'recovered');
        expect(flakyPostHits, 2);
      } finally {
        await dir.drop();
      }
    });

    test('a consumed stream body never retries', () async {
      await expectLater(
        Http.post(url('/flaky-stream'), body: _BytesSource(Uint8List.fromList(big))).text(),
        throwsA(isA<HttpException>().having((e) => e.status, 'status', 503)),
      );
      expect(flakyStreamHits, 1);
    });

    test('Retry-After delays the retry', () async {
      final watch = Stopwatch()..start();
      expect(await Http.get(url('/retry-after')).text(), 'recovered');
      expect(retryAfterHits, 2);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(800));
    });

    test('a second reader() on a request throws StateError', () async {
      final req = Http.get(url('/hello'));
      expect(await req.text(), 'hello');
      await expectLater(req.reader(), throwsStateError);
    });

    test('a second reader() on a response throws StateError', () async {
      final resp = await Http.get(url('/hello'));
      expect(await resp.bytes(), utf8.encode('hello'));
      await expectLater(resp.reader(), throwsStateError);
      await resp.close();
    });

    test('awaited-but-unread non-2xx responses share the kept-alive socket', () async {
      final resps = <Response>[];
      for (var i = 0; i < 20; i++) {
        final resp = await Http.get(url('/missing'));
        expect(resp.ok, isFalse);
        resps.add(resp); // kept referenced: no GC/finalizer may hide a leak
      }
      // Released on status, pooled by the shared client: no new socket each time.
      expect(missingPorts.length, lessThanOrEqualTo(2));
      for (final resp in resps) {
        await resp.close();
      }
    });

    test('redirect hops resolve: url is absolute', () async {
      final resp = await Http.get(url('/hop'));
      try {
        expect(resp.url, '${url('/final')}?q=1');
        expect(await resp.text(), 'done');
      } finally {
        await resp.close();
      }
    });

    test('resuming a complete file copies nothing on a 416', () async {
      final dir = await Dir.temp();
      try {
        final file = dir.file('full.bin');
        await file.write(List.generate(1000, (i) => i & 0xFF));
        expect(await Http.get(url('/resume416')).pipe(file, resume: true), 0);
        expect(lastRange, 'bytes=1000-');
        expect(await file.bytes(), List.generate(1000, (i) => i & 0xFF));
      } finally {
        await dir.drop();
      }
    });

    test('a 206 from the wrong offset throws HttpException', () async {
      final dir = await Dir.temp();
      try {
        final file = dir.file('part.bin');
        await file.write(List.generate(400, (i) => i & 0xFF));
        await expectLater(Http.get(url('/resume-shift')).pipe(file, resume: true), throwsA(isA<HttpException>()));
      } finally {
        await dir.drop();
      }
    });

    test('lengthHint is null under a content-encoding', () async {
      final resp = await Http.get(url('/enc'));
      try {
        expect(resp.lengthHint, isNull);
      } finally {
        await resp.close();
      }
    });

    test('sequential GETs share one kept-alive socket', () async {
      for (var i = 0; i < 50; i++) {
        expect(await Http.get(url('/hello')).text(), 'hello');
      }
      expect(helloPorts.length, lessThanOrEqualTo(2));
    });

    test('bodies decode in their declared charset, header or meta', () async {
      expect(await Http.get(url('/euckr-header')).text(), '한글');
      expect(await Http.get(url('/sjis-header')).text(), 'テスト');
      expect(await Http.get(url('/euckr-meta')).text(), contains('한글'));
      expect(await Http.get(url('/sjis-meta')).text(), contains('テスト'));
      expect((await Http.get(url('/euckr-meta')).html()).text, contains('한글'));
      expect((await Http.get(url('/sjis-meta')).html()).text, contains('テスト'));
      expect(await Http.get(url('/sjis-header')).lines().toList(), ['テスト']);
    });
  });

  group('response surface', () {
    late io.HttpServer server;
    setUp(() async {
      server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final res = req.response;
        if (req.uri.path == '/cookies') {
          res.headers.add('set-cookie', 'a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT');
          res.headers.add('set-cookie', 'b=2');
          res.write('ok');
        } else if (req.uri.path == '/slow-lines') {
          res.bufferOutput = false;
          res.write('first\n');
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 800));
          res.write('second\n');
        }
        await res.close();
      });
    });
    tearDown(() => server.close(force: true));
    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('headers keep every value and cannot be changed', () async {
      final r = await Http.get(url('/cookies'));
      expect(r.headers['set-cookie'], hasLength(2));
      expect(r.header('set-cookie'), startsWith('a=1'));
      expect(() => r.headers['x'] = ['y'], throwsUnsupportedError);
      await r.close();
    });

    test('Http.get(u).lines() yields a line before the body ends', () async {
      final clock = Stopwatch()..start();
      final first = await Http.get(url('/slow-lines')).lines().first;
      expect(first, 'first');
      expect(clock.elapsedMilliseconds, lessThan(600));
    });
  });
}
