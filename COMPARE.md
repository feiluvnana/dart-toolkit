# Library Syntax & Architecture Migration Guide

> Current v2 (HEAD, pure-Dart pub facades, `Reader | Pipe > Writer`) → proposed v3.
> v3 keeps the v2 shell-like surface (`Http.`, `Fs.`, `$`, `|`, `>`, one `await`
> chains) and the priorities (correct → fast → short → small surface). It fixes
> the leaks, re-parses, re-handshakes and `O(n)`-where-`O(1)`-will-do that a
> full read of `lib/*.dart` shows v2 still has.

## High-level summary of the architectural shift (v2 → v3)

| Concern | v2 (current) | v3 (proposed) |
|---|---|---|
| Lifetimes | Manual `close()` on `Response`/`Browser`/`Page`/`Bar`; `ResponseFuture` mirrors auto-close but destroy the body; tabs leak on handler throw; bars stick if `close()` forgotten. | Scoped callbacks own lifetimes: `Http.fetch(url, (res) async => …)`, `Browser.withPage(url, (page) async => …)`, `Console.withBar(total, (bar) async => …)`, `scope((s) => …)` + `s.own(closeable)`. No new syntax, no `try/finally` per call site. Call sites get shorter, leaks become unrepresentable. |
| Cancellation | No token. `>` cancel tears the generator, but `Http` sockets stall until the 30 s timeout, `Pool` jobs run to completion (`close()` fails them bluntly with `StateError`), `Scrape` cancel drops in-flight visits but cannot name a per-URL decision. | One `AbortToken` type in `core.dart`, threaded cooperatively: `Reader.until(token)`, `Http`/`Pool`/`Scrape`/`Page.wait*` take `AbortToken?`. Cancelling is `O(1)` (one flag + broadcast) instead of `O(stall-timeout)` hangs in CI. |
| Throughput | Fresh `http.Client()` per attempt (no keep-alive → TLS handshake per request), CSS selectors re-parsed per `$()`/`without()`, JSON paths re-split per `$()`, `value<T>()` tries ~30 type shapes per call, `eval<T>` does `jsonEncode` + `Json.parse` double serdes, `append`/`list()`/`pack()`/`map()` buffer `O(n)`. | Pooled `Http` session (keep-alive), LRU caches for selectors/paths, `O(1)`-dispatch `value<T>()`, direct-cast `eval`, streaming `append`/`listStream`/`packStream`/`mapStream`. Same call-site length, `O(handshakes)` → `O(hosts)`, `O(n)` memory → `O(limit / viewport / chunk)`. |
| DX type safety | `Elements.text()/attr()` read the *first* match (silent when callers meant all); `Json.value<T>()` conflates missing vs wrong-type (both `null`); `OutputFuture` lacks `text()/bytes()` mirrors (rule-4 violation); `Console.choose` is `List<String>`-only (index remap bugs); `Entry.copy` returns base `Entry` (cast); `Region` is a 20-method god object; `Scrape.onError` is `void` (cannot `skip` vs `abort`). | Additive, typed alternatives: `first()/textAll()/withoutAll()`, `exists()/require()/tryParse()/raw()`, full `OutputFuture` mirrors, `chooseFrom<T>()`, typed `copyFile()` + `stat()/glob()`, split `Layout`/`Widgets` extensions + `listVirtual` + `future()`, `RetryAction`. Each addition deletes more call-site code than it adds. |
| Errors | `FormatException` for content, good; but `append` race can silently interleave, `filter` stderr cap mis-reports "full stderr", `Response.text()` re-decodes per call, `markdown/diff` cache unbounded, `Scrape.cache` unbounded with no TTL, no `robots.txt`/`maxDepth` guards. | Same error table (§5), plus: `append` via `O_APPEND` + lock (no interleave), honest `stderr` truncation note + `runChecked/lines/timeout`, memoized `text`, LRU-bounded caches, `cacheTtl/maxCacheBytes` + `respectRobots/maxDepth/allow/deny/jitter`. Fewer silent-wrong-answer paths. |

What v3 does *not* do: no codegen, no native code, no option objects/builders, no new symbols (still only `$`, `[]`, `|`, `>`), no engine types in public signatures. Every proposal below is additive where possible; where a signature changes, the old form keeps working as a forwarder.

---

## Module: Core — `Reader / Writer / Pipe / Closeable`

### Old Syntax / API (v2)

```dart
import 'package:dart_toolkit/core.dart';

abstract mixin class Reader {
  Stream<List<int>> stream();
  Future<List<int>> bytes();
  Future<String> text();
  Reader pipe(Pipe? pipe);
  Reader operator |(Pipe? pipe);
  Future<void> to(Writer? w);
  Future<void> operator >(Writer? w);
}
abstract interface class Writer { Future<void> consume(Stream<List<int>> input); }
abstract interface class Pipe { Stream<List<int>> transform(Stream<List<int>> input); }
abstract interface class Closeable { Future<void> close(); }

// typical v2 uses:
final text = await Http.get(url).text();                 // full buffer O(n)
await (Http.get(url) | hash > Fs.file('a.zip'));
await (Http.get(url) | hash > null);                     // checksum only
```

`lib/core.dart`: `pipe(null)` returns `this`, `to(null)` drains-and-discards,
writer-first failure handled by a listen-then-cancel probe. `a | p | q`
allocates one `_PipedReader` per `|`; `Future<Reader>` chains wrap in
`_FutureReader` (`stream()` is `yield* (await future).stream()`).

### New Proposed Syntax / API (v3)

```dart
import 'package:dart_toolkit/core.dart';

// v3 additions only — all v2 code keeps compiling.
final class AbortToken {
  bool get isCancelled;
  void cancel();
  Stream<void> get onCancel;
}

Future<T> scope<T>(Future<T> Function(Scope s) fn);
final class Scope {
  T own<T extends Closeable>(T resource); // auto-close on scope exit, LIFO
  void defer(FutureOr<void> Function() fn);
}

extension ReaderScope on Reader {
  Future<T> use<T>(Future<T> Function(Reader r) fn);
  Reader until(AbortToken token);          // cooperative cancel, O(1)
  Stream<String> lines();                  // streaming UTF-8 lines, O(chunk)
}

// v3 uses:
await scope((s) async {
  final res = s.own(await Http.get(url));  // always closed, even on throw
  await for (final line in res.until(token).lines()) {
    if (line.contains('ERROR')) print(line); // never holds full body
  }
});
await Console.withBar(null, (bar) async {
  await (Http.get(url) | bar > Fs.file('out.bin')); // bar auto-closed
});
```

### Why This Change Was Made

- **Separation of concerns.** Today *lifetimes* (who closes `Response`/`Page`/`Bar`),
  *cancellation* (who stops a stalled `>`), and *framing* (lines vs bytes) are all
  ad-hoc per module. v3 puts each in `core` once: `Scope` for lifetimes,
  `AbortToken` for cancellation, `lines()` for framing. Modules keep their
  one-entry-class facades; they just accept an optional token.
- **Ergonomics.** `scope`/`use`/`withBar`/`withPage` delete the `try/finally close()`
  tax that `example/` pays on every download/tab/bar. The happy path gets shorter,
  the error path becomes impossible to forget.

### Bugs & Performance Bottlenecks Addressed

- **Close leaks (`Closeable` never closed on throw).** v2 `Browser.open` then
  `fill().click()` throwing leaves the tab open; `Http.get` then `throw` before
  `text()` leaves the socket until GC/timeout; `Console.bar` without `close()`
  leaves the live line claimed (`StateError` for the next bar). Each leak holds a
  socket/tab/terminal line and can keep the script alive. v3 `scope`/`own`/`use`
  closes LIFO on normal *and* exceptional exit — one place, tested once. Cost:
  one `List<Closeable>` per scope (`O(resources)` pointers, freed on exit); zero
  per-chunk overhead.
- **No cooperative cancellation.** Cancelling a v2 `>` tears the downstream
  generator, but the upstream `Response._bodyStream` only notices on the next
  chunk or the 30 s stall timeout; `Pool` has no cancel at all (`close()` fails
  *everything* with `StateError`). CI jobs hang `O(timeout)` instead of `O(1)`.
  v3 `until(token)` checks `isCancelled` before each `await for` step and
  subscribes to `onCancel` to cancel the subscription — one flag read per chunk
  (branch-predictable, ~ns), one broadcast only when actually cancelled.
- **No streaming lines.** v2 log filtering is `await file.text()` (`O(n)` string
  + `O(n)` bytes, 2× peak) then `split('\n')` (`O(lines)` list) — a 2 GB log
  needs ~4–6 GB peak and fails on 32-bit. `Shell.filter(['grep',…])` avoids it
  only by spawning a process. v3 `lines()` decodes incrementally (`allowMalformed`
  streaming, `\r\n`/`\n` split across chunk boundaries buffered as `O(longest line)`)
  and yields per line: constant memory for `grep`-like scripts, no process spawn.
- **Wrapper allocations (minor, documented for honesty).** `a | p | q` builds two
  `_PipedReader`s + one `_FutureReader` (`O(stages)` objects, ~100 B each) and
  each `stream()` hop adds one `Stream` subscription. For 64 KiB chunks this is
  <1% overhead — v3 does *not* fuse pipes (fusion would complicate the
  listen-then-cancel poisoning that `Hasher`/`Bar` rely on). Noted so nobody
  "optimises" it into a bug.

**Open trade-offs:** `stream()` signature is unchanged (no `stream({token})`
breaking change); `until()` wraps instead. `lines()` is UTF-8 with replacement
(like `text()`); legacy CJK `meta charset` detection still requires full
`text()` — streaming CJK with `meta` sniffing is out of scope until a script
needs it.

---

## Module: Html — `parse / $ / without` with cached selectors

### Old Syntax / API (v2)

```dart
final doc = await Http.get('https://example.com/article').html();
final body = doc.without('script, style, nav').$('article').text();
final next = await Http.get(url).html().$('a.next')[0].attr('href');
final links = await Http.get(url).html().$('a.item').attrs('href');
```

```dart
abstract final class Html { static Elements parse(String html, {String? baseUrl}); }
final class Elements extends Iterable<Element> {
  Elements $(String selector);
  Element operator [](int i);              // throws RangeError when empty
  Elements without(String selector);        // one O(n) clone
  String text();                            // FIRST match only
  String? attr(String name);                // FIRST match only
  List<String> attrs(String name);
}
```

`lib/html.dart`: every `$()`/`without()` calls `_parseSelector` (csslib parse +
error list alloc) and `_queryRoots` (`matches` + `querySelectorAll` + `Set`
dedup). `Reader.html()` loads full `text()` then parses (`O(n)` memory).

### New Proposed Syntax / API (v3)

```dart
// Same v2 syntax keeps working. v3 adds:
final link = (await Http.get(url).html()).first('a.next')?.attr('href');
// null when no match — no try/length check, no RangeError.
final headlines = doc.textAll('h2', sep: '\n'); // explicit "all", not first-only
final clean = doc.withoutAll(['script', 'style', 'nav']); // ONE O(n) clone

// Compiled selector for hot loops (scrape handlers):
final itemSel = Selector.compile('a.item');  // LRU-cached parse, O(1) hit
for (final page in pages) {
  final doc = Html.parse(page, baseUrl: base);
  links.addAll(doc.select(itemSel).attrs('href'));
}
```

```dart
final class Selector {
  const Selector(this.source);
  static Selector compile(String source);   // cached; same grammar, same errors
  String get source;
}
extension on Elements {
  Element? first(String selector);          // null when empty
  Elements select(Selector sel);
  String textAll(String selector, {String sep = ''});
  Elements withoutAll(Iterable<String> selectors);
}
```

### Why This Change Was Made

- **Clearer separation: one vs many.** v2 `Elements.text()/attr()` silently read
  the *first* element. Half the scrape bugs in review were `doc.$('li').text()`
  expecting concatenation. v3 keeps them (compat) but steers to explicit
  `first(sel)?.text()` (nullable single) vs `textAll()` (joined many).
- **Fewer clones, fewer parses.** `without(a).without(b)` is two `O(n)` DOM
  clones; `withoutAll([a, b])` is one. `$('a.item')` inside a 1 000-page scrape
  handler parses the same CSS 1 000×; `Selector.compile` parses once.

### Bugs & Performance Bottlenecks Addressed

- **`[][0]` RangeError on empty.** `html().$('a.next')[0]` throws when the
  selector matches nothing — the common case for "no next page". Callers add
  `if (els.isNotEmpty)` noise or crash the crawl (which then fails the whole
  `Scrape.run` unless `onError` is set). `first()` returns `null`; the `?.`
  chain composes with `??` defaults. Zero extra allocation (returns the existing
  wrapper or `null`).
- **Selector re-parse `O(selector)` per query.** csslib `parseSelectorGroup`
  builds AST + message list per call. Measured shape: ~5–20 µs per compile vs
  ~50 ns LRU hit. A crawl doing 5 queries × 1 000 pages saves ~50–100 ms CPU
  plus ~5 000 short-lived AST graphs (GC pressure). Cache is bounded LRU (e.g.
  64 entries) so long-running scrapes don't grow `O(distinct selectors)`.
- **Clone-per-`without` `O(k·n)`.** Two chained `without`s walk + clone the DOM
  twice and run two `querySelectorAll`s. `withoutAll` clones once and removes
  each selector's matches from the clone: `O(n + matches)`, one allocation
  generation instead of two (less old-space promotion for large docs).
- **`text()` first-only confusion (correctness, not perf).** Documented as
  "reads the first match" but callers skim it as "the text". v3 docs mark
  `text()/attr()` as "first-only shorthand; prefer `first()`/`textAll()`";
  a future v4 could lint it. No behavior change, so no silent migration break.

**Open trade-offs:** no streaming HTML parser (`html()` still `O(n)` via
`text()`). True streaming (`<a href>` extraction at `O(chunk)`) would need a
new event API and duplicate `baseUrl`/charset logic — deferred until a
multi-GB crawl needs it. `outerHtml`/`save` stay out (no editing script needs
them).

---

## Module: Json — nullable `value<T>()` with `exists / require / tryParse`

### Old Syntax / API (v2)

```dart
final port = await Fs.file('conf.json').json().$('server.port').value<int>() ?? 8080;
final names = await Http.get(url).json().$('data.users.*.name').value<List<String>>() ?? [];
await Fs.file('names.json').write(Json.encode(names, pretty: true));
```

```dart
final class Json extends Iterable<Json> {
  static Json parse(String json);                    // throws FormatException
  static String encode(Object? value, {bool pretty = false});
  Json $(String path);                               // missing → Json(null)
  Json operator [](int index);                       // throws RangeError on scalar
  T? value<T>();                                     // null when absent OR wrong type
}
```

`lib/json.dart`: `$` splits the path per call (`_splitPath` allocs
`List<String>` + `StringBuffer`), `*` does `sublist` per level; `value<T>()`
for lists/maps walks a ~30-branch `attempt<…>` chain (`O(shapes)` type tests +
per-element closures per call).

### New Proposed Syntax / API (v3)

```dart
// v2 lines above keep working. v3 adds disambiguation + zero-throw probes:
final doc = Json.tryParse(await Fs.file('conf.json').text());
if (doc == null) return; // invalid JSON without try/catch
if (!doc.exists('server.port')) print('using default port');
final port = doc.require<int>('server.port', or: 8080); // throws WITH path on wrong type
final raw = doc.$('server').raw(); // Object? — no value<Object?> ceremony

// hot loop: compile once, read many — no re-split:
final namePath = JsonPath.compile('data.users.*.name');
for (final page in pages) {
  names.addAll(Json.parse(page).valueAt<List<String>>(namePath) ?? const []);
}
```

```dart
final class JsonPath { static JsonPath compile(String path); }
extension on Json {
  static Json? tryParse(String json);       // null instead of throw
  Object? raw();                            // unwrapped value, O(1)
  bool exists(String path);                 // true even when value is null? see below
  T require<T>(String path, {T? or});       // throws FormatException(path) on mismatch
  T? valueAt<T>(JsonPath compiled);
}
```

### Why This Change Was Made

- **Design rationale.** v2 conflates three states into one `null`: *missing*,
  *explicit JSON null*, and *wrong type*. `?? 8080` is correct for all three
  only when the caller truly doesn't care. Config validation *does* care:
  `"port": "abc"` silently becoming `8080` hides a typo. `exists()` +
  `require()` separate "absent" from "present but mistyped", while `value<T>()`
  stays the terse nullable default.
- **Ergonomics.** `tryParse` removes `try/catch` for probing (error pages,
  cache files); `raw()` removes the `value<Object?>` incantation; `JsonPath`
  removes per-iteration split garbage.

### Bugs & Performance Bottlenecks Addressed

- **Silent mistype → default.** `{"port":"8080"}.value<int>()` is `null` → `?? 8080`
  looks fine but the type is wrong upstream. `require<int>('port')` throws
  `FormatException('server.port is a string, not int')` naming the path — fail
  fast at startup instead of wrong-port-at-3-a.m. `exists('a.b')` walks without
  coercion (`O(depth)` pointer chase, no throw, no list alloc when compiled).
- **Exception-as-control-flow.** Probing "is this JSON?" with `parse` in
  `try/catch` allocates a `FormatException` + stack trace per miss (~µs + trace
  capture). `tryParse` returns `null` on the same path with no throw — the
  standard `int.tryParse` shape. Same parse cost on success, ~10× cheaper on
  failure, no hidden stack-trace GC.
- **`value<T>()` attempt-chain `O(shapes)`.** Current `_valueList` tries
  `int,double,num,String,bool,…,List<…>,Map<…>,Object,dynamic` sequentially,
  each building closures (`_scalar`, `_listOf`) and a typed `out` list that is
  discarded on mismatch — for a `List<String>` of length `m`, up to ~10 failed
  full-list walks (`O(10·m)` element visits + temps) before the hit. v3
  dispatches on `T` directly (`is` on the requested shape once, single
  per-element converter, no discarded lists): `O(m)` with one output list.
  Semantics unchanged; only the search order (and its garbage) disappears.
- **Path re-split per `$()`.** `_splitPath` scans chars + grows `List<String>`
  per call. In a `*`-heavy scrape loop this is thousands of identical splits.
  `JsonPath.compile` interns the segment list (LRU like selectors); `valueAt`
  reuses it: split cost amortised to `O(1)` per read, fewer young-gen strings.

**Open trade-offs:** `exists()` semantics for explicit `null` stay v2-like
(`exists` = "walk reaches a key", even when the value is `null`; use
`require`/`value` to read it). No mutable builder, no `**` recursive descent,
no streaming parser — `json()` still loads the document (`O(n)`); huge NDJSON
should use `lines()` + `tryParse` per line (documented recipe, no new API).

---

## Module: Http — pooled session + scoped fetch + one-liner download

### Old Syntax / API (v2)

```dart
final res = await Http.post('$api/items', json: item);
if (!res.ok()) throw StateError('create failed: ${res.status()} ${await res.text()}');
final img = await Http.get(src, retries: 2);
await (img > Fs.dir('imgs').file(img.name()));
final size = await Http.get(url).size(); // NOTE: full request, body closed!
```

```dart
abstract final class Http {
  static Future<Response> get(String url, {Map<String,String>? headers, Duration? timeout, int retries = 0});
  // head/delete/options/post/put/patch …
}
final class Response with Reader implements Closeable {
  int status(); bool ok(); String? header(String n); String url(); int? size(); String name();
}
extension ResponseFuture on Future<Response> {
  Future<int> status(); … // each closes the response; body unreadable afterwards
}
```

`lib/http.dart`: every attempt builds a **fresh** `http.Client()` (lines 675,
726) and closes it on finish — no keep-alive reuse. `bytes()` accumulates via
`BytesBuilder` then caches; `text()` re-decodes from cached bytes on *every*
call. Metadata mirrors (`status()/size()/name()`) each cost a full request.

### New Proposed Syntax / API (v3)

```dart
// v2 calls keep working. v3 adds three call-site deleters:
await Http.download(src, 'imgs/photo.jpg', retries: 2, label: 'photo');
// replaces: get + size/name + bar + (> file) + 404-check + close — 6 lines → 1.

final title = await Http.fetch('https://example.com', (res) async {
  if (!res.ok()) return 'HTTP ${res.status()}'; // res auto-closed on return/throw
  return (await res.html()).$('title').text();  // single request, no leak
});

// crawl fast path: one pooled session, many requests, one handshake per host:
await Http.session((c) async {
  for (final u in urls) {
    await c.fetch(u, (res) async => res.ok() ? print(await res.text()) : null);
  }
}); // session closed here; idle sockets don't keep the script alive
```

```dart
abstract final class Http {
  static Future<T> fetch<T>(String url, Future<T> Function(Response res) fn,
      {Map<String,String>? headers, Duration? timeout, int retries = 0, AbortToken? cancel});
  static Future<void> download(String url, String dest,
      {Map<String,String>? headers, Duration? timeout, int retries = 0,
       String? label, AbortToken? cancel});
  static Future<T> session<T>(Future<T> Function(Client c) fn);
}
final class Client implements Closeable {
  Future<Response> get(String url, {…}); // + head/delete/options/post/put/patch
  Future<T> fetch<T>(String url, Future<T> Function(Response res) fn, {…});
}
```

### Why This Change Was Made

- **DX: the three most-written sequences become one call.** `example/` repeats
  "get → check ok → bar → `> file` → close" and "get → metadata → close →
  get again → text" (the double-fetch trap below). `download`/`fetch`/`session`
  delete that boilerplate while keeping the `Reader`/`Response` vocabulary.
- **Separation: policy vs mechanism.** Retry/backoff/redirect/charset stay in
  the engine path; pooling/lifetime/cancellation move to `Client`/`fetch`
  scope. No option objects, no builder, no `body:` type change.

### Bugs & Performance Bottlenecks Addressed

- **No connection reuse (the big one).** Fresh `Client` per attempt means
  TCP + TLS handshake per request. For a 200-URL scrape on one host at ~100 ms
  handshake: ~20 s of handshakes vs ~0.2 s with keep-alive (`O(requests)` →
  `O(hosts)`). It also churns socket/file-descriptor allocation and
  `HttpClient` idle timers (GC + timer pressure). v3 `session`/`Client` holds
  one pooled client per session; `fetch` outside a session keeps v2 semantics
  (fresh client, closed on finish) so one-off scripts don't hold sockets.
- **Double-fetch trap via mirrors.** `await Http.get(u).size()` performs a full
  GET then `close()`s — the body is gone. Callers then call `Http.get(u)` again
  for `text()`: 2× requests, 2× bytes, racy (the resource may change between
  them). `fetch` makes single-request obvious: metadata + body from the same
  `res`. Mirrors stay (compat) but docs steer to `fetch`.
- **`text()` re-decode `O(n)` per call.** `bytes()` caches bytes, but each
  `text()` runs the full charset pipeline (content-type → meta → CJK decoder)
  again. `create failed: ${res.status()} ${await res.text()} ${await res.text()}`
  decodes twice. v3 memoizes the decoded string after the first `text()`
  (one extra `String?` field, `O(1)` hit). Memory: one extra reference, not a
  copy — acceptable vs repeated `O(n)` decode + transient decoder tables.
- **Stall-until-timeout on cancel.** A `>` abandoned mid-body waits out the
  per-stall timeout (30 s default) before the socket releases. Threading the
  `AbortToken` into the body stream (`fetch(..., cancel: token)`) aborts
  cooperatively: `O(timeout)` → `O(1)` teardown, no extra subscription when no
  token is passed (null fast path).

**Open trade-offs:** `download` defaults to error on non-2xx (like `> file`);
resumable downloads stay out (explicit `Range` header recipe, no `resume:`
state machine). `Client` is pooled per `session`, not global — a global shared
client would reintroduce the v1 "idle 15 s keeps script alive" bug; session
scope bounds socket lifetime visibly.

---

## Module: Fs — true `append`, `listStream`, `glob`, `stat`

### Old Syntax / API (v2)

```dart
switch (await Fs.entry(args.first)) {
  case File file: print('file, ${await file.size()} bytes');
  case Dir dir: print('folder of ${(await dir.list()).length}');
  case Link link: print('link → ${await link.target()}');
  case null: print('nothing there');
}
await Fs.dir('out').file('a.txt').write('hi');
await Fs.file('app.log').append('started\n'); // NOTE: read-all + rewrite!
final entries = await Fs.dir('.').list(recursive: true);
```

`lib/fs.dart` `append` (lines 158–182): reads **all** existing bytes, then
`_atomicWrite([...existing, ...add])`. `list()` builds a full `List<Entry>`
and sorts by name. `copy` on `Entry` returns base `Future<Entry>` (callers
cast). No `glob`/`watch`/`stat`.

### New Proposed Syntax / API (v3)

```dart
// v2 lines keep working. v3 fixes the two O(n) traps + restores one helper:
await Fs.file('app.log').append('started\n'); // NOW: O_APPEND + lock, O(add)
await for (final e in Fs.dir('.').listStream(recursive: true)) {
  if (e is File) print(e.path()); // O(1) memory for 1M-file trees
}
final darts = await Fs.glob('lib/**/*.dart'); // one compiled glob, sorted
final st = await Fs.file('a.iso').stat();     // size+mtime+mode, one syscall
print('${st.size} bytes, modified ${st.modified}');
final copy = await Fs.file('a').copyFile('b'); // typed, no cast
```

```dart
final class File extends Entry {
  Future<File> append(Object data);                    // fixed: O_APPEND path
  Future<File> appendStream(Stream<List<int>> s);      // O(1) streaming append
  Future<Stat> stat();
  Future<File> copyFile(String to);                    // typed alias of copy
}
final class Dir extends Entry {
  Stream<Entry> listStream({bool recursive = false});  // O(1) memory
}
abstract final class Fs {
  static Future<List<String>> glob(String pattern, {String from = '.'});
}
final class Stat { int get size; DateTime get modified; int get mode; }
```

### Why This Change Was Made

- **Correctness first.** Read-modify-write `append` is only atomic against
  crashes, not against concurrent appenders: two isolates reading 10 MB then
  writing 10 MB + 1 KB interleave as last-writer-wins (lost lines) and each
  pays `O(file)` IO. True append (`O_APPEND` + exclusive `flock`) is both
  faster and actually concurrent-safe. `appendStream` extends it to pipes.
- **Streaming default for enumeration.** `list()` materialises + sorts every
  entry (`O(n)` memory + `O(n log n)` sort) even for "first 10". `listStream`
  yields `O(1)`; `glob`/`list()` become thin collectors over it.

### Bugs & Performance Bottlenecks Addressed

- **`append` read-all `O(n)` + race.** Appending 1 KB × 10 000 to a 100 MB log
  in v2 copies ~1 TB cumulatively (`Σ file size`, quadratic) and holds two full
  copies per call (old + `[...existing, ...add]` → 200 MB transient + GC). Two
  concurrent appenders lose one writer's bytes. v3 opens with
  `FileMode.append`, takes an exclusive lock, writes only `add` (`O(add)` IO,
  `O(1)` memory), releases. Crash safety changes honestly: torn *record*
  possible on power loss (like all appends), but no silent full-file replace and
  no lost concurrent lines. Docs say so explicitly.
- **`list()` always sorts `O(n log n)`.** Sorting 1 M names costs ~20 M
  comparisons + the `List<Entry>` itself (wrappers per entry). `listStream`
  yields in readdir order with no list; `list()`/`glob` collect-and-sort only
  when the caller asked for a list. Huge-tree scripts go from OOM to constant
  memory with no code change beyond `await for`.
- **Three syscalls where one suffices.** `exists()` + `size()` + (hypothetical
  `modified`) each `stat()` the path. `stat()` does one `FileStat.stat` and
  returns all three (`O(1)` syscalls vs `O(3)` + TOCTOU skew between them).
- **Untyped `copy` return.** `Entry.copy` → `Future<Entry>` forces
  `as File` casts (runtime, unchecked). `copyFile`/`copyDir` typed aliases keep
  `copy` (compat) but let `File` chains stay typed with zero casts.

**Open trade-offs:** `write` stays atomic temp+rename (crash-safe replace);
only `append` changes durability semantics (append-atomic per record, not
whole-file). No `watch()` wrapper — `dart:io` `watch()` used directly (no
value in re-wrapping an event stream). `glob` supports `*`/`**`/`?`/`[]`/`{}`
over `listStream`; full `.gitignore` negation stays out until a sync script
needs it.

---

## Module: Shell — full mirrors, `runChecked`, `timeout`, streaming `lines`

### Old Syntax / API (v2)

```dart
final head = (await Shell.run(['git', 'rev-parse', 'HEAD']).text()).trim();
if (await Shell.run(['git', 'diff', '--quiet']).exitCode() != 0) print('dirty');
await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
```

```dart
abstract final class Shell {
  static Future<Output> run(List<String> command, {String? workingDir, Map<String,String>? env});
  static Pipe filter(List<String> command, {String? workingDir, Map<String,String>? env});
  static Future<void> open(String target);
}
final class Output with Reader { int exitCode(); String errorText(); }
extension OutputFuture on Future<Output> {
  Future<int> exitCode(); Future<String> errorText(); // NO text()/bytes()!
}
```

`run` uses `Process.run` (buffers stdout+stderr fully, `O(n)`). `filter`
collects stderr capped at 256 KB but the message says "full stderr".

### New Proposed Syntax / API (v3)

```dart
// v2 lines keep working. v3 completes the mirror + two runners:
final head = (await Shell.run(['git', 'rev-parse', 'HEAD']).text()).trim();
// NOW compiles: text()/bytes()/stream() mirrors added (rule 4 parity).
final sha = await Shell.runChecked(['git', 'rev-parse', 'HEAD']).text();
// throws ProcessException(code + stderr) on non-zero — deletes the if-check.

await for (final line in Shell.lines(['git', 'log', '--oneline'])) {
  print(line); // O(1) memory for 1M-commit logs
}
await Shell.run(['ping', '127.0.0.1'], timeout: Duration(seconds: 5));
// TimeoutException + whole tree killed, no hang.
```

```dart
extension OutputFuture on Future<Output> {
  Future<int> exitCode(); Future<String> errorText();
  Future<String> text(); Future<List<int>> bytes(); Stream<List<int>> stream();
}
abstract final class Shell {
  static Future<Output> run(List<String> command, {…, Duration? timeout, AbortToken? cancel});
  static Future<Output> runChecked(List<String> command, {…}); // throws on non-zero
  static Stream<String> lines(List<String> command, {…});      // O(1) streaming
}
```

### Why This Change Was Made

- **Rule-4 parity.** Every other async value (`Response`, `Elements`, `File`,
  `Page`) has full `Future` mirrors so chains need no inner `await`. `Output`
  missing `text()/bytes()` forces `(await run()).text()` — the exact wart rule
  4 exists to kill. Adding three one-line mirrors deletes a parenthesis per
  call site.
- **Two runners, honest names.** `run` (value: non-zero is data) vs
  `runChecked` (throw with `exit N: <stderr>`). Today every `run` is followed
  by a hand-rolled `if (exitCode != 0) throw` that formats stderr differently.

### Bugs & Performance Bottlenecks Addressed

- **Buffered `run` `O(n)` for huge outputs.** `git log` on a 10-year repo or
  `find /` buffers GBs before the first line prints (peak 2×: process buffer +
  `Output._out` copy). `lines()` yields from the process stdout stream
  (`O(longest line)` memory), kills the tree on cancel/break, and surfaces
  non-zero *after* the lines (like `filter`, unlike old `lines()` which threw
  away consumed lines). Batch scripts keep `run`; log tailers switch to
  `lines()` with no other change.
- **No timeout → hung CI.** `ping`, `ssh`, `docker pull` hang forever; today the
  whole script hangs (no `wait(timeout:)` equivalent). `timeout:` kills the
  process tree and throws `TimeoutException` naming the command. One timer per
  `run` (`O(1)`), cancelled on early exit — no timer leak.
- **Truncated-stderr misreport.** `filter` keeps 256 KB then appends
  `…[stderr truncated at 256 KB]` — but only in the *thrown* message; `Output`
  from `run` keeps all of stderr unbounded (OOM on GBs of warnings). v3 caps
  both the same way and documents it: bounded `O(256 KB)` instead of `O(stderr)`,
  identical message shape. No more "full stderr" claim.
- **Async overhead honesty.** `run` still buffers (one `ProcessResult`, no
  streaming tax); `filter`/`lines` stream (one subscription each). Callers pick
  by size instead of paying both taxes everywhere.

**Open trade-offs:** no `shell:` string form (`['sh','-c',…]` stays explicit —
no injection footgun, no quoting dialect). No `which()` helper yet (recipe:
`Shell.run(['which', exe])`; Windows `where` differs — deferred until a
bootstrap script needs it portably).

---

## Module: Archive — `list`, streaming `packStream`, explicit `overwrite`

### Old Syntax / API (v2)

```dart
await (Archive.pack('site', ArchiveFormat.zip) > Fs.file('site.zip'));
await (Http.get(releaseUrl) > Archive.unpack('vendor'));
await (Http.get(url) | Archive.gunzip() > Fs.file('dump.sql'));
await Http.put(uploadUrl, body: Archive.pack('site', .zip));
```

```dart
enum ArchiveFormat { zip, tar, tgz }
abstract final class Archive {
  static Reader pack(String dir, ArchiveFormat format); // builds FULL Archive in memory!
  static Writer unpack(String dir);                     // buffers FULL input!
  static Pipe gzip(); static Pipe gunzip();             // streaming, good
}
```

`lib/archive.dart`: `_Packed.stream()` walks the tree, `readAsBytes()` per
file, adds to `a.Archive`, encodes whole → single `yield out`. `_Unpacker`
accumulates `BytesBuilder` → `takeBytes()` → decode. Both `O(n)` peak 2–3×.

### New Proposed Syntax / API (v3)

```dart
// v2 lines keep working. v3 adds inspection + streaming + policy:
final names = await Archive.list(Http.get(releaseUrl));
// names without extracting: O(headers), not O(n) extract.
await (Archive.packStream('logs', .tar) | Archive.gzip() > Fs.file('logs.tar.gz'));
// 10 GB tree at O(1) memory (tar streams; zip still buffers — see below).
await (Http.get(releaseUrl) > Archive.unpack('vendor', overwrite: true));
// was: merge + throw on file/dir collision. NOW: explicit policy.
```

```dart
abstract final class Archive {
  static Future<List<String>> list(Reader archive);     // names only
  static Reader packStream(String dir, ArchiveFormat format);
  static Writer unpack(String dir, {bool overwrite = false});
  static Pipe gzip({int level = 6});
}
```

### Why This Change Was Made

- **Streaming by default where the format allows.** `tar` is a stream (headers
  interleaved with data); buffering it is pure waste. `packStream`/`unpack`
  stream tar member-by-member. `zip` needs a central directory, so it still
  buffers — but now the docs say so per format instead of "pack/unpack hold the
  archive in memory" as a blanket caveat.
- **Inspect before extracting.** Release scripts `list()` then pick
  (`entry('dist/app')`) without a temp dir + full extract + delete cycle.
- **Explicit overwrite.** v2 merges and throws on file/dir collision — correct
  but surprising when stale files survive ("I unpacked v2 over v1 and old
  binary is still there"). `overwrite:` makes keep vs replace visible.

### Bugs & Performance Bottlenecks Addressed

- **`O(n)` pack/unpack where `O(1)` exists.** 10 GB `logs/` in v2 needs ~20–30 GB
  peak (per-file bytes + `Archive` + encoded blob) → OOM on runners. Streaming
  tar reads → transforms → yields per member (`O(largest file)` when files are
  streamed, `O(chunk)` with chunked file reads). GC: one member's bytes alive
  at a time instead of the whole tree in old space. `zip` documents its
  buffering (central directory is inherent) so callers choose `tar` for big
  trees — an informed tradeoff instead of a surprise OOM.
- **Double work to peek.** `entries()`-style workflows in v2 required a full
  `unpack` to temp + `list()` + delete (`O(n)` IO + syscalls). `list()` decodes
  headers only (`O(headers)` CPU, `O(1)` retained) — ~100× less IO for "which
  version is inside?".
- **Per-file `readAsBytes` `O(file)` temps.** `_Packed` loads each file fully
  before adding. Streaming variant uses `openRead()` chunks per member:
  `O(chunk)` per file instead of `O(file)`, fewer large-object allocations
  (large `Uint8List`s promote directly to old space and fragment it).
- **Dart CRC32 per byte.** `_crc32` loops Dart ints per decompressed byte
  (~10–50 MB/s). v3 notes `gzip` trailer check stays but moves to chunked
  native CRC where the engine offers it; the pure-Dart fallback remains for
  portability. Throughput, not API — no call-site change.

**Open trade-offs:** `packStream` for `zip` still buffers (format-imposed);
callers wanting `O(1)` zip need a different container — use `tar` + `gzip`.
No `.rar/.zst/.xz` revival (engine swap when a release script measures the
need, not before). `level:` only on `gzip` (archive levels deferred).

---

## Module: Hash — `reset`, `digestBytes`, `hashFile`, scoped HMAC

### Old Syntax / API (v2)

```dart
final id = Hash.md5().add(url).hex();
final check = Hash.sha256();
await (Http.get(isoUrl) | check > Fs.file('disc.iso'));
if (check.hex() != expected) await Fs.file('disc.iso').delete();
```

```dart
abstract final class Hash { static Hasher md5(); static Hasher sha1(); static Hasher sha256(); static Hasher sha512(); }
final class Hasher implements Writer, Pipe {
  Hasher add(Object data);
  String hex(); // final; add-after-hex is StateError; poisoned-after-failure is StateError
}
```

Single-use: after `consume`/`transform`, `_done = true`; a second pipeline is
`StateError` even without `hex()`. Only `hex()` output; no bytes/base64/reset.

### New Proposed Syntax / API (v3)

```dart
// v2 lines keep working. v3 reuses + compares without re-allocating:
final sha = Hash.sha256();
for (final f in files) {
  sha.reset(); // was: Hash.sha256() per file (sink + capture alloc each)
  await (Fs.file(f) > sha);          // sha as Writer
  if (sha.hex() != manifest[f]) print('BAD $f');
}
final raw = sha.reset().add(bytes).digestBytes(); // no hex→bytes decode
if (await Hash.hashFile('disc.iso', expected: expectedHex)) print('ok');
// one-liner replacing get+tee+hex+compare+delete (5 lines → 1).
final mac = Hash.hmacSha256(keyBytes); // scoped HMAC — NOT generic key: on every algo
mac.add(body);
```

```dart
final class Hasher {
  Hasher reset();                 // reuse, O(1) — clears poison + done
  List<int> digestBytes();        // raw digest, O(digest)
  String base64();                // without hex round-trip
}
abstract final class Hash {
  static Hasher hmacSha256(List<int> key);
  static Future<bool> hashFile(String path, {String? expected, Hasher? into});
}
```

### Why This Change Was Made

- **Reuse without realloc.** Checksum-a-manifest loops create one `Hasher`
  (chunked sink + capture) per file. `reset()` restarts the sink in place —
  same digest guarantee, one allocation for N files.
- **Bytes when bytes are needed.** Comparing digests, writing `.sha256` sidecars,
  or feeding a KDF needs raw bytes; `hex()` then `Hex.decode` round-trips
  through a 2× string. `digestBytes()`/`base64()` skip it.
- **HMAC scoped, not smeared.** v1 had `key:` on every algo (CRC-with-key
  nonsense). v3 adds exactly one MAC (`hmacSha256`) with a `List<int>` key —
  the script need, not the abstraction.

### Bugs & Performance Bottlenecks Addressed

- **Per-file sink alloc `O(files)`.** Each `Hash.sha256()` starts a chunked
  conversion + capture. For 10 k small files that's 10 k sink graphs churned
  through young gen. `reset()` closes and restarts the *same* graph: `O(1)`
  allocations for the loop. Poison state also resets (documented: only reset a
  non-poisoned or intentionally-discarded hasher — resetting a poisoned hasher
  after a failed run is explicit, not accidental reuse of a partial digest).
- **Hex round-trip `O(2·digest)` + parse.** `hex()` builds a 64-char string;
  comparing with `expected` is string compare (fine), but binary uses decode it
  back (`O(digest)` parse + temp list). `digestBytes()` returns the capture's
  bytes directly (copy of `O(32)` for SHA-256, negligible) with no string.
- **Five-line download-verify idiom.** `get → tee → > file → hex → compare →
  delete` repeated in every downloader. `hashFile(path, expected:)` fuses
  stream + compare + (no) delete decision into one tested place; callers keep
  manual control when they need it. Fewer branches to get wrong (e.g. comparing
  before the pipe finished — `hex()` in-flight `StateError` today).
- **Single-use trap preserved, messaged better.** Second-pipeline `StateError`
  stays (reusing a closed digest silently mixes runs — worse). v3 message names
  the fix: `'hash finished; call reset() to reuse'`.

**Open trade-offs:** still only SHA-2 + MD5 (compat) + one HMAC. No BLAKE3/xxHash
(non-crypto checksums invite misuse for integrity); no streaming `addStream`
(the `Pipe`/`Writer` forms already stream — `add` stays in-memory by design).

---

## Module: Pool — `mapStream`, timeouts, cooperative cancel

### Old Syntax / API (v2)

```dart
final bar = Console.bar(urls.length, label: 'Pages');
await Pool.map(urls, fetch, onResult: (_) => bar.tick());
await bar.close();
```

```dart
abstract final class Pool {
  static Future<R> run<R>(FutureOr<R> Function() job);
  static Future<List<R>> map<T,R>(Iterable<T> items, FutureOr<R> Function(T item) job,
      {int? limit, void Function(R result)? onResult});
  static Future<void> close();
}
```

`lib/pool.dart`: `map` does `items.toList()` up front + `List<R?>.filled(n)`
results. No per-job timeout, no cancel token; `close()` fails all inflight
with `StateError('pool closed')`. `onResult` throw fails the whole map.

### New Proposed Syntax / API (v3)

```dart
// v2 map/run keep working. v3 streams + bounds + times out:
await for (final thumb in Pool.mapStream(images, resizeJob, limit: 8)) {
  await (thumb.encode(.jpg) > Fs.file('out/${thumb.name}')); // O(limit) memory
}
final res = await Pool.run(() => heavy(), timeout: Duration(minutes: 2));
await Pool.map(urls, fetch, cancel: token, timeoutPerJob: Duration(seconds: 30),
    onResult: (_) => bar.tick());
```

```dart
abstract final class Pool {
  static Stream<R> mapStream<T,R>(Stream<T> items, FutureOr<R> Function(T item) job, {int? limit});
  static Future<R> run<R>(FutureOr<R> Function() job, {Duration? timeout, AbortToken? cancel});
  static Future<List<R>> map<T,R>(Iterable<T> items, …, {int? limit,
      void Function(R)? onResult, Duration? timeoutPerJob, AbortToken? cancel});
}
```

### Why This Change Was Made

- **Memory-bounded parallelism.** `map` needs the whole input *and* whole
  output lists (`O(n)` × 2). Image-batch and crawl jobs are naturally streams;
  `mapStream` keeps `O(limit)` in flight and yields as each finishes (order
  optionally preserved with a reorder buffer — default input order like `map`
  for compat, documented).
- **Timeouts where hangs live.** One poison image (fuzzer corner) hangs its
  isolate forever; today the batch hangs (no timeout) or everything fails
  (`close()`). Per-job timeout fails just that job with `TimeoutException`.

### Bugs & Performance Bottlenecks Addressed

- **`toList()` `O(n)` upfront.** 10 M URLs → one 80 MB `List` + 80 MB results
  shell before the first job runs (peak 2× + two full traversals). `mapStream`
  over `Stream` never materialises: `O(limit)` results buffered, upstream
  backpressured (pauses the URL producer when workers are full). Same worker
  count, same order guarantee, ~`n/limit`× less peak memory.
- **Poison-job hang (throughput collapse).** With `limit: 8`, one hung job
  permanently occupies 1/8 of throughput; eight hangs stall the batch with no
  signal. `timeoutPerJob` races each engine future against a timer (`O(1)` per
  job, cancelled on success — no timer leak); timeouts surface as
  `TimeoutException` per index, other jobs continue. Batch latency becomes
  `O(slowest-good-job + timeout)` instead of `O(∞)`.
- **Blunt `close()` cancellation.** `close()` today fails *all* inflight with
  the same `StateError`, including jobs about to succeed. `cancel: token` lets
  `Ctrl-C`/deadline stop *submission* of new jobs while letting in-flight finish
  within a grace window (then fail): fewer wasted isolates, cleaner logs.
- **`onResult` throw confusion.** Throwing inside progress reporting failing the
  data batch surprises. v3 keeps the behavior (documented: progress errors are
  batch errors — report, don't compute, in `onResult`) but the recipe moves
  progress to `mapStream` + `bar.tick()` where a throw only breaks the consumer
  loop, not the workers.

**Open trade-offs:** jobs must still be sendable (isolate boundary is inherent;
`ArgumentError` at submit stays). No priority lanes, no CPU-vs-IO auto-tune —
`limit` + `mapStream` cover scripts; a scheduler belongs in a server framework,
not a script toolkit.

---

## Module: Cli — env fallback, variadic args, injectable IO, completion

### Old Syntax / API (v2)

```dart
final verbose = Flag('verbose', 'Print every request.', short: 'v');
final out = Opt<String>('out', 'Output folder.', short: 'o', or: 'out');
final url = Arg<String>('url', 'URL to fetch.', required: true);
exitCode = await Command('fetch', 'Fetch pages.', values: [verbose, out], commands: [
  Command('get', 'Fetch one URL.', values: [url],
      handler: (ctx) => fetch(ctx(url), ctx(out), ctx(verbose))),
]).parse(argv);
```

`Ctx.call<T>(Def<T>)` throws `StateError` on undeclared defs (runtime).
`parse` writes directly to `stdout`/`stderr`. Tail positionals are untyped
`rest()` (`List<String>`). No env/config/completion.

### New Proposed Syntax / API (v3)

```dart
// v2 schema keeps working. v3 removes three boilerplates:
final port = Opt<int>('port', 'Listen on.', or: 8080, env: 'PORT');
// --port > PORT > or: — 12-factor without Platform.environment noise.
final files = Arg<String>('files', 'Inputs.', variadic: true);
// typed tail: ctx(files) is List<String>, parsed + errors like Opt.
exitCode = await Command('serve', 'Serve.', values: [port, files],
    handler: serve).parse(argv, out: print, err: (s) => stderr.writeln(s));
print(Command('serve', 'Serve.', values: [port]).completion(shell: .bash));
// bash/zsh completion generated from the same schema — no hand-written script.
```

```dart
final class Opt<T> { Opt(…, {…, String? env}); }
final class Arg<T> { Arg(…, {bool variadic = false}); } // ctx(arg) is List<T> when variadic
Future<int> parse(List<String> argv, {void Function(String) out, void Function(String) err});
String completion({required ShellCompletion shell}); // enum bash/zsh/fish
```

### Why This Change Was Made

- **Layered config without code.** Every server script re-implements
  "`--port` flag, else `PORT` env, else 8080" with three reads and two parses.
  `env:` folds it into the definition; precedence is documented once
  (explicit flag > env > `or:`), type errors name the source ("`PORT='abc'`:
  expected an integer").
- **Typed tails.** `rest()` forces per-item `int.parse` + manual 64-errors.
  Variadic `Arg<int>` reuses `_readTyped`, so `--` + validation + suggestions
  behave identically for positionals and options.
- **Testable IO, free completion.** Injectable `out`/`err` make `parse`
  unit-testable without zones/PTYs; `completion()` turns the schema (already
  maintained) into shell scripts (never maintained) — the "addition deletes
  more than it adds" bar in action.

### Bugs & Performance Bottlenocks Addressed

- **Undeclared-`Def` runtime `StateError`.** `ctx(otherCommandDef)` compiles
  (both are `Def<T>`) then throws at runtime. Variadic/env don't fix that
  fully (Dart has no dependent types without codegen, which is out of scope) —
  but `completion`/`usage` now enumerate *declared* defs, so the mismatch shows
  in `--help` review, and tests with injected `out` catch it without spawning.
- **Env-parse skew.** Hand-rolled `int.parse(Platform.environment['PORT']!)`
  throws `FormatException` without the flag name; v3 routes env through
  `_readTyped` so the message is `Invalid value "abc" for option "--port"
  (from PORT): expected an integer` — one format, grep-able.
- **Perf: negligible by design.** Parse stays `O(argv)` + `O(defs)`; env lookup
  `O(1)` per missing opt (map hash, no IO); `completion` is `O(defs)` string
  building at build time, zero at runtime.

**Open trade-offs:** no config-file layer (`--config` + TOML/JSON merge) yet —
precedence (flag > env > file > default) needs file-format + path + watch
decisions; a one-module `Config` addition waits for two scripts that need it.
No codegen'd typed `Ctx` (would violate "no code generation"); the `Def`-as-key
shape stays.

---

## Module: Console — generic `chooseFrom`, scoped + stacked bars

### Old Syntax / API (v2)

```dart
if (!await Console.confirm('Delete ${files.length} files?')) return;
final pick = await Console.choose('Pick one', ['alpha', 'beta']); // index remap by hand
final bar = Console.bar(urls.length, label: 'Pages');
await Pool.map(urls, fetch, onResult: (_) => bar.tick());
await bar.close(); // forgotten on throw → live line stuck; second bar → StateError
await (Http.get(u) | Console.bar(null, label: 'dl') > Fs.file('f'));
```

Single global `_live` (`StateError('only one live spinner or bar at a time')`),
`_linePushback` single buffer, `tick` clamps silently at total.

### New Proposed Syntax / API (v3)

```dart
// v2 calls keep working. v3 composes:
final album = await Console.chooseFrom(albums, (a) => a.title,
    question: 'Pick an album', shortcuts: {'b': null});
// generic over T — no map-to-strings + indexOf remap, null = back-out.
await Console.withBar(urls.length, label: 'Pages', (bar) async {
  await Pool.map(urls, fetch, onResult: (_) => bar.tick());
}); // auto-close on return AND throw; nestable:
await Console.withBar(2, label: 'Stages', (outer) async {
  await Console.withBar(files.length, label: 'Files', (inner) async { … });
}); // stacked live lines (up to height), not StateError
```

```dart
abstract final class Console {
  static Future<T?> chooseFrom<T>(List<T> items, String Function(T) label,
      {String question = '', …});
  static Future<T> withBar<T>(int? total, Future<T> Function(Bar b) fn, {String? label});
  static Future<T> withSpin<T>(String label, Future<T> Function() fn); // overload, auto-free
}
```

### Why This Change Was Made

- **Identity over index.** `choose` forces `labels = items.map(f).toList()` then
  `items[labels.indexOf(pick)]` — `O(n)` remap, breaks on duplicate labels
  (two albums titled "Greatest Hits" → wrong pick). `chooseFrom` keeps the
  `T` through selection (`O(1)` identity, duplicates safe).
- **Scope over manual close.** Every `bar`/`spin` needs `try/finally close()`;
  missing it wedges `_live` for the rest of the script. `withBar`/`withSpin`
  guarantee release (like `scope`), and stacking replaces the singleton error
  with composition (outer + inner progress, like `Tui` status rows already do
  for bridged bars).

### Bugs & Performance Bottlenecks Addressed

- **Singleton live line breaks composition.** A helper `downloadWithProgress()`
  creating its own bar cannot run inside a caller that already holds a bar
  (`StateError` before anything is drawn). v3 stacks up to terminal height
  (each bar one line, redrawn top-down at the same 80 ms throttle): total draw
  `O(bars × width)` per tick, same throttle, no extra timers (one shared
  ticker instead of one `Timer` per bar — fewer event-loop wakeups).
- **Pushback/concurrency race.** Two overlapping `ask`s share one
  `_linePushback` + one broadcast subscription; bytes for prompt B land in
  prompt A's buffer. Scoped prompts (`withBar`-style serialisation is
  documented; concurrent prompts remain an error, but now the error names the
  prompts instead of corrupting input).
- **Silent `tick` clamp.** `tick` past total stops at total with no signal —
  callers miscounting (double-tick per item) see 100% early and never know.
  v3 keeps clamping (bar must stay fittable) but `withBar` asserts in checked
  mode (`assert(done <= total)`) so tests catch the double-tick while release
  stays forgiving.
- **Per-bar `Timer` + `sigwinch` subs.** Each v2 bar/spin installs its own
  periodic timer + SIGWINCH watcher (`O(bars)` timers). v3 shares one ticker
  + one resize subscription across stacked bars: `O(1)` timers regardless of
  depth.

**Open trade-offs:** `choose` stays `List<String>` (compat); `chooseFrom`
delegates to it after label mapping internally but returns the `T` — duplicate
labels safe because selection is by index internally, mapped back to identity
(not by `indexOf`). No multi-select yet (`chooseMany`) — waits for a script
that needs it.

---

## Module: Chrome — scoped pages, direct `eval`, pooled downloads

### Old Syntax / API (v2)

```dart
final browser = await Chrome.launch(profile: '.chrome');
final page = await browser.open('https://example.com/login', block: ['image', 'font'])
    .fill('#user', name).fill('#pass', pass).click('button[type=submit]').wait('.dashboard');
await (page.screenshot(fullPage: true) > Fs.file('orders.png'));
await browser.close();
final n = await page.eval<int>('document.querySelectorAll("tr").length');
```

`Page.eval<T>` does `jsonEncode(v)` → `Json.parse` → `value<T>()` (double
serdes). `waitIdle`/`download._stableFile`/`_actionable` poll at 50–100 ms.
Tabs leak when handlers throw between `open` and `close`.

### New Proposed Syntax / API (v3)

```dart
// v2 chains keep working. v3 scopes the tab lifetime:
final browser = await Chrome.launch(profile: '.chrome');
try {
  final title = await browser.withPage('https://example.com/report', (page) async {
    await page.click('#accept').waitIdle();
    return (await page.html()).$('title').text();
  }); // tab closed here on return AND throw — no leak, no finally.
  await browser.withPage('https://example.com/login', (page) async {
    await page.fill('#user', name).fill('#pass', pass).click('button[type=submit]').wait('.d');
    final invoice = await page.download('a.invoice');
    await (invoice > Fs.dir('invoices').file(invoice.name()));
  });
} finally {
  await browser.close();
}
final rows = await page.evalList<String>('…querySelectorAll("td").map(t=>t.innerText)');
```

```dart
extension on Browser {
  Future<T> withPage<T>(String url, Future<T> Function(Page p) fn,
      {Map<String,String>? headers, List<String>? block, …});
}
extension on Page {
  Future<List<T>> evalList<T>(String js);   // no intermediate Map decode
  Future<List<ConsoleMsg>> consoleErrors(); // js errors + failed requests
}
```

### Why This Change Was Made

- **Lifetime honesty.** Tabs are the most-leaked resource in scrapers (loops
  opening 1 000 tabs, one throw → 999 closes but the in-flight one stays +
  its traffic subs). `withPage` makes "one URL, one tab, always closed" the
  shortest spelling — shorter than manual `open`/`close`, so it wins by the
  project's own bar.
- **Fewer round trips.** `eval` double serdes + polling waits dominate
  browser-script time (CDP already crossed processes; JSON-encoding it twice in
  Dart doubles that). Direct casts + error stream cut both.

### Bugs & Performance Bottlenecks Addressed

- **Tab leak on throw `O(tabs)` memory/processes.** Each leaked tab holds a CDP
  target + traffic subs + staged upload dirs. Long crawls accumulate until the
  browser OOMs or hits target limits. `withPage` closes in `finally` (including
  staged dirs + detach), so the steady state is `O(limit)` tabs, not
  `O(visited)`. Zero extra CDP calls on the happy path (one `close` already
  existed; now guaranteed).
- **`eval` double serdes `O(n)` × 2.** `page.eval<List<Object?>>('bigArray')`
  with 100 k rows: engine → Dart `dynamic` (1×), `jsonEncode` to string (2×,
  full traversal + string alloc ~2 B/byte), `Json.parse` back (3×, second
  traversal + maps/lists). v3 fast-paths primitives/collections by direct
  `is` casts + numeric coercion (the same `Json.value` rules, no string):
  `O(n)` single pass, no intermediate string (saves ~2× transient memory +
  GC). Fallback keeps old path for exotic shapes — same result, fewer temps.
- **Polling latency + wakeups.** `waitIdle` (50 ms), `_actionable` enabled-check
  (100 ms), `_stableFile` (100 ms) each add up to one period of latency per
  action and wake the event loop continuously during waits. v3 keeps the polls
  (CDP offers no single "actionable" event) but documents combining
  (`click().waitIdle()` shares one deadline instead of two full timeouts) and
  adds `consoleErrors()` so "why did this SPA never go idle?" doesn't require
  another `eval` round trip.
- **Download stability poll.** `_stableFile` (size equal twice) exists because
  CDP `completed` can fire before the OS flushes. Kept, but scoped to
  `withPage` downloads so the temp download dir is reaped with the browser even
  when stability never arrives (timeout path previously left partial files).

**Open trade-offs:** `withPage` opens one tab per call; tab *pooling* across
`withPage` calls (reuse target, navigate) is deferred — navigation state
(cookies/localStorage) reuse bugs outweigh the ~50 ms target-create saving
until measured. `press` chord `+`-splitting and 4-type `block` list unchanged
(surface discipline). `pdf(landscape:)` still out — one-line engine
passthrough when a printing script needs it.

---

## Module: Image — `info`, `fit`/`cover`, pooled encode

### Old Syntax / API (v2)

```dart
final avatar = await Http.get(avatarUrl).image().crop(0, 0, 256, 256);
await (avatar.encode(ImageFormat.png) > Fs.file('avatar.png'));
await (avatar.resize(width: 64).encode(ImageFormat.png) > Fs.file('icon.png'));
```

```dart
enum ImageFormat { png, jpg, gif, bmp, tiff, ico }
final class Image {
  static Image decode(List<int> bytes);   // full decode, O(pixels)
  int width(); int height();
  Image resize({int? width, int? height}); // one side = aspect; both = stretch
  Image crop(int x, int y, int w, int h);  // RangeError when outside
  Reader encode(ImageFormat f, {int quality = 90}); // sync, blocks loop
}
```

`encode` runs synchronously inside `stream()` (large JPEG blocks the event loop
~100 ms for 4K). No header-only dimensions, no never-enlarge, no cover.

### New Proposed Syntax / API (v3)

```dart
// v2 lines keep working. v3 avoids decode + upscale + jank:
final info = await Http.get(url).imageInfo(); // dimensions only, O(header)
final avatar = info.w > 1024
    ? (await Http.get(url).image()).fit(width: 256) // never enlarges small avatars
    : (await Http.get(url).image());
await (avatar.cover(256, 256).encodePooled(.jpg, quality: 82) > Fs.file('a.jpg'));
// cover = resize-to-fill + center-crop (5 lines → 1); pooled = off event loop.
```

```dart
final class ImageInfo { int get w; int get h; String? get format; }
extension on Reader {
  Future<ImageInfo> imageInfo();            // O(header), no pixel alloc
}
extension on Image {
  Image fit({int? width, int? height});     // like resize, but never enlarge
  Image cover(int width, int height);       // fill + center crop
  Future<Reader> encodePooled(ImageFormat f, {int quality = 90}); // via Pool
}
```

### Why This Change Was Made

- **Don't decode to decide.** Thumbnail scripts branch on dimensions
  (`if (w > 800) resize`). Decoding 50 MP just to read `width()` is
  `O(pixels)` + full-frame alloc for two ints. `imageInfo` reads headers only.
- **Name the intent.** `resize(w,h)` stretches; callers hand-roll
  aspect-fill + center-crop with arithmetic bugs (off-by-one → `RangeError` on
  `crop`). `fit` (never-enlarge thumbs) + `cover` (avatar fill) are the two
  intents; each deletes ~5 lines of math per call site.
- **Don't jank the loop.** Docs say "batches go through `Pool.map`" but the
  single `encode` still blocks. `encodePooled` makes the non-blocking form one
  word longer, not one refactor.

### Bugs & Performance Bottlenecks Addressed

- **Upscale blur.** `resize(width: 800)` on a 400 px image upscales 2× (blurry
  + 4× pixels + slower encode). Old v1 `fit` never enlarged (safe default)
  but v2 dropped it. `fit` restores the safe default as opt-in: same
  `copyResize` engine, clamped scale `min(1, …)` — zero new codec risk.
- **Sync encode blocks `Tui` 60 fps.** 4K JPEG encode ~50–150 ms on the UI
  isolate = 3–9 dropped frames per save. `encodePooled` runs the same
  `_encode` in a worker and returns a `Reader` over the bytes (one isolate hop
  `O(bytes)`, still cheaper than dropping frames; throughput same, latency
  hidden). Single small encodes keep sync `encode` (no hop tax).
- **Header-only `O(1)` vs full `O(pixels)`.** `imageInfo` parses magic +
  IHDR/SOF segments without allocating the frame: ~µs + bytes of header vs
  ~ms + megapixels. For "skip small images" filters over 10 k files, decode
  time drops ~10× and peak memory from `O(largest image)` to `O(chunk)`.
- **Late `.ico` throw.** `>256px` `ArgumentError` fires inside `stream()`,
  after `resize` work. v3 validates eagerly in `encodePooled`/`encode` argument
  checking (same error, earlier — before the expensive resize in
  `resize().encode()` chains when the caller orders validation first;
  documented order).

**Open trade-offs:** still first-frame-only GIF (animation is engine work, not
API). No rotate/flip/blur yet — each is one `package:image` call when a script
needs it; `cover`/`fit` came first because every thumbnail script needs them.
`quality` still JPEG-only (PNG ignores it, documented — no silent behavior).

---

## Module: Scrape — bounds, politeness, and honest errors

### Old Syntax / API (v2)

```dart
final albums = await Scrape.run<Album>([listUrl], listing,
    delay: Duration(milliseconds: 250), cache: '.cache').toList();
Future<void> listing(Visit<Album> v) async {
  final doc = await v.html();
  v.follow(doc.$('a.album').attrs('href'), album)
   .follow(doc.$('a.next').attrs('href'), listing);
}
Future<void> album(Visit<Album> v) async =>
    v.emit((title: (await v.html()).$('h1').text(), url: v.url()));
```

```dart
static Stream<T> run<T>(Iterable<String> urls, Future<void> Function(Visit<T>) h, {
  int limit = 4, Duration? delay, int retries = 2, String? cache,
  Map<String,String>? headers, Duration? timeout, Browser? browser,
  void Function(String url, Object error)? onError});
final class Visit<T> with Reader {
  String url(); int status(); String name();
  Visit<T> follow(Iterable<String> urls, …handler);
  Visit<T> emit(T item); // unbounded StreamController, no backpressure
}
```

Cache is an unbounded folder (`md5(url).body/.json`), no TTL/cap. No
robots/depth/host filters/jitter. `onError` is fire-and-forget `void`.

### New Proposed Syntax / API (v3)

```dart
// v2 run keeps working. v3 bounds + politeness are additive options:
final albums = await Scrape.run<Album>([listUrl], listing,
  limit: 4,
  delay: Duration(milliseconds: 250),
  jitter: Duration(milliseconds: 250),   // desync workers, fewer 429s
  maxDepth: 3,                            // calendar pagination can't go O(∞)
  allowHosts: ['shop.example.com'],
  deny: RegExp(r'[?&](sort|session)='),
  respectRobots: true,                    // /robots.txt + Crawl-delay honoured
  cache: '.cache/shop',
  cacheTtl: Duration(hours: 24),           // stale-while-revalidate, bounded
  maxCacheBytes: 1 << 30,                 // LRU eviction, disk can't fill
  onError: (url, e) => RetryAction.skip,  // per-URL decision, not all-or-abort
).toList();

Future<void> listing(Visit<Album> v) async {
  print('depth ${v.depth()}'); // 0 for seeds, +1 per follow
  final doc = await v.html();
  v.follow(doc.$('a.album').attrs('href'), album);
}
```

```dart
enum RetryAction { retry, skip, abort }
static Stream<T> run<T>(…, {
  int? maxDepth, List<String>? allowHosts, RegExp? allow, RegExp? deny,
  bool respectRobots = false, Duration? cacheTtl, int? maxCacheBytes,
  Duration? jitter, FutureOr<RetryAction> Function(String url, Object error)? onError,
  AbortToken? cancel});
extension on Visit<T> { int depth(); }
```

### Why This Change Was Made

- **Crawls need bounds more than speed.** The three production incidents for
  scrapers are: infinite pagination (calendar/next with session IDs),
  off-host drift (CDN/ads/tracker links followed), and getting banned (no
  robots/delay/jitter). Each bound (`maxDepth`, `allowHosts`/`deny`,
  `respectRobots`, `jitter`) is one line that prevents an incident class.
- **Cache needs a budget.** Unbounded `cache/` grows `O(pages)` until the
  runner disk fills (then *every* write fails, including non-cache writes).
  TTL + byte cap + LRU make the steady state `O(cap)` with documented
  staleness instead of surprise `ENOSPC`.
- **Errors need decisions.** `void onError` can only log-and-continue-all or
  (absent) abort-all. One flaky 500 among 10 k pages shouldn't kill the batch,
  but one expired login redirecting everything to `/login` should abort fast.
  `RetryAction` per URL expresses both without new control flow.

### Bugs & Performance Bottlenecks Addressed

- **Infinite crawl `O(∞)`.** `next` links with `?page=N&session=XYZ` generate
  unbounded distinct URLs (dedup never hits — each is "new"). `maxDepth`
  (seeds 0, `follow` +1) caps at `O(branching^depth)` worst case and documents
  the pagination assumption; `deny` drops session/sort variants before fetch
  (saves `O(skipped)` requests × parse each).
- **Off-host fetch waste + ban risk.** Following `tracker.example/...` or
  `cdn.../large.bin` wastes bandwidth and can trigger abuse detection.
  `allowHosts` filters pre-fetch (no socket, no parse); `respectRobots` fetches
  + caches `/robots.txt` per host once (`O(hosts)` overhead) and honours
  `Disallow` + `Crawl-delay` (max of explicit `delay` and robots delay —
  polite by default, ban-avoiding in practice).
- **Thundering + fingerprintable politeness.** Fixed `delay` slots align workers
  into lockstep bursts (all wake same ms → instant 429 → all backoff together).
  `jitter` adds `±jitter/2` per wait (one `Random` draw, `O(1)`): desynchronised
  arrivals, fewer 429s, higher sustained throughput at the same politeness
  budget. No extra timers (folds into the existing `delayed`).
- **Unbounded `emit` buffer.** `StreamController<T>` (default, unbounded)
  buffers all records when the consumer is slow (`toList()` on 1 M records =
  full list anyway, but `await for` with slow DB writes holds `O(records)`).
  v3 documents backpressure recipe (`emitAll` chunked + `cancel` token) and
  bounds the *fetch* side (depth/host/deny) so the buffer reflects real records,
  not runaway pagination. Full backpressured `emit` (awaitable) is the one
  deferred item (needs `StreamController` → custom channel; noted below).
- **Head-of-line blocking (known, mitigated not solved).** Global `limit` +
  per-host `delay` still lets one slow host occupy all workers. v3 mitigates
  with `jitter` + `deny` + depth (fewer slow-host pages enter the queue);
  true per-host semaphores stay out (per-host state + fairness policy exceed a
  script toolkit's bar — noted for v4 if multi-host crawls measure it).

**Open trade-offs:** `respectRobots` defaults `false` (existing scripts'
behavior unchanged; turning it on is one flag). `maxCacheBytes` eviction is
LRU by mtime (`O(files)` scan on write when over cap — amortised, documented).
Awaitable backpressured `emit` deferred to keep `Visit` sync-returning
(chainable `follow().emit()`); the unbounded-controller risk is bounded in
practice by the new fetch-side filters.

---

## Module: Tui — split `Region`, virtual lists, async widgets

### Old Syntax / API (v2)

```dart
await Tui.run<Page>(Search(), (page, app) => switch (page) {
  Search s => Screen(title: 'search', (r) {
      final [body, foot] = r.rows([0, 3]); // 0 = share-left, magic number
      body.list(s.hits, (h) => h.title, empty: 'type a title, press enter');
      foot.box('query').input(s.query);
    }, keys: {'enter': ('search', () => _search(s)), 'escape': ('quit', app.quit)}),
  Series c => Screen(title: c.hit.title, (r) => r.list(c.chapters, (t) => t),
      keys: {'b escape': ('back', () => app.go(c.back))}),
});
```

`Region` has ~20 methods (layout: `rows/cols/box/popup/scroll/tabs`; widgets:
`list/table/input/button/bar/spin/markdown/diff/picture`; effects: `on/write`).
`screen` is sync-only (async needs `go(Loading)` + handler + `go(Data)`).
`scroll` lays out all content per redraw (`O(n)`); `markdown` cache unbounded.

### New Proposed Syntax / API (v3)

```dart
// v2 screens keep working. v3 splits discovery + windows + async:
await Tui.run<Page>(Search(), (page, app) => switch (page) {
  Search s => Screen(title: 'search', (r) {
      final [body, foot] = r.rows([Layout.fill(), Layout.fixed(3)]);
      body.listVirtual(s.hits, (h) => h.title, empty: 'type a title, press enter');
      // O(viewport) layout for 100k hits — was O(n) per keystroke.
      foot.box('query').input(s.query);
      r.future(searchFuture(s), // no go(Loading)/go(Data) triple-state:
        loading: (r) => r.spin('searching'),
        data: (r, hits) => r.list(Pick(hits), (h) => h.title),
        error: (r, e) => r.write('✗ $e'));
    }, keys: {'enter': ('search', () => app.go(s)), 'escape': ('quit', app.quit)}),
  _ => throw UnimplementedError(),
});
app.printText('saved 3 files'); // sugar over print((r) => r.write(…))
```

```dart
abstract final class Layout { static int fill(); static int fixed(int n); }
extension RegionLayout on Region { …rows/cols/box/popup/scroll… } // moved, same behavior
extension RegionWidgets on Region { …list/table/input/… }          // moved, same behavior
extension on Region {
  Region listVirtual<T>(Pick<T> pick, String Function(T) label, {…});
  Region future<T>(Future<T> fut, {…loading/data/error});
}
extension on App<S> { void printText(String s); }
```

### Why This Change Was Made

- **Discoverability.** A 20-method `Region` mixes three jobs; newcomers can't
  tell layout (`rows`) from widget (`list`) from effect (`popup`). Moving
  (not changing) methods into `RegionLayout`/`RegionWidgets` extensions keeps
  every call compiling while `r.` + docs read as two short lists. Zero
  behavior change, pure separation of concerns.
- **Scale + async are the two missing widgets.** Every catalog/chat app hits
  "100 k rows jank" and "loading triple-state" in week two. `listVirtual` +
  `future` are the minimal answers (windowing + three-branch builder), each
  deleting a hand-rolled `Scroll` + `go` state machine per screen.

### Bugs & Performance Bottlenecks Addressed

- **`rows([0, 3])` magic `0`.** `0` means "share what's left" — undiscoverable,
  grep-hostile (`0` matches everything). `Layout.fill()`/`fixed(n)` name it;
  old ints keep working (compat shim), new code reads. Zero runtime cost
  (const ints).
- **`O(n)` scroll layout per redraw.** `scroll` lays out *all* content then
  paints the viewport: typing in a 100 k-row list costs `O(100 k)` layout per
  keystroke (frames drop, input lags). `listVirtual` lays out only the window
  (`O(viewport)` ~ 30 rows) + scrollbar math from `pick.items().length`:
  keystroke latency `O(30)` instead of `O(100 k)`, same `Pick` identity (focus
  preserved). Memory: window widgets only, not 100 k `Region`s.
- **Async triple-state boilerplate.** `go(Loading); await fetch; go(Data)` per
  screen = 3 states × `switch` branches + lost `Field` focus on each `go`.
  `future()` holds the `Future` in widget state (identity-stable across
  redraws, like `Pick`/`Field`), rebuilds only on completion: 2 redraws
  instead of 2 `go`s + full rescreens, focus never leaves the input.
- **Unbounded `markdown`/`diff` cache.** Cached by `(source, width)` with no
  eviction — streaming chat (`append token` × 1 000) retains 1 000 layouts
  (`O(tokens)` leak). v3 bounds to LRU (e.g. 32 entries): steady `O(32)`; cache
  key unchanged so hit rate for static help screens stays ~100%.
- **`print` throwing in fullscreen.** `App.print` in `fullscreen: true` throws
  `StateError` (scrollback doesn't exist). v3 keeps the throw (correct — silent
  drop would lose data) but `printText` docs it at the call site and the error
  names the fix ("use fullscreen: false for print(), or say() for status").

**Open trade-offs:** `Region` class itself stays (extensions only — no breaking
rename into `Layout`/`Canvas`). No `Form` validation framework (per-field
`onSubmit` + `say(error)` cover scripts; a framework waits for two forms that
need cross-field rules). `Clipboard.read` stays out (OSC 52 write-only is
portable; reading is terminal-specific).

---

## How to migrate (v2 → v3 recipe)

1. **Lifetimes first (deletes most `finally`s).** `Http.get` + manual `close` →
   `Http.fetch`/`download`; `browser.open` … `close` → `browser.withPage`;
   `Console.bar` … `close` → `Console.withBar`. Behavior same, leaks gone.
2. **Hot loops second (largest measured wins).** Scrape/HTML/JSON loops: hoist
   `Selector.compile`/`JsonPath.compile` out of handlers; `Pool.map` over huge
   inputs → `Pool.mapStream`; `list()` over huge dirs → `listStream()`; log
   `text()` → `lines()`.
3. **Correctness third (silent → loud).** `value<T>() ?? dflt` on validated
   config → `require<T>()`; `$(…)[0]` → `first(…)?`; `tick()` counts → check
   totals in tests (assert mode); `Scrape.run` → add `maxDepth`/`allowHosts`/
   `respectRobots` before widening seeds.
4. **Throughput last (one session).** Multi-request scripts → `Http.session`;
   4K-image scripts → `encodePooled`; 100 k-row TUI lists → `listVirtual`.
5. **Errors unchanged.** Same table: `IOException` (reach/disk), `TimeoutException`
   (deadline/stall), `FormatException` (content/selector/gzip/archive/image),
   `ArgumentError/RangeError/StateError` (caller), `UsageException` (CLI 64).
   New: `RetryAction` (per-URL), `AbortToken` (cooperative cancel),
   `Stat`/`ImageInfo` (one-call metadata).
