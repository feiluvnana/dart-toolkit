# Report · HTML & CSS-Selectors (`lib/lib2/src/html/`)

> Companion spec: [`../proposals/05_html.md`](../proposals/05_html.md).

---

## 1. Proposal promise (05:5–120)

- `Html.parse(text)` → `Doc` with an implied `root`; `find(sel)`/`all(sel)`.
- `find('div span')`, `find('#id'), '.cls', '[attr]', '[attr="v"]', ':first'` (05:87–95), plus the
  0.0.3 additions: `select`, `findChild`, `findParent`, `child`, `text`, `attr` (`or:false`,
  r34/r35).
- Composed selector support with a **purpose-built parser and AST** rather than regex (05:74–80).
- `Html.read(path)` pairs with `parse` like `Json.read`.
- Convention pairing: `parse/all/find/select` are the data nouns (r20); text-only body handling
  has a `or:` (r33).

## 2. Current `lib2` state

`lib/lib2/src/html/` — `html.dart` (`parse(sel?)`, `find`, `all`), `dom.dart` (`Doc`, `Element`,
`TextNode`, `Tag`, `Attr`), `selector.dart` (`Selector`, `QGroup`, parser+AST) and a post-order
tree walk. Selectors handled: tag, `#id`, `.class`, `[attr]`, `[attr=v]`, `[attr^=v]`,
`[attr$=v]`, `[attr*=v]`, combinators (` `, `>`, `+`, `~`) — parsed, not regex. Pseudo-classes are
limited to `:not(...)` and `:first`.

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | `Html.read(path)` — read+parse pairing | ✗ only `parse(String)`; a file read requires manual `File.text()` + parse | MAJOR |
| G2 | `Doc.find(sel)`/`all(sel)` | ✓ | ok |
| G3 | `:first` pseudo (05:95) | ✓ (`:first` returns first match) | ok |
| G4 | `[attr="v"]`, prefix/suffix/contains | ✓ | ok |
| G5 | White-space, comment, doctype handling | ✓ (comments and doctype skipped; text normalised) | ok |
| G6 | Implied `<html>/<head>/<body>` when absent | ✗ a bare `'hello'` yields no `html` element — `find('body')` misses text-only pages | MINOR |
| G7 | Void elements self-close correctly | ✓ | ok |
| G8 | Tag-name case (HTML is case-insensitive) — `find('DIV')` | ✓ lowercased at parse | ok |
| G9 | Selector AST extensible for `:has`, `:contains`, nth-child (0.0.3 list) | ✗ `:not`/`:first` only | MINOR |
| G10 | `//fragment` or named context: `root` is the `<html>` element | ✓ picks first `<html>` | ok |
| G11 | `Element.attr(name, or:)`, per-element `text()` | ✓ `attr` w/ `or`, `text` (via `TextNode` concat) | ok |
| G12 | Sibling `+`/`~` combinator | ✓ | ok |
| G13 | Malformed but common real-world HTML (unclosed `<li>`, `<p>`, `<td>`, stray `</div>`, `<b>` inside `<a>`) | parser handles auto-closing only with heuristics; legacy `lib/src/html/` is stricter — compare test corpus | MAJOR |
| G14 | Attribute with `=` inside value or quotes | ✓ quoted parser; bare `href=a=b` unhandled | MINOR |
| G15 | Entity decode (`&amp;` inside text/attrs) | unknown — likely raw; verify | MINOR |
| G16 | selectors in `html` that feed `crawl` (02 crawler) | ✓ `all('a[href]')` | ok |

## 4. Native requirements (`native2`)

HTML stays pure-Dart (not native). The **only** native adjacency is the pipeline receiver —
`Html.parse(await page.html())` where `page.html()` comes from native `tk_cdp_html`, and
`Html.parse(resp.text())` from the HTTP Reader (`http.md` G4). No FFI needed inside `html`.

## 5. Actionable specification

1. **`Html.read(String path)`** — reads `File(path).text()`, `parse`s, returns `Doc` (mirror
   `Json.read`; errors answer the `r29` policy). Keep `parse` accepting String and Uint8List
   (utf8 fast path).
2. **Implied structure:** when no `<html>` is parsed, synthesise
   `html > head + body` wrapping stray text/whitespace — so `find('body')` works on fragments,
   matching the proposal's `find('body')` example on real pages.
3. **Robustness pass against the legacy corpus:** port `test/html_test.dart` fixture pages
   (unclosed `li/p/td`, nested `a>img`, uppercase attrs, comments-with-dashes) and fix parser
   rules until parity; keep the fragment-shape checks.
4. **Selector AST additions (0.0.3 list, optional):** `:has(...)`, `:contains('x')` (element),
   `:nth-child(n)`, `:not`-nested; each is a parser branch + one walker predicate — no regex.
5. **Entity decode:** decode named + numeric entities in `TextNode` and unquoted/quoted `Attr`
   values at parse time (single pass shares the existing char loop).
6. **Tests** (`test/html_test.dart` for lib2): the proposal 05:87–95 selector table verbatim,
   whole-document implied-`body`, `Html.read` of a fixture file, entity decode, and the malformed
   corpus parity noted above.