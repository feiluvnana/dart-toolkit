# Proposal: a dependency-free toolkit, Rust where it pays, and a flatter tree

Three questions, answered with measurements from this machine (Dart 3.13.2, macOS arm64; a bare
`dart run` script starts in about 340 ms and drifts ±80):

1. Can the remaining third-party packages — `archive`, `xml`, `http`, `path`, `crypto` — be
   replaced in-house the way `html` was, and is it worth it?
2. Where is Dart genuinely too slow, and would Rust fix it?
3. What should `lib/` look like so that imports are short and exports are not a puzzle?

**Recommendation in one paragraph.** Replace `archive`, `xml` and `http` in that order; each
costs 240–480 ms of startup for every program that imports its module, and each replacement is
about the size of the HTML parser. Leave `path` and `crypto` alone: their startup cost is inside
the noise. Do not add Rust now. The only CPU-bound hot spot Dart loses badly is hashing (168 MB/s
against 2.0–2.3 GB/s native), and it can be made native without a Rust toolchain on every user's
machine — see §3. Flatten `lib/` to one file per module and make each module a single library, so
nothing in `src/` ever needs an `export … show` list.

---

## 1. What each dependency costs

Startup, three rounds, one package imported by an otherwise empty script (delta over bare):

| package | +ms over bare | what the toolkit uses from it |
|---|---|---|
| `archive` | +330 (+316 / +260 / +415) | zip encode and decode, deflate |
| `xml` parser only | +340 (+337 / +311 / +370) | `XmlDocument.parse` |
| `xml` + `xpath` | +480 (+446 / +492 / +507) | `$` |
| `http` | +240 (+219 / +247 / +252) | `Client`, `Request`, `Response`, `StreamedResponse`, `MockClient` in tests |
| `dart:io` `HttpClient` | ≈0 (+17 / +5 / +17) | what `package:http` wraps |
| `path` | +80 (+76 / +36 / +137) | 12 functions at 21 call sites |
| `crypto` | +50 (+32 / +14 / +107) | SHA-256, MD5 |
| `dart:io` `ZLibEncoder` | +40 (+43 / +13 / +80) | native deflate, already in the SDK |

Per module today, from `tool/startup.dart`: `archive` +413, `xml` +693, `http` +291, `html`
+250 (all of it `http`), `hash` +153 and `fs` +152 (the shared `path`), `process` +125.

Runtime, CPU-bound work on 128 MB of text-like data:

| operation | pure Dart | native | ratio |
|---|---|---|---|
| SHA-256 | 168 MB/s (`package:crypto`) | 2 031–2 337 MB/s (OpenSSL 3.6) | 12–14× |
| MD5 | 271 MB/s | — | — |
| deflate, level 6 | 27 MB/s (`package:archive`) | 81 MB/s (`dart:io` zlib) | 3× |
| inflate | 103 MB/s (`package:archive`) | 372 MB/s (`dart:io` zlib) | 3.6× |
| zip a 32 MB directory | 60 MB/s (`package:archive`, file API) | 54 MB/s (system `zip`) | 1× |

Two things fall out. `package:archive`'s file API already leans on `dart:io`'s native zlib, so
replacing it wins startup, not throughput. And hashing is the one place where pure Dart is an
order of magnitude behind, because the SDK ships no native digest.

---

## 2. Module by module

### 2.1 `archive` — replace; +330 ms back, same speed, ~450 lines

Zip is a container format: local file headers, deflate or stored data, a central directory, an
end record; ZIP64 for entries or archives over 4 GB. The compression itself is
`ZLibEncoder(raw: true)` / `ZLibDecoder(raw: true)` from `dart:io` — native, streaming, and
3× faster than the pure-Dart deflate `package:archive` uses when it is not going through a file.
CRC-32 is a 256-entry table and a loop.

What to write: a `ZipWriter` that streams entries to an `IOSink` (`zipTo`, `zipToSync`), a
`ZipReader` that reads the central directory from the end of the file and inflates entries on
demand (`extractTo`, `extractToSync`, plus a lazy `entries` listing the current API lacks), the
path-traversal check that already exists, and ZIP64. Not written: tar, gzip files (already
`GZipCodec` in `dart:io`), bzip2, encryption, split archives.

Check: round-trip against `package:archive` and against the system `zip`/`unzip` on the same
fixtures, in a differential test as `html` has, with the reference kept as a dev dependency.

### 2.2 `xml` — replace; +480 ms back for a scraper that uses `$`, ~900 lines

The HTML work is the template. An XML tokenizer is simpler than the HTML one — no implicit
closes, no void elements, no raw-text modes — plus namespaces, `CDATA`, processing instructions,
and the five predefined entities with numeric references (DTD-defined entities are declared
unsupported). The query language is the question. Options:

- **XPath 1.0 subset**: `/a/b`, `//b`, `*`, `@attr`, `[@a='v']`, `[n]`, `[last()]`, `text()`,
  `..`, `|`, `contains()`, `starts-with()`. That is what feeds, sitemaps and SOAP responses use,
  and what every `$` in the tests uses. About the size of the CSS engine.
- CSS on XML instead. Shorter to write, but XPath is what the format's users type, and the
  convention says one query language per format, the one native to it.

Take the subset. `XmlDocument.raw` becomes an in-house `XmlElement` tree with `name`,
`attributes`, `children`, `text`, `innerText`, `$`; the tests that reach into `xml_dom.XmlElement`
stop importing `package:xml`.

### 2.3 `http` — replace; +240 ms back from every networked program, ~600 lines, the widest API change

`package:http` is a thin layer over `dart:io`'s `HttpClient`, which costs nothing to import. The
toolkit uses it for four types, and exposes them: `http.Response` is the receiver of `text`,
`json`, `html`, `xml`, `isOk`, `isolate`; `http.BaseRequest`/`Request` is what `scrape` seeds and
what `onRequest` edits; `Http.session(client:)` takes an `http.Client`; every scrape test uses
`MockClient`.

The in-house shape: `Request` (method, url, headers, body bytes), `Response` (status, reason,
headers, `bytes`, `text` decoded once, `request`, `url` after redirects), a streaming
`Response.stream` for downloads and the body cap, and a `Client` interface with one method,
`Future<StreamedResponse> send(Request)`, implemented once over `HttpClient` and once as
`MockClient(handler)` in `lib/src/http/testing.dart` for tests. Redirects stay the engine's.
`Http.session` keeps its signature with the new `Client`.

Order matters: this is a breaking change to every program that names `http.Response`, so it
lands in its own release, after `archive` and `xml`, once the shape has been used by `download`
and `scrape` for a while behind the existing types.

### 2.4 `path` — keep

+80 ms in a noisy measurement; +30 in an earlier one. Twelve functions, and the two that are
hard — `normalize` and `relative` on Windows with drive letters and UNC paths — are exactly the
ones `package:path` gets right and a rewrite would get wrong for a year. Not worth it.

### 2.5 `crypto` — keep the package, add a native fast path (§3)

+50 ms, inside the noise, and a pure-Dart SHA-256 is the same code whoever writes it. The
problem with hashing is throughput, not the dependency.

---

## 3. Rust

### 3.1 What is on the table

Dart build hooks (`hook/build.dart`, `package:hooks`, `package:code_assets`) are stable since
Dart 3.10 and run automatically under `dart run`, `dart test` and `dart build` — no experiment
flag. A hook can invoke `cargo`, or download a prebuilt library, and hand the `.dylib`/`.so`/
`.dll` to the program, which binds it with `dart:ffi`. So Rust is technically available today,
and this machine has the toolchain.

### 3.2 What it would cost

- **Every user's machine needs `cargo`**, or the hook must download prebuilt binaries for the
  user's OS and architecture from a release the CI produced. The second is the only acceptable
  default for a scripting toolkit; it means a five-target build matrix, signed artifacts, and a
  fallback when offline.
- **First run builds or downloads**; every run after that pays a `DynamicLibrary.open`, which is
  microseconds. Startup is not the problem.
- **Data crosses the boundary by copying** unless it is already in native memory. Hashing a
  stream is a natural fit: chunks go in, 32 bytes come out. A parser is the opposite: building a
  Dart tree from Rust means one FFI call per node, and Dart parsing at 20–70 ms per megabyte is
  already fast enough that the boundary would eat the gain.
- **Two languages in one repo**: a second CI, a second linter, a second place a bug can hide.

### 3.3 Where it would pay, measured

Only hashing: 168 MB/s against 2.0–2.3 GB/s. A 4 GB download verified by `sha256()` takes 24 s in
Dart and 2 s native. Nothing else the toolkit does is CPU-bound and behind: deflate is already
native through `dart:io`, parsing is memory-bound and fast, everything else waits on the network
or the disk.

### 3.4 Recommendation

**Not Rust, and not now.** Take the native hashing win without a toolchain:

1. **`Path.sha256()` and `md5()` use the platform's OpenSSL/LibreSSL through `dart:ffi` when
   present** — `libcrypto` ships with macOS and every Linux distribution, and Windows has
   `bcrypt.dll` with the same primitives — and fall back to the pure-Dart implementation when the
   library is missing. No build step, no download, no cargo; one `DynamicLibrary.open` guarded by
   a try. About 150 lines including the three platform bindings.
2. Revisit Rust only when a measured, CPU-bound, non-parsing hot spot appears that the SDK does
   not already cover natively. Write the measurement into CONVENTIONS.md so the bar is explicit:
   ≥5× on a realistic input, on a path scripts actually wait on.

Dart is fast enough for this toolkit's work. Where it is not, the SDK usually already carries the
native code; where the SDK does not, the operating system does.

---

## 4. Folder structure and exports

### 4.1 What is messy today

- **The doubled name.** Every import is `package:dart_toolkit/http.dart`,
  `package:dart_toolkit/html.dart`: twelve directories that each hold one file whose name
  repeats the directory's.
- **`show` lists paper over public internals.** `http/http.dart` exports `session.dart show
  Http` because `ClientLease` and `clientFor` must be visible to `download.dart` and `scrape.dart`
  but not to users. `html_document.dart` re-exports `dom.dart show Element, Elements, …` for the
  same reason: `parseHtml`, `voidElements`, `Selector`, `escapeText` are public so the parser's
  three files can see each other. `fetch.dart` carries a comment saying "not exported" instead
  of being private.
- **Two kinds of export in one tree.** Module files export `../src/<module>/*.dart`; one `src`
  file (`html_document.dart`) exports another `src` file. A reader cannot tell from a file's
  location whether it is a module or a piece of one.

### 4.2 Proposed layout

```
lib/
  dart_toolkit.dart        the barrel, unchanged
  archive.dart             one library per module …
  async.dart
  cli.dart
  collection.dart
  core.dart
  fs.dart
  hash.dart
  html.dart
  http.dart
  process.dart
  util.dart
  xml.dart
  src/
    html/                  … whose implementation is its parts
      dom.dart
      parser.dart
      selector.dart
      entities.dart
    http/
      client.dart
      download.dart
      response.dart
      scrape.dart
      session.dart
      testing.dart
    …
```

Rules, replacing the current mix:

1. **A module is one library.** `lib/html.dart` is `library; part 'src/html/dom.dart'; part
   'src/html/parser.dart'; …`, with the module's doc comment and all of its imports. Every file
   under `src/<module>/` is a `part of '../../html.dart';`. Everything the module does not mean
   to publish is `_private` and shared freely between its parts. No `show`, no `hide`, no
   re-export, no "not exported" comment.
2. **`src/` never exports.** A `part` cannot, which enforces it.
3. **Cross-module use imports the module file**, `import '../http.dart'`, never a file inside
   another module's `src/`. Today `html_document.dart` reaches into `http/fetch.dart` and
   `http/response.dart`; with parts it cannot. What one module offers another is public API,
   which is the right test — `fetchOk` becomes `Uri.getOk()`, or is folded into `url.html()`.
4. **Imports get shorter**: `import 'package:dart_toolkit/http.dart';`. Nine characters per
   line, five to eight lines per script.
5. **`tool/check_deps.dart` walks `lib/<module>.dart` and its parts**; the budget table keeps
   its keys.

The one cost of `part`: a part cannot have its own `import` lines, so a module's imports live in
one place. For modules of three to six files that is a feature — the closure a module drags in
is visible in one screen, which is what the startup work has been about.

### 4.3 Migration

Mechanical, one commit: move the twelve module files up a level, turn `export` lists into `part`
lists, add `part of` headers, replace `import '../x/y.dart'` inside `src` with `import
'../x.dart'` (or the module's own parts), make the seam helpers private, update `check_deps`,
`startup`, README, CONVENTIONS and every import in `bin/`, `example/` and `test/`. Old paths can
be kept for one release as one-line re-exports (`lib/http/http.dart: export '../http.dart';`),
or not — every release so far has been breaking.

---

## 5. Order of work

| step | what | startup won | size | breaking |
|---|---|---|---|---|
| 1 | flatten `lib/`, parts, private seams | — | mechanical | import paths |
| 2 | `archive` in-house over `dart:io` zlib | +330 ms per archiving program | ~450 lines + differential test | none |
| 3 | `xml` in-house with an XPath subset | +480 ms per XML scraper | ~900 lines + differential test | `XmlDocument.raw` type |
| 4 | native hashing through the platform's libcrypto | 12–14× on `sha256()` | ~150 lines | none |
| 5 | `http` in-house over `HttpClient` | +240 ms per networked program | ~600 lines + `MockClient` | `http.Response`, `http.Request`, `Client` everywhere |

After step 5 the package has one runtime dependency, `path`, and the third-party budget table in
`tool/check_deps.dart` has one non-empty row. Rust stays a documented option with a measured bar,
not a toolchain requirement.
