# JSON (`format.json.*`, `Json`)

A read cursor over a decoded document, so nothing is cast and a path that is
not there reads empty. The HTML side of this library hands back a
`Markup` and nobody casts; this is the same idea for the other format a
script meets constantly.

`format.json` is the codec, spelled exactly like [`format.yaml`](yaml.md) and
`format.toml` — `parse`, `read`, `format`:

```dart
format.json.parse('{"a": 1}').number('a');            // 1
format.json.parse('not json').empty;                  // true — no throw
await format.json.read('config.json');                // Future<Json>
format.json.format({'a': 1});                         // indented by 2
format.json.format({'a': 1}, indent: 0);              // '{"a":1}'
```

It sits in `format` rather than `util` because a **format** is knowledge from
outside Dart — Rule 1's definition of a subject is the format or the binary,
which is the same argument that admitted `format.zip`. Putting JSON in `util` and
YAML in `format` meant a reader looking for "where do formats live" found two
places.

The `Json` *type* is exported from `util`, because it is a pure value three
domains hand back and a type `net` needs cannot live under `format`:

```dart
res.parse(format.json).at('data.items');   // a response      — see http.md
format.json.parse(text);                   // a string
await format.json.read('config.json');     // a file
await format.yaml.read('config.yaml');     // and YAML, and TOML
await req!.json();                         // a request body  — see serve.md
```

Writing a document straight to disk stays `io.dump`, which stages through a
`.part` file like every other write in this library; `format` is the string
half, for when the text is going somewhere that is not a file.

---

## Reading a document

| `Markup` (HTML) | `Json` |
| :--- | :--- |
| `q('sel')` | `j.at('a.b')` — a dotted path, `[0]` or `.0` for an index |
| `q.text` / `q.texts` | `j.text(key)` / `j.texts()` |
| — | `j.number(key)`, `j.flag(key)` |
| `q.all(sel, build)` | `j.all(build)` — one per array element |
| `q.one(sel, build)` | `j.one(build)` |
| `q.count`, `q.empty` | `j.count`, `j.empty` |
| — | `j.raw`, the decoded `Object?` underneath |
| `q.xpath(query)` | `j.jsonpath(expr)` |

```dart no-compile
final doc = format.json.parse(res.body);

doc.text('data.user.name');                    // String?
doc.number('data.total');                      // num?
doc.flag('data.active');                       // bool?
doc.at('data.tags').texts();                   // Sequence<String>

final items = doc.at('data.items').all((item) => (
  sku: item.text('sku'),
  price: item.number('price.amount'),
));                                            // Sequence<({...})>
```

Every read is nullable and nothing throws: a missing path, a field that used to
be a string and is now an object, a body that is not JSON at all — each reads
`null` or the empty cursor, because the caller asked for a value and the honest
answer is that there is not one. `text` renders a number or a boolean as text,
so a document that quotes its numbers one release and stops the next does not
break a reader.

There are no `Slot`s here. A slot exists so a *writer* and a *reader* in
different places can agree on a key; reading a document is one place.
[`io.store`](store.md) is the two-places case and keeps `Slot`.

A whole-document typed build goes through `raw`:

```dart
final config = Config.fromJson((await format.json.read('config.json')).raw);
```

---

## JSONPath

`at` walks one dotted path to one node. `jsonpath` runs a query and hands back
every match as a `Sequence<Json>` — the JSON side of `Markup.xpath`, named
after its language for the same reason:

```dart
doc.jsonpath(r'$.store.book[*].author');
doc.jsonpath(r'$..price').sift((p) => p.number());
doc.jsonpath(r'$.store.book[?(@.price < 10)]').sift((b) => b.text('title'));
```

| Form | Selects |
| :--- | :--- |
| `$` | the root; optional, so `store.book` works too |
| `.name`, `['name']`, `["name"]` | one child |
| `['a','b']` | several named children |
| `.*`, `[*]` | every child of a map or list |
| `..name`, `..*` | that name anywhere below, at any depth |
| `[0]`, `[-1]`, `[0,2]` | list positions, negative from the end |
| `[1:4]`, `[:3]`, `[::2]`, `[::-1]` | slices, with an optional step |
| `[?(@.field)]` | children that have that field |
| `[?(@.price < 10)]` | `==` `!=` `<` `<=` `>` `>=` against a literal |
| `[?(@.name =~ /^wid/)]` | a regular-expression match |

Deliberately absent: script expressions, `$` inside a filter, and arithmetic.
Each is a language rather than a query, and a filter that needs one is a `keep`
on the `Sequence` this returns. An expression the reader cannot parse selects
nothing, matching how a missing path reads.

The same cursor reads YAML and TOML — see [`format.yaml`](yaml.md).

---

## See Also

- [`format.yaml.*`](yaml.md) — the other two format codecs, spelled identically
- [`util.*`](util.md#6-sequences-sequencet) — the `Sequence` that `all`, `texts` and `jsonpath` return
- [`net.http.*`](http.md#typed-json-replyat) — `Reply.at`, the response door
- [`net.serve`](serve.md) — `Asked.json`, the request door
- [`io.store.*`](store.md) — the two-places case, which keeps `Slot`
---
