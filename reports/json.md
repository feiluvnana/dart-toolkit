# Report · JSON (`lib/lib2/src/json/json.dart`)

> Companion spec: [`../proposals/04_json.md`](../proposals/04_json.md).

---

## 1. Proposal promise (04:5–80)

- `Json.parse(text|bytes|file)` → typed value with **positioned errors**;
- `Json.dump(v, pretty: 2)` with `wrap:`/line trimming;
- `get(path)` dotted-path reads (`'a.b[0].c'`), typed coercions (`asInt`, `or`, `as`), and
  **writes back** `'a[2].b' = v`;
- `Json.read(path)/Json.write(path, v)` — the JSON ↔ file pairing; stream-safe partial writes;
- convenience `lines()` reading a file as typed lines (proposal frames it under fs, implemented in
  `fs/io.dart`).

## 2. Current `lib2` state

`lib/lib2/src/json/json.dart` (149 lines): `parse(String)` (buffers all), `dump(v,
{pretty: 0})` returning a String, `get(v, path)`, `JsonMap`/`JsonList` wrapper classes, and
`read/list/get/write/print/...` static file helpers. Errors are `FormatException` with a message
and index but no line/column. Files are read/written through `io.File` (`utf8.decoder` round-trip).

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | `parse(Uint8List)` (UTF-8 fast path, no decode copy) | ✗ `String` only; bytes go through `utf8.decode` before parse | MINOR (perf; native has no JSON engine — out of native scope) |
| G2 | **Positioned error** (line:col + source excerpt) | ✗ message + index only | MAJOR |
| G3 | `dump(pretty: 2)` | ✓ pretty exists; no `wrap:` (max line width break) | MINOR |
| G4 | `get('a.b[0].c')` dotted path — **read and write** | ✓ `get` exists; **write-by-path (set) is missing**; no `or`/coercion helpers on the path form | MAJOR |
| G5 | `Json.write(path)` partial-file safety (write temp, atomic rename) | ✓ uses `File.write` — but that is **not** atomic (`io_fs.md` G3/G4: no temp+rename on Windows-held targets) | MINOR now, MAJOR once atomic lands in fs |
| G6 | Strict `JsonMap`/`JsonList` decoding | ✓ wrappers; but path index access is String-typed (`'…'`) and negative/Latin-number indexes are unhandled | MINOR |
| G7 | `lines()` typed fs convenience | ✓ in `fs/io.dart` | ok |
| G8 | Duplicate keys / depth limits / cycle guard on dump | ✗ unhandled (inf recursion on cyclic maps) | MINOR |
| G9 | `null` vs missing distinction in `get` (r32 `or:`) | `or` clones default on null — loses "was it missing?" | MINOR |
| G10 | `set` safely appends arrays (`a[3]=v` beyond length) / refuses deep missing parents | ✗ write-by-path absent | MAJOR |

## 4. Native requirements (`native2`)

JSON is pure-Dart (parsing is not in the proposal's native list). Two native *adjacencies* keep
JSON pipeline-friendly:

- `Json.add(json)` feeding a `List<Object?>` (r7) — if a streaming `read` needs a one-shot
  accumulate, the native sink pattern (`write_fn`) applies only if a native consumer requests JSON
  (none does today).
- HTTP `.json()` decodes through the streaming `Resp` (`http.md` G1); `parse` of that body uses
  `utf8.decoder` — fine, no FFI.

## 5. Actionable specification

1. **Positioned errors:** `FormatException('json at $line:$col', source, offset)` with a
   `_JsonScaffold` that tracks line/col during the surrounding `dart:convert` failure — or a small
   hand-rolled recursive-descent parser for exact control (matches the codebase's "own first"
   policy; ~120 lines).
2. **`get`/`set` path engine** in `json.dart`:
   - `Object? get(dynamic v, String path)` — keep, add `(Label) $Object else`-style `or:` support
     (r43) on missing/`null`.
   - `dynamic set(dynamic v, String path, Object? value)` returning a **new** value (immutable
     maps succeed `JsonMap`; arrays clone shallowly). Creator semantics: missing parent objects
     are created as `{}`/`[]` by pointer shape; `a[-1]=x` appends; out-of-range non-`-1` → throw.
   - Keys with dots/brackets escaped `\\.`/`\\[` in the path grammar.
3. **`dump` wins:** `wrap: 80` wraps long arrays/objects onto multiple `pretty` lines —
   implement only when needed by clients; note as optional.
4. **`write(path, v)`:** delegate final placement to the fs atomic rename helper once it exists
   (`io_fs.md` §5.4) so a crash mid-write never corrupts the previous JSON.
5. **Cycle/depth guard on dump:** track ancestry; throw `FormatException` on recursive structure.
6. **Tests** (`test/json_test.dart` for lib2): path get/set including escaped keys and `-1`
   append, positioned errors reported with correct line:col, `or:` on missing and on `null`,
   round-trip dump/parse with pretty, and the fs `lines()` typed read.