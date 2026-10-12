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
      if (path == '/hello') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..write('hello <b>world</b>');
      } else if (path == '/echo' && request.method == 'POST') {
        final body = await request.cast<List<int>>().transform(utf8.decoder).join();
        request.response
          ..statusCode = HttpStatus.created
          ..headers.set('x-echo', 'yes')
          ..write('got:$body');
      } else if (path == '/headers') {
        request.response
          ..statusCode = HttpStatus.ok
          ..write(request.headers.value('x-test') ?? 'none');
      } else if (path == '/slow') {
        await Future<void>.delayed(const Duration(seconds: 5));
        request.response
          ..statusCode = HttpStatus.ok
          ..write('slow');
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('nope');
      }
      await request.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  group('Http.get', () {
    test('returns status/text/header', () async {
      final res = await Http.get('$base/hello');
      expect(res.status(), HttpStatus.ok);
      expect(res.text(), 'hello <b>world</b>');
      expect(res.header('content-type'), contains('text/plain'));
    });

    test('header() is case-insensitive, null if absent', () async {
      final res = await Http.get('$base/hello');
      expect(res.header('Content-Type'), res.header('content-type'));
      expect(res.header('missing'), isNull);
    });

    test('sends request headers', () async {
      final res = await Http.get('$base/headers', headers: {'x-test': 'hi'});
      expect(res.text(), 'hi');
    });

    test('non-2xx is still a Response', () async {
      final res = await Http.get('$base/nope');
      expect(res.status(), HttpStatus.notFound);
      expect(res.text(), 'nope');
    });

    test('timeout throws TimeoutException', () async {
      expect(
        Http.get('$base/slow', timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('Http.post', () {
    test('sends body, returns status/text/header', () async {
      final res = await Http.post('$base/echo', body: 'a=1');
      expect(res.status(), HttpStatus.created);
      expect(res.text(), 'got:a=1');
      expect(res.header('x-echo'), 'yes');
    });
  });
}
