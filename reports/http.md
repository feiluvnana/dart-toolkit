# Report · HTTP & Networking (`lib/lib2/src/http/http.dart`)

> Companion spec: [`../proposals/03_http.md`](../proposals/03_http.md).

---

## 1. Proposal promise (03:5–96)

- `Http.get(url).text()/.json()/.html()`; `Http.post(url, body: {...})`; `resp.ok/status` (03:9–23).
- **`Resp` implements `Reader` for zero-allocation streaming** (03:29); `resp.bytes/text/json/html`
  (03:38–41).
- Streaming: `Http.get(url).pipe(File('huge.iso'))` (03:50); `.pipe(Archive.unpack(dst:))`
  (03:53).
- Advanced: Range-resume partial download (03:64–76); **zero-buffer file upload**
  `Http.post(..., body: file)` where the file is a `Reader` (03:84–87); `retry:` + `timeout:`
  auto on 5xx/network errors (03:93–95).

## 2. Current `lib2` state

`lib/lib2/src/http/http.dart` (153 lines): static `get/head/post/put/patch/delete` returning a
**buffered** `Resp{status, headers, body, url}`; `Http.download(url, Writer dst)` streams into a
`Writer`; a `_collect` reads the whole body into a `BytesBuilder`. No redirect-limit/retry logic
beyond dart:io's, no cookie jar, no proxy, no resume.

## 3. Gap analysis

| # | Proposal | `lib2` today | Severity |
|---|---|---|---|
| G1 | `Resp` implements `Reader` — zero-allocation streaming | ✗ whole body pre-collected into `Uint8List`; `.text()`/`.json()` on memory; `Resp.pipe(file)` impossible in streaming form | **BLOCKER** |
| G2 | `Http.get(url).pipe(File('…'))` | only `Http.download(url, dst)` — reverses the proposal's noun order and only works on the static; a `Resp` can't pipe | **BLOCKER** |
| G3 | `.json()` on the response | ✓ `Resp.json()` via `Json.parse` | ok |
| G4 | `.html()` on the response | ✗ missing (use from `html` module: `Html.parse(resp.text())`) | MINOR |
| G5 | `Http.post(body: {'user':…})` form-ish payload | ✗ `body` is written via `.toString()` unless `json:` is given; a map silently becomes `{user: alice}` | MAJOR |
| G6 | Stream upload of a `Reader`/`File` | ✗ payload fully materialised | **BLOCKER** |
| G7 | Range **resume** (`Range: bytes=N-`, append to existing file, `.part` files) | ✗ none | **BLOCKER** |
| G8 | `retry:` (auto on 5xx/network) + sane `timeout:` (per response/body read, default 30 s) | ✗ no retry; `timeout` applies only to `request.close()`, not the body stream | **BLOCKER** |
| G9 | `resp.ok`/`status` | ✓ | ok |
| G10 | Final `url` after redirects | ✓ (from `redirects.last`) | ok |
| G11 | Status/scope defaults (retry twice, 30 s, per-host 4) | not present; fine for the lib2 minimal surface, note as future | MINOR |
| G12 | Error table: `HttpException` family, `StatusException` for non-2xx when read | ✗ `ok` only; a non-2xx `.text()` does not throw | MAJOR |
| G13 | Cookie jar, proxy, cache | not in the lib2 proposal (legacy features) — **out of scope** | — |

## 4. Native requirements (`native2`)

HTTP transport stays on `dart:io` (not in the proposal's native list). Native2's role is the
**content decoding and the pipe sinks** that HTTP feeds:

- `Resp` body streaming decodes `gzip`/`br`/`zstd` via `tk_inflate_new/into/finish` and
  `tk_decompress` (existing exports) on a worker — so the response's `Reader` is a decoding
  pipeline, not a byte dump.
- The read-into-native sinks consume the streaming body: `Archive.unpack(dst:)` and
  `Image.decode` (`archive.md`/`image.md`).
- A native *connection pool* is intentionally **not** planned (PLAN.md declares HTTP/2 and
  autoscaled concurrency out of scope).

## 5. Actionable specification

1. **Make `Resp` a `Reader`.** `Http.get` returns the response without pre-reading; the body is an
   internal `Stream<Uint8List>` or `dart:io` response exposed through `Reader.read` (chunked via a
   `BufferReader`/frame buffer). Add `text()`/`json()`/`html()` that read the Reader once (with a
   30 s per-read budget), and expose `resp.pipe(dst)` from the core extension.
2. **Add `Http.get(url)` strict reading** on top — `await url.get()`-style semantics: `.json()`
   throws `StatusException` unless 2xx (r44: readings decide their policy).
3. **`Http.post(url, body: Reader|String|bytes, json:)`:** if `body` is a `Reader`, stream it with
   `Transfer-Encoding: chunked` / `content-length` where known — no materialisation.
4. **Range resume:** `Http.download(url, into:/to:, resume: true)` keeps the existing `.part` when
   stopped; on rerun `HEAD` for `accept-ranges`, `Range: bytes=<size>-`, append through a seek'd
   `File` (`io_fs.md` G5), verify final checksum where given, atomic rename into place.
5. **Retry/timeout:** `Http.scope(...)` minimal — reuse the CONVENTIONS table (`Retry.network`,
   30 s, 5xx + network-exception retries ×2). Cancellation drains the body so the connection
   returns to the pool.
6. **Tests** (`test/http_test.dart` for lib2): local `HttpServer` fixtures — streaming a 5 MiB
   body into a hash writer equals hashing the bytes (proves no double-buffer), resume after an
   abort, body-Reader upload received intact, 503-then-200 retry, and a gzip-encoded response
   decoding through `tk_inflate`.