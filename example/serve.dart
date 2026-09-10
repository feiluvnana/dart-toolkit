// Listen, instead of fetching: an OAuth callback, a webhook, a preview.
//
//   dart run example/serve.dart
//
// `net.serve` is the mirror of `net.http`: the client half reads a URL and
// returns a Reply, so the server half takes an Asked and returns a Served.
// Every request below is a real one over a real socket, against the server
// this file starts — so the lines that matter are the ones you would write
// against a live redirect.

import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final log = system.console.logger;

  // ------------------------------------------------------------------ a server
  // `port: 0` asks the OS for a free port, which is what a test wants and what
  // a callback on a machine with something already on 8080 wants too.
  // `host` defaults to localhost, so nothing is exposed off the machine.
  final preview = io.join('output', 'serve', 'index.html');
  io.write(preview, '<h1>Scraped 3 pages</h1>');

  final server = await net.serve(0, (req) async {
    return switch (req.path) {
      // A switch on the path *is* the router. Path parameters, middleware and
      // static directories are all one step towards a web framework.
      '/health' => Served.json({'ok': true, 'at': util.time.iso()}),
      '/report' => Served.file(preview),
      '/hook' => await _hook(req),
      '/away' => Served.redirect('/health'.url),
      _ => Served.status(404),
    };
  });
  final origin = 'http://localhost:${server.port}';
  log.ok('Listening on $origin');

  // A JSON reply comes back through the same cursor a scraped API does.
  final health = (await net.http.get('$origin/health'.url)).parse(format.json);
  log.info("health   ${health.at('ok').flag()} at ${health.at('at').text()}");

  // A file reply streams, with its content type read off the extension.
  final page = await net.http.get('$origin/report'.url);
  log.info('report   ${page.headers['content-type']} — ${page.body.trim()}');

  // Anything the switch does not name is a 404 with its reason phrase.
  log.info('missing  ${(await net.http.get('$origin/nope'.url)).status}');

  // A webhook receiver: read the body as JSON, and answer with a status when
  // it is not the shape you expected rather than throwing.
  final good = await net.http.post(
    '$origin/hook'.url,
    body: Body.json({'event': 'crawl.done', 'pages': 3}),
  );
  log.info('hook     ${good.status} ${good.body}');

  final bad = await net.http.post('$origin/hook'.url, body: Body.text('nope'));
  log.warn('hook     ${bad.status} ${bad.body}');

  final port = server.port;
  await server.close();
  log.ok('Closed. A live server holds the process open until you do this.');

  // -------------------------------------------------------------- one answer
  // An OAuth callback is not a server. It is a single answer a script waits
  // for, and writing it as a server means writing the shutdown too. `once`
  // serves until the handler returns non-null, replies, closes, and hands the
  // value back — so the whole dance is one line plus the browser.
  final waiting = net.once(
    port,
    (req) => req.query['code'],
    reply: Served.text('Signed in. You can close this tab.'),
    timeout: 5.s,
  );

  // Standing in for the browser the provider would redirect.
  await util.time.wait(100.ms);
  await net.http.get('http://localhost:$port/callback'.url); // no code: 404
  await net.http.get('http://localhost:$port/callback?code=abc123'.url);

  log.ok('Callback delivered code ${await waiting}');

  // And when the redirect never comes, the timeout is a null to handle rather
  // than a script that hangs on a schedule.
  final none = await net.once(
    port,
    (req) => req.query['code'],
    timeout: 200.ms,
  );
  log.info('Second wait timed out: ${none == null}');

  await net.http.close();
  await system.shutdown();
}

/// A webhook handler: verify the method, decode the body, answer with a status
/// when it is not the shape you expected.
Future<Served> _hook(Asked req) async {
  if (req.method != HttpMethod.post) return Served.status(405);

  // A body that is not JSON reads as the empty cursor rather than throwing,
  // which is what a receiver wants: a malformed POST is a 400 to return.
  final event = await req.json();
  final name = event.text('event');
  if (name == null) return Served.status(400);

  return Served.json({'received': name, 'pages': event.number('pages')});
}
