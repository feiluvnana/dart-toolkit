import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// Fetches [url], retrying while nothing is listening yet.
Future<Reply> _reach(Uri url) =>
    concurrent.retry(() => net.http.get(url), times: 40, backoff: 25.ms);

void main() {
  group('net.serve', () {
    late Server server;

    setUp(() async {
      server = await net.serve(0, (req) async {
        return switch (req.path) {
          '/callback' => Served.text(req.query['code'] ?? ''),
          '/health' => Served.json({'ok': true}),
          '/bytes' => Served.bytes([1, 2, 3]),
          '/away' => Served.redirect('/health'),
          '/echo' => Served.json((await req.json()).raw),
          '/body' => Served.text(await req.text()),
          '/method' => Served.text(req.method.wire),
          '/head' => Served.text(req.headers['x-token'] ?? ''),
          '/boom' => throw StateError('handler blew up'),
          _ => Served.status(404),
        };
      });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => Uri.parse('http://localhost:${server.port}$path');

    test('binds port 0 and reports the port it got', () async {
      expect(server.port, greaterThan(0));
      expect(server.host, isNotEmpty);
      expect(server.toString(), contains('${server.port}'));

      // Still answers after close: the socket throws once unbound, and a
      // script logging where it *was* listening should not be the crash.
      final port = server.port;
      await server.close(force: true);
      expect(server.port, equals(port));
      expect(server.host, isNotEmpty);
    });

    test('a text reply carries the body and the type', () async {
      final res = await net.http.get(at('/callback?code=abc123'));
      expect(res.status, equals(200));
      expect(res.body, equals('abc123'));
      expect(res.headers['content-type'], contains('text/plain'));
    });

    test('a json reply comes back through the cursor', () async {
      final res = await net.http.get(at('/health'));
      expect(res.parse(format.json).at('ok').flag(), isTrue);
      expect(res.headers['content-type'], contains('application/json'));
    });

    test('bytes, status and redirect', () async {
      expect((await net.http.get(at('/bytes'))).bytes, equals([1, 2, 3]));
      expect((await net.http.get(at('/nope'))).status, equals(404));
      expect((await net.http.get(at('/nope'))).body, equals('Not Found'));
      final followed = await net.http.get(at('/away'));
      expect(
        followed.parse(format.json).at('ok').flag(),
        isTrue,
        reason: 'redirect followed',
      );
      final raw = await net.http.get(at('/away'), redirect: false);
      expect(raw.status, equals(302));
      expect(raw.headers['location'], equals('/health'));
    });

    test('a file reply streams, and a missing one is a 404', () async {
      final dir = io.temp('dt_serve_');
      try {
        final page = io.join(dir.path, 'index.html');
        io.write(page, '<h1>hi</h1>');
        final one = await net.serve(0, (req) async => Served.file(page));
        try {
          final res = await net.http.get(
            Uri.parse('http://localhost:${one.port}/'),
          );
          expect(res.body, equals('<h1>hi</h1>'));
          expect(res.headers['content-type'], contains('text/html'));
        } finally {
          await one.close(force: true);
        }

        final gone = await net.serve(
          0,
          (req) async => Served.file(io.join(dir.path, 'absent.html')),
        );
        try {
          expect(
            (await net.http.get(
              Uri.parse('http://localhost:${gone.port}/'),
            )).status,
            equals(404),
          );
        } finally {
          await gone.close(force: true);
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('a request exposes its method, headers and body three ways', () async {
      expect((await net.http.post(at('/method'))).body, equals('POST'));
      expect(
        (await net.http.get(at('/head'), headers: {'X-Token': 'k'})).body,
        equals('k'),
      );
      expect(
        (await net.http.post(at('/body'), body: Body.text('hello'))).body,
        equals('hello'),
      );
      final echoed = await net.http.post(
        at('/echo'),
        body: Body.json({'n': 1}),
      );
      expect(echoed.parse(format.json).at('n').number(), equals(1));
    });

    test('a handler that throws is a 500, not a dead socket', () async {
      expect((await net.http.get(at('/boom'))).status, equals(500));
      expect(
        (await net.http.get(at('/health'))).status,
        equals(200),
        reason: 'the server is still listening',
      );
    });
  });

  group('net.once', () {
    test('serves until the handler answers, then closes', () async {
      final probe = await net.serve(0, (req) async => Served.status(404));
      final port = probe.port;
      await probe.close(force: true);

      final waiting = net.once(port, (req) => req.query['code']);
      // The first request has no code, so the wait goes on. Retried, because
      // `once` binds asynchronously and the test does not hold its Server.
      final ignored = await _reach(
        Uri.parse('http://localhost:$port/callback'),
      );
      expect(ignored.status, equals(404));

      final answered = await _reach(
        Uri.parse('http://localhost:$port/callback?code=xyz'),
      );
      expect(answered.body, contains('close this tab'));
      expect(await waiting, equals('xyz'));
    });

    test('a timeout gives up and returns null', () async {
      final probe = await net.serve(0, (req) async => Served.status(404));
      final port = probe.port;
      await probe.close(force: true);

      expect(
        await net.once(port, (req) => req.query['code'], timeout: 150.ms),
        isNull,
      );
    });
  });
}
