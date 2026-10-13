import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/http.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late String base;

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
      } else if (path == '/stall') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('a');
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 5));
        request.response.write('b');
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

    test('redirects are followed, url() is final', () async {
      final res = await Http.get('$base/redirect');
      expect(res.status(), HttpStatus.ok);
      expect(res.url(), '$base/hello');
      expect(await res.text(), contains('hello'));
    });

    test('post sends body, returns status/text/header', () async {
      final res = await Http.post('$base/echo', body: 'a=1');
      expect(res.status(), HttpStatus.created);
      expect(await res.text(), 'got:a=1');
      expect(res.header('x-echo'), 'yes');
    });

    test('put sends body', () async {
      final res = await Http.put('$base/item', body: 'a=1');
      expect(await res.text(), 'put:a=1');
    });

    test('patch sends body', () async {
      final res = await Http.patch('$base/item', body: 'b=2');
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
      final res = await Http.post('$base/echo', body: utf8.encode('a=2'));
      expect(await res.text(), 'got:a=2');
    });

    test('body streams a Reader', () async {
      final res = await Http.put(
        '$base/upload',
        body: _Mem('0123456789'),
        headers: {'content-length': '10'},
      );
      expect(await res.text(), 'size:10;length:10');
    });

    test('wrong body type is an ArgumentError', () async {
      expect(
        Http.post('$base/echo', body: 42),
        throwsArgumentError,
      );
    });
  });

  group('Response as Reader', () {
    test('text() decodes with the charset header', () async {
      final res = await Http.get('$base/latin');
      expect(await res.text(), 'caf\u00e9');
    });

    test('text() and bytes() cache: calling again is free', () async {
      final res = await Http.get('$base/hello');
      final a = await res.text();
      expect(await res.text(), a);
      expect(await res.bytes(), utf8.encode(a));
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

    test('a failed pipe releases the connection', () async {
      final res = await Http.get('$base/hello');
      await expectLater(res > _BoomWriter(), throwsStateError);
      // The socket must not linger: close() is a no-op, not a hang.
      await res.close().timeout(const Duration(seconds: 5));
    });

    test('Future mirrors match', () async {
      final f = Http.get('$base/hello');
      expect(await f.status(), HttpStatus.ok);
      expect(await f.header('content-type'), contains('text/plain'));
      expect(await f.url(), '$base/hello');
      expect(await f.text(), contains('hello'));
      await f.close();
    });
  });
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(utf8.encode(_text));
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
