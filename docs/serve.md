# Serving (`net.serve`, `net.once`)

The mirror image of the client half of `net`: something that listens. Three
ordinary script jobs need one, and all three otherwise mean `dart:io`'s
`HttpServer` and a hand-rolled request switch:

- an **OAuth callback** — the reason a scraping script needs a server at all,
  and the reason it needs one for about eleven seconds;
- a **webhook receiver**, for anything triggered from outside;
- a **preview** of what was just scraped, because opening `output/` in a
  browser beats reading JSON in a terminal.

The client side reads a URL and returns a `Reply`. The server side is the same
shape backwards: it takes an `Asked` and returns a `Served`.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final server = await net.serve(8080, (req) async {
    return switch (req.path) {
      '/callback' => Served.text(req.query['code'] ?? ''),
      '/health' => Served.json({'ok': true}),
      '/report' => Served.file('output/report.html'),
      _ => Served.status(404),
    };
  });

  system.console.logger.info('listening on ${server.port}');
  await server.close();
}
```

---

## 1. `net.serve`

```dart no-compile
Future<Server> serve(int port, FutureOr<Served> Function(Asked req) handler,
    {String host = 'localhost'});
```

Pass `port: 0` to let the OS pick a free one and read `server.port` back — what
a test wants, and what an OAuth callback on a machine with something already on
`8080` wants too.

`host` defaults to `localhost`, so nothing is exposed off the machine until a
script asks for it. Pass `'0.0.0.0'` when it should be.

| Member | Gives |
| :--- | :--- |
| `server.port` | the port actually bound |
| `server.host` | the address bound |
| `server.close({force})` | stops listening; waits for in-flight requests unless forced |

A live server holds the socket open, so a script that serves and then does
nothing else stays alive. That is the point for a webhook receiver and a trap
for everything else.

A handler that throws is answered `500` and the server keeps listening: the
client is waiting, and a hung request is harder to debug than a status.

---

## 2. The request (`Asked`)

| Member | Gives |
| :--- | :--- |
| `req.url` | the full `Uri` as requested |
| `req.path` | the path, always starting with `/` |
| `req.query` | `Map<String, String>` |
| `req.headers` | `Map<String, String>`, lowercased |
| `req.method` | `HttpMethod` |
| `req.text()` | the body as UTF-8 text |
| `req.bytes()` | the body as raw bytes |
| `req.json()` | the body as a [`Json`](json.md) cursor |

The body is cached, so reading it twice is free. A body that is not JSON reads
as the empty cursor rather than throwing, which is what a webhook receiver
wants: a malformed POST is a `400` to return, not an exception to catch.

```dart
await net.serve(9000, (req) async {
  if (req.method != HttpMethod.post) return Served.status(405);
  if (req.headers['x-signature'] != secret) return Served.status(401);

  final event = await req.json();
  if (event.text('type') == null) return Served.status(400);

  await io.async.dump('events/${util.time.stamp()}.json', event.raw);
  return Served.json({'received': true});
});
```

It is named `Asked` rather than `Request` because 2.0.0 spent that name once
already and renamed out of it: a type called `Request` sitting beside
`package:http`'s and `dart:io`'s is the shadow that made `HttpClient` a bug
rather than a compile error.

---

## 3. The reply (`Served`)

Every constructor names the shape of the answer, so a handler says what it is
returning rather than assembling headers:

```dart
Served.text('done');
Served.text('<h1>hi</h1>', type: 'text/html; charset=utf-8');
Served.json({'ok': true});
Served.bytes(await io.async.bytes('logo.png'), type: 'image/png');
Served.file('output/report.html');       // content type from the extension
Served.status(404);                      // the standard reason phrase as the body
Served.redirect('/done'.url);                // 302; pass status: 301 for permanent
```

Every one takes `status` and extra `headers`. `Served.file` streams the file and
answers `404` when it is not there, so previewing a directory that has not been
written yet is a status rather than a crash. There is no `Served.html` — one
argument is cheaper than a second name.

---

## 4. `net.once`

An OAuth callback is not a server. It is a single answer a script waits for, and
writing it as a server means writing the shutdown too:

```dart
final code = await net.once(8080, (req) => req.query['code']);
```

Requests whose handler hands back `null` are answered `404` and the wait goes
on. The request that *does* answer sees `reply`, and only once that reply has
actually been flushed does the server close — closing on the handler's return
raced the write, and the browser saw a refused connection.

```dart
final code = await net.once(
  8080,
  (req) => req.query['code'],
  reply: Served.text('Signed in. You can close this tab.'),
  timeout: 2.m,
);
if (code == null) {
  system.console.logger.error('no callback arrived');
  return;
}
```

`timeout` gives up and returns `null` rather than waiting for a redirect that is
never coming. `once` beside `serve` is the same pairing as `io.csv.pipe` beside
`write`: different behaviour, not an alias.

---

## Deliberately not here

Routing with path parameters, middleware, static-directory serving beyond
`Served.file`, HTTPS, and WebSockets. Each is the first step towards a web
framework, and this is a scraping toolkit that needs to catch a redirect.

A `switch` on `req.path` is the router. It is enough for every job listed at the
top of this page.

---

## See Also

- [`net.http.*`](http.md) — the client half, and `Reply`
- [`io.*`](io.md) — what `Served.file` serves
- [`format.json`](json.md) — the cursor `req.json()` returns
