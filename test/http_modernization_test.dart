import 'dart:async';
import 'dart:convert';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('v7.0 HTTP Modernization & Ergonomics', () {
    late Server server;

    setUp(() async {
      server = await net.serve(0, (Asked req) async {
        return switch (req.path) {
          '/hello' => const Served.text('hello world'),
          '/json' => Served.json({'message': 'ok', 'count': 42}),
          '/echo' => Served.text(await req.text()),
          '/hop1' => Served.redirect('/hop2'.url),
          '/hop2' => Served.redirect('/hop3'.url),
          '/hop3' => const Served.text('reached hop 3'),
          '/headers' => Served.json(req.headers),
          _ => Served.status(404),
        };
      });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => 'http://localhost:${server.port}$path'.url;

    test('HTTP convenience verbs on net.http and net', () async {
      final resGet = await net.http.get(at('/hello'));
      expect(resGet.status, 200);
      expect(resGet.text, 'hello world');
      expect(resGet.body, 'hello world');

      final resPost = await net.http.post(
        at('/echo'),
        body: const Body.text('posted body'),
      );
      expect(resPost.status, 200);
      expect(resPost.text, 'posted body');

      final resNet = await net.get(at('/hello'));
      expect(resNet.status, 200);
      expect(resNet.text, 'hello world');

      final resPut = await net.put(at('/echo'), body: const Body.text('put body'));
      expect(resPut.status, 200);
      expect(resPut.text, 'put body');

      final resDelete = await net.delete(at('/hello'));
      expect(resDelete.status, 200);
    });

    test('Method tear-offs work directly with concurrent.run over native List', () async {
      final urls = [at('/hello'), at('/hello'), at('/hello')];
      // Passing raw List<Uri> and net.http.get tear-off without .seq or wrappers
      final replies = await concurrent.run(urls, net.http.get, size: 2);
      expect(replies.length, 3);
      for (final r in replies) {
        expect(r.status, 200);
        expect(r.text, 'hello world');
      }
    });

    test('Fluent HTTP extensions on Uri', () async {
      final reply = await at('/json').get();
      expect(reply.status, 200);
      expect(reply.json.text('message'), 'ok');
      expect(reply.json.number('count'), 42);
      expect(reply.jsonDecoded<Map<String, dynamic>>()['message'], 'ok');

      final echoReply = await at('/echo').post(body: const Body.text('via uri extension'));
      expect(echoReply.text, 'via uri extension');
    });

    test('Sane redirect defaults follow redirects automatically', () async {
      // By default redirects: 5 follows hop1 -> hop2 -> hop3
      final res = await net.http.get(at('/hop1'));
      expect(res.status, 200);
      expect(res.text, 'reached hop 3');

      // Explicit opt-out with redirects: 0 holds at 302
      final held = await net.http.get(at('/hop1'), redirects: 0);
      expect(held.status, 302);
      expect(held.headers['location'], '/hop2');
    });

    test('Zone-scoped client isolation with net.withClient', () async {
      final mock = Fetcher(pool: _MockClient());

      await net.withClient(mock, () async {
        final res = await net.http.get('https://example.test/mock'.url);
        expect(res.status, 200);
        expect(res.text, 'mocked response');
      });

      // Outside the zone, standard client is restored
      final realRes = await net.http.get(at('/hello'));
      expect(realRes.text, 'hello world');
    });

    test('Streaming response body via Reply.stream and Fetcher.stream', () async {
      final reply = await net.http.stream(HttpMethod.get, at('/hello'));
      expect(reply.status, 200);
      final chunks = await reply.stream.toList();
      final fullBody = utf8.decode(chunks.expand((c) => c).toList());
      expect(fullBody, 'hello world');
    });

    test('package:http ecosystem conversions', () async {
      final reply = await net.http.get(at('/hello'));
      final httpResponse = reply.toHttpResponse();
      expect(httpResponse.statusCode, 200);
      expect(httpResponse.body, 'hello world');

      final reconstructed = Reply.fromHttpResponse(httpResponse);
      expect(reconstructed.status, 200);
      expect(reconstructed.text, 'hello world');
    });
  });
}

class _MockClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = utf8.encode('mocked response');
    return http.StreamedResponse(
      Stream.value(bytes),
      200,
      contentLength: bytes.length,
      request: request,
    );
  }
}
