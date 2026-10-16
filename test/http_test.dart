import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/src/cookies.dart' as jar;
import 'package:dart_toolkit/src/resume.dart' show PassThrough, replays;
import 'package:dart_toolkit/utils.dart';
import 'package:test/test.dart';

import 'support/child.dart';
import 'support/io.dart';
import 'support/poll.dart';

/// Python-generated fixtures (codecs with the same names): `python3 -c
/// "open('x','wb').write('…'.encode('euc-kr'))"`, bytes pasted as literals so
/// the suite needs no python at test time.
const _cjk = {
  'euc-kr': ('euc-kr', [176, 161, 179, 170, 199, 209, 177, 219]), // 가나한글
  'shift_jis': ('shift_jis', [147, 250, 150, 123, 140, 234, 131, 101, 131, 88, 131, 103]), // 日本語テスト
  'euc-jp': ('euc-jp', [198, 252, 203, 220, 184, 236, 165, 198, 165, 185, 165, 200]), // 日本語テスト
  'gbk': ('gbk', [214, 208, 206, 196, 188, 242, 204, 229, 178, 226, 202, 212]), // 中文简体测试
  'gb18030': ('gb18030', [149, 50, 130, 54, 149, 50, 130, 55]), // 𠀀𠀁 (4-byte sequences)
  'big5': ('big5', [164, 164, 164, 229, 193, 99, 197, 233, 180, 250, 184, 213]), // 中文繁體測試
  'cp949': ('euc-kr', [148, 238, 138, 221]), // 뷁듶 (CP949 extensions)
};

/// The client most tests share: default settings.
final http = Http.client(check: false); // these tests read non-2xx Responses

void main() {
  serveTests();
  clientTests();
  rateTests();
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
        request.response.statusCode = int.parse(request.uri.queryParameters['code'] ?? '500');
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
          ..headers.contentType = ContentType('text', 'html', charset: entry.$1)
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
        request.response.headers.contentType = ContentType('text', 'plain', charset: 'shift_jis');
        request.response.add([0xff, 0x41, 0x82, 0x28]);
      } else if (path == '/unknown-charset') {
        request.response.headers.contentType = ContentType('text', 'plain', charset: 'x-made-up');
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
      final res = await http.get('$base/hello');
      expect(res.status(), HttpStatus.ok);
      expect(res.header('content-type'), contains('text/plain'));
      expect(res.url(), '$base/hello');
      await res.close();
    });

    test('header() is case-insensitive, null if absent', () async {
      final res = await http.get('$base/hello');
      expect(res.header('Content-Type'), res.header('content-type'));
      expect(res.header('missing'), isNull);
      await res.close();
    });

    test('sends request headers', () async {
      final res = await http.get('$base/headers', headers: {'x-test': 'hi'});
      expect(await res.text(), 'hi');
    });

    test('non-2xx is still a Response', () async {
      final res = await http.get('$base/nope');
      expect(res.status(), HttpStatus.notFound);
      expect(await res.text(), 'nope');
    });

    test('check: true throws with status, method, url and a body snippet', () async {
      final strict = Http.client(); // check: is on by default
      await expectLater(
        strict.get('$base/nope'),
        throwsA(
          isA<HttpStatusException>()
              .having((e) => e.message, 'message', 'HTTP 404 GET $base/nope: nope')
              .having((e) => e.status, 'status', 404),
        ),
      );
      await expectLater(
        strict.post('$base/nope'),
        throwsA(isA<HttpException>().having((e) => e.message, 'message', startsWith('HTTP 404 POST '))),
      );
      expect(await strict.get('$base/hello').text(), isNotEmpty);
      await expectLater(http.get('$base/nope').check(), throwsA(isA<HttpStatusException>()));
    });

    test('redirects are followed, url() is final', () async {
      final res = await http.get('$base/redirect');
      expect(res.status(), HttpStatus.ok);
      expect(res.url(), '$base/hello');
      expect(await res.text(), contains('hello'));
    });

    test('post sends body, returns status/text/header', () async {
      final res = await http.post('$base/echo', body: Body.text('a=1'));
      expect(res.status(), HttpStatus.created);
      expect(await res.text(), 'got:a=1');
      expect(res.header('x-echo'), 'yes');
    });

    test('Body.json accepts a Json inside the value', () async {
      final r = await http.post('$base/echo', body: .json({'a': Json.parse('{"b":[1,2]}')}));
      expect(await r.text(), 'got:{"a":{"b":[1,2]}}');
    });

    test('a 500 is never retried; a 503 retries every verb, a 502 only idempotent ones', () async {
      final once = Http.client(retries: 1, check: false);
      await once.put('$base/boom', body: Body.text('x'));
      expect(hits['PUT'], 1);
      await once.put('$base/boom?code=503', body: Body.text('x'));
      await once.post('$base/boom?code=503', body: Body.text('x'));
      expect((hits['PUT'], hits['POST']), (3, 2));
      await once.post('$base/boom?code=502', body: Body.text('x'));
      await once.delete('$base/boom?code=502');
      expect((hits['POST'], hits['DELETE']), (3, 2));
    }, tags: 'slow');

    test('post sends json and form bodies', () async {
      final j = await http.post('$base/echo', body: .json({'a': 1}));
      expect(await j.text(), 'got:{"a":1}');
      final f = await http.post('$base/echo', body: Body.form({'a': '1'}));
      expect(await f.text(), 'got:a=1');
    });

    test('put sends body', () async {
      final res = await http.put('$base/item', body: Body.text('a=1'));
      expect(await res.text(), 'put:a=1');
    });

    test('patch sends body', () async {
      final res = await http.patch('$base/item', body: Body.text('b=2'));
      expect(await res.text(), 'patch:b=2');
    });

    test('delete works', () async {
      final res = await http.delete('$base/item');
      expect(await res.text(), 'deleted');
    });

    test('head returns status, empty text', () async {
      final res = await http.head('$base/hello');
      expect(res.status(), HttpStatus.ok);
      expect(await res.text(), isEmpty);
    });

    test('body takes bytes', () async {
      final res = await http.post('$base/echo', body: Body.bytes(utf8.encode('a=2')));
      expect(await res.text(), 'got:a=2');
    });

    test('body streams a Reader', () async {
      final res = await http.put(
        '$base/upload',
        body: Body.stream(Mem('0123456789')),
        headers: {'content-length': '10'},
      );
      expect(await res.text(), 'size:10;length:10');
    });

    test('H1: an upload the server never reads times out, never hangs', () async {
      await expectLater(
        Http.client(timeout: 1.seconds).put('$base/blackhole', body: Body.stream(_SlowReader())),
        throwsA(isA<TimeoutException>()),
      );
    }, tags: 'slow');

    test('a streamed body is sent once, whatever retries says', () async {
      final before = hits['PUT'] ?? 0;
      await Http.client(retries: 2, check: false).put('$base/boom?code=503', body: Body.stream(Mem('x')));
      expect(hits['PUT'], before + 1);
    });
  });

  group('Response as Reader', () {
    test('text() decodes with the charset header', () async {
      final res = await http.get('$base/latin');
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
        final res = await http.get('$base/cjk?which=${entry.key}');
        expect(await res.text(), entry.value, reason: entry.key);
      }
    });

    test('H5: <meta charset> is sniffed without a header', () async {
      final res = await http.get('$base/meta');
      expect(await res.text(), contains('日本語テスト'));
    });

    test('H5: malformed bytes become U+FFFD, never a throw', () async {
      final res = await http.get('$base/badbytes');
      expect(await res.text(), '�A�(');
    });

    test('H5: unknown charset falls back to UTF-8', () async {
      final res = await http.get('$base/unknown-charset');
      expect(await res.text(), 'plain ascii');
    });

    test('text() and bytes() cache: calling again is free', () async {
      final res = await http.get('$base/hello');
      final a = await res.text();
      expect(await res.text(), a);
      expect(await res.bytes(), utf8.encode(a));
    });

    test('bytes() is unmodifiable', () async {
      final res = await http.get('$base/hello');
      final b = await res.bytes();
      expect(() => b[0] = 0, throwsUnsupportedError);
      await res.close();
    });

    test('piping streams without caching; reading after is StateError', () async {
      final res = await http.get('$base/hello');
      final sink = Collect();
      await (res > sink);
      expect(sink.data, isNotEmpty);
      expect(() => res.stream(), throwsStateError);
      expect(res.bytes(), throwsStateError);
    });

    test('close() drops an unread body; reading after is StateError', () async {
      final res = await http.get('$base/hello');
      await res.close();
      await res.close(); // idempotent
      expect(() => res.stream(), throwsStateError);
    });

    test('close() after a full read is a no-op', () async {
      final res = await http.get('$base/hello');
      await res.bytes();
      await res.close();
    });

    test('a stalled body times out naming the URL', () async {
      final res = await Http.client(timeout: 300.milliseconds).get('$base/stall');
      expect(
        res.bytes(),
        throwsA(isA<TimeoutException>().having((e) => e.message, 'message', contains('GET $base/stall'))),
      );
    });

    test('dropping an unbounded body does not drain it', () async {
      final res = await http.get('$base/stall');
      final sw = Stopwatch()..start();
      await res.close();
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('a writer that fails before reading frees a slow response', () async {
      final sw = Stopwatch()..start();
      await expectLater(http.get('$base/stall') > _ThrowFirstWriter(), throwsStateError);
      await http.get('$base/hello').text();
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('a failed pipe releases the connection', () async {
      final res = await http.get('$base/hello');
      await expectLater(res > BoomWriter(), throwsStateError);
      // The socket must not linger: close() is a no-op, not a hang.
      await res.close().timeout(const Duration(seconds: 5));
    });

    test('Future mirrors match', () async {
      expect(await http.get('$base/hello').status(), HttpStatus.ok);
      expect(await http.get('$base/hello').header('content-type'), contains('text/plain'));
      expect(await http.get('$base/hello').url(), '$base/hello');
      expect(await http.get('$base/hello').text(), contains('hello'));
      expect(await http.get('$base/hello').ok(), isTrue);
      // /hello is chunked (no content-length); /sized sets one.
      expect(await http.get('$base/hello').size(), isNull);
      expect(await http.get('$base/sized').size(), 5);
      expect(await http.get('$base/hello').name(), 'hello');
    });

    test('H2: mirrors close the response (one-shot)', () async {
      final f = http.get('$base/hello');
      expect(await f.status(), HttpStatus.ok);
      // Nothing else can reach the response now: reading fails, closing
      // is a harmless no-op, and the process is not kept alive.
      await expectLater(f.text(), throwsStateError);
      await f.close();
    });

    test('json() on an error page names the status', () async {
      final bad = await http.get('$base/nope');
      await expectLater(
        bad.json(),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('404'))),
      );
    });
  });
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

final class _ThrowFirstWriter with Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async => throw StateError('before reading');
}

void abortTests() {
  group('Client.close', () {
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
      final c = Http.client();
      final res = await c.get('$url/slow');
      final read = res.bytes();
      final sw = Stopwatch()..start();
      Timer(100.milliseconds, c.close);
      await expectLater(read, throwsA(isA<Exception>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5))); // the slow body takes far longer
    });

    test('a pending request fails and is not retried', () async {
      var hits = 0;
      final (_, slow) = await serve((r) => hits++); // never answers
      final c = Http.client();
      final f = c.get('$slow/');
      final expectation = expectLater(
        f,
        throwsA(isA<HttpRequestException>().having((e) => e.reason, 'reason', RequestFailure.aborted)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await c.close();
      await expectation.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(hits, 1);
    }, tags: 'slow');

    test('abort wakes a pending retry backoff', () async {
      final (_, bad) = await serve(
        (r) => r.response
          ..statusCode = 503
          ..close(),
      );
      final c = Http.client();
      final f = c.get('$bad/');
      final expectation = expectLater(f, throwsA(isA<HttpRequestException>()));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await c.close();
      await expectation.timeout(const Duration(milliseconds: 800));
    });

    test('close is per client: others keep working, the closed one refuses', () async {
      final c = Http.client();
      await c.close();
      await c.close(); // idempotent
      await expectLater(c.get('$url/fast'), throwsA(isA<HttpRequestException>()));
      expect(await http.get('$url/fast').text(), 'ok');
    });

    test('a script that aborts a slow download exits by itself', () async {
      final r = await runDart(
        '''
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/src/resume.dart' show PassThrough;
import 'package:dart_toolkit/utils.dart';
Future<void> main(List<String> a) async {
  final c = Http.client();
  final res = await c.get(a[0]);
  res.bytes().catchError((_) => res.bytes()).ignore();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await c.close();
}
''',
        args: ['$url/slow'],
        timeout: const Duration(seconds: 20),
      );
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
          case '/login':
            r.response
              ..statusCode = 302
              ..headers.set('location', '/home')
              ..cookies.add(Cookie('sid', 's3cret')..path = '/');
          case '/home':
            final sid = r.cookies.where((c) => c.name == 'sid').firstOrNull?.value;
            r.response
              ..statusCode = sid == 's3cret' ? 200 : 401
              ..write('sid=$sid');
          case '/logout':
            r.response.cookies.add(
              Cookie('sid', '')
                ..path = '/'
                ..maxAge = 0,
            );
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
      final res = await Http.client(timeout: 500.milliseconds)
          .put('$url/sink', body: Body.stream(_Drip(8, const Duration(milliseconds: 150))));
      expect(await res.text(), '8');
    });

    test('a status mirror never waits for a slow small body', () async {
      final sw = Stopwatch()..start();
      expect(await Http.client(timeout: 20.seconds).get('$url/trickle').status(), 200);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('HEAD keeps the connection whatever content-length says', () async {
      final c = Http.client();
      peers.clear();
      for (var i = 0; i < 4; i++) {
        expect(await c.head('$url/big-head').ok(), isTrue);
      }
      expect(peers, hasLength(1));
      await c.close();
    });

    test('a redirect to a non-http or malformed URL is an HttpException', () async {
      final unsendable = isA<HttpRequestException>().having((e) => e.reason, 'reason', RequestFailure.unsendable);
      await expectLater(http.get('$url/to-mailto'), throwsA(unsendable));
      await expectLater(http.get('$url/to-bad'), throwsA(unsendable));
    });

    test('a writer that never reads still lets the script exit', () async {
      final r = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/src/resume.dart' show PassThrough;
import 'package:dart_toolkit/utils.dart';
final class Ignore with Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {}
}
Future<void> main() async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  s.listen((r) => r.response
    ..contentLength = 1 << 20
    ..add(List.filled(1 << 20, 0))
    ..close());
  await (Http.client().get('http://127.0.0.1:\${s.port}/') > Ignore());
  await s.close();
}
''', timeout: const Duration(seconds: 10));
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    test('a cross-origin redirect drops credential headers, custom ones too', () async {
      final seen = <String, String?>{};
      final (_, other) = await serve((r) {
        for (final h in ['authorization', 'x-api-key', 'private-token', 'accept']) {
          seen[h] = r.headers.value(h);
        }
        r.response.close();
      });
      await http
          .get(
            '$url/to-other?to=$other/',
            headers: {'authorization': 'Bearer T', 'x-api-key': 'K', 'private-token': 'P', 'accept': 'text/html'},
          )
          .then((r) => r.close());
      expect(seen, {'authorization': null, 'x-api-key': null, 'private-token': null, 'accept': 'text/html'});
    });

    test('error messages never show URL credentials or token values', () async {
      final secret = url.replaceFirst('http://', 'http://alice:hunter2@');
      await expectLater(
        Http.client().get('$secret/denied?access_token=SECRET&page=2'),
        throwsA(
          isA<HttpException>().having(
            (e) => '$e',
            'text',
            allOf(contains('access_token=***&page=2'), isNot(contains('hunter2')), isNot(contains('SECRET'))),
          ),
        ),
      );
    });

    test('an unread response, chunked or not, lets the script exit', () async {
      final r = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/src/resume.dart' show PassThrough;
import 'package:dart_toolkit/utils.dart';
Future<void> main() async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  s.listen((r) {
    if (r.uri.path == '/len') r.response.contentLength = 4;
    r.response..statusCode = 404..write('nope');
    r.response.close();
  });
  for (final p in ['/len', '/chunked']) {
    print((await Http.client(check: false).get('http://127.0.0.1:\${s.port}\$p')).status());
  }
  await s.close(force: true);
}
''', timeout: const Duration(seconds: 15));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, '404\n404\n');
    });

    test('a body past the 64 KB prefix reads whole after a delay, and pipes', () async {
      final big = List.generate(300000, (i) => i % 251);
      final (_, other) = await serve(
        (r) => r.response
          ..add(big)
          ..close(),
      );
      final u = '$other/';
      final res = await http.get(u);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await res.bytes(), big);
      final sink = Collect();
      await (await http.get(u) > sink);
      expect(sink.data, big);
    });

    test('a refused connection names the request', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      await expectLater(
        Http.client(retries: 0).get('http://127.0.0.1:$port/thing'),
        // Refused, or reset when a parallel test took the freed port: named either way.
        throwsA(isA<IOException>().having((e) => '$e', 'text', contains('GET http://127.0.0.1:$port/thing'))),
      );
    });

    test('query: appends encoded pairs; a null value drops its key', () async {
      final seen = <String>[];
      final (_, echo) = await serve((r) {
        seen.add(r.uri.query);
        r.response.close();
      });
      final u = '$echo/s';
      await http.get(u, query: {'q': 'a b&c', 'page': 2, 'skip': null, 'on': true}).status();
      await http.get('$u?x=1', query: {'y': 'é'}).status();
      await http
          .post(
            u,
            query: {
              'k': 'v',
              'id': ['a', 'b'],
            },
          )
          .status();
      await http.get(u, query: {'variables': {'id': 7, 'tags': ['a']}}).status();
      expect(seen, [
        'q=a+b%26c&page=2&on=true',
        'x=1&y=%C3%A9',
        'k=v&id=a&id=b',
        'variables=%7B%22id%22%3A7%2C%22tags%22%3A%5B%22a%22%5D%7D', // a Map goes as JSON (GraphQL)
      ]);
    });

    test('a sequential loop that awaits between requests keeps one connection', () async {
      peers.clear();
      for (var i = 0; i < 5; i++) {
        await http.get('$url/hello').text();
        await Future<void>.delayed(const Duration(milliseconds: 20)); // a file write
      }
      expect(peers, hasLength(1));
    });

    test('cookies: a login that redirects keeps its session, per host and per client', () async {
      final c = Http.client(check: false);
      final res = await c.post('$url/login', body: .form({'user': 'a'}));
      expect((res.status(), await res.text()), (200, 'sid=s3cret'));
      expect(await c.get('$url/home').status(), 200);
      expect(c.cookies()['sid'], 's3cret');
      // Another host (localhost vs 127.0.0.1) never sees it, nor another client.
      final other = url.replaceFirst('127.0.0.1', 'localhost');
      expect(await c.get('$other/home').status(), 401);
      expect(await Http.client(check: false).get('$url/home').status(), 401);
      // A copy shares the jar.
      expect(await c.copy(retries: 0).get('$url/home').status(), 200);
      // A per-call cookie header wins by name for that call.
      expect(await c.get('$url/home', headers: {'cookie': 'sid=x'}).text(), 'sid=x');
      await c.get('$url/logout').status();
      expect(await c.get('$url/home').status(), 401);
    });

    test('a session persists through Cookies.encode/parse', () async {
      final c = Http.client();
      await c.post('$url/login').status();
      final saved = Cookies.parse(c.cookies().encode());
      expect(await Http.client(cookies: saved).get('$url/home').text(), 'sid=s3cret');
    });

    test('Cookies.parse reads a browser cookies.txt export', () {
      final jar = Cookies.parse(
        [
          '# Netscape HTTP Cookie File',
          '# This is a generated file! Do not edit.',
          '',
          '.example.com\tTRUE\t/\tTRUE\t4102444800\tsid\ts3cret',
          '#HttpOnly_.example.com\tTRUE\t/\tTRUE\t0\ttok\tabc',
          'www.example.com\tFALSE\t/app\tFALSE\t4102444800\thost\tonly',
          '.example.com\tTRUE\t/\tFALSE\t1\told\texpired',
          'not a cookie line',
        ].join('\r\n'),
      );
      expect(cookieHeader(jar, 'https://www.example.com/app/x'), 'host=only; sid=s3cret; tok=abc');
      expect(cookieHeader(jar, 'https://api.example.com/'), 'sid=s3cret; tok=abc');
      expect(cookieHeader(jar, 'http://www.example.com/'), isNull); // sid and tok are secure
      expect(jar['old'], isNull);
      final again = Cookies.parse(jar.encode());
      expect(cookieHeader(again, 'https://www.example.com/app/x'), cookieHeader(jar, 'https://www.example.com/app/x'));
      expect(cookieHeader(again, 'https://api.example.com/'), 'sid=s3cret; tok=abc');
    });

    test('Cookies.parse of text with no cookies.txt line is a ContentException (B24)', () {
      for (final bad in [
        '.example.com TRUE / TRUE 4102444800 sid s3cret', // spaces, from a paste
        '[{"domain": ".example.com", "name": "sid", "value": "s3cret"}]', // a JSON export
      ]) {
        expect(() => Cookies.parse(bad), throwsA(isA<ContentException>()), reason: bad);
      }
      expect(cookieHeader(Cookies.parse(''), 'https://example.com/'), isNull);
      expect(cookieAgent(Cookies.parse('# Netscape HTTP Cookie File\n# user-agent: UA\n')), 'UA');
    });

    test('a script exits once its client closes', () async {
      final sw = Stopwatch()..start();
      final r = await runDart(
        '''
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/src/resume.dart' show PassThrough;
import 'package:dart_toolkit/utils.dart';
Future<void> main(List<String> a) async {
  final c = Http.client();
  print(await c.get(a[0]).text());
  await c.close();
}
''',
        args: ['$url/hello'],
        timeout: const Duration(seconds: 25),
      );
      expect(r.stdout, 'hello\n');
      expect(sw.elapsed, lessThan(const Duration(seconds: 6)));
    });

    test('two reads at once share one body', () async {
      final res = await http.get('$url/hello');
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

void rateTests() {
  group('Rate', () {
    late HttpServer server;
    late String base;
    var hits = <DateTime>[];
    var refuse = 0;
    setUp(() async {
      hits = [];
      refuse = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        hits.add(DateTime.now());
        req.response.statusCode = refuse-- > 0 ? 429 : 200;
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('allows count per window, then waits for the oldest to leave', () async {
      final waits = <Duration>[];
      final rate = Rate(2, const Duration(milliseconds: 400), onWait: waits.add);
      final start = DateTime.now();
      final c = Http.client(rate: rate);
      for (var i = 0; i < 3; i++) {
        await (await c.get(base)).close();
      }
      expect(hits, hasLength(3));
      expect(hits[2].difference(start), greaterThanOrEqualTo(const Duration(milliseconds: 390)));
      expect(waits, isEmpty, reason: 'onWait only hears waits of a second or more');
    });

    test('a 429 waits the window out instead of backing off from 1 s', () async {
      refuse = 1;
      final rate = Rate(10, const Duration(milliseconds: 300));
      final res = await Http.client(rate: rate, retries: 1).get(base);
      expect(res.status(), 200);
      await res.close();
      final gap = hits[1].difference(hits[0]);
      expect(gap, greaterThanOrEqualTo(const Duration(milliseconds: 250)));
      expect(gap, lessThan(const Duration(milliseconds: 900)));
    });

    test('close ends a paced wait', () async {
      final c = Http.client(rate: Rate(1, 5.minutes));
      await (await c.get(base)).close();
      final second = expectLater(c.get(base), throwsA(isA<HttpRequestException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await c.close();
      await second;
      expect(hits, hasLength(1));
    });
  });
}

void clientTests() {
  group('client settings', () {
    late HttpServer server;
    late String url;
    final hits = <String, int>{};
    final seen = <String, String?>{};
    setUp(() async {
      hits.clear();
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'http://127.0.0.1:${server.port}';
      server.listen((r) async {
        final path = r.uri.path;
        hits[path] = (hits[path] ?? 0) + 1;
        for (final h in ['x-a', 'x-b', 'x-csrf', 'cookie', 'range']) {
          seen[h] = r.headers.value(h);
        }
        final file = List.generate(1000, (i) => i % 256);
        switch (path) {
          case '/file':
            final range = r.headers.value('range');
            final from = range == null ? 0 : int.parse(range.substring(6, range.length - 1));
            if (from > 0) {
              r.response
                ..statusCode = 206
                ..headers.set('content-range', 'bytes $from-999/1000');
            }
            r.response
              ..contentLength = 1000 - from
              ..add(file.sublist(from));
          case '/norange':
            r.response
              ..contentLength = 1000
              ..add(file);
          case '/versioned': // version 2 of the file now; If-Range must name it to resume
            final body = utf8.encode('version two!');
            final range = r.headers.value('range');
            r.response.headers.set('etag', '"v2"');
            final ifRange = r.headers.value('if-range');
            if (range != null && (ifRange == null || ifRange == '"v2"')) {
              final from = int.parse(range.substring(6, range.length - 1));
              r.response
                ..statusCode = 206
                ..headers.set('content-range', 'bytes $from-${body.length - 1}/${body.length}')
                ..add(body.sublist(from));
            } else {
              r.response.add(body);
            }
          case '/wrongrange': // answers any Range with the whole file as a 206
            if (r.headers.value('range') != null) {
              r.response
                ..statusCode = 206
                ..headers.set('content-range', 'bytes 0-999/1000');
            }
            r.response
              ..contentLength = 1000
              ..add(file);
          case '/token':
            r.response.cookies.add(Cookie('csrftoken', 'T0K')..path = '/');
          case '/cookies':
            r.response.headers
              ..add('set-cookie', 'good=1; Path=/')
              ..add('set-cookie', 'bad=2; Expires=not a date at all; Path=/') // the attribute is ignored
              ..add('set-cookie', '=nameless; Path=/')
              ..add('set-cookie', 'noequals; Path=/')
              ..add('set-cookie', 'tld=3; Domain=com; Path=/')
              ..add('set-cookie', 'ip=4; Domain=0.0.1; Path=/')
              ..add('set-cookie', 'deep=5; Path=/a/b')
              ..add('set-cookie', 'shallow=6; Path=/a');
          case '/gzip':
            r.response.headers.set('content-encoding', 'gzip');
            final z = gzip.encode(utf8.encode('x' * 5000));
            r.response
              ..contentLength = z.length
              ..add(z);
          case '/vary':
            r.response.headers.set('vary', 'x-a');
            r.response.write('v${hits[path]}');
          case '/me': // per-user, no Vary: the cache must key on the credentials itself
            r.response.cookies.add(Cookie('sid', 'S3CRET'));
            r.response.write('${hits[path]} ${r.headers.value('authorization')} ${r.headers.value('range')}');
          case '/banned':
            r.response
              ..statusCode = 429
              ..headers.set('retry-after', '1');
          case '/busy':
            r.response.statusCode = r.headers.value('x-a') == 'busy' ? 429 : 200;
            r.response.write(r.headers.value('x-a'));
          case '/missing':
            r.response
              ..statusCode = 404
              ..write('line 1\nline 2');
          default:
            r.response.write(r.uri.toString());
        }
        await r.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('base: relative URLs resolve against it; absolute ones pass', () async {
      final c = Http.client(base: '$url/api/');
      expect(await c.get('items', query: {'n': 1}).text(), '/api/items?n=1');
      expect(await c.get('/root').text(), '/root');
      expect(await c.get('$url/abs').text(), '/abs');
      expect(() => Http.client().get('relative'), throwsArgumentError);
    });

    test('headers: client defaults, per-call wins by name; copy merges', () async {
      final c = Http.client(headers: {'x-a': '1', 'X-B': '2'});
      await c.get('$url/h', headers: {'x-b': 'call'}).status();
      expect((seen['x-a'], seen['x-b']), ('1', 'call'));
      await c.copy(headers: {'x-a': 'copy'}).get('$url/h').status();
      expect((seen['x-a'], seen['x-b']), ('copy', '2'));
    });

    test('csrf copies a cookie into a header on every send', () async {
      final c = Http.client(csrf: (cookie: 'csrftoken', header: 'x-csrf'));
      await c.get('$url/token').status();
      await c.post('$url/h').status();
      expect(seen['x-csrf'], 'T0K');
      expect(seen['cookie'], 'csrftoken=T0K');
      // Another host (the same server by name) gets neither the cookie nor its copy.
      await c.post('${url.replaceFirst('127.0.0.1', 'localhost')}/h').status();
      expect((seen['x-csrf'], seen['cookie']), (null, null));
    });

    test('set-cookie: a bad one skips only itself; Domain needs a dot; longest path first', () async {
      final c = Http.client();
      await c.get('$url/cookies').status();
      final jar = c.cookies();
      expect([jar['good'], jar['bad'], jar['tld'], jar['ip'], jar['deep'], jar['shallow']], ['1', '2', null, null, '5', '6']);
      expect(cookieHeader(jar, '$url/a/b/c'), 'deep=5; shallow=6; good=1; bad=2');
      expect(cookieHeader(jar, 'http://example.com/'), isNull);
      jar.set('k', 'v', url: url);
      expect(cookieHeader(jar, '$url/'), contains('k=v'));
    });

    test('a per-call cookie header merges with the jar by name', () async {
      final c = Http.client(
        cookies: Cookies().set('a', '1', url: url).set('b', '2', url: url),
      );
      await c.get('$url/h', headers: {'cookie': 'b=call; c=3'}).status();
      expect(seen['cookie'], 'a=1; b=call; c=3');
    });

    test('resume: a bar without a total learns the length, resumed or skipped', () async {
      final r = await runDart(r'''
import 'dart:io' as io;
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
Future<void> main() async {
  final server = await io.HttpServer.bind('127.0.0.1', 0);
  server.listen((q) {
    final range = q.headers.value('range');
    if (range == 'bytes=400-') {
      q.response.statusCode = 206;
      q.response.headers.set('content-range', 'bytes 400-999/1000');
      q.response.contentLength = 600;
      q.response.add(List.filled(600, 1));
    } else {
      q.response.contentLength = 1000;
      q.response.add(List.filled(1000, 1));
    }
    q.response.close();
  });
  final cdn = Http.client(resume: true);
  final url = 'http://127.0.0.1:${server.port}/f';
  await Fs.tempDir((dir) async {
    final to = dir.file('f.bin');
    await (cdn.get(url) & Console.bar('fresh') > to);
    await (cdn.get(url) & Console.bar('skipped') > to);
    await to.delete();
    await dir.file('f.bin.part').write('x' * 400);
    await (cdn.get(url) & Console.bar('resumed') > to);
  });
  await server.close(force: true);
}
''');
      final err = r.stderr as String;
      for (final label in ['fresh', 'skipped', 'resumed']) {
        expect(err, contains('$label 1000 B/1000 B'));
      }
    });

    test('a probe hears the bytes and the full length of a resumed download', () async {
      final dir = await Directory.systemTemp.createTemp('tap');
      addTearDown(() => dir.delete(recursive: true));
      final c = Http.client(resume: true);
      final to = _Path('${dir.path}/f.bin');
      await File('${to.path}.part').writeAsBytes(List.filled(600, 0));
      final heard = <(int, int?)>[];
      await (c.get('$url/file') & _Heard(heard) > to);
      expect(heard.last, (1000, 1000)); // the 600 stored bytes replay through it
      expect(heard.map((h) => h.$1), orderedEquals([...heard.map((h) => h.$1)]..sort()));
    });

    group('resume: a GET piped into a file', () {
      late Directory dir;
      final body = List.generate(1000, (i) => i % 256);
      final c = Http.client(resume: true);
      setUp(() async => dir = await Directory.systemTemp.createTemp('resume'));
      tearDown(() => dir.delete(recursive: true));

      test('is atomic and skips a complete file', () async {
        final to = _Path('${dir.path}/sub/f.bin');
        final before = hits['/file'] ?? 0;
        await (c.get('$url/file') > to);
        expect(await File(to.path).readAsBytes(), body);
        expect(File('${to.path}.part').existsSync(), isFalse);
        await (c.get('$url/file') > to); // same content-length: skipped after the headers
        expect(hits['/file'], before + 2);
      });

      test('resumes a .part', () async {
        final to = _Path('${dir.path}/f.bin');
        await File('${to.path}.part').writeAsBytes(body.sublist(0, 600));
        await (c.get('$url/file') > to);
        expect(seen['range'], 'bytes=600-');
        expect(await File(to.path).readAsBytes(), body);
      });

      test('restarts when the server ignores Range', () async {
        final other = _Path('${dir.path}/g.bin');
        final before = hits['/norange'] ?? 0;
        await File('${other.path}.part').writeAsBytes([9, 9, 9]);
        await (c.get('$url/norange') > other);
        expect(await File(other.path).readAsBytes(), body);
        expect(hits['/norange'], before + 1); // its 200 is the whole body, not fetched again
      });

      test('restarts a .part of an older version (its tag), resumes the current one', () async {
        final v = _Path('${dir.path}/v.bin');
        await File('${v.path}.part').writeAsString('VERSION'); // version one's bytes
        await File('${v.path}.part.tag').writeAsString('"v1"');
        await (c.get('$url/versioned') > v);
        expect(await File(v.path).readAsString(), 'version two!');
        expect(seen['range'], 'bytes=7-');
        expect(File('${v.path}.part.tag').existsSync(), isFalse);
        await File(v.path).delete();
        await File('${v.path}.part').writeAsString('version');
        await File('${v.path}.part.tag').writeAsString('"v2"');
        await (c.get('$url/versioned') > v);
        expect(await File(v.path).readAsString(), 'version two!');
      });

      test('restarts on a 206 for another range instead of splicing it on', () async {
        final wrong = _Path('${dir.path}/w.bin');
        await File('${wrong.path}.part').writeAsBytes(body.sublist(0, 5));
        await (c.get('$url/wrongrange') > wrong);
        expect(await File(wrong.path).readAsBytes(), body);
      });

      test('writes no file for a 404', () async {
        await expectLater(
          c.get('$url/missing') > _Path('${dir.path}/m'),
          throwsA(isA<HttpStatusException>().having((e) => e.status, 'status', 404)),
        );
        expect(File('${dir.path}/m').existsSync(), isFalse);
      });

      test('a writer without a path just receives the body; awaiting the GET sends it', () async {
        final sink = Collect();
        await (c.get('$url/file') > sink);
        expect(sink.data, hasLength(1000));
        expect((await c.get('$url/file')).status(), 200);
      });

      test('T3: a connection dropped mid-body keeps the .part; the next run resumes it', () async {
        // Raw HTTP, so the first answer can die mid-body; past the 64 KB a
        // response prefetches whole, so the bytes stream to the .part.
        final big = List.generate(200000, (i) => i * 7 % 256);
        final drop = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(drop.close);
        final ranges = <String?>[];
        drop.listen((sock) {
          final head = StringBuffer();
          late final StreamSubscription<List<int>> sub;
          sub = sock.listen((data) {
            head.write(latin1.decode(data));
            if (!head.toString().contains('\r\n\r\n')) return;
            unawaited(sub.cancel());
            final range = RegExp(r'^range: (\S+)', caseSensitive: false, multiLine: true).firstMatch('$head')?[1];
            ranges.add(range);
            if (range == null) {
              sock.add(latin1.encode('HTTP/1.1 200 OK\r\ncontent-length: 200000\r\netag: "d1"\r\n\r\n'));
              sock.add(big.sublist(0, 100000));
              sock.flush().then((_) => Future<void>.delayed(const Duration(milliseconds: 200))).then((_) => sock.destroy()); // mid-body
            } else {
              sock.add(
                latin1.encode(
                  'HTTP/1.1 206 Partial Content\r\ncontent-range: bytes 100000-199999/200000\r\n'
                  'content-length: 100000\r\netag: "d1"\r\n\r\n',
                ),
              );
              sock.add(big.sublist(100000));
              sock.flush().then((_) => sock.close());
            }
          });
        });
        final to = _Path('${dir.path}/drop.bin');
        final u = 'http://127.0.0.1:${drop.port}/f';
        final once = Http.client(resume: true, retries: 0);
        await expectLater(once.get(u) > to, throwsA(isA<IOException>()));
        expect(await File('${to.path}.part').length(), 100000);
        await (once.get(u) > to);
        expect(ranges.last, 'bytes=100000-');
        expect(await File(to.path).readAsBytes(), big);
      });

      test('T3: a pipe that fails deletes the .part', () async {
        final to = _Path('${dir.path}/pipe.bin');
        await expectLater(c.get('$url/file') | _Broken() > to, throwsStateError);
        expect(File('${to.path}.part').existsSync(), isFalse);
        expect(File('${to.path}.part.tag').existsSync(), isFalse);
      });

      test('without resume every pipe downloads again', () async {
        final plain = _Path('${dir.path}/p.bin');
        await (Http.client().get('$url/file') > plain);
        expect(File('${plain.path}.part').existsSync(), isFalse);
      });
    });

    test('resume replays stored bytes through pass-through pipes; others download again', () async {
      final dir = await Directory.systemTemp.createTemp('replay');
      addTearDown(() => dir.delete(recursive: true));
      final body = List.generate(1000, (i) => i % 256);
      final c = Http.client(resume: true);
      final to = _Path('${dir.path}/f.bin');
      await File('${to.path}.part').writeAsBytes(body.sublist(0, 400));
      final sum = HashUtils.sha256().addBytes(body).hex();
      final count = _Count();
      await (c.get('$url/file') | count | HashUtils.sha256(expect: sum) > to);
      expect(count.bytes, 1000, reason: 'the pipes saw the whole file');
      expect(await File(to.path).readAsBytes(), body);
      // A complete file: the pipes see the stored bytes; nothing is fetched twice.
      final again = _Count();
      await (c.get('$url/file') | again | HashUtils.sha256(expect: sum) > to);
      expect(again.bytes, 1000);
      // A pipe that may change bytes never trusts stored ones: it downloads again.
      final before = hits['/file']!;
      await (c.get('$url/file') | _Plain() > to);
      expect(hits['/file'], before + 1);
      expect(await File(to.path).readAsBytes(), body);
      // A GET nobody pipes or awaits is still sent.
      unawaited(c.get('$url/file?lone').then((r) => r.close()));
      expect(await eventually(() => hits['/file'] == before + 2), isTrue);
      // A hash mismatch deletes the .part.
      await File(to.path).delete();
      await File('${to.path}.part').writeAsBytes(body.sublist(0, 10));
      await expectLater(c.get('$url/file') | HashUtils.sha256(expect: '0' * 64) > to, throwsA(isA<ContentException>()));
      expect(File('${to.path}.part').existsSync(), isFalse);
    });

    test('resume tells rate meters how many bytes come back from disk (regression: speed counted the .part)', () async {
      final dir = await Directory.systemTemp.createTemp('replayed');
      addTearDown(() => dir.delete(recursive: true));
      final body = List.generate(1000, (i) => i % 256);
      final c = Http.client(resume: true);
      final to = _Path('${dir.path}/f.bin');
      await File('${to.path}.part').writeAsBytes(body.sublist(0, 400));
      final resumed = _Replays();
      await (c.get('$url/file') | resumed > to);
      expect((resumed.replayed, resumed.bytes), (400, 1000));
      final skipped = _Replays();
      await (c.get('$url/file') | skipped > to);
      expect((skipped.replayed, skipped.bytes), (1000, 1000));
    });

    test('pool: round-robin over idle members; a 429 benches a member and retries on another', () async {
      final a = Http.client(headers: {'x-a': 'a'});
      final b = Http.client(headers: {'x-a': 'b'});
      final both = Http.pool([a, b]);
      expect([for (var i = 0; i < 4; i++) await both.get('$url/busy').text()], ['a', 'b', 'a', 'b']);
      final busy = Http.client(headers: {'x-a': 'busy'});
      final p = Http.pool([busy, b]);
      expect([for (var i = 0; i < 3; i++) await p.get('$url/busy').text()], ['b', 'b', 'b']);
      expect(hits['/busy'], 4 + 4); // one 429 from `busy`, then it stays benched
      await p.close();
      await both.close();
    });

    test('pool: with every member benched, a retry waits for the first one back', () async {
      final p = Http.pool([Http.client(retries: 2, check: false), Http.client(retries: 2, check: false)]);
      final sw = Stopwatch()..start();
      expect(await p.get('$url/banned').status(), 429);
      expect(hits['/banned'], 3);
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 900))); // was ~10 ms: straight into the ban
      await p.close();
    });

    test('limit: caps a body read into memory, decoded size included; piping is unlimited', () async {
      final small = Http.client(max: 1000);
      await expectLater(
        small.get('$url/gzip').text(),
        throwsA(isA<ContentException>().having((e) => e.message, 'message', contains('over 1000 bytes'))),
      );
      final sink = Collect();
      await (small.get('$url/gzip') > sink);
      expect(sink.data, hasLength(5000));
      expect((await Http.client().get('$url/gzip').text()).length, 5000);
      expect(() => Http.client(max: -1), throwsArgumentError);
      await small.close();
    });

    test('size() is null for a body decoded on the fly', () async {
      final res = await Http.client().get('$url/gzip');
      expect(res.size(), isNull);
      expect((await res.text()).length, 5000);
    });

    test('lines() works on an error page, like text()', () async {
      final res = await Http.client(check: false).get('$url/missing');
      expect(await res.lines().toList(), ['line 1', 'line 2']);
    });

    test('piping an error page throws what check() throws', () async {
      final res = await Http.client(check: false).get('$url/missing');
      await expectLater(
        res > Collect(),
        throwsA(
          isA<HttpStatusException>()
              .having((e) => e.method, 'method', 'GET')
              .having((e) => e.snippet, 'snippet', 'line 1 line 2'),
        ),
      );
    });
  });
}

/// A pass-through pipe that counts bytes, marked as such like a Bar.
final class _Count with Pipe implements PassThrough {
  var bytes = 0;
  @override
  Stream<List<int>> transform(Stream<List<int>> input) => input.map((c) {
    bytes += c.length;
    return c;
  });
}

/// A pass-through pipe that hears the replay count, as `Speed` does.
final class _Replays with Pipe implements PassThrough {
  _Replays() {
    replays[this] = (n) => replayed += n;
  }
  var replayed = 0;
  var bytes = 0;
  @override
  Stream<List<int>> transform(Stream<List<int>> input) => input.map((c) {
    bytes += c.length;
    return c;
  });
}

/// A pipe with no pass-through promise.
final class _Plain with Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) => input;
}

/// A writer that reports a path, as an fs `File` does.
final class _Path with Writer {
  _Path(this.path);
  final String path;
  @override
  Origin origin() => Origin(path: path);
  @override
  Future<void> consume(Stream<List<int>> input) async {
    final sink = File(path).openWrite();
    await sink.addStream(input);
    await sink.close();
  }
}

void serveTests() {
  test('cookies: no registry domain like co.uk, no Secure cookie over http', () {
    final c = Cookies();
    jar.storeSetCookies(c, Uri.parse('https://evil.co.uk/'), ['sid=EVIL; Domain=co.uk']);
    jar.storeSetCookies(c, Uri.parse('http://shop.example.com/'), ['s=1; Secure', 'p=2']);
    jar.storeSetCookies(c, Uri.parse('https://a.example.com/'), ['d=3; Domain=example.com']);
    expect(jar.headerFor(c, Uri.parse('https://bank.co.uk/')), isNull);
    expect(jar.headerFor(c, Uri.parse('https://shop.example.com/')), 'p=2; d=3');
  });

  test('S6: plain http cannot overwrite a Secure cookie', () {
    final c = Cookies();
    jar.storeSetCookies(c, Uri.parse('https://bank.example/'), ['sid=REAL; Secure; Path=/']);
    jar.storeSetCookies(c, Uri.parse('http://bank.example/'), ['sid=TOSSED; Path=/', 'other=1']);
    jar.storeSetCookies(c, Uri.parse('http://www.bank.example/'), ['sid=TOSSED; Domain=bank.example; Path=/a']);
    expect(jar.headerFor(c, Uri.parse('https://bank.example/a')), 'sid=REAL; other=1');
    jar.storeSetCookies(c, Uri.parse('https://bank.example/'), ['sid=NEW; Path=/']); // https may
    expect(jar.headerFor(c, Uri.parse('https://bank.example/')), 'sid=NEW; other=1');
  });

  test('S6: Domain= on a shared host or a registry name is refused', () {
    for (final (setter, domain, victim) in [
      ('https://evil.blogspot.de/', 'blogspot.de', 'https://victim.blogspot.de/'),
      ('https://evil.blogspot.co.uk/', 'blogspot.co.uk', 'https://victim.blogspot.co.uk/'),
      ('https://evil.city.tokyo.jp/', 'tokyo.jp', 'https://shop.tokyo.jp/'),
      ('https://evil.s3.eu-west-1.amazonaws.com/', 's3.eu-west-1.amazonaws.com', 'https://victim.s3.eu-west-1.amazonaws.com/'),
      ('https://evil.uk.com/', 'uk.com', 'https://victim.uk.com/'),
      ('https://evil.example.com.br/', 'com.br', 'https://victim.com.br/'),
      ('https://evil.shop.za/', 'shop.za', 'https://victim.shop.za/'),
    ]) {
      final k = Cookies();
      jar.storeSetCookies(k, Uri.parse(setter), ['sid=TOSSED; Domain=$domain; Path=/']);
      expect(jar.headerFor(k, Uri.parse(victim)), isNull, reason: domain);
    }
    final ok = Cookies();
    for (final (setter, domain) in [
      ('https://www.nicovideo.jp/', 'nicovideo.jp'),
      ('https://www.spiegel.de/', 'spiegel.de'),
      ('https://mail.example.co.uk/', 'example.co.uk'),
      ('https://a.mybucket.s3.amazonaws.com.example/', 'amazonaws.com.example'),
    ]) {
      jar.storeSetCookies(ok, Uri.parse(setter), ['d=1; Domain=$domain']);
      expect(jar.headerFor(ok, Uri.parse('https://other.$domain/')), 'd=1', reason: domain);
    }
  });

  test('a transport error names the request without its credentials or tokens', () async {
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    raw.listen((s) async {
      s.write('HTTP/1.1 200 OK\r\nx-half: ');
      await s.flush();
      await s.close();
    });
    addTearDown(raw.close);
    final err = await Http.client(retries: 0)
        .get('http://u:pw@127.0.0.1:${raw.port}/a?token=SECRET&page=2')
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(err, isA<HttpException>());
    expect('$err', allOf(contains('token=***'), isNot(contains('SECRET')), isNot(contains('pw'))));
  });
}

/// A pipe that fails on its first chunk (not a transport error).
final class _Broken with Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    await for (final _ in input) {
      throw StateError('pipe broke');
    }
  }
}

final class _Heard with Probe {
  _Heard(this._heard);
  final List<(int, int?)> _heard;
  @override
  void update(int done, int? total) => _heard.add((done, total));
}
