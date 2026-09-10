// Talk to a server: sessions, bodies, JSON, downloads.
//
//   dart run example/http.dart
//
// The requests below are real ones over a real socket — the server they reach
// is started at the bottom of this file, so the example needs no network.
// Point the same calls at any host and nothing about them changes.

import 'dart:convert' show utf8;
// `dart:io` and this package can be imported side by side: through 1.7.0 the
// package's own HttpClient, HttpResponse and Cookie shadowed these silently,
// and 2.0.0 renamed all three (Fetcher, Reply, Morsel) so they no longer do.
import 'dart:io' show ContentType, Cookie, HttpServer;

import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final log = system.console.logger;
  final server = await _serve();
  final origin = 'http://${server.address.host}:${server.port}';

  // A client of your own: headers, timeout, retries, a body-size cap, and a
  // cookie jar that turns it into a session. `net.http` is a shared one for
  // scripts that need no configuring; `net.use(client)` swaps that out
  // process-wide.
  final client = Fetcher(
    headers: {'User-Agent': 'ExampleBot/1.0'},
    timeout: 15.s,
    retries: 3,
    session: true,
    cap: 10 * 1024 * 1024,
  );

  try {
    // A response knows how to query its own HTML.
    final page = await client.get('$origin/'.url);
    log.ok(
      'GET ${page.status} ${page.type} — ${page.parse(format.html)('h1').text}',
    );

    // Bodies are sealed, so the encoding is explicit at the call site:
    // Body.json, Body.form, Body.text, Body.bytes.
    final echo = await client.post(
      '$origin/echo'.url,
      body: const Body.json({'id': 1, 'name': 'keyboard'}),
    );
    // Reading a body is a codec, whichever format it is. Nothing throws: a
    // body that is not JSON is the empty cursor, so the fallback is a `??`.
    log.ok('POST ${echo.status} — ${echo.parse(format.json).raw}');
    final junk = Reply.text('<nope>').parse(format.json);
    log.info('Fallback on junk: ${junk.raw ?? const {}}');

    // Cookies set anywhere in the session are sent everywhere they apply.
    await client.get('$origin/signin'.url);
    final who = await client.get('$origin/whoami'.url);
    log.ok(
      'Session: ${who.body.trim()} (jar holds ${client.jar?.length} cookies)',
    );

    // A streamed download, written atomically through a `.part` file so an
    // interrupted run never leaves a truncated one behind. It skips a
    // destination that already holds bytes, so a re-run costs nothing.
    io.remove('output/blob.bin');
    final bar = Progress(total: 1, unit: ProgressUnit.bytes, message: 'blob');
    final file = await client.download(
      '$origin/blob'.url,
      'output/blob.bin',
      onProgress: (got, total) {
        if (total > 0) bar.update(got, total: total);
      },
    );
    // A bar draws nothing off a terminal, so the summary is a log line.
    bar.done();
    log.ok(
      'Downloaded ${util.size.format(io.stat(file.path).size)} to ${file.path}',
    );

    // Many URLs at once, bounded, results in input order.
    final pages = await concurrent.run(
      ['$origin/', '$origin/whoami'],
      (url) => client.get(url.url),
      size: 2,
    );
    log.ok('Fetched ${pages.length}: ${[for (final p in pages) p.status]}');
  } finally {
    await client.close();
    await server.close();
  }
}

/// A throwaway server on a free port, so the example is self-contained.
Future<HttpServer> _serve() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    final res = req.response;
    switch (req.uri.path) {
      case '/echo':
        res.headers.contentType = ContentType.json;
        res.write(utf8.decode(await req.expand((chunk) => chunk).toList()));
      case '/signin':
        res.cookies.add(Cookie('sid', 'abc123'));
        res.write('ok');
      case '/whoami':
        final sid = req.cookies.where((c) => c.name == 'sid').firstOrNull;
        res.write(sid == null ? 'anonymous' : 'alice (${sid.value})');
      case '/blob':
        res.headers.contentType = ContentType.binary;
        res.add(List<int>.filled(64 * 1024, 7));
      default:
        res.headers.contentType = ContentType.html;
        res.write('<h1>Example server</h1>');
    }
    await res.close();
  });
  return server;
}
