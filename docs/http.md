# HTTP Networking (`net.http.*`)

A retrying HTTP client whose responses know how to query their own HTML, decode JSON safely, handle sessions and cookies, and resolve their own relative links.

URLs are always `Uri` values, matching `package:http`. The `.url` extension keeps call sites short.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final res = await net.http.get('https://news.ycombinator.com'.url);

  if (res.ok) {
    for (final title in res.$('.titleline > a').texts) {
      print(title);
    }
  }
}
```

---

## 1. Requests

`net.http` is a shared `HttpClient`. Every verb takes a `Uri`:

```dart
await net.http.get(url);
await net.http.post(url, body: const Body.json({'id': 1}));
await net.http.put(url, body: const Body.text('raw'));
await net.http.patch(url, body: const Body.form({'a': '1'}));
await net.http.delete(url);
await net.http.head(url);
```

Bodies are a sealed type, so each shape is explicit rather than inferred from a runtime type test:

| Constructor | Sends | Content-Type |
| :--- | :--- | :--- |
| `Body.text(String)` | The string verbatim | `text/plain; charset=utf-8` |
| `Body.bytes(List<int>)` | Raw bytes | `application/octet-stream` |
| `Body.form(Map<String, String>)` | Form URL encoded | `application/x-www-form-urlencoded` |
| `Body.json(Object?)` | JSON encoded | `application/json; charset=utf-8` |

Per-call `headers` and `timeout` override the client's defaults.

---

## 2. Responses (`HttpResponse`)

```dart
res.ok;             // status in 200..299
res.status;         // HTTP status code (e.g. 200, 404)
res.headers;        // response headers map
res.body;           // decoded text with charset auto-detection, cached
res.json;           // decoded JSON, cached (throws on invalid JSON)
res.decode(null);   // safely decodes JSON or returns fallback
res.charset;        // detected encoding (e.g. 'utf-8', 'iso-8859-1')
res.url;            // final URL after following redirects
res.requestedUrl;   // initial requested URL
res.doc;            // parsed HTML document, cached

// DOM & XPath Selection:
res.$('h1').text;               // text of first h1 match
res.$('a').hrefs;               // all href attributes
res.$('a').href;                // first href attribute
res.$('img').srcs;              // all src attributes
res.$('div').lines;             // text split on <br> and newlines
res.$xpath('//h1').texts;       // XPath query text list

// Resolved absolute URIs:
res.links();                    // List<Uri> resolved against res.url
res.srcs();                     // List<Uri> for images/scripts resolved against res.url

await res.save('out/page.html'); // saves response bytes atomically
```

### Charset Detection

`HttpResponse.body` automatically detects character encoding from:
1. The `Content-Type` header (e.g. `charset=windows-1252`).
2. HTML `<meta charset="...">` or `<meta http-equiv="Content-Type">` tags in the payload.
3. Falls back gracefully to UTF-8 / Latin1.

### Declarative Extraction (`extract`)

Extract structured data declaratively using CSS selectors and property targets (`@attr` or `@text`):

```dart
final product = res.extract({
  'title': 'h1.title',
  'price': '.price@text',
  'canonical': 'link[rel="canonical"]@href',
  'categories': ['ul.breadcrumbs > li'],
  'reviews': ['.review', {
    'user': '.author',
    'rating': '.stars@data-rating',
    'comment': '.body',
  }],
});
```

Values come back as `Object?`. Where you want the type, name the field with a
`Field` and read it with `pick`:

```dart
final String? title = res.pick(Field.text('h1.title'));
final List<String> tags = res.pick(Field.texts('ul.tags > li'));
final List<String> hrefs = res.pick(Field.attrs('a', 'href'));
final int reviews = res.pick(Field.fn((el) => el.querySelectorAll('.review').length));
```

The cases are `Field.text`, `Field.attr`, `Field.texts`, `Field.attrs`,
`Field.map`, `Field.list` and `Field.fn`. They mix freely with the string
shorthand inside one `extract` schema.

---

## 3. Retries & Redirects

Failed requests retry up to `retries` times (default 2) on a transport error, a 5xx, or a 429. A `Retry-After` header is honoured when the server sends one — in either delta-seconds or HTTP-date form; an unparseable one falls back to the client's own backoff rather than throwing. Otherwise the delay is `backoff * attempt` with up to 25% jitter.

Set `cap` to refuse oversized bodies, which a broad crawl needs so one unexpected URL cannot exhaust memory:

```dart
final client = HttpClient(cap: 10 * 1024 * 1024); // 10 MB
```

Redirects are followed automatically by default (up to `redirects: 10`). Access `res.url` for the final landing destination:

```dart
final client = HttpClient(
  redirect: true,
  redirects: 5,
);
final res = await client.get('http://bit.ly/example'.url);
print('Landed on: ${res.url}');
```

---

## 4. Cookies & Sessions (`CookieJar`)

Create a stateful session that preserves cookies across requests:

```dart
// Ephemeral session client:
final session = HttpClient(session: true);
await session.post('https://example.com/login'.url, body: const Body.form({
  'user': 'alice',
  'pass': 'secret',
}));
final dashboard = await session.get('https://example.com/dashboard'.url);

// Or bring your own jar, to share or inspect it:
final jar = CookieJar();
final client = HttpClient(jar: jar);
await client.get('https://example.com/'.url);
print(jar['session_id']);
```

The jar follows RFC 6265: several `Set-Cookie` headers on one response are all
stored, `Max-Age` takes precedence over `Expires`, an expired cookie deletes the
entry it names, and a cookie set at `/login` is sent to `/dashboard` — its
default path is the directory of the request, not the request itself.

---

## 5. Proxies

Configure an HTTP or HTTPS proxy:

```dart
final client = HttpClient(
  proxy: 'http://127.0.0.1:8080',
);
```

---

## 6. Downloads

```dart
await net.http.download('https://example.com/a.zip'.url, 'out/a.zip');
```

Streams to disk through a `.part` staging file, verifies the length against `Content-Length`, and skips the download when the destination already holds bytes. A failure **propagates** — it is not swallowed.

`sync` downloads a whole map of destination-to-source concurrently:

```dart
await net.http.sync({
  'out/a.zip': 'https://example.com/a.zip'.url,
  'out/b.zip': 'https://example.com/b.zip'.url,
}, size: 4);
```

---

## 7. Your Own Client

Construct an `HttpClient` for custom headers, a custom timeout, proxy, session cookies, or a `base` directory that relative download paths resolve against. **The caller must close it.**

```dart
final client = HttpClient(
  headers: {'Authorization': 'Bearer $token'},
  timeout: const Duration(seconds: 10),
  retries: 5,
  base: 'downloads',
  proxy: 'http://proxy.internal:3128',
);

await client.download(url, 'album/track.mp3'); // -> downloads/album/track.mp3
await client.close();
```

To apply one client process-wide — including in tests — hand it to `net.use`, which closes the previous one:

```dart
await net.use(HttpClient(headers: {'Authorization': 'Bearer $token'}));
```

---

## See Also

- [`net.crawl`](crawl.md) — multi-page pipelines
- [`$()`](selector.md) — the selector API used by `res.$`

