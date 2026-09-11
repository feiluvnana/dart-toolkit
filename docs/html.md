# HTML (`format.html`)

The format codec for HTML, spelled like `format.json`, `format.yaml` and
`format.toml`: `parse`, `read`, `format`. It hands back a `Markup` cursor —
a chainable set of matched elements over `package:html`.

Before 4.0.0 this lived in `net` as a `$` bolted to the side of a response,
which is why a crawler could only really read one format. Now `net` fetches
bytes and `format` reads them:

```dart
final res  = await net.http.get(url);
final page = res.parse(format.html);

page.find('h1').text;
page.find('a').attrs('href');
```

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() {
  const markup = '''
    <ul class="tracks">
      <li class="track" data-id="1"><a href="/t/1">Track One</a></li>
      <li class="track bonus" data-id="2"><a href="/t/2">Track Two</a></li>
    </ul>
  ''';

  final page = format.html.parse(markup);

  print(page.find('.track a').texts);   // [Track One, Track Two]
  print(page.find('.bonus').data('id'));      // 2
}
```

The jQuery `$` is the same thing under its own name, kept off the default
surface because `$` in every script's global scope is a cost not every script
wants to pay:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/html.dart';

// setup: const markup = '<ul><li class="track bonus" data-id="2">'
// setup:     '<a href="/t/2">Track Two</a></li></ul>';
print($(markup, '.track a').texts.list);
print(markup.$('.bonus').data('id'));
```

---

## 1. Entry Points

| Expression | Import / Receiver | Meaning |
| :--- | :--- | :--- |
| `format.html.parse(text)` | `dart_toolkit.dart` | Parse markup into a `Markup` |
| `format.html.query(text)` | `dart_toolkit.dart` | Parse markup into an XPath `Markup` |
| `format.html.fragment(text)` | `dart_toolkit.dart` | Parse a piece of a page, unwrapped |
| `format.html.read(path)` | `dart_toolkit.dart` | Read and parse a file |
| `format.html.format(markup)` | `dart_toolkit.dart` | Render a cursor back to HTML text |
| `res.parse(format.html)` | `Reply` / `Page` | The response body, parsed once and memoised |
| `$(markup, [selector])` | `package:dart_toolkit/html.dart` | The jQuery spelling of `parse` |
| `$xpath(markup, [query])` | `package:dart_toolkit/html.dart` | The jQuery spelling of `query` |
| `markup.$(selector)` | `String` extension | Parse an HTML string and query it |
| `markup.$xpath(query)` | `String` extension | The same, for XPath |
| `element.query` | `Element` extension | A `package:html` element as a cursor |
| `page.find(selector)` | `Markup` | Search the page, or the current set |
| `page.xpath(query)` | `Markup` | The same, in XPath |

### One search, one spelling

`page(selector)` was a callable shorthand for `find` through 4.0.0 — the
release that made the two *one search* and then kept both names for it. It is
gone in 5.0.0, and the reason is not only Rule 5: which selector **language**
the callable spoke depended on how the cursor had been built, so
`page('//h1')` was XPath on a cursor from `format.html.query` and a failed CSS
selector on one from `format.html.parse`, with nothing at the call site saying
which. `find` and `xpath` each say so in their names.

`$` and `$xpath` on `Element` and `Document` are gone with it. They sat on the
*default* surface, which contradicted the opt-in rule the `String` extension
follows, and they were `element.query` under a second name.

On a cursor rooted on a document — what `format.html.parse` and
`res.parse(format.html)` give back — `find` searches the whole page. On a
scoped cursor it searches the descendants of the current set, so chaining
means what it reads as:

```dart
page.find('.row').find('.name').texts;   // names inside rows, only
```

`matching(selector)` is how you ask whether the set *itself* qualifies.

### Full jQuery Selectors

`find` supports full jQuery selector syntax, not just standard CSS:

- **Text search**: `:contains("text")`, `:icontains("text")` (case-insensitive)
- **Descendant test**: `:has(selector)` (e.g. `div:has(a.active)`)
- **Negation**: `:not(selector)`
- **Positional index**: `:first`, `:last`, `:eq(n)` (supports negative index `-1`), `:even`, `:odd`, `:gt(n)`, `:lt(n)`
- **Tag groups**: `:header` (`h1..h6`), `:input` (`input, textarea, select, button`), `:button`, `:checkbox`, `:radio`, `:text`, `:password`, `:submit`, `:reset`
- **Content state**: `:empty`, `:parent`, `:selected`, `:checked`, `:disabled`, `:enabled`, `:visible`, `:hidden`
- **Attribute inequality**: `[attr!="val"]`
- **Structural**: `:nth-child(an+b)`, `:nth-last-child`, `:nth-of-type`,
  `:nth-last-of-type`, `:first-of-type`, `:last-of-type`, `:only-of-type`,
  `:only-child` — plus `:is(...)` and `:where(...)`. These are evaluated here
  rather than by `package:csslib`, which matched `:nth-child(2)` against
  nothing at all and threw `UnimplementedError` for `:nth-of-type`. A selector
  this cannot evaluate is now a `FormatException` naming the part it could not
  read.

```dart no-compile
res.parse(format.html).find('a:contains("More")');       // First link containing "More"
res.parse(format.html).find('div:has(p.desc)');          // Divs containing a p.desc
res.parse(format.html).find('ul > li:even');             // Even list items (0, 2, ...)
res.parse(format.html).find(':header');                  // All headers (h1..h6)
res.parse(format.html).xpath('//a[@class="link"]');  // XPath selection
```

---

## 2. Traversal

```dart
final result = res.parse(format.html).find('.main');

result.find('.child');       // descendants matching selector
result.children();           // direct children
result.children('.only');    // direct children matching selector
result.parent();             // direct parent
result.closest('.wrapper');  // nearest self-or-ancestor matching selector
result.siblings();           // sibling elements
result.prev();               // previous sibling
result.next();               // next sibling

result.at(0);                // single-element Markup
result.at(-1);               // last element; out-of-range yields an empty Markup
result[0];                   // Element?, or null if out of range
```

Filtering is split by type, so nothing takes an untyped argument:

```dart
// setup: final result = page.find('.row');
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
final firstHref = res.parse(format.html).find('a.morelink').attr('href');          // single href (String?)
final allHrefs  = res.parse(format.html).find('a.morelink').attrs('href');         // all hrefs (List<String>)
final firstSrc  = res.parse(format.html).find('img.thumb').attr('src');            // single src (String?)
final allSrcs   = res.parse(format.html).find('img.thumb').attrs('src');           // all srcs (List<String>)
final titleText = res.parse(format.html).find('h1.title').text;            // text of h1 (String)
final allTitles = res.parse(format.html).find('.titleline > a').texts;     // all texts (List<String>)
final xpathText = res.parse(format.html).xpath('//h2').texts;          // XPath text list
```

`lines` is built for `<br>`-separated blocks like tracklists, and decodes entities on the way out:

```dart
final list = $('<div>01. First<br>02. Tom &amp; Jerry</div>').lines;
// ['01. First', '02. Tom & Jerry']
```

### Typed records (`all`, `one`, `pick`)

Every reader above hands back a `String` or a `List<String>`. To get a *shape*
out of a page with each field's type intact, build a record: `all` gives each
match its own scoped `Markup`, `one` does the same for a section a page
has at most one of, and `pick` reads a `Field` at any depth.

```dart
final variants = res.parse(format.html).all('.variant', (row) => (
  name: row.find('.name').text,
  sku: row.attr('data-sku'),
  qty: row.pick(Field.text('.qty').when(int.tryParse)),
));
// Sequence<({String name, String? sku, int? qty})>

final seller = res.parse(format.html).one('.seller', (s) => (
  name: s.find('.name').text,
  rating: s.pick(Field.text('.rating').when(util.text.number)),
));
// ({String name, num? rating})?
```

The scoping is the point: `row('.name')` searches inside that row, so a nested
read cannot quietly match every `.name` on the page. Nest `all` inside `all`
for a sub-object of a sub-object.

A whole page is the same idea with no wrapper:

```dart
final product = (
  title: res.parse(format.html).find('h1').text,
  price: res.parse(format.html).pick(Field.text('.price').when(util.text.number)),
  variants: res.parse(format.html).all('.variant', (row) => (sku: row.attr('data-sku'))),
);
```

See [http.md](http.md#typed-extraction-records) for how this sits beside the
`extract` shorthand.

### Whitespace

Text comes back the way a browser draws it: runs of spaces and newlines collapse to one space. Pages are indented, so the markup for one heading usually holds both:

```html
<h1 class="name">
  Wireless
  Keyboard
</h1>
```

```dart
res.parse(format.html).find('.name').text;                  // 'Wireless Keyboard'
res.parse(format.html).extract({'name': '.name'});       // {'name': 'Wireless Keyboard'}
res.parse(format.html).pick(Field.text('.name'));        // 'Wireless Keyboard'
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
final form = res.parse(format.html).find('form');
final size = form.find('select[name=size]').value;   // 'm'
final ticked = form.find('input[type=checkbox]').values;  // only the checked ones
```

> `Markup.links()` returns **raw** attribute strings. To get absolute URLs, use `Reply.links()`, which resolves against the response URL.

---

## 4. It Holds a `Sequence`

Through 2.0.0 `Markup` mixed in `Iterable<Element>`, which put Dart's whole
collection vocabulary next to this library's on every selector result — and is
how `every` came to mean `Iterable.every` here. It now **holds** a
[`Sequence`](collection.md) instead of being an `Iterable`, so
the element-level work has one spelling:

```dart
final tracks = $(html).find('.track');

tracks.count;                                   // how many matched
tracks.empty;                                   // and no complement
tracks.elements.collect(.foreach((el) => print(el.attr('data-id'))));
tracks.elements.transform(.map((e) => e.text)).list;
tracks.elements.transform(.where((e) => e.classes.contains('bonus'))).collect(.count());
tracks.elements.collect(.first());                          // Element? — nullable, never throws
```

`elements` is the sequence of matched `Element`s; everything else on
`Markup` — `find`, `at`, `filter`, `children`, `texts`, `all`, `one` — is
unchanged and still returns markup-shaped answers rather than raw elements.

`each` on the `Markup` itself still gives you the element and its index:

```dart
$(html).find('.track').each((el, i) => print('$i: ${el.text}'));
```
