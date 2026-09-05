# HTTP & Networking Subsystem (`net.http.*` / `net.*`)

The `net` namespace in **Dart Script Toolkit** provides concise, strictly 1-word methods for HTTP client requests, streaming downloads, atomic file saving, and jQuery-like HTML querying.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Quick GET request and text/JSON parsing
  final res = await net.get('https://api.github.com/zen');
  print('GitHub Zen: ${res.body}');

  // 2. HTML parsing with jQuery-like $() syntax
  final page = await net.get('https://news.ycombinator.com');
  for (final link in page.$('.titleline > a').links()) {
    print('Story: $link');
  }

  // 3. POST request
  final created = await net.post('https://httpbin.org/post', body: {'name': 'Dart'});
  print(created.body);

  // 4. Atomic streaming file download with .part protection
  await net.download('https://example.com/archive.zip', 'downloads/archive.zip');

  // 5. Batch concurrent download synchronization
  await net.sync({
    'images/logo.png': 'https://example.com/logo.png',
    'images/banner.jpg': 'https://example.com/banner.jpg',
  }, concurrency: 4);
}
```

---

## 1. Quick Request Methods (1-word)

All primary HTTP methods are available directly on `net.*` or `net.http.*`:

- `net.get(url, {headers, timeout})`
- `net.post(url, {body, headers, timeout})`
- `net.put(url, {body, headers, timeout})`
- `net.delete(url, {headers, timeout})`
- `net.patch(url, {body, headers, timeout})`
- `net.head(url, {headers, timeout})`

### `HttpResponse`
Every request returns an `HttpResponse` wrapping:
- `res.ok`: Boolean flag indicating 2xx success.
- `res.status`: Numeric HTTP status code (e.g., `200`, `404`).
- `res.headers`: Response headers map (`Map<String, String>`).
- `res.body`: UTF-8 decoded text with malformed character tolerance.
- `res.json`: Decoded JSON payload (`Object?`).
- `res.doc`: Parsed HTML `Document`.
- `res.$(selector)`: Evaluates CSS selector and returns chainable `QueryResult`.
- `res.link([filter])` / `res.links([filter])`: Extracts resolved absolute URLs from `<a>`, `<link>`, and `<area>` tags.
- `res.src([filter])` / `res.srcs([filter])`: Extracts resolved absolute media/script URLs.
- `res.lines`: Clean non-empty text lines from document.
- `res.save(filePath, [sourceUrl])`: Atomically saves response bytes or downloads a linked asset.

---

## 2. Streaming Downloads (`net.download()` & `net.sync()`)

### `net.download()`
Streams a remote file directly to a local path with `.part` protection to prevent corrupted partial files:

```dart
await net.download(
  'https://example.com/large-file.iso',
  'downloads/file.iso',
  onProgress: (received, total) {
    print('$received / $total bytes');
  },
);
```

### `net.sync()`
Concurrently synchronizes a collection of download tasks:

```dart
await net.sync(
  {
    'assets/1.png': 'https://example.com/1.png',
    'assets/2.png': 'https://example.com/2.png',
  },
  concurrency: 8,
  match: true, // Skips existing non-empty files
);
```

---

## 3. Configured Sessions (`net.http.client()`)

For custom headers, base URLs, retry policies, or connection reuse:

```dart
final client = net.http.client(
  headers: {'Authorization': 'Bearer <token>'},
  retries: 3,
  backoff: Duration(milliseconds: 300),
  base: 'downloads',
);

final data = await client.get('https://api.example.com/data');
await client.download('https://example.com/file.zip', 'file.zip');

print('Downloaded ${client.count} new files');
await client.close();
```
