# formats

## Upgrading

| before | after |
|---|---|
| `decodeEntities(s)` | `s.html.text` |
| `ini['debug'].toOrNull<bool>() ?? false` | `ini['debug'].or(false)` |
| `for (final a in doc.$('a[href]')) a.attr('href')` | `doc.$('a[href]').attrs('href')` |
| `page.resolve(a.attr('href'))` / `ctx.resolve(...)` over each link | `doc.$('a').links` (List<Uri>, resolved) |
| `doc.$('main').first.markup` | `doc.$('main').markup` |
| `ul.children.where((e) => e.name == 'li' && e.classes.contains('x'))` | `ul.$('> li.x')` |
| `DateTime.parse(doc['t'].to<String>())` | `doc['t'].to<DateTime>()` |
| `File(p).writeAsString(JsonEncoder.withIndent('  ').convert(doc.raw))` | `doc.save(p)` (`.json`, `.yaml`, `.yml`) |
| `StringYamlExtensions(s).yaml` and the other five named String extensions | `StringFormatsExtensions(s).yaml` (only matters where an extension is named explicitly) |
| `JsonDocumentYamlExtensions`, `JsonTableExtensions`, `ElementTableExtensions`, `ElementsTableExtensions` | members of `JsonDocument`, `Element`, `Elements`; call sites unchanged |

## Removed

- `decodeEntities` (now private): `'Tom &amp; Jerry'.html.text` is the spelling, double-escaped API fields included.
- `_TomlParser._defined`, a set that was written to and never read.
- The six one-getter String extensions (`json`, `yaml`, `toml`, `ini`, `html`, `xml`) are one `StringFormatsExtensions`.
- `JsonDocumentYamlExtensions.toYaml`, `JsonTableExtensions.table`, `ElementTableExtensions.table` and `ElementsTableExtensions.table` are members now; `Iterable<JsonDocument>.table` stays an extension.

## Added

- `JsonDocument.or(fallback)`: `toOrNull<T>() ?? fallback`, with `T` inferred from the fallback.
- `JsonDocument.save(path)`: indented JSON or YAML by extension, creating parent directories, mirroring `read` and `Table.save`. Any other extension is a `FormatException`; nothing is written. File IO is `dart:io`, as `read` does; `fs` is not imported.
- `to<DateTime>()` / `toOrNull<DateTime>()` read ISO 8601 text.
- `Elements.attrs(name)`: the attribute on every match that has it.
- `Elements.markup`: the first match serialised, a `StateError` when nothing matched.
- `Elements.links`: each match's `href` (or `src`) as a `Uri`, resolved against `HtmlDocument.base`. A match with neither, or with a value that does not parse, is skipped; with no base a link stays as written.
- `HtmlDocument.parse(text, url:)` / `HtmlDocument(root, url:)` and `HtmlDocument.base`: the first `<base href>` in `<head>` resolved against `url`, or `url`. `res.html` now passes the response's URL (`url ?? request?.url`). The address is kept in an `Expando` on the root, so no element grows a field.
- `Element.$` and `Elements.$` take a leading combinator: `> li.x` (children), `+ dd` (the next sibling), `~ p` (later siblings), read as `:has()` reads a relative selector. When one alternative of a list starts with a combinator, every alternative is read from the element (`> a, b`: `b` is a descendant of it). A document's `$` has no element to read from, so such a selector matches nothing there.

## Faster

Back-to-back A/B, alternating order, median of 6 process runs (each the median of 7 or 41 in-process reps), JIT on macOS:

- `JsonDocument` keeps its parent and step and builds the path string only when an error is thrown. `to`/`toOrNull` return `raw` straight away when it already is a `T`. `_eachOf` no longer builds a path per element. Over 200k objects: `d['id'].to<int>()` 9.4 → 3.2 ms. `.map` on each object 32.0 → 15.9 ms. `$..id` 28.5 → 23.0 ms. Error text is unchanged, and a test pins it for key, index, quoted key, JSONPath and typed-map paths.
- XPath's document-order map leaves attributes out. An attribute sorts by its owner, and then by its slot among the owner's attributes, which is computed only for the attributes in the result. `//td/@id | //tr/@class` over 2000 rows: 15.7 → 7.4 ms. `//tr/td` never sorted and is unchanged (0.90 → 0.83, noise).
- The attribute axis with a name test is one map lookup. Over 4000 rows × 5 cells with 4 attributes each: `//*[@class]` 2.44 → 1.59 ms. `//td[@lang]` 2.92 → 2.37 ms. `//td/@lang` 3.22 → 2.58 ms.

## Verified from phases 1–2 (no change needed)

FMT-1 to FMT-14 are fixed. Beyond the phase-2 tests I checked: 20 000 fuzzed `toYaml` round-trips with 0 failures, a 100 000-deep `<span>` chain in a table cell, block keys `1.20` and `0x10` staying text, boolean-versus-node-set comparisons in both operand orders, and optgroup/option closing. The doc mismatches are fixed too: GUIDE:605 (`Elements.attr` throws), GUIDE:499 (`toYaml` round-trips), and `dom.dart`/`xml/dom.dart` (`$(r'media\:content')` works). GUIDE:605 also called `lines` a plural; it reads the first match, and the passage is corrected.

## Skipped

- None of the audit items. `JsonDocument.save` writes JSON and YAML only, because there are no TOML or INI writers (the audit only says to keep YAML writing).
- bin/ call sites (`keybox.dart:146` `song.resolve(page.$(…).attr('href'))` → `.links.first`, `books.dart:83`) are left to the integrator. They sit in lines the http agent is rewriting (`url.html()` is going away).

## CONVENTIONS

- "A conversion is the way in": add that each module puts its String conversions in one extension (`StringFormatsExtensions`). Why: six one-getter extensions were six doc pages and six names for one idea.
- "One word per idea": add a `links` row (`a link, resolved` → `links`). Why: so http's `follow`/`resolve` and any future `Nodes.links` use the same word and the same `HtmlDocument.base`.
