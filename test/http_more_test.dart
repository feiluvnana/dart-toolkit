// Regression tests for the 2026-10-16 http round: cache, charset lines,
// pool resume, copy, resume edges, cookies, proxies, server cap, and the
// additions (multipart, per-host rate, ETag revalidation, socks5, sent()).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/src/cookies.dart' as jar;
import 'package:test/test.dart';

import 'support/capture.dart';
import 'support/child.dart';
import 'support/io.dart';
import 'support/poll.dart';

/// A [Writer] into a file path, so the resume handshake sees a path.
final class _File with Reader, Writer {
  _File(this.path);

  final String path;

  @override
  Origin origin() => Origin(path: path, name: path.split('/').last);

  @override
  Stream<List<int>> stream() => File(path).openRead();

  @override
  Future<void> consume(Stream<List<int>> input) => input.pipe(File(path).openWrite());
}

const _sjisLine = [147, 250, 150, 123, 140, 234, 131, 101, 131, 88, 131, 103]; // 日本語テスト

void main() {
  late HttpServer server;
  late String url;
  final hits = <String, int>{};
  final seen = <String, String?>{};
  final file = Uint8List.fromList(List.generate(5000, (i) => i % 251));
  var rotate = 0;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}';
    server.listen((r) async {
      final path = r.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      seen['user-agent'] = r.headers.value('user-agent');
      final res = r.response;
      switch (path) {
        case '/rotate':
          res.headers.add('set-cookie', 'sid=${++rotate}; Path=/');
          res.write('page');
        case '/gz':
          res.headers
            ..contentType = ContentType.text
            ..set('content-encoding', 'gzip');
          res.add(gzip.encode(utf8.encode('a' * 5000)));
        case '/sjis':
          res.headers.set('content-type', 'text/plain; charset=shift_jis');
          res.add([..._sjisLine, 10, ..._sjisLine]);
        case '/file':
          final range = r.headers.value('range');
          res.headers.set('etag', '"f1"');
          if (range == null) {
            res.contentLength = file.length;
            res.add(file);
          } else {
            hits['range'] = (hits['range'] ?? 0) + 1;
            final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
            if (from >= file.length) {
              res.statusCode = 416;
              res.headers.set('content-range', 'bytes */${file.length}');
            } else {
              res.statusCode = 206;
              res.headers.set('content-range', 'bytes $from-${file.length - 1}/${file.length}');
              res.contentLength = file.length - from;
              res.add(file.sublist(from));
            }
          }
        case '/etag':
          res.headers.set('etag', '"v1"');
          if (r.headers.value('if-none-match') == '"v1"') {
            res.statusCode = 304;
            hits['/etag304'] = (hits['/etag304'] ?? 0) + 1;
          } else {
            res.write('tagged body');
          }
        case '/busy':
          res.statusCode = 429;
          res.headers.set('retry-after', '5');
        case '/hop':
          res.statusCode = 302;
          res.headers.set('location', '/ua');
        case '/ua':
          res.write(r.headers.value('user-agent'));
        case '/seen':
          res.write([for (final h in ['accept', 'sec-fetch-mode', 'upgrade-insecure-requests']) r.headers.value(h)].join('|'));
        case '/private':
          res.statusCode = 302;
          res.headers.set('location', '/accounts/login/?next=/private');
        case '/accounts/login/':
          res.write('<form>sign in</form>');
        case '/multipart':
          final body = await utf8.decodeStream(r);
          res.write('${r.headers.value('content-type')}|${r.headers.contentLength}|$body');
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  });

  tearDownAll(() => server.close(force: true));
  setUp(hits.clear);

  Future<Directory> temp() async {
    final dir = await Directory.systemTemp.createTemp('http3');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  test('bug 3: lines() decodes a 2xx body with its charset', () async {
    expect(await Http.client().get('$url/sjis').lines().toList(), ['日本語テスト', '日本語テスト']);
  });

  test('lines() joins a character the server flushed in two halves', () async {
    for (final (charset, bytes) in [('shift_jis', _sjisLine), ('utf-8', utf8.encode('日本語テスト'))]) {
      final (_, split) = await serve((r) async {
        r.response.headers.set('content-type', 'text/plain; charset=$charset');
        r.response.add(bytes.sublist(0, 5)); // mid-character in both
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        r.response.add([...bytes.sublist(5), 10, ...bytes]);
        await r.response.close();
      });
      expect(await Http.client().get(split).lines().toList(), ['日本語テスト', '日本語テスト'], reason: charset);
    }
  });

  group('resume', () {
    test('bug 4: Http.pool honours resume: true', () async {
      final dir = await temp();
      final pool = Http.pool([Http.client(resume: true), Http.client(resume: true)]);
      final out = _File('${dir.path}/f.bin');
      await (pool.get('$url/file') > out);
      await (pool.get('$url/file') > out); // complete: skipped (a GET to compare, no second)
      expect(await File(out.path).readAsBytes(), file);
      await File('${dir.path}/g.bin.part').writeAsBytes(file.sublist(0, 1234));
      await File('${dir.path}/g.bin.part.tag').writeAsString('"f1"');
      await (pool.get('$url/file') > _File('${dir.path}/g.bin'));
      expect(await File('${dir.path}/g.bin').readAsBytes(), file);
      expect(hits['range'], 1); // resumed with Range, not downloaded again
      await pool.close();
    });

    test('bug 8: a changed file downloads with one GET; a complete .part finishes on a 416', () async {
      final dir = await temp();
      final c = Http.client(resume: true);
      final out = _File('${dir.path}/f.bin');
      await File(out.path).writeAsBytes([1, 2, 3]); // stale, wrong size
      await (c.get('$url/file') > out);
      expect([await File(out.path).readAsBytes(), hits['/file']], [file, 1]);
      await File(out.path).delete();
      await File('${out.path}.part').writeAsBytes(file);
      await (c.get('$url/file') > out);
      expect(
        [await File(out.path).readAsBytes(), hits['/file'], await File('${out.path}.part').exists()],
        [file, 2, false],
      );
    });
  });

  test('bug 7: copy(proxy:) on a pool is refused instead of collapsing the members', () {
    final pool = Http.pool([Http.client(proxy: 'http://127.0.0.1:1'), Http.client()]);
    expect(() => pool.copy(proxy: 'http://127.0.0.1:2'), throwsArgumentError);
    expect(pool.copy(retries: 0), isA<Client>());
  });

  test('bug 10: the pool abort error names the absolute URL', () async {
    final pool = Http.pool([Http.client(retries: 2, base: '$url/')]);
    final pending = pool.get('busy');
    expect(await eventually(() => (hits['/busy'] ?? 0) > 0), isTrue); // in flight, retrying
    unawaited(pool.close());
    await expectLater(pending, throwsA(isA<HttpRequestException>().having((e) => e.url, 'url', '$url/busy')));
  });

  test('bug 10: a proxy without a port uses 1080; an unknown scheme is refused', () async {
    expect(() => Http.client(proxy: 'ftp://p'), throwsArgumentError);
    // The refusal (nothing listens on 1080 here) names the port it tried.
    try {
      await (await ServerSocket.bind(InternetAddress.loopbackIPv4, 1080)).close();
    } on SocketException {
      return markTestSkipped('something listens on 127.0.0.1:1080');
    }
    await expectLater(
      Http.client(proxy: 'socks5://127.0.0.1', retries: 0).get('$url/ua').text(),
      throwsA(predicate((e) => '$e'.contains('1080'))),
    );
  });

  test('S3: secret client headers go only to the base origin, or the first one without base', () async {
    final seen = <String, Map<String, String?>>{};
    final (other, _) = await serve((r) {
      seen['${r.uri}'] = {'auth': r.headers.value('authorization'), 'key': r.headers.value('x-api-key'), 'ua': r.headers.value('x-app')};
      r.response.close();
    });
    final evil = 'http://localhost:${other.port}'; // another origin: localhost, not 127.0.0.1
    final home = 'http://127.0.0.1:${other.port}';
    const h = {'authorization': 'Bearer SECRET', 'x-api-key': 'K', 'x-app': 'me'};
    final based = Http.client(base: '$home/', headers: h);
    await based.get('/a').status();
    await based.get('$evil/b').status();
    await based.get('//localhost:${other.port}/c').status();
    await based.get('$evil/d', headers: {'authorization': 'Bearer MINE'}).status(); // per call: as asked
    final first = Http.client(headers: h);
    await first.get('$home/e').status();
    await first.get('$evil/f').status();
    expect(seen['/a'], {'auth': 'Bearer SECRET', 'key': 'K', 'ua': 'me'});
    expect(seen['/b'], {'auth': null, 'key': null, 'ua': 'me'});
    expect(seen['/c'], {'auth': null, 'key': null, 'ua': 'me'});
    expect(seen['/d']!['auth'], 'Bearer MINE');
    expect(seen['/e'], {'auth': 'Bearer SECRET', 'key': 'K', 'ua': 'me'});
    expect(seen['/f'], {'auth': null, 'key': null, 'ua': 'me'});
  });

  test('B1: a SOCKS proxy that never answers times out and lets the script exit', () async {
    final r = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/http.dart';
Future<void> main() async {
  final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  silent.listen((_) {}); // accepts, never answers
  final c = Http.client(proxy: 'socks5://127.0.0.1:\${silent.port}', timeout: const Duration(milliseconds: 300), retries: 0);
  try {
    await c.get('http://example.invalid/').text();
  } catch (e) {
    print('failed');
  }
  await c.close();
  await silent.close();
}
''', timeout: const Duration(seconds: 10));
    expect(r.stdout, contains('failed'));
    expect(r.exitCode, 0, reason: 'still running 10 s later: \${r.stderr}');
  });

  group('tls', () {
    late SecurityContext ctx;
    late Directory dir;
    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('tls');
      final made = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', //
        '-addext', 'subjectAltName=DNS:localhost', '-addext', 'extendedKeyUsage=serverAuth', //
        '-keyout', '${dir.path}/key.pem', '-out', '${dir.path}/cert.pem',
      ]);
      if (made.exitCode != 0) return;
      ctx = SecurityContext()
        ..useCertificateChain('${dir.path}/cert.pem')
        ..usePrivateKey('${dir.path}/key.pem');
      SecurityContext.defaultContext.setTrustedCertificates('${dir.path}/cert.pem'); // what every client trusts
    });
    tearDownAll(() => dir.delete(recursive: true));

    Future<HttpServer> tls(void Function(HttpRequest r) answer) async {
      final s = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
      s.listen(answer);
      addTearDown(() => s.close(force: true));
      return s;
    }

    test('bug 10: an https → http redirect warns on stderr', () async {
      final s = await tls(
        (r) => r.response
          ..statusCode = 302
          ..headers.set('location', '$url/ua')
          ..close(),
      );
      final run = await capture(
        () => Http.client().get('https://localhost:${s.port}/x').status(),
      );
      expect(run.value, 200);
      expect(run.err, contains('redirected from https to $url/ua'));
    });

    test('socks5: https through the proxy, names resolved by it', () async {
      final s = await tls(
        (r) => r.response
          ..write('tls ${r.headers.value('host')}')
          ..close(),
      );
      final proxy = await _Socks.start();
      addTearDown(proxy.close);
      final c = Http.client(proxy: 'socks5://127.0.0.1:${proxy.port}');
      expect(await c.get('https://localhost:${s.port}/').text(), 'tls localhost:${s.port}');
      expect(proxy.targets, ['localhost:${s.port}']);
    });
  });

  group('socks5', () {
    test('plain http through the proxy, with a login', () async {
      final proxy = await _Socks.start(user: 'me', pass: 'p@ss');
      addTearDown(proxy.close);
      final c = Http.client(proxy: 'socks5://me:p%40ss@127.0.0.1:${proxy.port}');
      expect(await c.get('$url/ua').text(), contains('Chrome/'));
      expect(await c.get('$url/ua').text(), contains('Chrome/'));
      expect(proxy.targets, ['127.0.0.1:${server.port}']); // one tunnel, kept alive
      final wrong = Http.client(proxy: 'socks5://me:nope@127.0.0.1:${proxy.port}', retries: 0);
      await expectLater(wrong.get('$url/ua'), throwsA(isA<SocketException>()));
    });

    test('bug 6: copy(timeout:) also sets the connect timeout', () async {
      final proxy = await _Socks.start(delay: const Duration(milliseconds: 700));
      addTearDown(proxy.close);
      final quick = Http.client(proxy: 'socks5://127.0.0.1:${proxy.port}', timeout: 300.milliseconds, retries: 0);
      expect(await quick.copy(timeout: 5.seconds).get('$url/ua').status(), 200);
      final sw = Stopwatch()..start();
      await expectLater(quick.get('$url/ua'), throwsA(isA<TimeoutException>()));
      expect(sw.elapsed, greaterThanOrEqualTo(300.milliseconds));
    });
  });

  group('browser and login', () {
    test('browser: sends what a browser sends for a page or an API call; headers still win', () async {
      expect(await Http.client(browser: .page).get('$url/seen').text(), startsWith('text/html,'));
      expect(await Http.client(browser: .page).get('$url/seen').text(), endsWith('|navigate|1'));
      expect(await Http.client(browser: .api).get('$url/seen').text(), '*/*|cors|null');
      expect(await Http.client(browser: .api, headers: {'accept': 'application/json'}).get('$url/seen').text(), startsWith('application/json|'));
      expect(await Http.client().get('$url/seen').text(), contains('null|null'), reason: 'none without browser:');
    });

    test('login: landing on a sign-in page throws SessionException, a ToolkitException', () async {
      final api = Http.client(login: ['/accounts/login']);
      await expectLater(
        api.get('$url/private'),
        throwsA(isA<SessionException>().having((e) => e.url, 'url', contains('/accounts/login/'))),
      );
      expect(await api.get('$url/ua').status(), 200);
      await expectLater(api.copy().get('$url/private'), throwsA(isA<ToolkitException>()), reason: 'a copy keeps login:');
    });
  });

  group('cookies', () {
    test('bug 9: a lenient set-cookie parser keeps spaces, quotes and odd dates', () {
      final c = Cookies();
      final u = Uri.parse('https://a.example.com/');
      jar.storeSetCookies(c, u, [
        'q="quoted value"; Path=/',
        'sp=a b c',
        'old=1; Expires=Wed, 21-Oct-2015 07:28:00 GMT',
        'new=2; expires=Wed, 21-Oct-2099 07:28:00 GMT',
        'gone=3; Max-Age=0',
      ]);
      expect([c['q'], c['sp'], c['old'], c['new'], c['gone']], ['"quoted value"', 'a b c', null, '2', null]);
      expect(jar.cookieDate('Sun, 06 Nov 94 08:49:37 GMT'), DateTime.utc(1994, 11, 6, 8, 49, 37));
    });

    test('bug 9: shared hosts like github.io are public suffixes', () {
      final c = Cookies();
      jar.storeSetCookies(c, Uri.parse('https://evil.github.io/'), ['sid=EVIL; Domain=github.io']);
      jar.storeSetCookies(c, Uri.parse('https://me.github.io/'), ['mine=1']);
      expect(jar.headerFor(c, Uri.parse('https://victim.github.io/')), isNull);
      expect(jar.headerFor(c, Uri.parse('https://me.github.io/')), 'mine=1');
    });

    test('reader.cookies() reads a session file with its user-agent; or: answers a missing one', () async {
      final dir = await temp();
      final f = '${dir.path}/.session';
      await File(f).writeAsString(
        '# Netscape HTTP Cookie File\nuser-agent: Mozilla/5.0 Test\n127.0.0.1\tFALSE\t/\tFALSE\t0\tsid\tS1\n',
      );
      final session = await _File(f).cookies(or: Cookies());
      expect([session['sid'], session.agent()], ['S1', 'Mozilla/5.0 Test']);
      expect(Cookies.parse(session.encode()).agent(), 'Mozilla/5.0 Test');
      final none = await _File('${dir.path}/missing').cookies(or: Cookies());
      expect([none.agent(), none.encode().split('\n').length], [null, 1]);
      await expectLater(_File('${dir.path}/missing').cookies(), throwsA(isA<PathNotFoundException>()));
      // The client sends the jar's user-agent unless a header names one.
      expect(await Http.client(cookies: session).get('$url/ua').text(), 'Mozilla/5.0 Test');
      expect(await Http.client(cookies: session, headers: {'User-Agent': 'mine'}).get('$url/ua').text(), 'mine');
    });
  });

  test('a desktop Chrome user-agent by default', () async {
    expect(await Http.client().get('$url/ua').text(), matches(RegExp(r'^Mozilla/5\.0 .* Chrome/\d+')));
  });

  test('sent() counts wire requests: redirect hops; a pool sums', () async {
    final c = Http.client(retries: 1);
    await c.get('$url/hop').text(); // 302 + the target
    expect(c.sent(), 2);
    final pool = Http.pool([Http.client(), Http.client()]);
    await pool.get('$url/ua').status();
    await pool.get('$url/ua').status();
    expect(pool.sent(), 2);
  });

  test('E1: copies count in their parent\'s sent() and close with it', () async {
    final root = Http.client();
    final a = root.copy(retries: 0), b = a.copy(headers: {'x': '1'});
    await a.get('$url/ua').status();
    await b.get('$url/ua').status();
    expect((root.sent(), a.sent(), b.sent()), (2, 2, 1));
    await b.close(); // a closed copy leaves its count behind
    expect(root.sent(), 2);
    await root.close();
    await expectLater(a.get('$url/ua'), throwsA(isA<HttpRequestException>()));
  });

  test('Body.multipart: fields in memory with a length; a Reader file streams', () async {
    final c = Http.client();
    final mem = await c.post('$url/multipart', body: .multipart({'a': '1', 'q"': 'x'})).text();
    final [type, length, body] = mem.split('|');
    final boundary = type.split('boundary=').last;
    expect(type, startsWith('multipart/form-data; boundary='));
    expect(int.parse(length), utf8.encode(body).length);
    expect(
      body,
      '--$boundary\r\nContent-Disposition: form-data; name="a"\r\n\r\n1\r\n'
      '--$boundary\r\nContent-Disposition: form-data; name="q%22"\r\n\r\nx\r\n--$boundary--\r\n',
    );
    final dir = await temp();
    await File('${dir.path}/cat.png').writeAsString('PNG!');
    final up = await c.post('$url/multipart', body: .multipart(const {}, files: {'file': _File('${dir.path}/cat.png')})).text();
    expect(up, contains('|-1|'));
    expect(up, contains('name="file"; filename="cat.png"\r\nContent-Type: image/png\r\n\r\nPNG!\r\n'));
  });

  test('Rate(perHost: true) paces each host apart', () async {
    final c = Http.client(rate: Rate(1, 600.milliseconds, perHost: true));
    final sw = Stopwatch()..start();
    await c.get('$url/ua').status();
    await c.get('http://localhost:${server.port}/ua').status();
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 450)));
    await c.get('$url/ua').status();
    expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 550)));
  });
}

/// A SOCKS5 server for tests: optional login, an optional delay before it
/// answers the greeting, and the targets it tunnelled to.
final class _Socks {
  _Socks._(this._server, this.user, this.pass, this.delay) {
    _server.listen(_serve);
  }

  static Future<_Socks> start({String? user, String? pass, Duration delay = Duration.zero}) async =>
      _Socks._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), user, pass, delay);

  final ServerSocket _server;
  final String? user, pass;
  final Duration delay;
  final targets = <String>[];
  final _sockets = <Socket>[];

  int get port => _server.port;

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }

  Future<void> _serve(Socket client) async {
    _sockets.add(client);
    final buf = <int>[];
    final more = StreamController<void>.broadcast();
    Socket? upstream;
    client.listen(
      (d) {
        if (upstream != null) {
          upstream.add(d);
        } else {
          buf.addAll(d);
          more.add(null);
        }
      },
      onDone: () => upstream?.destroy(),
      onError: (_) {},
    );
    Future<List<int>> read(int n) async {
      while (buf.length < n) {
        await more.stream.first;
      }
      final out = buf.sublist(0, n);
      buf.removeRange(0, n);
      return out;
    }

    try {
      final [_, n] = await read(2);
      final methods = await read(n);
      await Future<void>.delayed(delay);
      if (user != null) {
        if (!methods.contains(2)) return client.add([5, 0xFF]);
        client.add([5, 2]);
        final [_, ul] = await read(2);
        final u = utf8.decode(await read(ul));
        final p = utf8.decode(await read((await read(1))[0]));
        final ok = u == user && p == pass;
        client.add([1, ok ? 0 : 1]);
        if (!ok) return client.destroy();
      } else {
        client.add([5, 0]);
      }
      final [_, _, _, type] = await read(4);
      final host = switch (type) {
        1 => (await read(4)).join('.'),
        _ => utf8.decode(await read((await read(1))[0])),
      };
      final pb = await read(2);
      final port = pb[0] << 8 | pb[1];
      targets.add('$host:$port');
      final up = await Socket.connect(host == 'localhost' ? '127.0.0.1' : host, port);
      _sockets.add(up);
      client.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
      upstream = up;
      if (buf.isNotEmpty) up.add(List.of(buf));
      up.listen(client.add, onDone: client.destroy, onError: (_) {});
    } catch (_) {
      client.destroy();
    }
  }
}
