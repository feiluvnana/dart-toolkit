import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/http.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The battery every [Client] must pass, against its own local server.
///
/// ```dart
/// void main() => clientConformance('IoClient', (_) => IoClient());
/// ```
///
/// [create] is called once per test with the server's base URL. [skip] names checks an
/// implementation cannot answer — `skip: {'methods'}` for a browser.
void clientConformance(String name, FutureOr<Client> Function(Uri base) create, {Set<String> skip = const {}}) {
  group('$name conformance', () {
    late HttpServer server;
    late Uri base;
    late Client client;
    final requests = <HttpRequest>[];
    String? skipped(String check) => skip.contains(check) ? 'skipped by the implementation' : null;

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
            case '/upload':
              response.headers.contentType = ContentType.text;
              final body = await utf8.decoder.bind(request).join();
              response.write('${request.headers.contentLength} ${body.length} $body');
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
    }, skip: skipped('ok'));

    test('a non-2xx is a response, not a throw', () async {
      final missing = await get('/missing');
      expect(missing.statusCode, 404);
      expect(missing.isOk, isFalse);
      expect((await get('/boom')).statusCode, 500);
    }, skip: skipped('status'));

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
    }, skip: skipped('redirect'));

    test('a body arrives as a stream, not one lump', () async {
      final streamed = await client.send(Request('GET', base.resolve('/chunks')));
      final seen = <int>[];
      await for (final chunk in streamed.stream) {
        seen.add(chunk.length);
      }
      expect(seen.fold<int>(0, (a, b) => a + b), 'chunk0chunk1chunk2chunk3'.length);
    }, skip: skipped('stream'));

    test('request headers and bodies reach the server', () async {
      final request = Request('POST', base.resolve('/echo'), headers: {'x-probe': 'yes'}, text: 'payload');
      final res = await (await client.send(request)).read();
      expect(res.text, 'POST yes payload');
    }, skip: skipped('methods'));

    test('a streamed body reaches the server, and its length was announced', () async {
      // `files:` never fills `Request.bytes`, so an implementation that sends that field
      // instead of `Request.open()` sends an empty body with a content-length that lies.
      final dir = tempDir('tk_upload_');
      final file = File('$dir/note.txt')..writeAsStringSync('the payload');
      final request = Request('POST', base.resolve('/upload'), form: {'title': 'x'}, files: {'doc': file.path});
      final res = await (await client.send(request)).read();
      final [announced, received, ...] = res.text.split(' ');
      expect(announced, received, reason: 'content-length did not match what arrived');
      expect(res.text, contains('the payload'));
      expect(res.text, contains('name="title"'));
      expect(res.text, contains('filename="note.txt"'));
    }, skip: skipped('methods'));

    test('an unknown directive is ignored, not refused', () async {
      const unknown = RequestKey<String>('conformance.unknown');
      final request = Request('GET', base.resolve('/ok'))..[unknown] = 'whatever';
      expect((await (await client.send(request)).read()).statusCode, 200);
    }, skip: skipped('directives'));

    test('close is idempotent', () async {
      await client.close();
      await client.close();
    }, skip: skipped('close'));
  });
}
