# jQuery-like Selectors (`$()`)

A chainable wrapper over `package:html`. `$()` parses markup into a queryable `QueryResult`.

---

## Quick Overview

Top-level `$` and `$xpath` can be imported from `package:dart_toolkit/selector.dart`, or accessed via `net.$` / `net.$xpath`, or called directly on HTML strings (`markup.$('...')`) and HTTP responses (`res.$('...')`).

```dart
import 'package:dart_toolkit/selector.dart';

void main() {
  const html = '''
    <ul class="tracks">
      <li class="track" data-id="1"><a href="/t/1">Track One</a></li>
      <li class="track bonus" data-id="2"><a href="/t/2">Track Two</a></li>
    </ul>
  ''';

  print($(html, '.track a').texts);   // [Track One, Track Two]
  print($(html, '.bonus').data('id'));      // 2
}
```

---

## 1. Entry Points

There is exactly one clean way to reach each shape:

| Expression | Import / Receiver | Meaning |
| :--- | :--- | :--- |
| `$(markup, [selector])` | `package:dart_toolkit/selector.dart` | Parse markup into a `QueryResult` |
| `$xpath(markup, [query])` | `package:dart_toolkit/selector.dart` | Parse markup into an XPath `QueryResult` |
| `net.$(markup, [selector])` | `dart_toolkit.dart` | Top-level selector via `net` singleton |
| `net.$xpath(markup, [query])` | `dart_toolkit.dart` | Top-level XPath via `net` singleton |
| `markup.$(selector)` | `String` extension | Parse HTML string and query it |
| `markup.$xpath(query)` | `String` extension | Parse HTML string and query via XPath |
| `response.$(selector)` | `HttpResponse` / `Response` | Query parsed HTML response body |
| `response.$xpath(query)` | `HttpResponse` / `Response` | Query response body via XPath |
| `element.$(selector)` | `Element` extension | Query within an existing element |
| `result.find(selector)` | `QueryResult` | Query descendants of current matches |
| `result(selector)` | `QueryResult` | Callable shorthand for `.find(...)` |

### Full jQuery Selectors

The `$` selection supports full jQuery selector syntax, not just standard CSS:

- **Text search**: `:contains("text")`, `:icontains("text")` (case-insensitive)
- **Descendant test**: `:has(selector)` (e.g. `div:has(a.active)`)
- **Negation**: `:not(selector)`
- **Positional index**: `:first`, `:last`, `:eq(n)` (supports negative index `-1`), `:even`, `:odd`, `:gt(n)`, `:lt(n)`
- **Tag groups**: `:header` (`h1..h6`), `:input` (`input, textarea, select, button`), `:button`, `:checkbox`, `:radio`, `:text`, `:password`, `:submit`, `:reset`
- **Content state**: `:empty`, `:parent`, `:selected`, `:checked`, `:disabled`, `:enabled`, `:visible`, `:hidden`
- **Attribute inequality**: `[attr!="val"]`

```dart
res.$('a:contains("More")');       // First link containing "More"
res.$('div:has(p.desc)');          // Divs containing a p.desc
res.$('ul > li:even');             // Even list items (0, 2, ...)
res.$(':header');                  // All headers (h1..h6)
res.$xpath('//a[@class="link"]');  // XPath selection
```

---

## 2. Traversal

```dart
final result = res.$('.main');

result.find('.child');       // descendants matching selector
result.children();           // direct children
result.children('.only');    // direct children matching selector
result.parent();             // direct parent
result.closest('.wrapper');  // nearest self-or-ancestor matching selector
result.siblings();           // sibling elements
result.prev();               // previous sibling
result.next();               // next sibling

result.at(0);                // single-element QueryResult
result.at(-1);               // last element; out-of-range yields an empty QueryResult
result[0];                   // Element?, or null if out of range
```

Filtering is split by type, so nothing takes an untyped argument:

```dart
result.filter((el) => el.classes.contains('bonus')); // by predicate
result.matching('.bonus');                            // by selector
result.not('.bonus');                                 // by selector, negated
```

---

## 3. Extraction

All plural property extractors are getters returning `List<String>` across all matched elements. Singular property extractors are getters returning the attribute of the first matched element (or empty string/null):

| Member | Kind | Returns |
| :--- | :--- | :--- |
| `href` / `hrefs` | Getter | First raw `href` / list of all raw `href` attributes |
| `src` / `srcs` | Getter | First raw `src` / list of all raw `src` attributes |
| `text` | Getter | Text of all matches as a browser renders it, space-joined |
| `texts` | Getter | The same, one entry per match |
| `title` / `titles` | Getter | `title` attribute on first match / across matches |
| `alt` / `alts` | Getter | `alt` attribute on first match / across matches |
| `action` / `actions` | Getter | `action` attribute on first match / across matches |
| `value` / `values` | Getter | Form values as a browser would submit them — see below |
| `html` / `outer` | Getter | Inner / outer HTML string of the first match |
| `lines` | Getter | Text split on `<br>` and newlines, markup stripped and entities decoded |
| `dataset` | Getter | `Map<String, String>` of every `data-*` attribute on the first match |
| `attr(name)` | Method | `String?` on the first match |
| `attrs(name)` | Method | `List<String>` across every match |
| `data(key)` | Method | The `data-[key]` attribute value of the first match |
| `has(name)` | Method | Whether any match carries the class |
| `links()` / `link()` | Method | Raw `href` values on matches and descendants |
| `srcs()` / `src()` | Method | Raw `src` values on matches and media descendants |

Extracting attributes from a query result:

```dart
final firstHref = res.$('a.morelink').href;          // single href (String?)
final allHrefs  = res.$('a.morelink').hrefs;         // all hrefs (List<String>)
final firstSrc  = res.$('img.thumb').src;            // single src (String?)
final allSrcs   = res.$('img.thumb').srcs;           // all srcs (List<String>)
final titleText = res.$('h1.title').text;            // text of h1 (String)
final allTitles = res.$('.titleline > a').texts;     // all texts (List<String>)
final xpathText = res.$xpath('//h2').texts;          // XPath text list
```

`lines` is built for `<br>`-separated blocks like tracklists, and decodes entities on the way out:

```dart
final list = $('<div>01. First<br>02. Tom &amp; Jerry</div>').lines;
// ['01. First', '02. Tom & Jerry']
```

### Whitespace

Text comes back the way a browser draws it: runs of spaces and newlines collapse to one space. Pages are indented, so the markup for one heading usually holds both:

```html
<h1 class="name">
  Wireless
  Keyboard
</h1>
```

```dart
res.$('.name').text;                  // 'Wireless Keyboard'
res.extract({'name': '.name'});       // {'name': 'Wireless Keyboard'}
res.pick(Field.text('.name'));        // 'Wireless Keyboard'
```

Inside a `<pre>` or a `<textarea>` the whitespace *is* the content, so there it is kept and only trimmed — a scraped code sample survives intact. `util.text.clean` does the same job to a plain string.

### Form values

`value` reads a control the way a browser would submit it:

| Control | `value` |
| :--- | :--- |
| `<textarea>` | Its text |
| `<select>` | The selected `<option>`'s value, or its text when it has none; the first option when nothing is marked `selected` |
| checkbox, radio | Its value only when `checked` — `'on'` when it has none — and `null` otherwise |
| anything else | Its `value` attribute |

```dart
final form = res.$('form');
final size = form.find('select[name=size]').value;   // 'm'
final ticked = form.find('input[type=checkbox]').values;  // only the checked ones
```

> `QueryResult.links()` returns **raw** attribute strings. To get absolute URLs, use `HttpResponse.links()`, which resolves against the response URL.

---

## 4. It Is a Real Iterable

`QueryResult` mixes in `Iterable<Element>`, so the standard library works directly:

```dart
for (final el in $(html).find('.track')) {
  print(el.attr('data-id'));
}

$(html).find('.track').map((e) => e.text).toList();
$(html).find('.track').where((e) => e.classes.contains('bonus'));
$(html).find('.track').length;
$(html).find('.track').firstOrNull;
```

`each` is available when you want the element and its index:

```dart
$(html).find('.track').each((el, i) => print('$i: ${el.text}'));
```
