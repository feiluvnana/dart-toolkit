# Web Crawling & Scraping Subsystem (`crawl.*` / `$()`)

The `crawl` namespace in **Dart Script Toolkit** provides a complete, modern web scraping and crawling framework with jQuery-like DOM manipulation, declarative routing, pipeline link-following, streaming atomic file downloads, and bounded concurrency.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. One-liner scraping with jQuery-like selector
  final res = await crawl.get('https://news.ycombinator.com');
  final titles = res.$('.titleline > a').texts;
  console.ok('Fetched ${titles.length} news titles.');

  // 2. Multi-step crawler with declarative routes
  final app = crawl.engine(concurrency: 4, base: 'downloads');

  app.route(RegExp(r'/catalog$'), (res) {
    for (final a in res.$('.item-card a')) {
      res.follow(a.attr('href')!, tag: 'item');
    }
  });

  app.tag('item', (res) async {
    final title = res.$('h1.title').text;
    final pdfUrl = res.link('.pdf');
    if (pdfUrl != null) {
      await res.save('docs/$title.pdf', pdfUrl);
    }
  });

  await app.run(['https://example.com/catalog']);
}
```

---

## 1. High-Level Crawler Workflows

### `crawl.run(urls, handler, {concurrency, base, delay, dedupe, dl})`
Executes an end-to-end multi-page crawling session starting from `urls` and returns a `Stats` summary:

```dart
final stats = await crawl.run(
  'https://books.toscrape.com',
  (res) async {
    if (res.tag == 'book') {
      final title = res.$('h1').text;
      final price = res.$('.price_color').text;
      console.info('$title -> $price');
    } else {
      // Album or Catalog page: follow product links and pagination
      for (final a in res.$('.product_pod h3 a')) {
        res.follow(a.attr('href')!, tag: 'book');
      }
      if (res.link('next') case final next?) {
        res.follow(next);
      }
    }
  },
  concurrency: 4,
  delay: Duration(milliseconds: 100),
);

console.ok('Crawled ${stats.completed} pages in ${stats.elapsed}.');
```

### `crawl.collect<T>(urls, handler, {concurrency, base, dl})`
Crawls URLs and collects all items emitted via `res.emit(item)` into a strongly typed `List<T>`:

```dart
final headlines = await crawl.collect<String>(
  'https://news.ycombinator.com',
  (res) {
    for (final title in res.$('.titleline > a').texts) {
      res.emit(title);
    }
  },
  concurrency: 4,
);

console.writer.table(['Index', 'Headline'], [
  for (var i = 0; i < headlines.take(10).length; i++) [i + 1, headlines[i]]
]);
```

---

## 2. Crawler Engine Architecture (`crawl.engine()`)

The `Engine<T>` is the core scheduler and worker pool coordinator:

```dart
final engine = crawl.engine<Map<String, dynamic>>(
  concurrency: 8,
  delay: Duration(milliseconds: 50),
  base: 'output',
  dedupe: true,
);
```

### Configuration Options
| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `concurrency` | `int` | `1` | Number of concurrent worker fibers. |
| `delay` | `Duration` | `Duration.zero` | Polite rate-limiting pause between downloads per worker. |
| `base` | `String?` | `null` | Base storage folder for relative file saves. |
| `dedupe` | `bool` | `true` | When true, ignores duplicate URLs (normalized, minus fragments). |
| `dl` | `Downloader<T>?` | `HttpDownloader<T>()` | Custom or mocked HTTP downloader. |
| `scheduler` | `Scheduler<T>?` | `Scheduler<T>()` | Custom request scheduler or `Priority<T>()`. |

### Routing & Tagging
Handlers can be registered directly on the engine using either URL patterns (`route`) or explicit pipeline tags (`tag`):

```dart
// Match URL pattern
engine.route(RegExp(r'/category/(\d+)'), (res) async {
  console.info('Processing category: ${res.url}');
});

// Match tagged requests
engine.tag('product', (res) async {
  final item = {
    'name': res.$('.title').text,
    'sku': res.meta['sku'],
  };
  res.emit(item);
});
```

### Event Listeners (`engine.on.*`)
```dart
engine.on.start(() => console.info('Crawler pipeline starting...'));
engine.on.progress((res) => console.write('.'));
engine.on.item((item) => console.ok('Scraped: $item'));
engine.on.done((stats) => console.ok('Completed ${stats.completed} requests.'));
engine.on.error((err, stack) => console.fail('Error: $err'));
```

---

## 3. Response & Pipeline Controls (`res.*`)

Every handler receives a `Response<T>` instance loaded with contextual shortcuts:

### URL Following with Relative Resolution
```dart
// Automatically resolves relative URLs like "/items/1" against res.url
res.follow('page/2.html');

// Attach tags and metadata
res.follow(
  '/product/42',
  tag: 'product',
  meta: {'category': 'electronics', 'source': res.url.toString()},
  priority: 10,
);
```

### Direct Asset Saving
```dart
// 1. Save response bytes directly
await res.save('page.html');

// 2. Stream remote asset to file atomically with .part protection
final remoteAudio = res.link('.mp3');
if (remoteAudio != null) {
  await res.save('tracks/track1.mp3', remoteAudio);
}
```

### Emitting Structured Data
```dart
res.emit({'title': res.$('h1').text, 'url': res.url.toString()});
```

### Aborting Crawl Early
```dart
if (res.status == 429 || res.body.contains('CAPTCHA')) {
  res.stop('Rate limit reached');
}
```

---

## 4. jQuery-like Selector `$()` & `QueryResult`

You can query the DOM on responses, raw HTML strings, elements, or documents:

```dart
// On response
final items = res.$('div.card');

// On raw HTML string
final q = $('<div><a href="/link" class="cta">Click here</a></div>');
```

### CSS Queries & Traversal
- `res.$(selector)`: Find descendant elements matching CSS selector.
- `q.find(selector)`: Search descendants.
- `q.children([selector])`: Direct child elements.
- `q.parent([selector])`: Immediate parent element.
- `q.closest(selector)`: Nearest ancestor matching selector.
- `q.filter(selectorOrFn)`: Filter current collection.
- `q.not(selector)`: Exclude matching elements.
- `q.eq(index)`: Get single element wrapped as `QueryResult`.
- `q.firstMatch`, `q.lastMatch`: First or last element as `QueryResult`.

### Text & Attribute Extraction
```dart
// Text
final title = res.$('h1').text;          // Combined trimmed text
final list = res.$('li').texts;          // List<String> of each element's text
final lines = res.$('.address').lines;    // Split on <br> or newlines

// Attributes
final id = res.$('#item').attr('id');
final classes = res.$('a').attrs('class');

// Asset Extraction
final firstPdf = res.$('a').link('.pdf');   // First link matching pattern
final allJpgs = res.$('img').srcs('.jpg');  // All image sources
```

---

## 5. Batch Asset Synchronization (`crawl.sync()`)

Concurrently download and synchronize asset maps with optional URL prefixes and existence checks:

```dart
final assets = {
  'images/banner.jpg': 'https://example.com/assets/banner.jpg',
  'images/logo.png': 'common/logo.png', // uses prefix
};

await crawl.sync(
  assets,
  prefix: 'https://example.com/',
  base: 'downloads',
  concurrency: 8,
  match: true, // skips file if already exists and size > 0
);
```
