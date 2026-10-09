# Module Proposal 04: Web Scraping & Markup (`lib/scrape.dart`, `lib/html.dart`, `lib/xml.dart`, `lib/xpath.dart`)

## 1. Overview & Vision

The Scraping & Markup module provides fast, standard-compliant HTML/XML parsing, CSS selector matching, XPath evaluation, automated web crawling, and browser-grade form submission.

### Core Problems in the Existing API
1. **Manual Element Loops**: Extracting text content or attributes from multiple matching elements requires manual `for` loops or tedious `.map((e) => e.attr('href')).toList()` chaining.
2. **Missing Shorthand Element Accessors**: Accessing a single element (e.g. the first matching `<h1>` or `<meta>`) requires `.first` or checking `.isNotEmpty`, which throws if missing.
3. **Crawl Orchestration Verbosity**: Setting up recursive crawling with depth limits, rate limits, and custom filters requires manual bookkeeping.

---

## 2. Detailed Before vs After Comparison

### 2.1 CSS Selectors & Batch Field Extraction

#### Before:
```dart
final html = await url.get().html;

// Extracting list of titles
final titles = <String>[];
for (final el in html.$('h2.article-title')) {
  titles.add(el.text.trim());
}

// Extracting list of link hrefs
final links = html.$('a.post-link')
    .map((e) => e.attr('href'))
    .whereType<String>()
    .toList();

// Finding single element safely
final authorEl = html.$('.author').firstOrNull;
final authorName = authorEl?.text.trim();
```

#### After (Proposed):
```dart
final html = await url.getHtml();

// 1. Direct batch getters on Element Selection
final titles = html.$('h2.article-title').texts;       // List<String>
final links  = html.$('a.post-link').attrs('href');     // List<String>

// 2. Safe single element lookups
final author = html.find('.author')?.text;              // String?
final banner = html.find('img.hero')?.attr('src');      // String?

// 3. Structured Record Extraction from Elements
final articles = html.$('article.card').map((card) => (
  title:  card.find('h2')?.text ?? 'Untitled',
  url:    card.find('a')?.attr('href'),
  image:  card.find('img')?.attr('src'),
  author: card.find('.byline')?.text,
)).toList();
```

---

### 2.2 XPath Evaluation

#### Before:
```dart
final items = html.$x('//div[@class="item"]/a/@href');
final urls = items.map((node) => node.text).toList();
```

#### After (Proposed):
```dart
// Direct typed XPath querying
final urls = html.xpath('//div[@class="item"]/a/@href').values;
final totalCount = html.xpath('count(//div[@class="item"])').number;
```

---

### 2.3 Web Crawler (`url.crawl`)

#### Before:
```dart
final crawler = site.crawl<Asset>(onResponse: (page) => findAssets(page));
crawler.progress('Crawling');
await crawler;
```

#### After (Proposed):
```dart
// Declarative crawler with depth, concurrency, rate limiting & progress
final assets = await site.crawl<Asset>(
  depth: 3,
  concurrency: 6,
  delay: 100.ms, // polite crawl delay
  filter: (url) => url.host == site.host && !url.path.contains('/logout'),
  onPage: (html, url) {
    return html.$('.download-link').attrs('href').map((href) => Asset(url / href));
  },
  show: 'Crawling Site Assets',
);
```

##### Visual Look (Live Crawler Output):
```text
⠙ Crawling Site Assets  184 pages crawled (9.2 pages/s)  (20s)
    https://example.com/gallery/vol-01
    https://example.com/gallery/vol-02
    https://example.com/gallery/vol-03
    +181 more
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **Plural Extractors** | Manual `.map()` and `for` loops | `.texts`, `.attrs('name')` | Clean, 1-word batch extraction |
| **Single Lookups** | `.$('selector').firstOrNull` | `.find('selector')` | Null-safe, no index out of bounds |
| **Crawler Control** | Limited callback parameters | `depth:`, `delay:`, `filter:`, `show:` | Complete crawling engine in 1 function |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- `html.find(selector)` returns `Element?` instead of throwing `MissingException`.
  - *Rationale*: Null-safe lookups are much more ergonomic for scraping websites where elements might be missing dynamically.

### Backward Compatibility:
- 100% backward compatible. All existing `html.$`, `html.$x`, `Element.attr`, and `DOM` tree mutation methods continue to work unchanged.
