// `proxy:` against loopback fakes: SOCKS5 replies, address types, a close
// mid-handshake, long fields, and an http proxy that wants a login.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/http.dart';
import 'package:test/test.dart';

/// A one-shot SOCKS5 proxy: [script] answers the handshake (it gets the
/// bytes so far and the socket); after a success reply the socket speaks
/// HTTP and answers `via socks`.
Future<ServerSocket> socks(FutureOr<bool> Function(List<int> greeting, Socket s, Stream<Uint8List> rest) script) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((s) async {
    try {
      final input = s.asBroadcastStream();
      final greeting = await input.first;
      if (!await script(greeting, s, input)) return;
      await input.first; // the HTTP request
      s.add(latin1.encode('HTTP/1.1 200 OK\r\ncontent-length: 9\r\nconnection: close\r\n\r\nvia socks'));
      await s.flush();
      await s.close();
    } on StateError {
      s.destroy(); // the client hung up first
    }
  });
  return server;
}

/// Accept no login, read the connect request, answer [reply] with an
/// address of [type] (1 IPv4, 3 a name, 4 IPv6).
FutureOr<bool> Function(List<int>, Socket, Stream<Uint8List>) answer(int reply, {int type = 1}) =>
    (greeting, s, rest) async {
      s.add([5, 0]);
      await rest.first;
      s.add([
        5, reply, 0, type, //
        ...switch (type) {
          1 => [127, 0, 0, 1],
          4 => List.filled(16, 0),
          _ => [9, ...'localhost'.codeUnits],
        },
        0, 80,
      ]);
      return reply == 0;
    };

void main() {
  Future<String> through(ServerSocket p, {String scheme = 'socks5', String host = 'example.test'}) =>
      Http.client(proxy: '$scheme://127.0.0.1:${p.port}', retries: 0, timeout: const Duration(seconds: 5))
          .get('http://$host/')
          .text();

  for (final type in [1, 3, 4]) {
    test('T5: a success reply with address type $type tunnels the request', () async {
      final p = await socks(answer(0, type: type));
      addTearDown(p.close);
      expect(await through(p), 'via socks');
    });
  }

  test('T5: a failure reply is named', () async {
    final p = await socks(answer(5));
    addTearDown(p.close);
    await expectLater(through(p), throwsA(predicate((e) => '$e'.contains('connection refused for example.test:80'))));
  });

  test('T5: a proxy that closes mid-handshake is named', () async {
    final p = await socks((greeting, s, rest) async {
      await s.close();
      return false;
    });
    addTearDown(p.close);
    await expectLater(through(p), throwsA(predicate((e) => '$e'.contains('SOCKS proxy closed the connection'))));
  });

  test('T5: a login the proxy refuses is named', () async {
    final p = await socks((greeting, s, rest) async {
      s.add([5, 2]); // user/pass
      await rest.first;
      s.add([1, 1]); // refused
      return false;
    });
    addTearDown(p.close);
    final c = Http.client(proxy: 'socks5://u:p@127.0.0.1:${p.port}', retries: 0);
    await expectLater(c.get('http://example.test/').text(), throwsA(predicate((e) => '$e'.contains('login refused'))));
  });

  test('S11: SOCKS fields over 255 bytes are refused, not truncated into another host', () async {
    expect(() => Http.client(proxy: 'socks5://${'u' * 256}:p@127.0.0.1:1'), throwsArgumentError);
    final p = await socks(answer(0));
    addTearDown(p.close);
    await expectLater(
      through(p, host: '${'a' * 63}.${'b' * 63}.${'c' * 63}.${'d' * 63}.test'),
      throwsA(predicate((e) => '$e'.contains('over 255 bytes'))),
    );
  });

  test('S12: a bad proxy URL is reported without its password', () {
    expect(
      () => Http.client(proxy: 'ftp://user:SECRET@host'),
      throwsA(isA<ArgumentError>().having((e) => '$e', 'text', isNot(contains('SECRET')))),
    );
  });

  test('T5: an http proxy that asks for a login gets the URL\'s credentials', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final want = 'Basic ${base64Encode(utf8.encode('u:p w'))}';
    server.listen((r) {
      if (r.headers.value('proxy-authorization') != want) {
        r.response
          ..statusCode = 407
          ..headers.set('proxy-authenticate', 'Basic realm="p"');
      } else {
        r.response.write('authed ${r.uri}');
      }
      r.response.close();
    });
    final c = Http.client(proxy: 'http://u:p%20w@127.0.0.1:${server.port}', retries: 0);
    expect(await c.get('http://example.test/x').text(), 'authed http://example.test/x');
  });
}
