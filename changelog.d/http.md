# http (client)

## Upgrading

| before | after |
|---|---|
| `await url.fetch()` | `await url.get().text` / `.bytes` / `.json` / `.html` / `.xml` (each throws unless 2xx) |
| `await url.json()` / `url.html()` / `url.xml()` | `await url.get().json` / `.html` / `.xml` |
| `await client.fetch(u)` / `client.json(u)` / `client.html(u)` / `client.xml(u)` | `await client.get(u).text` / `.json` / `.html` / `.xml` |
| `final r = await api.post(json: x); if (!r.isOk) throw …; r.json['id']` | `(await api.post(json: x).json)['id']` |
| `await url.send(Request('POST', url, json: {…}))` | `await Request('POST', url, json: {…}).send()` |
| `IoClient(userAgent: 'me/1')` | `Http.scope(headers: {'user-agent': 'me/1'}, …)` |
| `IoClient(keepAlive: d)`, `request.persistentConnection = false` | `headers: {'connection': 'close'}` |
| `Response(…, isRedirect: true)`, `StreamedResponse(…, isRedirect: …)` | drop the argument; `isRedirect` is a getter (3xx with a `location`) |
| `Future<Response> f = url.get();` | still compiles: verbs return `Fetch`, which implements `Future<Response>` |

## Removed

- `UriExtensions.fetch`, `UriExtensions.json()`, `UriDocumentExtensions` (`url.html()`, `url.xml()`),
  `ClientExtensions.fetch/json/html/xml` — eight methods; the readings on `Fetch` replace them.
- `UriExtensions.send(Request)` — the receiver was ignored, so the URL was written twice.
- `IoClient(userAgent:, keepAlive:)`, `Request.persistentConnection`. `connectTimeout:` stays.
- `isRedirect` as a stored field and its four constructor parameters (`Response`, `Response.bytes`,
  `StreamedResponse`); it is now derived.
- Internal: `_sleep` (inlined as `duration.delay()`), `_Retry.declined` (folded into
  `_Retry.after(res, attempt, once: true)`).

## Added

- `Fetch implements Future<Response>`, returned by every verb on `Uri` and `Client` (and by
  `client.fire`). Awaited, it is the lenient `Response`; `.json`, `.text`, `.html`, `.xml`,
  `.bytes` are `Future`s that throw `HttpException('404 Not Found', uri: <url that answered>)`
  unless 2xx. Built the way `ShellRun` is (a `Future` facade over one inner future).
- `Request.send()` → `Fetch`.
- `Http.scope(delay:)` jitters each gap by ±25 % (`Duration.jittered`); a fixed gap is a bot signal.

## Faster

- P-HTTP-1: `bytes:` given as a `Uint8List` is no longer copied into the request.
  `Request('POST', url, bytes: <8 MiB Uint8List>)`: **~520 µs → 0.7 µs** (median of 14 alternating
  old/new runs, 200 iterations each; old 490–753 µs, new 0.7 µs every run).

## Verified done in phase 2 (no change)

- B-HTTP-3 / HTTP-6 `withQuery` lists and repeated keys; HTTP-7 HEAD on 303; HTTP-8 IP cookie
  domains; HTTP-9 cache 304 streams from the opened file, download mtime from `Last-Modified`;
  HTTP-10 `maxRedirects = 20` and `delay` keyed by origin. HTTP-10's fragment item was resolved in
  phase 2 as "drop the fragment" (tested in `HTTP-10: redirect drops fragment…`); left as is.

## Skipped

- Nothing from the assigned list.

## Integrator notes

- `scrape.dart` got two mechanical edits (drop `isRedirect:` in the `Response.bytes` call;
  `_Retry.declined(streamed)` → `_Retry.after(streamed, item.attempt, once: true)`). `chrome.dart`
  needed none.
- `lib/formats.dart:6` doc comment now says `url.get().json`.
- `CONVENTIONS.md:437` still mentions `url.xml()` (I may not edit it): make it `url.get().xml`.
- GUIDE:180 (`Either.tryCatch(() => url.get().json)`) overlaps the core agent's `tryCatch` deletion.
- `Response.isolate` left for the core agent.

## CONVENTIONS

- Extend "A reading implies its policy" with the HTTP example:
  `(await api.post(json: x).json)['score']` — the reading throws unless 2xx, awaiting the verb is
  lenient. Why: README's dashboard example silently carried on after a 401, and every API call
  wrote a 3-line status check.
- Table "Ambient over threaded", `Http.scope` row: `delay` (per-host gap, jittered ±25 %).
