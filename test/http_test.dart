import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/scrape.dart';
import 'package:test/test.dart' hide Retry;

import 'client_conformance.dart';
import 'support.dart';

/// Quick retries, so a test of them takes milliseconds.
const _quick = Retry(2, backoff: Duration(milliseconds: 1));

/// An in-process SOCKS5 server (RFC 1928, RFC 1929 login): it records each CONNECT as
/// `host:port` and pipes the connection to the loopback port [targets] names for that host.
final class _Socks5 {
  final ServerSocket _server;
  final Map<String, int> targets;
  final String? user;
  final String? password;
  final asked = <String>[];

  _Socks5._(this._server, this.targets, this.user, this.password) {
    _server.listen(_serve);
  }

  static Future<_Socks5> start({required Map<String, int> targets, String? user, String? password}) async =>
      _Socks5._(await ServerSocket.bind('127.0.0.1', 0), targets, user, password);

  int get port => _server.port;

  Future<void> close() => _server.close();

  Future<void> _serve(Socket client) async {
    final buffer = <int>[];
    final more = StreamController<void>.broadcast();
    var closed = false;
    final sub = client.listen(
      (b) {
        buffer.addAll(b);
        more.add(null);
      },
      onDone: () {
        closed = true;
        more.add(null);
      },
    );
    Future<List<int>> take(int n) async {
      while (buffer.length < n) {
        if (closed) throw StateError('client went away');
        await more.stream.first;
      }
      final out = buffer.sublist(0, n);
      buffer.removeRange(0, n);
      return out;
    }

    try {
      final greeting = await take(2);
      final methods = await take(greeting[1]);
      final wanted = user == null ? 0x00 : 0x02;
      if (!methods.contains(wanted)) {
        client.add([5, 0xff]);
        return client.destroy();
      }
      client.add([5, wanted]);
      if (wanted == 0x02) {
        final head = await take(2);
        final name = utf8.decode(await take(head[1]));
        final pass = utf8.decode(await take((await take(1))[0]));
        final ok = name == user && pass == password;
        client.add([1, ok ? 0 : 1]);
        if (!ok) return client.destroy();
      }
      final request = await take(4);
      final String host;
      switch (request[3]) {
        case 0x03:
          host = utf8.decode(await take((await take(1))[0]));
        case 0x01:
          host = (await take(4)).join('.');
        default:
          return client.destroy();
      }
      final portBytes = await take(2);
      asked.add('$host:${portBytes[0] << 8 | portBytes[1]}');
      final target = targets[host];
      if (target == null) {
        client.add([5, 4, 0, 1, 0, 0, 0, 0, 0, 0]); // host unreachable
        return client.destroy();
      }
      final upstream = await Socket.connect('127.0.0.1', target);
      client.add([5, 0, 0, 1, 127, 0, 0, 1, target >> 8, target & 0xff]);
      if (buffer.isNotEmpty) upstream.add(buffer);
      sub.onData(upstream.add);
      sub.onDone(upstream.destroy);
      upstream.listen(client.add, onDone: client.destroy, onError: (Object _) => client.destroy());
    } catch (_) {
      client.destroy();
    }
  }
}

/// A loopback server that answers [route] and counts what it was asked.
Future<(Uri, List<HttpRequest>)> _site(FutureOr<void> Function(HttpRequest r) route) async {
  final seen = <HttpRequest>[];
  final (_, base) = await serve((r) async {
    seen.add(r);
    await route(r);
  });
  return (base, seen);
}

void main() {
  group('requests', () {
    test('the verbs send their bodies with their content types', () async {
      final (base, _) = await _site((r) async {
        final body = await utf8.decoder.bind(r).join();
        r.response.write('${r.method} ${r.headers.contentType?.mimeType} $body');
      });
      expect(await (base / 'a').post(json: {'x': 1}).text, 'POST application/json {"x":1}');
      expect(await (base / 'a').put(text: 'hi').text, 'PUT text/plain hi');
      expect(
        await (base / 'a')
            .patch(
              form: {
                'q': 'a b',
                'n': null,
                'l': [1, 2],
              },
            )
            .text,
        'PATCH application/x-www-form-urlencoded q=a+b&l=1&l=2',
      );
      expect(await (base / 'a').delete().text, 'DELETE null ');
      expect(() => base.post(text: 'a', json: 1), throwsArgumentError);
    });

    test('a file: body streams with its length and type', () async {
      final dir = tempDir();
      final file = File('$dir/note.txt')..writeAsStringSync('the payload');
      final (base, _) = await _site((r) async {
        final body = await utf8.decoder.bind(r).join();
        r.response.write('${r.headers.contentLength} ${r.headers.contentType?.mimeType} $body');
      });
      expect(await base.put(file: file.path).text, '11 text/plain the payload');
    });

    test('sending copies the request: the caller\'s is untouched, and it can be sent twice', () async {
      final (base, seen) = await _site((r) => r.response.write('ok'));
      final request = Request('GET', base, headers: {'x-a': '1'});
      await request.send();
      await request.send();
      expect(seen, hasLength(2));
      expect(request.headers.keys, ['x-a']);
    });

    test('a HEAD redirected by a 303 stays a HEAD, a POST becomes a GET', () async {
      final (base, seen) = await _site((r) {
        if (r.uri.path == '/from') {
          r.response
            ..statusCode = 303
            ..headers.set('location', '/to#frag');
        }
      });
      await (base / 'from').head();
      await (base / 'from').post(text: 'x');
      expect([for (final r in seen) '${r.method} ${r.uri}'], ['HEAD /from', 'HEAD /to', 'POST /from', 'GET /to']);
    });
  });

  group('await is strict', () {
    late Uri base;
    setUp(() async {
      (base, _) = await _site((r) {
        if (r.uri.path == '/missing') {
          r.response
            ..statusCode = 404
            ..headers.contentType = ContentType.json
            ..write('{"error":"gone"}');
        } else {
          r.response.write('fine');
        }
      });
    });

    test('a 404 throws a StatusException that keeps the response', () async {
      final error = await (base / 'missing').get().then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<StatusException>().having((e) => e.response.json['error'].to<String>(), 'error', 'gone'));
      expect('$error', '404 Not Found from ${base}missing');
      await expectLater((base / 'missing').get().json, throwsA(isA<StatusException>()));
      await expectLater((base / 'missing').get().text, throwsA(isA<StatusException>()));
    });

    test('isOk and settled look without throwing', () async {
      expect(await (base / 'missing').head().isOk, isFalse);
      expect(await base.get().isOk, isTrue);
      expect(await (base / 'missing').get().settled, isA<Failed<Object?, Response>>());
      expect(await base.get().settled, isA<Done<Object?, Response>>());
    });

    test('a failure to answer is a ClientException, and isOk still throws it', () async {
      final socket = await ServerSocket.bind('127.0.0.1', 0);
      final dead = Uri.parse('http://127.0.0.1:${socket.port}/');
      await socket.close();
      await Http.scope(retry: Retry.none, () async {
        await expectLater(dead.get(), throwsA(isA<ClientException>()));
        await expectLater(dead.get().isOk, throwsA(isA<HttpException>()));
      });
    });

    test('a task is named by its host and path', () {
      final task = (base / 'a/b').get();
      expect(task.label, '127.0.0.1/a/b');
      expect(task.item, base / 'a/b');
      return task;
    });
  });

  group('the body streamed', () {
    test('arrives in pieces, never held, with the task reporting its bytes', () async {
      final (base, _) = await _site((r) async {
        r.response.contentLength = 8 * 4096;
        for (var i = 0; i < 8; i++) {
          r.response.add(List.filled(4096, i));
          await r.response.flush();
        }
      });
      final task = base.get();
      final amounts = <int>[];
      final listening = task.statuses.listen((s) {
        if (s case Running(:final received) when received > 0) amounts.add(received);
      }).asFuture<void>();
      var total = 0;
      await for (final chunk in task.stream) {
        total += chunk.length;
      }
      await listening;
      expect(total, 8 * 4096);
      expect(amounts.last, 8 * 4096);
      expect((await task).bytes, isEmpty, reason: 'streamed, so the response holds no body');
    });

    test('a non-2xx is a StatusException on the stream', () async {
      final (base, _) = await _site((r) => r.response.statusCode = 500);
      await Http.scope(retry: Retry.none, () async {
        await expectLater(base.get().stream.toList(), throwsA(isA<StatusException>()));
      });
    });
  });

  group('responses', () {
    test('rels reads the Link header by rel, resolved against the url', () {
      final res = Response(
        '',
        200,
        url: Uri.parse('https://api.x/items?page=1'),
        headers: {'link': '<?page=2>; rel="next", </items?page=9>; rel=last'},
      );
      expect(res.rels['next'], Uri.parse('https://api.x/items?page=2'));
      expect(res.rels['last'], Uri.parse('https://api.x/items?page=9'));
    });

    test('name: filename* in UTF-8 or ISO-8859-1, then filename, then the URL', () {
      Response named(String disposition) => Response(
        '',
        200,
        headers: {'content-disposition': disposition},
        url: Uri.parse('https://x/dl/file.bin?id=1'),
      );
      expect(named("attachment; filename*=UTF-8''caf%C3%A9.txt").name, 'café.txt');
      // The regression: a Latin-1 escape threw rather than naming the file.
      expect(named("attachment; filename*=iso-8859-1''caf%E9.txt").name, 'café.txt');
      expect(named('attachment; filename="../../etc/passwd"').name, 'passwd');
      expect(named('inline').name, 'file.bin');
      expect(Response('', 200, url: Uri.parse('https://x/')).name, '');
    });

    test('a body is decoded by the charset its header, a <meta> or a BOM declares', () {
      final latin = [0x63, 0x61, 0x66, 0xe9];
      expect(Response.bytes(latin, 200, headers: {'content-type': 'text/plain; charset=iso-8859-1'}).text, 'café');
      expect(
        Response.bytes(
          [...utf8.encode('<meta charset="windows-1252">'), 0x93],
          200,
          headers: {'content-type': 'text/html'},
        ).text,
        endsWith('“'),
      );
      expect(
        Response.bytes(
          [0xef, 0xbb, 0xbf, ...utf8.encode('é')],
          200,
          headers: {'content-type': 'text/plain; charset=latin1'},
        ).text,
        'é',
      );
      expect(
        Response.bytes(
          utf8.encode('{"a":"<meta charset=latin1>é"}'),
          200,
          headers: {'content-type': 'application/json'},
        ).text,
        contains('é'),
      );
    });

    test('res.html, res.json and res.xml read a response in hand, whatever its status', () {
      final res = Response('<p id="x">hi</p>', 500, headers: {'content-type': 'text/html'});
      expect(res.html.$('#x').first.text, 'hi');
      expect(identical(res.html, res.html), isTrue, reason: 'parsed once');
      expect(Response('{"a":[1,2]}', 404).json['a'].list, hasLength(2));
      expect(Response('<r><i>1</i></r>', 200).xml.$x('//i').first.text, '1');
    });
  });

  group('content encodings', () {
    final plain = utf8.encode('<p>${'hello ' * 200}</p>');
    test('gzip arrives decoded and no longer says it is encoded', () async {
      final (base, seen) = await _site((r) {
        r.response.headers.set('content-encoding', 'gzip');
        r.response.add(gzip.encode(plain));
      });
      final res = await base.get();
      expect(res.bytes, plain);
      expect(res.headers['content-encoding'], isNull);
      expect(seen.single.headers.value('accept-encoding'), contains('gzip'));
    });

    test('a download asks for the bytes as stored', () async {
      final (base, seen) = await _site((r) => r.response.write('x'));
      final dir = tempDir();
      await (base / 'f.bin').download(into: dir);
      expect(seen.single.headers.value('accept-encoding'), 'identity');
    });
  });

  group('Uri', () {
    test('/ joins a segment under the path; a colon stays a segment', () {
      final api = Uri.parse('https://x.com/api');
      expect(api / 'users', Uri.parse('https://x.com/api/users'));
      expect(api / 'projects:batchGet', Uri.parse('https://x.com/api/projects:batchGet'));
      expect(api / '../v2', Uri.parse('https://x.com/v2'));
    });

    test('withQuery adds, replaces and removes, keeping repeated keys', () {
      final url = Uri.parse('https://x/a?t=1&t=2&q=x');
      expect(url.withQuery({'q': 'y', 'n': 1}).queryParametersAll, {
        't': ['1', '2'],
        'q': ['y'],
        'n': ['1'],
      });
      expect(Uri.parse('https://x/a?q=x').withQuery({'q': null}), Uri.parse('https://x/a'));
    });

    test('name is one safe segment', () {
      expect(Uri.parse('https://x/t/song.mp3?x=1').name, 'song.mp3');
      expect(Uri.parse('https://x/a%2Fb%3Ac').name, 'a_b_c');
      expect(Uri.parse('https://x/con.txt').name, '_con.txt');
      expect(Uri.parse('https://x/..').name, '');
    });

    test("'…'.url parses", () => expect('https://x/a'.url, Uri.parse('https://x/a')));
  });

  group('Mime', () {
    test('reads its type, subtype and charset', () {
      final html = 'Text/HTML; charset="utf-8"'.mime;
      expect(html.type, 'text');
      expect(html.subtype, 'html');
      expect(html.charset, 'utf-8');
      expect('image/png'.mime.charset, isNull);
      expect('image/'.mime.subtype, '');
    });

    test('matches a content type: exactly, by a prefix, by a wildcard', () {
      expect('image/'.mime.matches('image/png; q=1'), isTrue);
      expect('image/*'.mime.matches('IMAGE/webp'), isTrue);
      expect('*/*'.mime.matches('application/json'), isTrue);
      expect('text/html'.mime.matches('text/html; charset=utf-8'), isTrue);
      expect('text/html'.mime.matches('text/plain'), isFalse);
      expect('image/'.mime.matches('not a type'), isFalse);
    });

    test('anything else is a FormatException', () {
      for (final bad in ['', 'image', '/png', 'text/html; charset', 'a b/c', 'text/html;=x']) {
        expect(() => Mime(bad), throwsFormatException, reason: bad);
      }
      expect(Mime('application/vnd.api+json; version=2'), 'application/vnd.api+json; version=2');
    });
  });

  group('scope', () {
    test('headers merge, names compared ignoring case, the inner winning', () async {
      final (base, seen) = await _site((r) => r.response.write('ok'));
      await Http.scope(headers: {'X-Who': 'outer', 'x-keep': 'k'}, () {
        return Http.scope(headers: {'x-who': 'inner'}, () => base.get());
      });
      expect(seen.single.headers.value('x-who'), 'inner');
      expect(seen.single.headers.value('x-keep'), 'k');
    });

    test('a credential in headers: is an ArgumentError; bad settings are too', () {
      expect(() => Http.scope(headers: {'Authorization': 'x'}, () {}), throwsArgumentError);
      expect(() => Http.scope(headers: {'cookie': 'a=b'}, () {}), throwsArgumentError);
      expect(() => Http.scope(timeout: Duration.zero, () {}), throwsArgumentError);
      expect(() => Http.scope(delay: Duration.zero, () {}), throwsArgumentError);
      expect(() => Http.scope(perHost: 0, () {}), throwsArgumentError);
      expect(() => Http.scope(credentials: {'api.x': const Secret('t')}, () {}), throwsArgumentError);
      expect(() => Http.scope(credentials: {'https://x/path': const Secret('t')}, () {}), throwsArgumentError);
    });

    test('a redirect loop fails once, never retried: it would loop again', () async {
      var n = 0;
      final fake = Client.fake((r) {
        n++;
        return Response('', 302, headers: {'location': '/loop'});
      });
      await Http.scope(client: fake, retry: _quick, () async {
        await expectLater(
          Uri.parse('https://l.test/loop').get(),
          throwsA(isA<ClientException>().having((e) => e.message, 'message', contains('redirects'))),
        );
      });
      expect(n, 21, reason: 'the first request and its 20 redirects, once');
    });

    test('credentials go only to their origin, never across a redirect', () async {
      final (other, otherSeen) = await _site((r) => r.response.write('other'));
      final (base, seen) = await _site((r) {
        if (r.uri.path == '/away') {
          r.response
            ..statusCode = 302
            ..headers.set('location', '$other');
        }
      });
      final origin = '${base.scheme}://${base.host}:${base.port}';
      await Http.scope(credentials: {origin: const Secret('Bearer t')}, () async {
        await (base / 'here').get();
        await (base / 'away').get();
        await other.get();
      });
      expect([for (final r in seen) r.headers.value('authorization')], ['Bearer t', 'Bearer t']);
      expect([for (final r in otherSeen) r.headers.value('authorization')], [null, null]);
      expect('${const Secret('Bearer t')}', '•••');
    });

    test("a request's own authorization does not follow it to another origin", () async {
      final (other, otherSeen) = await _site((r) => r.response.write('other'));
      final (base, _) = await _site((r) {
        r.response
          ..statusCode = 302
          ..headers.set('location', '$other');
      });
      await base.get(headers: {'authorization': 'mine'});
      expect(otherSeen.single.headers.value('authorization'), isNull);
    });

    test('outside a scope and inside one, a 503 is retried, each retry a Warned', () async {
      var n = 0;
      final (base, _) = await _site((r) {
        if (n++ < 2) r.response.statusCode = 503;
      });
      final task = Http.scope(retry: _quick, () => base.get());
      expect((await task).statusCode, 200);
      n = 0;
      // The default outside a scope is the same policy.
      final outside = base.get();
      final warned = outside.statuses.where((s) => s is Warned).toList();
      expect((await outside).statusCode, 200);
      expect(await warned, hasLength(2));
    });

    test('one retry loop per request: a 500 is sent 1 + times, a 501 once', () async {
      var sent = 0;
      final (base, _) = await _site((r) {
        sent++;
        r.response.statusCode = r.uri.path == '/501' ? 501 : 500;
      });
      await Http.scope(retry: _quick, () async {
        await expectLater(base.get(), throwsA(isA<StatusException>()));
        expect(sent, 3);
        sent = 0;
        // An outer retry never repeats a request whose own loop gave up.
        await expectLater(
          [base].parallelize((u) => u.get(), retry: _quick),
          throwsA(isA<BatchException<Uri, Response>>()),
        );
        expect(sent, 3);
        sent = 0;
        await expectLater((base / '501').get(), throwsA(isA<StatusException>()));
        expect(sent, 1);
      });
    });

    test('a POST is sent again only when the server said it did nothing', () async {
      var sent = 0;
      final (base, _) = await _site((r) {
        sent++;
        if (r.uri.path == '/busy' && sent == 1) {
          r.response
            ..statusCode = 429
            ..headers.set('retry-after', '0');
        } else if (r.uri.path == '/boom') {
          r.response.statusCode = 500;
        }
      });
      await Http.scope(retry: _quick, () async {
        await expectLater((base / 'boom').post(text: 'x'), throwsA(isA<StatusException>()));
        expect(sent, 1);
        sent = 0;
        expect((await (base / 'busy').post(text: 'x')).statusCode, 200);
        expect(sent, 2);
      });
    });

    test('a Retry-After past the policy\'s max is the answer at once', () async {
      var sent = 0;
      final (base, _) = await _site((r) {
        sent++;
        r.response
          ..statusCode = 429
          ..headers.set('retry-after', '3600');
      });
      await Http.scope(retry: const Retry(3, max: Duration(seconds: 1)), () async {
        await expectLater(
          base.get(),
          throwsA(isA<StatusException>().having((e) => '$e', 'text', contains('Retry-After 3600 s'))),
        );
      });
      expect(sent, 1);
    });

    test('a timeout is a TimeoutException naming the URL and the limit', () async {
      final (base, _) = await _site((r) => Completer<void>().future);
      await Http.scope(timeout: 100.ms, retry: Retry.none, () async {
        await expectLater(
          base.get(),
          throwsA(isA<TimeoutException>().having((e) => '$e', 'text', contains('$base timed out after 100ms'))),
        );
      });
    });

    test('a quiet body chunk times out, and a stream listened outside the scope keeps its settings', () async {
      final (base, seen) = await _site((r) async {
        r.response.write('a');
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        r.response.write('b');
      });
      await Http.scope(timeout: 100.ms, retry: Retry.none, () async {
        await expectLater(base.get(), throwsA(isA<TimeoutException>()));
      });
      // Made inside, listened to outside: the headers of the scope it was made in.
      final events = await Http.scope(headers: {'x-made': 'in'}, () async => base.events());
      await events.toList();
      expect(seen.last.headers.value('x-made'), 'in');
    });

    test('perHost: at most so many at once to one host', () async {
      var open = 0, most = 0;
      final (base, _) = await _site((r) async {
        most = (++open) > most ? open : most;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        open--;
      });
      await Http.scope(
        perHost: 2,
        () => [for (var i = 0; i < 8; i++) base / '$i'].parallelize((u) => u.get(), concurrency: 8),
      );
      expect(most, 2);
    });

    test('delay: spaces the requests to one host', () async {
      final times = <DateTime>[];
      final (base, _) = await _site((r) => times.add(DateTime.now()));
      await Http.scope(delay: 80.ms, () async {
        for (var i = 0; i < 3; i++) {
          await (base / '$i').get();
        }
      });
      for (var i = 1; i < times.length; i++) {
        expect(times[i].difference(times[i - 1]), greaterThan(const Duration(milliseconds: 50)));
      }
    });

    test('the scope holds until the batch its body returns has finished', () async {
      // The regression: a scope closed its client when the body returned, before any download ran.
      final (base, seen) = await _site((r) => r.response.write('file ${r.uri.path}'));
      final dir = tempDir();
      final files = await Http.scope(
        headers: {'x-scope': 'yes'},
        () => [for (var i = 0; i < 4; i++) base / 'f$i.txt'].parallelize((u) => u.download(into: dir)),
      );
      expect(files, hasLength(4));
      expect({for (final r in seen) r.headers.value('x-scope')}, {'yes'});
    });
  });

  group('cookies', () {
    test('a session outside any scope keeps what a response sets', () async {
      final (base, seen) = await _site((r) {
        if (r.uri.path == '/login') r.response.headers.add('set-cookie', 'sid=abc; Path=/');
      });
      await (base / 'login').get();
      await (base / 'me').get();
      expect(seen.last.headers.value('cookie'), 'sid=abc');
    });

    test('cookies: is the session jar; a cookie set on a redirect hop is kept', () async {
      final (base, seen) = await _site((r) {
        if (r.uri.path == '/login') {
          r.response
            ..statusCode = 302
            ..headers.set('location', '/home')
            ..headers.add('set-cookie', 'sid=1');
        }
      });
      final jar = CookieJar();
      await Http.scope(cookies: jar, () => (base / 'login').post(form: {'u': 'me'}));
      expect(seen.last.headers.value('cookie'), 'sid=1');
      expect(jar.single.name, 'sid');
      // A request's own cookie wins.
      await Http.scope(cookies: jar, () => base.get(headers: {'cookie': 'mine=1'}));
      expect(seen.last.headers.value('cookie'), 'mine=1');
    });

    test('store: keeps the session between scopes', () async {
      final (base, seen) = await _site((r) {
        if (r.uri.path == '/login') r.response.headers.add('set-cookie', 'sid=kept; Max-Age=3600');
      });
      final store = Store(tempDir());
      await Http.scope(store: store, () => (base / 'login').get());
      await Http.scope(store: store, () => (base / 'again').get());
      expect(seen.last.headers.value('cookie'), 'sid=kept');
      expect(File('${store.folder}/cookies.json').existsSync(), isTrue);
    });

    test('a jar reads and writes cookies.txt and JSON; a cookie needs a domain', () async {
      final dir = tempDir();
      final jar = CookieJar([
        HttpCookie('a', 'x,"y"', domain: 'example.com', secure: true),
        HttpCookie('b', '2', domain: '.example.com', httpOnly: true),
      ]);
      for (final name in ['c.txt', 'c.json']) {
        expect(await jar.save('$dir/$name'), '$dir/$name');
        final back = await CookieJar.read('$dir/$name');
        expect(
          [for (final c in back) '${c.name}=${c.value} ${c.hostOnly} ${c.httpOnly}'],
          ['a=x,"y" true false', 'b=2 false true'],
        );
      }
      // The regression: a cookie with no domain was silently dropped.
      expect(() => HttpCookie('sid', 'x', domain: ''), throwsArgumentError);
      jar.remove('a');
      expect(jar.map((c) => c.name), ['b']);
      jar.clear();
      expect(jar, isEmpty);
      File('$dir/bad.txt').writeAsStringSync('example.com\tFALSE\n');
      await expectLater(
        CookieJar.read('$dir/bad.txt'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('bad.txt'))),
      );
    });

    test('a Secure cookie over http is refused, and a Domain must be this host or a parent', () async {
      final (base, seen) = await _site((r) {
        if (r.uri.path == '/set') {
          r.response.headers
            ..add('set-cookie', 's=1; Secure')
            ..add('set-cookie', 'o=1; Domain=other.com')
            ..add('set-cookie', 'ok=1');
        }
      });
      final jar = CookieJar();
      await Http.scope(cookies: jar, () async {
        await (base / 'set').get();
        await (base / 'next').get();
      });
      expect(seen.last.headers.value('cookie'), 'ok=1');
    });
  });

  group('cache', () {
    test('cache: an answer is served without a request while fresh, Done(fresh: false)', () async {
      final (base, seen) = await _site((r) => r.response.write('v${DateTime.now().microsecondsSinceEpoch}'));
      await Http.scope(cache: 1.d, () async {
        final first = await base.get().text;
        final again = base.get();
        expect(await again.text, first);
        expect(await again.settled, isA<Done<Object?, Response>>().having((d) => d.fresh, 'fresh', isFalse));
      });
      expect(seen, hasLength(1));
    });

    test('a stale answer is asked for again conditionally, and a 304 serves it', () async {
      final (base, seen) = await _site((r) {
        if (r.headers.value('if-none-match') == '"v1"') {
          r.response.statusCode = 304;
          return;
        }
        r.response
          ..headers.set('etag', '"v1"')
          ..write('body');
      });
      final store = Store(tempDir());
      await Http.scope(store: store, cache: 1.ms, () async {
        expect(await base.get().text, 'body');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(await base.get().text, 'body');
      });
      expect(seen.last.headers.value('if-none-match'), '"v1"');
      expect(Directory('${store.folder}/cache').listSync(), isNotEmpty);
    });

    test("one user's answer is never another's", () async {
      final (base, seen) = await _site((r) => r.response.write('for ${r.headers.value('authorization')}'));
      final origin = '${base.scheme}://${base.host}:${base.port}';
      await Http.scope(cache: 1.d, () async {
        final a = await Http.scope(credentials: {origin: const Secret('a')}, () => base.get().text);
        final b = await Http.scope(credentials: {origin: const Secret('b')}, () => base.get().text);
        expect([a, b], ['for a', 'for b']);
      });
      expect(seen, hasLength(2));
    });

    test('a revalidation that is retried is still answered by its 304', () async {
      var n = 0;
      final fake = Client.fake((r) {
        n++;
        if (n == 1) return Response('v1', 200, headers: {'etag': '"x"'});
        if (n == 2) return Response('busy', 503);
        if (r.headers['if-none-match'] == '"x"') return Response('', 304);
        return Response('v2', 200);
      });
      final url = Uri.parse('https://a.test/page');
      await Http.scope(client: fake, cache: 1.ms, retry: _quick, () async {
        expect(await url.get().text, 'v1');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(await url.get().text, 'v1');
      });
      expect(n, 3);
    });

    test("Vary is read from the headers that went out, the scope's included", () async {
      final fake = Client.fake(
        (r) => Response('${r.headers['accept-language']}', 200, headers: {'vary': 'accept-language'}),
      );
      final url = Uri.parse('https://b.test/page');
      Future<String> asked(String language) =>
          Http.scope(client: fake, cache: 1.d, headers: {'accept-language': language}, () => url.get().text);
      expect([await asked('fr'), await asked('en'), await asked('fr')], ['fr', 'en', 'fr']);
    });

    test('a served answer keeps the URL that answered it, after its redirects', () async {
      final fake = Client.fake(
        (r) => r.url.path == '/a' ? Response('', 301, headers: {'location': '/dir/b'}) : Response('b', 200),
      );
      final url = Uri.parse('https://c.test/a');
      await Http.scope(client: fake, cache: 1.d, () async {
        expect((await url.get()).url, Uri.parse('https://c.test/dir/b'));
        final served = url.get();
        expect((await served).url, Uri.parse('https://c.test/dir/b'));
        expect(await served.settled, isA<Done<Object?, Response>>().having((d) => d.fresh, 'fresh', isFalse));
      });
    });
  });

  group('Client.fake', () {
    test('answers every request, its body held', () async {
      final fake = Client.fake((request) => Response('${request.method} ${request.text}', 201));
      await Http.scope(client: fake, () async {
        final res = await Uri.parse('https://api.test/a').post(json: {'a': 1});
        expect(res.statusCode, 201);
        expect(res.text, 'POST {"a":1}');
      });
    });

    test('its redirects are followed, and its cookies kept, as a real server\'s', () async {
      final fake = Client.fake(
        (request) => switch (request.url.path) {
          '/a' => Response('', 302, headers: {'location': '/b', 'set-cookie': 'k=v'}),
          _ => Response(request.headers['cookie'] ?? 'none', 200),
        },
      );
      await Http.scope(client: fake, cookies: CookieJar(), () async {
        expect(await Uri.parse('https://api.test/a').get().text, 'k=v');
      });
    });
  });

  group('IoClient', () {
    group('a SOCKS5 proxy', () {
      late HttpServer site;
      setUp(() async => (site, _) = await serve((r) => r.response.write('hello ${r.uri.path}')));

      Future<String> through(String proxy, String url) {
        final client = IoClient(proxies: [Uri.parse(proxy)]);
        addTearDown(client.close);
        return Http.scope(client: client, retry: Retry.none, () => Uri.parse(url).get().text);
      }

      test('carries plain HTTP, the name resolved by the proxy', () async {
        final proxy = await _Socks5.start(targets: {'site.test': site.port});
        addTearDown(proxy.close);
        expect(await through('socks5://127.0.0.1:${proxy.port}', 'http://site.test:80/a'), 'hello /a');
        expect(proxy.asked, ['site.test:80']);
      });

      test('logs in, and a refused login is a ClientException with its cause', () async {
        final proxy = await _Socks5.start(targets: {'site.test': site.port}, user: 'me', password: 'p@ss');
        addTearDown(proxy.close);
        expect(await through('socks5h://me:p%40ss@127.0.0.1:${proxy.port}', 'http://site.test/b'), 'hello /b');
        await expectLater(
          through('socks5://me:nope@127.0.0.1:${proxy.port}', 'http://site.test/b'),
          throwsA(isA<ClientException>().having((e) => e.cause, 'cause', isA<SocketException>())),
        );
      });

      test('an unknown proxy scheme is an ArgumentError', () {
        expect(() => IoClient(proxies: [Uri.parse('socks4://127.0.0.1:1')]), throwsArgumentError);
      });
    });

    test('proxies are taken in turn, one that cannot connect passed over', () async {
      Future<Uri> proxy(String name) async {
        final (_, url) = await serve((r) => r.response.write('$name ${r.uri}'));
        return url;
      }

      final socket = await ServerSocket.bind('127.0.0.1', 0);
      final dead = Uri.parse('http://127.0.0.1:${socket.port}');
      await socket.close();
      final client = IoClient(proxies: [await proxy('a'), dead, await proxy('b')]);
      addTearDown(client.close);
      final answers = await Http.scope(client: client, retry: Retry.none, () async {
        return [for (var i = 0; i < 3; i++) await Uri.parse('http://site.test/$i').get().text];
      });
      expect(answers, ['a http://site.test/0', 'b http://site.test/1', 'b http://site.test/2']);
    });
  });

  clientConformance('IoClient', (_) => IoClient());

  group('events', () {
    test('server-sent events, with the last id', () async {
      final (base, seen) = await _site((r) {
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write('id: 1\ndata: a\n\nevent: tick\ndata: b\ndata: c\n\n: comment\n');
      });
      final events = await base.events().toList();
      expect([for (final e in events) '${e.event}:${e.data}:${e.id}'], ['message:a:1', 'tick:b\nc:1']);
      expect(seen.single.headers.value('accept'), 'text/event-stream');
    });

    test('NDJSON asked with a JSON body is one event a line', () async {
      final (base, seen) = await _site((r) async {
        await utf8.decoder.bind(r).join();
        r.response.write('{"a":1}\n\n{"a":2}\n');
      });
      final events = await base.events(json: {'stream': true}).toList();
      expect([for (final e in events) e.data], ['{"a":1}', '{"a":2}']);
      expect(seen.single.method, 'POST');
    });

    test('a quiet stream is not cut by the scope\'s timeout', () async {
      // The regression: an event stream died after 30 s of quiet.
      final (base, _) = await _site((r) async {
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write('data: a\n\n');
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        r.response.write('data: b\n\n');
      });
      final events = await Http.scope(timeout: 100.ms, () => base.events().toList());
      expect([for (final e in events) e.data], ['a', 'b']);
    });

    test('a failing status throws a StatusException holding the error body', () async {
      final (base, _) = await _site((r) {
        r.response
          ..statusCode = 401
          ..write('{"error":"key"}');
      });
      await expectLater(
        base.events().toList(),
        throwsA(isA<StatusException>().having((e) => e.response.text, 'body', '{"error":"key"}')),
      );
    });

    test('reconnect: resends Last-Event-ID after retry:, and stops on a 204', () async {
      var n = 0;
      final (base, seen) = await _site((r) {
        if (n++ == 2) {
          r.response.statusCode = 204;
          return;
        }
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write('retry: 10\nid: $n\ndata: x$n\n\n');
      });
      final events = await base.events(reconnect: true).toList();
      expect([for (final e in events) e.data], ['x1', 'x2']);
      expect([for (final r in seen) r.headers.value('last-event-id')], [null, '1', '2']);
    });

    test("a stream never goes through the scope's cache", () async {
      var n = 0;
      final fake = Client.fake(
        (r) => Response('data: event ${++n}\n\n', 200, headers: {'content-type': 'text/event-stream'}),
      );
      final url = Uri.parse('https://e.test/stream');
      final got = await Http.scope(client: fake, cache: 1.d, () async {
        return [for (var i = 0; i < 2; i++) ...await url.events().map((e) => e.data).toList()];
      });
      expect(got, ['event 1', 'event 2']);
    });
  });
}
