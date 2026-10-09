# Module Proposal 03: HTTP & Networking (`lib/http.dart`)

## 1. Overview & Vision

The HTTP module provides network requests on `Uri` as `Task` instances, streaming downloads, server-sent events, session cookies, connection pools, HTTP caching, and scoped execution policies (`Http.scope`).

### Core Problems in the Existing API
1. **Multi-Step Decoding**: Fetching JSON or HTML requires two to three steps: `final res = await url.get(); final json = jsonDecode(await res.text);`.
2. **Verbose Query Building**: Constructing URLs with query parameters requires manual string templates or verbose `url.replace(queryParameters: ...)`.
3. **Repetitive Auth & Headers**: Attaching standard Bearer tokens, API keys, or custom headers requires repeatedly instantiating `Map<String, String>` headers.
4. **Download Boilerplate**: Downloading a URL to a file with progress requires manual wiring between `download()`, `Task`, and `Path`.

---

## 2. Detailed Before vs After Comparison

### 2.1 Typed Requests on `Uri` and `String`

#### Before:
```dart
// 1. GET and JSON decode
final res = await 'https://api.github.com/repos/dart-lang/sdk'.url.get(
  headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
);
final map = jsonDecode(await res.text) as Map<String, dynamic>;

// 2. POST with JSON body
final postRes = await 'https://api.example.com/items'.url.post(
  headers: {'Content-Type': 'application/json'},
  json: {'title': 'New Item', 'price': 99},
);
```

#### After (Proposed):
```dart
// 1. Direct typed JSON GET with Bearer Auth
final map = await 'https://api.github.com/repos/dart-lang/sdk'
    .url
    .bearer(token)
    .getJson<Map<String, dynamic>>();

// 2. Direct typed JSON POST
final created = await 'https://api.example.com/items'
    .url
    .bearer(token)
    .postJson<Map<String, dynamic>>({'title': 'New Item', 'price': 99});

// 3. Direct HTML parse
final html = await 'https://news.ycombinator.com'.url.getHtml();

// 4. Direct Text / Bytes
final text = await 'https://example.com/robots.txt'.url.getText();
final bytes = await 'https://example.com/favicon.ico'.url.getBytes();
```

---

### 2.2 Fluent URL Path & Query Parameter Builder

#### Before:
```dart
final base = 'https://api.example.com'.url;
final url = base.replace(
  path: '${base.path}/v2/search',
  queryParameters: {
    'query': 'dart',
    'limit': '50',
    'active': 'true',
  },
);
```

#### After (Proposed):
```dart
// Operator / appends path segment; Operator & sets query parameters
final url = 'https://api.example.com'.url / 'v2' / 'search' & {
  'query': 'dart',
  'limit': 50,
  'active': true,
};
```

---

### 2.3 Streaming Downloads with Progress Display

#### Before:
```dart
final task = 'https://example.com/large.iso'.url.download(to: 'large.iso');
final file = await task.show('Downloading ISO');
```

#### After (Proposed):
```dart
// Single-expression download with automatic progress display
final file = await 'https://example.com/large.iso'
    .url
    .downloadTo('large.iso', show: 'Downloading ISO');
```

##### Visual Look:
```text
⠙ Downloading ISO  ━━━━━━━╸───────────────  35%  1.2/3.4 GB  4.5 MB/s  eta 8m 12s  (4m 15s)
```

---

### 2.4 Scoped HTTP Context (`Http.scope`)

#### Before:
```dart
await Http.scope(
  () => sync(),
  timeout: 30.s,
  retry: Retry(3),
  perHost: 4,
  headers: {'User-Agent': 'MyBot/1.0'},
);
```

#### After (Proposed):
```dart
// Fluent client builder & scoped runner
await Http.scope(() => sync(), config: (http) {
  http.timeout = 30.s;
  http.retry(attempts: 3, backoff: 2.0);
  http.perHost = 4;
  http.userAgent = 'MyBot/1.0';
  http.bearer = token;
  http.enableCache(maxAge: 1.h);
});
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **JSON Requests** | 3 steps (`get()` -> `text` -> `jsonDecode()`) | 1 step (`getJson<T>()`) | **-66% lines of code**, type-safe |
| **URL Querying** | Verbose `Uri.replace(...)` | `url / 'path' & {'k': 'v'}` | Intuitive, standard operator syntax |
| **File Downloads** | Manual task creation & `.show()` wiring | `url.downloadTo(path, show: '...')` | 1-line download with visual bar |
| **Authentication** | Manual header maps | `.bearer(token)`, `.header(k, v)` | High discoverability |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- **Automatic Content Decoding**: `getJson<T>()` parses JSON in the caller isolate for payloads `< 1MB` and delegates to a worker isolate for payloads `> 1MB`.
  - *Mitigation*: Users who need raw byte streams can still call `url.get().stream` or `url.getBytes()`.

### Backward Compatibility:
- 100% backward compatible. All existing verbs (`url.get()`, `url.post()`, `url.download()`, `Request`, `Response`, `Http.scope`) continue to work seamlessly.
