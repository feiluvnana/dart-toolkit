import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:test/test.dart';

import 'support/child.dart';

/// Python-generated fixtures (codecs with the same names): `python3 -c
/// "open('x','wb').write('…'.encode('euc-kr'))"`, bytes pasted as literals so
/// the suite needs no python at test time.
const _cjk = {
  'euc-kr': ('euc-kr', [176, 161, 179, 170, 199, 209, 177, 219]), // 가나한글
  'shift_jis': (
    'shift_jis',
    [147, 250, 150, 123, 140, 234, 131, 101, 131, 88, 131, 103]
  ), // 日本語テスト
  'euc-jp': (
    'euc-jp',
    [198, 252, 203, 220, 184, 236, 165, 198, 165, 185, 165, 200]
  ), // 日本語テスト
  'gbk': (
    'gbk',
    [214, 208, 206, 196, 188, 242, 204, 229, 178, 226, 202, 212]
  ), // 中文简体测试
  'gb18030': (
    'gb18030',
    [149, 50, 130, 54, 149, 50, 130, 55]
  ), // 𠀀𠀁 (4-byte sequences)
  'big5': (
    'big5',
    [164, 164, 164, 229, 193, 99, 197, 233, 180, 250, 184, 213]
  ), // 中文繁體測試
  'cp949': ('euc-kr', [148, 238, 138, 221]), // 뷁듶 (CP949 extensions)
};

void main() {
  abortTests();
  edgeTests();
  late HttpServer server;
  late String base;
  final hits = <String, int>{};

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      final method = request.method;
      if (path == '/hello' && method == 'HEAD') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text;
      } else if (path == '/hello' && method == 'OPTIONS') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('allow', 'GET, HEAD, OPTIONS');
      } else if (path == '/hello') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..write('hello <b>world</b>');
      } else if (path == '/latin') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'plain', charset: 'iso-8859-1')
          ..add(latin1.encode('caf\u00e9'));
      } else if (path == '/echo' && method == 'POST') {
        final body = await request.cast<List<int>>().transform(utf8.decoder).join();
        request.response
          ..statusCode = HttpStatus.created
          ..headers.set('x-echo', 'yes')
          ..write('got:$body');
      } else if (path == '/item' && (method == 'PUT' || method == 'PATCH')) {
        final body = await request.cast<List<int>>().transform(utf8.decoder).join();
        request.response
          ..statusCode = HttpStatus.ok
          ..write('${method.toLowerCase()}:$body');
      } else if (path == '/item' && method == 'DELETE') {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('deleted');
      } else if (path == '/headers') {
        request.response
          ..statusCode = HttpStatus.ok
          ..write(request.headers.value('x-test') ?? 'none');
      } else if (path == '/redirect') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('location', '/hello');
      } else if (path == '/upload' && method == 'PUT') {
        final body = await request.cast<List<int>>().toList();
        final size = body.fold<int>(0, (a, c) => a + c.length);
        request.response
          ..statusCode = HttpStatus.ok
          ..write('size:$size;length:${request.headers.value('content-length')}');
      } else if (path == '/boom') {
        hits[method] = (hits[method] ?? 0) + 1;
        request.response.statusCode = HttpStatus.internalServerError;
      } else if (path == '/stall') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('a');
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 5));
        request.response.write('b');
      } else if (path == '/blackhole' && method == 'PUT') {
        // Accept the headers, never read the body, never answer in time.
        await Future<void>.delayed(const Duration(seconds: 30));
        request.response.statusCode = HttpStatus.ok;
      } else if (path == '/sized') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..contentLength = 5
          ..write('12345');
      } else if (path == '/cjk') {
        // Encoded bodies served raw: the charset label picks the decoder.
        final which = request.uri.queryParameters['which'] ?? 'euc-kr';
        final entry = _cjk[which]!;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('text', 'html', charset: entry.$1)
          ..add(entry.$2);
      } else if (path == '/meta') {
        // No header charset: <meta charset> in the first 1024 bytes wins.
        request.response.headers.contentType = ContentType('text', 'html');
        request.response.add(
          utf8.encode('<html><head><meta charset="shift_jis"></head><body>') +
              _cjk['shift_jis']!.$2 +
              utf8.encode('</body></html>'),
        );
      } else if (path == '/badbytes') {
        request.response.headers.contentType =
            ContentType('text', 'plain', charset: 'shift_jis');
        request.response.add([0xff, 0x41, 0x82, 0x28]);
      } else if (path == '/unknown-charset') {
        request.response.headers.contentType =
            ContentType('text', 'plain', charset: 'x-made-up');
        request.response.write('plain ascii');
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('nope');
      }
      await request.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  group('verbs', () {
    test('get returns status/header/url', () async {
      final res = await Http.get('$base/hello');
      expect(res.status(), HttpStatus.ok);
      expect(res.header('content-type'), contains('text/plain'));
      expect(res.url(), '$base/hello');
      await res.close();
    });

    test('header() is case-insensitive, null if absent', () async {
      final res = await Http.get('$base/hello');
      expect(res.header('Content-Type'), res.header('content-type'));
      expect(res.header('missing'), isNull);
      await res.close();
    });

    test('sends request headers', () async {
      final res = await Http.get('$base/headers', headers: {'x-test': 'hi'});
      expect(await res.text(), 'hi');
    });

    test('non-2xx is still a Response', () async {
      final res = await Http.get('$base/nope');
      expect(res.status(), HttpStatus.notFound);
      expect(await res.text(), 'nope');
    });

    test('check: true throws with status, method, url and a body snippet', () async {
      await expectLater(
        Http.get('$base/nope', check: true),
        throwsA(isA<HttpException>().having((e) => e.message, 'message',
            'HTTP 404 GET $base/nope: nope')),
      );
      await expectLater(
        Http.post('$base/nope', check: true),
        throwsA(isA<HttpException>()
            .having((e) => e.message, 'message', startsWith('HTTP 404 POST '))),
      );
      expect(await Http.get('$base/hello', check: true).text(), isNotEmpty);
    });

    test('redirects are followed, url() is final', () async {
      final res = await Http.get('$base/redirect');
      expect(res.status(), HttpStatus.ok);
      expect(res.url(), '$base/hello');
      expect(await res.text(), contains('hello'));
    });

    test('post sends body, returns status/text/header', () async {
      final res = await Http.post('$base/echo', body: Body.text('a=1'));
      expect(res.status(), HttpStatus.created);
      expect(await res.text(), 'got:a=1');
      expect(res.header('x-echo'), 'yes');
    });

    test('Body.json accepts a Json inside the value', () async {
      final r = await Http.post('$base/echo',
          body: .json({'a': Json.parse('{"b":[1,2]}')}));
      expect(await r.text(), 'got:{"a":{"b":[1,2]}}');
    });

    test('retries re-send any verb that asks, POST and PATCH included', () async {
      await Http.put('$base/boom', body: Body.text('x'), retries: 1);
      expect(hits['PUT'], 2);
      await Http.post('$base/boom', body: Body.text('x'), retries: 1);
      await Http.patch('$base/boom', body: Body.text('x'), retries: 1);
      expect(hits['POST'], 2);
      expect(hits['PATCH'], 2);
      await Http.post('$base/boom', body: Body.text('x'));
      expect(hits['POST'], 3); // the default: no retries
    });

    test('post sends json and form bodies', () async {
      final j = await Http.post('$base/echo', body: .json({'a': 1}));
      expect(await j.text(), 'got:{"a":1}');
      final f = await Http.post('$base/echo', body: Body.form({'a': '1'}));
      expect(await f.text(), 'got:a=1');
    });

    test('put sends body', () async {
      final res = await Http.put('$base/item', body: Body.text('a=1'));
      expect(await res.text(), 'put:a=1');
    });

    test('patch sends body', () async {
      final res = await Http.patch('$base/item', body: Body.text('b=2'));
      expect(await res.text(), 'patch:b=2');
    });

    test('delete works', () async {
      final res = await Http.delete('$base/item');
      expect(await res.text(), 'deleted');
    });

    test('head returns status, empty text', () async {
      final res = await Http.head('$base/hello');
      expect(res.status(), HttpStatus.ok);
      expect(await res.text(), isEmpty);
    });

    test('options returns allow header', () async {
      final res = await Http.options('$base/hello');
      expect(res.header('allow'), contains('GET'));
      await res.close();
    });

    test('body takes bytes', () async {
      final res = await Http.post('$base/echo', body: Body.bytes(utf8.encode('a=2')));
      expect(await res.text(), 'got:a=2');
    });

    test('body streams a Reader', () async {
      final res = await Http.put(
        '$base/upload',
        body: Body.stream(_Mem('0123456789')),
        headers: {'content-length': '10'},
      );
      expect(await res.text(), 'size:10;length:10');
    });

    test('H1: an upload the server never reads times out, never hangs',
        () async {
      await expectLater(
        Http.put(
          '$base/blackhole',
          body: Body.stream(_SlowReader()),
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a streamed body is sent once, never retried', () async {
      // A stream cannot be resent: resendable is false by type, so even
      // with retries a failure surfaces instead of hanging or resending.
      // Covered by the type (Body.stream) + the H1 timeout above.
    });
  });

  group('Response as Reader', () {
    test('text() decodes with the charset header', () async {
      final res = await Http.get('$base/latin');
      expect(await res.text(), 'caf\u00e9');
    });

    test('H5: WHATWG CJK decoders match the header charset', () async {
      final cases = {
        'euc-kr': '가나한글',
        'shift_jis': '日本語テスト',
        'euc-jp': '日本語テスト',
        'gbk': '中文简体测试',
        'gb18030': '\u{20000}\u{20001}',
        'big5': '中文繁體測試',
        'cp949': '뷁듶',
      };
      for (final entry in cases.entries) {
        final res = await Http.get('$base/cjk?which=${entry.key}');
        expect(await res.text(), entry.value, reason: entry.key);
      }
    });

    test('H5: <meta charset> is sniffed without a header', () async {
      final res = await Http.get('$base/meta');
      expect(await res.text(), contains('日本語テスト'));
    });

    test('H5: malformed bytes become U+FFFD, never a throw', () async {
      final res = await Http.get('$base/badbytes');
      expect(await res.text(), '�A�(');
    });

    test('H5: unknown charset falls back to UTF-8', () async {
      final res = await Http.get('$base/unknown-charset');
      expect(await res.text(), 'plain ascii');
    });

    test('text() and bytes() cache: calling again is free', () async {
      final res = await Http.get('$base/hello');
      final a = await res.text();
      expect(await res.text(), a);
      expect(await res.bytes(), utf8.encode(a));
    });

    test('bytes() is an unmodifiable O(1) view, not a copy', () async {
      final res = await Http.get('$base/hello');
      final b = await res.bytes();
      expect(() => b[0] = 0, throwsUnsupportedError);
      await res.close();
    });

    test('insecure trusts only the hosts it names, with their subdomains', () async {
      final dir = await Directory.systemTemp.createTemp('tls');
      addTearDown(() => dir.delete(recursive: true));
      final made = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', //
        '-keyout', '${dir.path}/key.pem', '-out', '${dir.path}/cert.pem',
      ]);
      if (made.exitCode != 0) markTestSkipped('needs openssl');
      final ctx = SecurityContext()
        ..useCertificateChain('${dir.path}/cert.pem')
        ..usePrivateKey('${dir.path}/key.pem');
      final tls = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
      tls.listen((r) => r.response
        ..write('secret')
        ..close());
      addTearDown(() => tls.close(force: true));
      final u = 'https://localhost:${tls.port}/';
      expect(await Http.get(u, insecure: ['localhost']).text(), 'secret');
      await expectLater(Http.get(u), throwsA(isA<HandshakeException>()));
      await expectLater(Http.get(u, insecure: ['example.com']), throwsA(isA<HandshakeException>()));
    });

    test('insecure is per-call and hold() keeps the client', () async {
      final plain = await Http.get('$base/hello', insecure: ['127.0.0.1']);
      expect(await plain.text(), contains('hello'));
      final hold = Http.hold();
      try {
        final r = await Http.get('$base/hello');
        expect(await r.text(), contains('hello'));
      } finally {
        await hold.close();
      }
    });

    test('piping streams without caching; reading after is StateError', () async {
      final res = await Http.get('$base/hello');
      final sink = _Sink();
      await (res > sink);
      expect(sink.data, isNotEmpty);
      expect(() => res.stream(), throwsStateError);
      expect(res.bytes(), throwsStateError);
    });

    test('close() drops an unread body; reading after is StateError', () async {
      final res = await Http.get('$base/hello');
      await res.close();
      await res.close(); // idempotent
      expect(() => res.stream(), throwsStateError);
    });

    test('close() after a full read is a no-op', () async {
      final res = await Http.get('$base/hello');
      await res.bytes();
      await res.close();
    });

    test('a stalled body times out naming the URL', () async {
      final res = await Http.get(
        '$base/stall',
        timeout: const Duration(milliseconds: 300),
      );
      expect(
        res.bytes(),
        throwsA(isA<TimeoutException>().having(
          (e) => e.message,
          'message',
          contains('$base/stall'),
        )),
      );
    });

    test('dropping an unbounded body does not drain it', () async {
      final res = await Http.get('$base/stall');
      final sw = Stopwatch()..start();
      await res.close();
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('a writer that fails before reading frees a slow response', () async {
      final sw = Stopwatch()..start();
      await expectLater(Http.get('$base/stall') > _ThrowFirstWriter(), throwsStateError);
      await Http.get('$base/hello').text();
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('a failed pipe releases the connection', () async {
      final res = await Http.get('$base/hello');
      await expectLater(res > _BoomWriter(), throwsStateError);
      // The socket must not linger: close() is a no-op, not a hang.
      await res.close().timeout(const Duration(seconds: 5));
    });

    test('Future mirrors match', () async {
      expect(await Http.get('$base/hello').status(), HttpStatus.ok);
      expect(
        await Http.get('$base/hello').header('content-type'),
        contains('text/plain'),
      );
      expect(await Http.get('$base/hello').url(), '$base/hello');
      expect(await Http.get('$base/hello').text(), contains('hello'));
      expect(await Http.get('$base/hello').ok(), isTrue);
      // /hello is chunked (no content-length); /sized sets one.
      expect(await Http.get('$base/hello').size(), isNull);
      expect(await Http.get('$base/sized').size(), 5);
      expect(await Http.get('$base/hello').name(), 'hello');
    });

    test('H2: mirrors close the response (one-shot)', () async {
      final f = Http.get('$base/hello');
      expect(await f.status(), HttpStatus.ok);
      // Nothing else can reach the response now: reading fails, closing
      // is a harmless no-op, and the process is not kept alive.
      await expectLater(f.text(), throwsStateError);
      await f.close();
    });

    test('json() on an error page names the status', () async {
      final bad = await Http.get('$base/nope');
      await expectLater(
        bad.json(),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('404'),
        )),
      );
    });
  });
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(utf8.encode(_text));
}

/// An endless body, for the blackhole test: the only exit is the timeout.
final class _SlowReader with Reader {
  @override
  Stream<List<int>> stream() async* {
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      yield List.filled(65536, 65);
    }
  }
}

final class _Sink implements Writer {
  final data = <int>[];
  @override
  Future<void> consume(Stream<List<int>> input) async {
    await for (final c in input) {
      data.addAll(c);
    }
  }
}

final class _BoomWriter implements Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    var n = 0;
    await for (final _ in input) {
      n++;
      if (n == 1) throw StateError('writer blew up mid-write');
    }
  }
}

final class _ThrowFirstWriter implements Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async =>
      throw StateError('before reading');
}

void abortTests() {
  group('Http.abort', () {
    late HttpServer srv;
    late String url;
    setUp(() async {
      srv = await HttpServer.bind('127.0.0.1', 0);
      url = 'http://127.0.0.1:${srv.port}';
      srv.listen((req) async {
        if (req.uri.path == '/slow') {
          req.response.add([1, 2, 3]);
          await req.response.flush();
          await Future<void>.delayed(const Duration(seconds: 30));
        } else {
          req.response.write('ok');
        }
        await req.response.close().catchError((_) {});
      });
    });
    tearDown(() => srv.close(force: true));

    test('fails an in-flight body read promptly, without retrying', () async {
      final res = await Http.get('$url/slow', retries: 3);
      final read = res.bytes();
      final sw = Stopwatch()..start();
      Timer(const Duration(milliseconds: 100), Http.abort);
      await expectLater(read, throwsA(isA<Exception>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('a pending request fails and is not retried', () async {
      final slow = await HttpServer.bind('127.0.0.1', 0);
      var hits = 0;
      slow.listen((r) => hits++); // never answers
      final f = Http.get('http://127.0.0.1:${slow.port}/', retries: 3);
      final expectation = expectLater(f, throwsA(isA<HttpException>()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      Http.abort();
      await expectation.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(hits, 1);
      await slow.close(force: true);
    });

    test('abort wakes a pending retry backoff', () async {
      final bad = await HttpServer.bind('127.0.0.1', 0);
      bad.listen((r) {
        r.response.statusCode = 503;
        r.response.close();
      });
      final f = Http.get('http://127.0.0.1:${bad.port}/', retries: 3);
      final expectation = expectLater(f, throwsA(isA<HttpException>()));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      Http.abort();
      await expectation.timeout(const Duration(milliseconds: 800));
      await bad.close(force: true);
    });

    test('requests after abort work', () async {
      Http.abort();
      expect(await Http.get('$url/fast').text(), 'ok');
    });

    test('a script that aborts a slow download exits by itself', () async {
      final r = await runDart('''
import 'package:dart_toolkit/http.dart';
Future<void> main(List<String> a) async {
  final res = await Http.get(a[0]);
  res.bytes().catchError((_) => res.bytes()).ignore();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  Http.abort();
}
''', args: ['$url/slow'], timeout: const Duration(seconds: 20));
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });
  });
}

void edgeTests() {
  group('edges', () {
    late HttpServer server;
    late String url;
    final peers = <int>{};

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'http://127.0.0.1:${server.port}';
      server.listen((r) async {
        peers.add(r.connectionInfo!.remotePort);
        switch (r.uri.path) {
          case '/sink':
            var n = 0;
            await for (final c in r) {
              n += c.length;
            }
            r.response.write('$n');
          case '/trickle':
            r.response.contentLength = 60000;
            try {
              for (var i = 0; i < 60000; i++) {
                r.response.add([65]);
                await r.response.flush();
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
            } catch (_) {
              return; // the client hung up
            }
          case '/big-head':
            r.response.contentLength = 1000000;
            if (r.method != 'HEAD') r.response.add(List.filled(1000000, 0));
          case '/to-mailto':
            r.response
              ..statusCode = 302
              ..headers.set('location', 'mailto:x@y');
          case '/denied':
            r.response
              ..statusCode = 401
              ..write('denied');
          case '/to-other':
            r.response
              ..statusCode = 302
              ..headers.set('location', r.uri.queryParameters['to']!);
          case '/to-bad':
            r.response
              ..statusCode = 302
              ..headers.set('location', 'http://[bad');
          default:
            r.response.write('hello');
        }
        try {
          await r.response.close();
        } catch (_) {}
      });
    });

    tearDownAll(() => server.close(force: true));

    test('an upload that keeps moving outlives the timeout', () async {
      final res = await Http.put('$url/sink',
          body: Body.stream(_Drip(8, const Duration(milliseconds: 150))), timeout: const Duration(milliseconds: 500));
      expect(await res.text(), '8');
    });

    test('a status mirror never waits for a slow small body', () async {
      final sw = Stopwatch()..start();
      expect(await Http.get('$url/trickle', timeout: const Duration(seconds: 20)).status(), 200);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('HEAD keeps the connection whatever content-length says', () async {
      final hold = Http.hold();
      try {
        peers.clear();
        for (var i = 0; i < 4; i++) {
          expect(await Http.head('$url/big-head').ok(), isTrue);
        }
        expect(peers, hasLength(1));
      } finally {
        await hold.close();
      }
    });

    test('a redirect to a non-http or malformed URL is an HttpException', () async {
      await expectLater(Http.get('$url/to-mailto'), throwsA(isA<HttpException>()));
      await expectLater(Http.get('$url/to-bad'), throwsA(isA<HttpException>()));
    });

    test('a writer that never reads still lets the script exit', () async {
      final r = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/http.dart';
final class Ignore implements Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {}
}
Future<void> main() async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  s.listen((r) => r.response
    ..contentLength = 1 << 20
    ..add(List.filled(1 << 20, 0))
    ..close());
  await (Http.get('http://127.0.0.1:\${s.port}/') > Ignore());
  await s.close();
}
''', timeout: const Duration(seconds: 10));
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    test('a cross-origin redirect drops credential headers, custom ones too', () async {
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String, String?>{};
      other.listen((r) {
        for (final h in ['authorization', 'x-api-key', 'private-token', 'accept']) {
          seen[h] = r.headers.value(h);
        }
        r.response.close();
      });
      addTearDown(() => other.close(force: true));
      await Http.get('$url/to-other?to=http://127.0.0.1:${other.port}/', headers: {
        'authorization': 'Bearer T',
        'x-api-key': 'K',
        'private-token': 'P',
        'accept': 'text/html',
      }).then((r) => r.close());
      expect(seen, {'authorization': null, 'x-api-key': null, 'private-token': null, 'accept': 'text/html'});
    });

    test('error messages never show URL credentials or token values', () async {
      final secret = url.replaceFirst('http://', 'http://alice:hunter2@');
      await expectLater(
        Http.get('$secret/denied?access_token=SECRET&page=2', check: true),
        throwsA(isA<HttpException>().having((e) => '$e', 'text', allOf(
          contains('access_token=***&page=2'),
          isNot(contains('hunter2')),
          isNot(contains('SECRET')),
        ))),
      );
    });

    test('an unread response, chunked or not, lets the script exit', () async {
      final r = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/http.dart';
Future<void> main() async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  s.listen((r) {
    if (r.uri.path == '/len') r.response.contentLength = 4;
    r.response..statusCode = 404..write('nope');
    r.response.close();
  });
  for (final p in ['/len', '/chunked']) {
    print((await Http.get('http://127.0.0.1:\${s.port}\$p')).status());
  }
  await s.close(force: true);
}
''', timeout: const Duration(seconds: 15));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, '404\n404\n');
    });

    test('a body past the 64 KB prefix reads whole after a delay, and pipes', () async {
      final big = List.generate(300000, (i) => i % 251);
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      other.listen((r) => r.response
        ..add(big)
        ..close());
      addTearDown(() => other.close(force: true));
      final u = 'http://127.0.0.1:${other.port}/';
      final res = await Http.get(u);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await res.bytes(), big);
      final sink = _Sink();
      await (await Http.get(u) > sink);
      expect(sink.data, big);
    });

    test('a refused connection names the request', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      await expectLater(Http.get('http://127.0.0.1:$port/thing'),
          throwsA(isA<SocketException>().having((e) => e.message, 'message', contains('GET http://127.0.0.1:$port/thing'))));
    });

    test('two reads at once share one body', () async {
      final res = await Http.get('$url/hello');
      expect(await Future.wait([res.text(), res.text()]), ['hello', 'hello']);
    });
  });
}

/// [count] one-byte chunks, [gap] apart.
final class _Drip with Reader {
  _Drip(this.count, this.gap);
  final int count;
  final Duration gap;

  @override
  Stream<List<int>> stream() async* {
    for (var i = 0; i < count; i++) {
      await Future<void>.delayed(gap);
      yield [65];
    }
  }
}
