# HTTP Networking (`net.http.*`)

A retrying HTTP client that handles sessions, cookies, redirects, caching and retries, and resolves its own relative links.

**It parses nothing.** A crawler fetches JSON, sitemaps, archives and images as readily as it fetches pages, so a `Reply` carries the bytes, the text and the headers, and reading them is `res.parse(codec)` with a codec from [`format`](html.md).

URLs are always `Uri` values, matching `package:http`. The `.url` extension keeps call sites short.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final res = await net.http.get('https://news.ycombinator.com'.url);

  if (res.ok) {
    for (final title in res.parse(format.html).find('.titleline > a').texts.list) {
      print(title);
    }
  }
}
```

---

## 1. Requests

`net.http` is a shared `Fetcher`. Every verb takes a `Uri`:

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

A `<form>` on a page builds its own `Body.form` — see [docs/form.md](form.md).

---

## 2. Responses (`Reply`)

```dart
res.ok;             // status in 200..299
res.status;         // HTTP status code (e.g. 200, 404)
res.headers;        // response headers map
res.type;           // MIME type from Content-Type, e.g. 'text/html'
res.body;           // decoded text with charset auto-detection, cached
res.bytes;          // the raw body
res.charset;        // detected encoding (e.g. 'utf-8', 'iso-8859-1')
res.url;            // final URL after following redirects
res.requested;      // initial requested URL
res.cached;         // whether it came from an HttpCache rather than the network

// Reading the body — one member, and it names no format:
res.parse(format.html);         // Markup
res.parse(format.json);         // Json
res.parse(format.yaml);         // Json

// Resolving a relative reference against the URL the body came from:
res.url.resolve('/next');                         // an absolute Uri
res.parse(format.html).find('a').attrs('href')
    .to(res.url.resolve);                         // every link, absolute

await res.save('out/page.html'); // saves response bytes atomically
```

### Reading a body (`Reply.parse`)

`parse` takes a `Codec` — every accessor under `format` is one — and hands back
that format's cursor. It is the only door from a response to a document, which
is what lets one crawl handle more than one format:

```dart
final items = switch (res.type) {
  'application/json' =>
    res.parse(format.json).at('items').all((i) => Item(i.text('sku') ?? '')),
  _                  => res.parse(format.html).all('.item', Item.from),
};
```

Results are memoised per codec, so a handler that reads one page five times
parses it once. Nothing throws: a body that is not the format asked for is the
empty cursor, the same as a missing path.

**Migrating from 3.x.** `Reply` used to carry the formats itself — five HTML
members and three JSON ones, on a class that is about HTTP:

| 3.x | 4.0.0 |
| :--- | :--- |
| `res.$('h1').text` | `res.parse(format.html).find('h1').text` |
| `res.$xpath('//h1')` | `res.parse(format.html).xpath('//h1')` |
| `res.doc` | `res.parse(format.html).document` |
| `res.extract({...})` | `res.parse(format.html).extract({...})` |
| `res.pick(field)` | `res.parse(format.html).pick(field)` |
| `res.json` | `res.parse(format.json).raw` |
| `res.decode(fallback)` | `res.parse(format.json).raw ?? fallback` |
| `res.at('data.items')` | `res.parse(format.json).at('data.items')` |
| `res.form('#login')` | `res.parse(format.html).form('#login')!.at(res.url)` |

A handler that reads a page more than once names the cursor:

```dart
final page = res.parse(format.html);
page.find('h1').text;
page.find('a').attrs('href');
```

### Typed JSON

`res.parse(format.json).raw` is `Object?`, so every read off it is a cast. The
[`Json`](json.md) cursor is the typed door, where nothing is cast and a path
that is not there reads empty:

```dart no-compile
final doc = (await net.http.get('https://api.example.com/products'.url))
    .parse(format.json);

doc.number('data.total');                      // num?
doc.text('meta.cursor');

final items = doc.at('data.items').all((item) => (
  sku: item.text('sku'),
  price: item.number('price.amount'),
));                                            // Sequence<({...})>

doc.jsonpath(r'$..price').sift((p) => p.number());
```

A body that is not JSON at all is the empty cursor too, so this never needs a
`try`.

### Charset Detection

`Reply.body` automatically detects character encoding from:
1. The `Content-Type` header (e.g. `charset=windows-1252`).
2. HTML `<meta charset="...">` or `<meta http-equiv="Content-Type">` tags in the payload.
3. Falls back gracefully to UTF-8 / Latin1.

### Typed Extraction (records)

The way to get data off a page with its type intact is a Dart record. `all`
builds one per match, scoped to that match, and `one` does the same for a
section a page has at most one of:

```dart
final product = (
  title: res.parse(format.html).find('h1.title').text,
  price: res.parse(format.html).pick(Field.text('.price').when(util.text.number)),
  categories: res.parse(format.html).find('ul.breadcrumbs > li').texts,
  reviews: res.parse(format.html).all('.review', (row) => (
    user: row.find('.author').text,
    rating: row.pick(Field.attr('.stars', 'data-rating').when(int.tryParse)),
    comment: row.find('.body').text,
  )),
);

product.reviews.first?.rating;   // int?, no cast anywhere
```

Nothing here is `Object?`. `all` hands each match its own `Markup`, so a
nested read cannot accidentally match the whole page — the mistake that made
repeated sub-objects worth having a helper for.

- `all(selector, build)` — one record per match, `List<R>`.
- `one(selector, build)` — the first match, or `null`.
- `pick(field)` — a single typed `Field`, at any depth.

### Fields

A `Field<T>` is one typed read, usable off a page or inside `all`:

```dart
final String? title = res.parse(format.html).pick(Field.text('h1.title'));
final List<String> tags = res.parse(format.html).pick(Field.texts('ul.tags > li'));
final List<String> hrefs = res.parse(format.html).pick(Field.attrs('a', 'href'));
final int reviews = res.parse(format.html).pick(Field.fn((el) => el.querySelectorAll('.review').length));
```

The cases are `Field.text`, `Field.attr`, `Field.texts`, `Field.attrs`,
`Field.nest`, `Field.list` and `Field.fn`.

Two combinators adjust a field that already works, so `Field.fn` is rarely
needed:

```dart
Field.text('.price').when(util.text.number);   // Field<num?> — skips a null
Field.text('.stock').map((t) => t ?? 'unknown');   // Field<String> — sees it
Field.texts('.row').map((rows) => rows.length);    // Field<int>
```

`when` is the one you usually want: most readers are nullable, and a converter
like `int.tryParse` takes a `String`, not a `String?`. `map` is the
unconditional form, for a converter that has something to say about an absent
value.

### The String Shorthand (`extract`)

For a first look at an unfamiliar page, `extract` takes a schema of strings and
hands back `Map<String, Object?>`:

```dart
final data = res.parse(format.html).extract({
  'title': 'h1.title',
  'price': '.price@text',
  'canonical': 'link[rel="canonical"]@href',
  'categories': ['ul.breadcrumbs > li'],
  'reviews': ['.review', {'user': '.author', 'comment': '.body'}],
});
```

Every value is `Object?` and every read is a cast, which is why it is the tool
for exploring rather than the one for a pipeline you are going to keep.
`Field`s mix freely into the same schema.

---

### Rate limits

A `Fetcher` can carry a [`Limiter`](concurrent.md#how-often-not-how-many-concurrentrate),
which is where a rate belongs when it is the server's rather than the script's:

```dart
final api = Fetcher(limiter: concurrent.rate(10, per: 1.s));
await concurrent.run(urls, api.get, size: 8);   // 8 in flight, 10 per second
```

Every attempt takes a token, retries included, because the server counts those
too.

### Forms

A response knows the forms it carries. `res.form(selector)` collects their controls — hidden inputs, a CSRF token, the options already selected — so a script overrides the two fields it cares about and sends the rest back unchanged:

```dart
final login = await session.get('https://example.com/login'.url);
final home = await login.parse(format.html).form('#login')!
    .at(login.url)
    .fill({'user': user, 'pass': pass})
    .send(client: session);
```

See [docs/form.md](form.md).

---

## 3. Retries & Redirects

Failed requests retry up to `retries` times (default 2) on a transport error, a 5xx, or a 429. A `Retry-After` header is honoured when the server sends one — in either delta-seconds or HTTP-date form; an unparseable one falls back to the client's own backoff rather than throwing. Otherwise the delay is `backoff * attempt` with up to 25% jitter.

Set `cap` to refuse oversized bodies, which a broad crawl needs so one unexpected URL cannot exhaust memory:

```dart
final client = Fetcher(cap: 10 * 1024 * 1024); // 10 MB
```

Redirects are followed automatically by default (up to `redirects: 10`). Access `res.url` for the final landing destination:

```dart
final res = await net.http.get(
  'http://bit.ly/example'.url,
  redirect: true,   // follow them, which is the default
  redirects: 5,     // at most this many hops
);
print('Landed on: ${res.url}');
```

---

## 4. Cookies & Sessions (`CookieJar`)

Create a stateful session that preserves cookies across requests:

```dart
// Ephemeral session client:
final session = Fetcher(session: true);
await session.post('https://example.com/login'.url, body: const Body.form({
  'user': 'alice',
  'pass': 'secret',
}));
final dashboard = await session.get('https://example.com/dashboard'.url);

// Or bring your own jar, to share or inspect it:
final jar = CookieJar();
final client = Fetcher(jar: jar);
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
final client = Fetcher(
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

## 7. Caching (`HttpCache`)

Re-running a scrape over pages that have not changed is the normal case while an extractor is being written. Give a client a cache and the second run stops paying for it:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final client = Fetcher(cache: HttpCache('.cache'));

  final res = await client.get('https://example.com/article'.url);
  if (res.cached) {
    print('unchanged since last run');
  }

  await client.close();
}
```

| Situation | What happens |
| :--- | :--- |
| Nothing stored | Fetched normally, then stored |
| Stored, still inside its `max-age` or `Expires` | Served from disk, **no request at all** |
| Stored, with an `ETag` or `Last-Modified` | Revalidated with `If-None-Match` / `If-Modified-Since`; a `304` serves the stored body and no body crosses the wire |
| Stored, but the page changed | Refetched and re-stored |

`res.cached` is true in the second and third rows — a stored response served without a fresh download — and false in the first and fourth.

Only `GET` responses with status 200 are stored, and only when the server did not say `no-store`. There is no eviction: `cache.clear()` empties the directory and returns how many entries went.

`HttpCache` is usable on its own — `read`, `write`, `remove`, `clear` — and a `CacheEntry` reports `fresh`, `lifetime` and the `validators` it would revalidate with.

Crawls take the same thing as a directory: `net.crawl(url).cache('.cache')`.

---

## 8. Size Limits

`cap` refuses a body larger than the given number of bytes, throwing `FatalHttpException` — which is not retried, because a server's answer being too big is settled rather than transient. The transfer is abandoned as soon as `Content-Length` says so, or as soon as the arriving bytes do:

```dart
final client = Fetcher(cap: util.size.parse('5MiB')!);
```

---

## 9. Your Own Client

Construct an `Fetcher` for custom headers, a custom timeout, proxy, session cookies, a `cache`, a `cap`, or a `base` directory that relative download paths resolve against. **The caller must close it.**

```dart
final client = Fetcher(
  headers: {'Authorization': 'Bearer $token'},
  timeout: const Duration(seconds: 10),
  retries: 5,
  base: 'downloads',
  proxy: 'http://proxy.internal:3128',
  limiter: concurrent.rate(10, per: 1.s),
);

await client.download(url, 'album/track.mp3'); // -> downloads/album/track.mp3
await client.close();
```

To apply one client process-wide — including in tests — hand it to `net.use`, which closes the previous one:

```dart
await net.use(Fetcher(headers: {'Authorization': 'Bearer $token'}));
```

---

## See Also

- [`net.crawl`](crawl.md) — multi-page pipelines
- [`net.serve`](serve.md) — the other direction: something that listens
- [`format.html`](html.md) — the `Markup` cursor `res.parse(format.html)` hands back
- [`format.json`](json.md) — the cursor `res.at` returns

