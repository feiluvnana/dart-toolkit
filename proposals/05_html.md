# 05: HTML & DOM

Dead-simple HTML document parsing and CSS querying.

---

## 1. Parse & Query

```dart
final doc = Html.parse('''
  <html>
    <body>
      <div id="content">
        <h1>Welcome</h1>
        <a href="/login" class="link">Sign In</a>
        <a href="/about" class="link">About Us</a>
      </div>
    </body>
  </html>
''');

// Find first match
final title = doc.find('h1')?.text; // 'Welcome'

// Find all matches
final links = doc.all('a.link');
for (final a in links) {
  print('${a.text} -> ${a.attr('href')}');
}
```

---

## 2. Element API

Consistently short 1-word properties and methods:

```dart
final el = doc.find('#content')!;

print(el.tag);            // 'div'
print(el.text);           // inner text content
print(el.html);           // inner HTML string
print(el.attr('id'));     // 'content'

// Scoped queries inside element
final btn = el.find('.btn');
final items = el.all('li');

// Mutation
el.drop(); // removes element from DOM
```

---

## 3. Direct File I/O

```dart
final doc = await Html.read('index.html');
final h1  = doc.find('h1')?.text;

// Write modified HTML back to disk
await File('dist.html').write(doc.html);
```

---

## 4. Advanced Use Cases

### 4.1 HTML Table Scraping to Structured Data
Extract tabular data into Dart maps in 5 lines:

```dart
final doc = await Http.get('https://example.com/stocks').html();
final rows = <Map<String, String>>[];

for (final tr in doc.all('table#quotes tr:not(:first-child)')) {
  final cols = tr.all('td');
  if (cols.length >= 3) {
    rows.add({
      'ticker': cols[0].text.trim(),
      'price': cols[1].text.trim(),
      'change': cols[2].text.trim(),
    });
  }
}
```

### 4.2 HTML Sanitization (XSS Defense)
Strip harmful elements like `<script>`, `<iframe>`, and inline event handlers:

```dart
void sanitize(Element root) {
  for (final bad in root.all('script, iframe, style, object')) {
    bad.drop();
  }
}
```

### 4.3 Automatic Relative URL Resolution
Resolving relative links against the source base URL:

```dart
final base = 'https://news.ycombinator.com/news';
final doc  = await Http.get(base).html();

for (final a in doc.all('a[href]')) {
  final href = a.attr('href')!;
  final full = Uri.parse(base).resolve(href).toString();
  print(full);
}
```
