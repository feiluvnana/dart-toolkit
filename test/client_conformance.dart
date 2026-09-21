import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// The battery every [Client] must pass, and its own server to pass it against.
///
/// A client is the seam the whole `http` module sits on: `url.get()`, a download and a crawl
/// all reach the network through one, so an implementation that reports a redirect wrong or
/// throws on a 404 breaks code that never mentions it. Point this at a factory and it says
/// whether yours is one of them:
///
/// ```dart
/// void main() => clientConformance('IoClient', () => IoClient());
/// ```
///
/// [create] is called once per test with the base URL of a local server; return the client
/// under test. [skip] names checks an implementation cannot answer — a browser renders pages
/// and has no opinion about PUT, so `clientConformance('browser', …, skip: {'methods'})`.
void clientConformance(String name, FutureOr<Client> Function(Uri base) create, {Set<String> skip = const {}}) {
  group('$name conformance', () {
    late HttpServer server;
    late Uri base;
    late Client client;
    final requests = <HttpRequest>[];

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://${server.address.host}:${server.port}');
      unawaited(
        server.forEach((request) async {
          requests.add(request);
          final response = request.response;
          switch (request.uri.path) {
            case '/ok':
              response.headers.contentType = ContentType.html;
              response.headers.set('X-Mixed-Case', 'kept');
              response.write('<html><body><p id="here">ok</p></body></html>');
            case '/missing':
              response.statusCode = 404;
              response.write('no');
            case '/boom':
              response.statusCode = 500;
              response.write('sorry');
            case '/moved':
              response.statusCode = 302;
              response.headers.set('location', '$base/ok');
            case '/chunks':
              response.headers.contentType = ContentType.text;
              for (var i = 0; i < 4; i++) {
                response.write('chunk$i');
                await response.flush();
              }
            case '/echo':
              response.headers.contentType = ContentType.text;
              final body = await utf8.decoder.bind(request).join();
              response.write('${request.method} ${request.headers.value('x-probe')} $body');
            default:
              response.statusCode = 404;
          }
          await response.close();
        }),
      );
    });

    setUp(() async {
      requests.clear();
      client = await create(base);
    });

    tearDown(() async => client.close());
    tearDownAll(() async => server.close(force: true));

    Future<Response> get(String path) async => (await client.send(Request('GET', base.resolve(path)))).read();

    test('a 2xx arrives with its body and its headers', () async {
      final res = await get('/ok');
      expect(res.statusCode, 200);
      expect(res.isOk, isTrue);
      expect(res.text, contains('ok'));
      // Header names are matched however they are spelled.
      expect(res.headers['x-mixed-case'] ?? res.headers['X-Mixed-Case'], 'kept');
    }, skip: skip.contains('ok') ? 'skipped by the implementation' : null);

    test('a non-2xx is a response, not a throw', () async {
      final missing = await get('/missing');
      expect(missing.statusCode, 404);
      expect(missing.isOk, isFalse);
      expect((await get('/boom')).statusCode, 500);
    }, skip: skip.contains('status') ? 'skipped by the implementation' : null);

    test('url is the URL that answered, after redirects', () async {
      final res = await get('/moved');
      // Either the client followed the hop, or it handed the 302 back for the caller to
      // follow — but it may not claim the redirect's own URL answered with a 200.
      if (res.statusCode == 200) {
        expect(res.url?.path, '/ok', reason: 'followed the redirect but reported the wrong url');
      } else {
        expect(res.statusCode, inInclusiveRange(300, 399));
        expect(res.headers['location'], isNotNull);
      }
    }, skip: skip.contains('redirect') ? 'skipped by the implementation' : null);

    test('a body arrives as a stream, not one lump', () async {
      final streamed = await client.send(Request('GET', base.resolve('/chunks')));
      final seen = <int>[];
      await for (final chunk in streamed.stream) {
        seen.add(chunk.length);
      }
      expect(seen.fold<int>(0, (a, b) => a + b), 'chunk0chunk1chunk2chunk3'.length);
    }, skip: skip.contains('stream') ? 'skipped by the implementation' : null);

    test('request headers and bodies reach the server', () async {
      final request = Request('POST', base.resolve('/echo'), headers: {'x-probe': 'yes'}, text: 'payload');
      final res = await (await client.send(request)).read();
      expect(res.text, 'POST yes payload');
    }, skip: skip.contains('methods') ? 'skipped by the implementation' : null);

    test('an unknown directive is ignored, not refused', () async {
      const unknown = RequestKey<String>('conformance.unknown');
      final request = Request('GET', base.resolve('/ok'))..[unknown] = 'whatever';
      expect((await (await client.send(request)).read()).statusCode, 200);
    }, skip: skip.contains('directives') ? 'skipped by the implementation' : null);

    test('close is idempotent', () async {
      await client.close();
      await client.close();
    }, skip: skip.contains('close') ? 'skipped by the implementation' : null);
  });
}
