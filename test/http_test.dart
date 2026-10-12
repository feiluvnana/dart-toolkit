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
  });

  group('Http.post', () {
    test('sends body, returns status/text/header', () async {
      final res = await Http.post('$base/echo', body: 'a=1');
      expect(res.status(), HttpStatus.created);
      expect(res.text(), 'got:a=1');
      expect(res.header('x-echo'), 'yes');
    });
  });

  group('other verbs', () {
    test('put sends body', () async {
      final res = await Http.put('$base/item', body: 'a=1');
      expect(res.status(), HttpStatus.ok);
      expect(res.text(), 'put:a=1');
    });

    test('patch sends body', () async {
      final res = await Http.patch('$base/item', body: 'b=2');
      expect(res.status(), HttpStatus.ok);
      expect(res.text(), 'patch:b=2');
    });

    test('delete works', () async {
      final res = await Http.delete('$base/item');
      expect(res.status(), HttpStatus.ok);
      expect(res.text(), 'deleted');
    });

    test('head returns status, empty text', () async {
      final res = await Http.head('$base/hello');
      expect(res.status(), HttpStatus.ok);
      expect(res.text(), isEmpty);
    });

    test('options returns allow header', () async {
      final res = await Http.options('$base/hello');
      expect(res.status(), HttpStatus.ok);
      expect(res.header('allow'), contains('GET'));
    });
  });
}
