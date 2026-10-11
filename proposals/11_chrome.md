# 11: Chrome & Browser Automation

Headless Chrome and Chromium automation driven by Rust CDP (Chrome DevTools Protocol) over native WebSockets.

---

## 1. Quick Launch & Page Navigation

```dart
// Launch browser
final chrome = await Chrome.launch();

// Open page
final page = await chrome.open('https://news.ycombinator.com');

// Extract rendered HTML
final html = await page.html();
print(html);

await chrome.close();
```

---

## 2. Page Interaction (`click`, `type`, `eval`)

Consistently short 1-word methods:

```dart
final page = await chrome.open('https://example.com/login');

// Type into inputs
await page.type('#user', 'alice');
await page.type('#pass', 'secret');

// Click button
await page.click('#submit');

// Wait for selector to appear after navigation
await page.wait('#dashboard');

// Evaluate JavaScript expression
final title = await page.eval('document.title');
print(title);
```

---

## 3. Screenshots & PDFs (`shot`, `pdf`)

Captures return byte buffers implementing `Reader` for direct piping to `File` or `Image`:

```dart
// Take screenshot
await page.shot().pipe(File('screenshot.png'));

// Generate PDF
await page.pdf().pipe(File('invoice.pdf'));
```

---

## 4. Advanced Use Cases

### 4.1 Scraping JavaScript-Rendered SPAs
Standard HTTP scraping fails on client-side rendered Single Page Apps (React/Vue). Chrome evaluates JS and provides the fully hydrated DOM:

```dart
final chrome = await Chrome.launch();
final page   = await chrome.open('https://spa-store.com/products');

// Wait for dynamic product list to hydrate
await page.wait('.product-card');

// Pass rendered HTML straight into Html DOM parser
final doc = Html.parse(await page.html());
for (final card in doc.all('.product-card')) {
  print('${card.find('.name')?.text} - ${card.find('.price')?.text}');
}

await chrome.close();
```

### 4.2 Full-Page Screenshot to Optimized WebP Pipeline
Combine `Chrome`, `Image`, and `File` in a zero-copy pipeline:

```dart
final page = await chrome.open('https://flutter.dev');

// Capture full scrollable page
final rawBytes = await page.shot(full: true);

// Compress and scale down via native Image engine
await Image.load(rawBytes)
  .scale(0.8)
  .save('flutter_preview.webp', quality: 85);
```

### 4.3 Multi-Page Scraping with Worker Pool
```dart
final chrome = await Chrome.launch();
final pool   = Pool(4);

for (final url in targetUrls) {
  pool.run(() async {
    final page = await chrome.open(url);
    await page.wait('main');
    await page.shot().pipe(File('shots/${Uri.parse(url).host}.png'));
    await page.close();
  });
}

await pool.wait();
await chrome.close();
```
