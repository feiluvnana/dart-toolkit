# Changelog

## Unreleased

The second audit, applied. Six auditors probed the package with real sockets, a headless
Chrome, a probe C library and about 50 000 fuzzed parser inputs, then each finding was fixed
with a regression test. The worst were silent: an archive that could write outside its
destination, a bearer token carried from https to http, a resumed download spliced from two
versions of a file, a truncated gzip body returned as 200, and a crawl that ^C could not stop.
FFI now calls what it used to refuse.

### Upgrading

| Before | After |
|---|---|
| `a.attr('href')!` | `a.attr('href')` — it throws a `StateError` naming the tag; `attrOrNull` is the nullable form |
| `client.crawl<T>(seeds)` | `client.scrape<T>(seeds)` (a `Uri`, `Uri`s or `Request`s) |
| `for (a in html.$('a.next')) ctx.follow(a.attr('href')!)` | `ctx.follow(html.$('a.next'))` |
| `CliCommand('x', args: [a], options: [b])` | `CliCommand('x', values: [a, b])` |
| `Arg.rest('paths')` | `Arg.text('paths').many()` |
| `Arg.text('file')`, then `ctx(file).path` | `Arg.by('file', Path.new)`, then `ctx(file)` |
| `t.saveCsv('out.csv')` | `t.save('out.csv')` — csv, tsv, json, ndjson, jsonl or md by extension |
| `.show(slots: 4)` | `.show()` |
| `Console.warn('$e')` | `Console.warn(e)` |
| `glob('**/*')` listed directories | files only; `glob('**/')` for directories |
| `(await which('git'))!.run(args: [tag])` | `run('git tag', args: [tag])` |
| a token and `Future.delayed(5.s, token.cancel)` | `Cancel.scope(timeout: 5.s, …)` |
| `run('a \| b')` passed `\|` as an argument | throws `ArgumentError`; write `('a' \| 'b').run()` or `shell: true` |
| a POST retried under `Http.scope(retries:)` | sent once, unless a 429/503 gave `Retry-After` |
| a scope's `authorization` went to every host | only to the origin of the scope's first request |
| prompts on stdout | prompts on stderr |
| a CSV header `id,id` read as one `id` | `id`, `id_2` |
| `lookupFunction<Double Function(Double, Int32), …>('ldexp')(1.0, 10)` | `libm.call('ldexp', C.f64, 1.0, 10)` |
| `libc.call('pow', C.f64, 2, 10.0)` threw | computes garbage, since ints and doubles now mix — write `2.0` |

### Safety

- **Fixed: an archive could write outside its destination.** A link whose target did not
  exist yet was never checked, so `d/b → ..` plus `l → d/b/../x` extracted "fine" and a second
  archive then wrote through `l`. Links are followed even when they dangle, every directory an
  entry lands in is checked, and a file replaces a link at its name instead of writing
  through it.
- **Fixed: credentials followed a redirect to another origin.** `_hop` compared only the host,
  so https→http or another port carried `authorization`. A scope's credential headers are
  also bound to the origin of its first request.
- **Fixed: a resumed download of a changed file was two versions spliced, reported
  `Downloaded`.** A resume sends `If-Range` with the first answer's `ETag` or `Last-Modified`
  (kept as `<name>.part.if-range`); a `206` that starts elsewhere is refused.
- **Fixed: a gzip, brotli or zstd body cut off halfway came back as 200.** It is a
  `ClientException` naming the encoding. gzip decodes natively too.
- **Fixed: a crawl's own files were uncapped.** robots.txt is read to 512 KiB and a sitemap to
  50 MB, compressed or unpacked; a corrupt gzip sitemap no longer throws an uncaught error.

### Cancellation

- **Every wait hears the scope.** A crawl, a request (mid-body too), a retry's backoff, a
  `Retry-After` wait, a `delay:` gap, `Duration.delay`, `Mutex` and `Semaphore` all stop on
  `Cancel.scope`. A cancelled download reports `DownloadFailed(CancelledException)` and lets go
  of its socket.
- **A `Cancel.scope` inside another hears the outer one**, so library code that opens its own
  scope under `Cli.run` still stops on ^C. **Added: `Cancel.scope(timeout:)`.**
- `Cancel`, `CancelToken` and `CancelledException` moved from `async` to `core`, unchanged.
- `run()` keeps its timeout and cancel armed while a background child holds stdout open.

### HTTP and Chrome

- **Added: `url.events()`** — server-sent events or NDJSON as a `Stream<ServerEvent>`.
- **Added: `Http.scope(cache: dir)`** — a conditional-GET cache for scripts run again and again;
  a 304 is served as the 200 it stands for.
- **Added: `ctx.follow(elements)`** takes each element's `href`, else its `src` — pagination with
  no new name. **Deleted: `client.crawl`**; `client.scrape(seeds)` is the one spelling.
- Inside `Http.scope(retries:)` a body cut off halfway carries on from where it stopped. POST and
  PATCH are not retried unless the server said it did nothing. `delay:` spaces redirect hops.
  A `416 bytes */N` equal to the part completes it; two pairs with one destination are one
  download. `fetch()` says `404 Not Found`.
- **Charsets:** a byte-order mark wins, `<meta>` is read only for HTML, and Shift_JIS, EUC-KR,
  GBK, Big5, KOI8-R and the rest of the WHATWG labels decode (`encoding_rs`, +170 KB per
  library).
- **Cookies:** an empty `Domain=` is ignored; a `Secure` cookie over http is refused.
  **robots.txt** compares percent-normalised paths and whole product tokens (`bot` ≠ `mybot`).
- **Scrape fixed:** a sitemap page redirecting off-site widened the scope; a login redirecting
  to itself with a cookie was silently lost; robots, `delay` and `perHost` were shared across
  ports and schemes of one host; `/p?` and `/p` were two pages. The frontier uses about 40%
  less memory (1M follows: 435 → 257 MB), and a sitemap index is read in parallel.
- **Chrome fixed:** a late event from the previous page settled the next navigation with an
  empty body; `pushState` and `#hash` navigations timed out and `page.url` went stale;
  `frame()` could not reach cross-origin iframes and `frame.goto` moved the whole tab; two
  download waits could claim one file, a download from a new tab was missed, and a download
  overwrote a file of the same name (it lands as `name (2).ext`); a 204 was a transport error.

### Native and FFI

- **Integers and doubles mix in one call** on macOS and Linux, up to eight arguments:
  `atof`, `strtod`, `lround`, `ldexp`, `fma`. On Windows a mix is refused.
- **Added:** `C.f32`; calling a key makes a value of that type (`C.f32(2.0)`, and `C.i32(a)` to
  read a negative int in a callback); variadics via `fn(name, ret, fixed: n)`; `Ffi.errno`;
  `s.out(C.i32)` out-parameters; `C.i32.list(ptr, n)` array views; `C.struct([...])` with typed
  field keys; `own(p, 'free', size:)`.
- An unmodifiable typed list is no longer written to. A callback that throws says so on stderr.
- **Faster:** `abs` 19 → 12 ns, `sqrt` 30 → 15 ns, `strlen(String)` 80 → 66 ns, and
  `fn.async` 72 → 4 µs on kept helper isolates.
- **Fixed:** zip times are local time, as `unzip` reads them. A batch hash with an empty file
  name gave the files after it the wrong digests.

### Formats

- **Nothing silent:** a bad TOML or YAML escape is a `FormatException` with its line, not a
  `RangeError`. TOML refuses a table defined twice, an extended inline table, and `[[a]]` over
  a plain array (which used to append an object to it). YAML refuses a duplicate key and text
  after a closing quote, and puts `&a b: c`'s anchor on the key. YAML and TOML refuse nesting
  deeper than 1000; JSONPath `..` walks any depth.
- INI reads Java properties files; a quoted section part keeps its dots.
- SVG keeps `viewBox` and `foreignObject`. `</ p>` and `</>` are dropped, the HTML5 punctuation
  entities decode, `html:first-child` matches, and XPath `number()` is XPath 1.0's.
- **Added:** YAML merge keys (`<<: *base`), CSS `:contains(text)`, and `JsonDocument.read(path)`,
  which picks the parser by extension (`tk read` is one line now).
- **Faster:** `nextElement` over 40k siblings 1.1 s → under 1 ms; `/>` under deep markup
  2.4 s → 30 ms; stray XML end tags 0.5 s → 2 ms.

### Processes and concurrency

- **`run()`:** `args:` (`$1`… under `shell: true`) and `.stream` for live lines. An unclosed
  quote is a `FormatException`, and `|`, `&&`, `;`, `>` or `$(` outside quotes an
  `ArgumentError`, instead of arguments passed silently. `yes | head -1` no longer fails. A file
  that cannot run is 126; `which` finds only runnable files. On Windows only `.bat`, `.cmd` and
  built-ins go through `cmd.exe`, which refuses metacharacter arguments.
- **`Pool`:** `close()` closes busy workers too (an isolate pool closed mid-item kept the
  program alive), and the queue is first come, first served.
- A `flatMap` mapper that throws is the stream's error. `.env` values may span lines.
- **Faster:** `parallelize` ~10× without isolates and ~20% with; `debounce` ~50×; `delayBy` ~3×.

### CLI, tables and files

- **Help says what an option takes** (`--top <int>`, `--mode <fast|slow>`). A mistyped option
  gets a did-you-mean, a bad number names its option, and a program of subcommands run with
  none exits 64.
- `confirm` re-asks on a typo; `select(or:)` rejects a default that is not a choice. `-q`
  silences spinners, bars and boards; the live region never wraps, however narrow the terminal.
- **CSV fails loudly:** an unclosed quote is a `FormatException` with its line, and a `""` row
  round-trips. Streaming a huge quoted cell went from 1.9 s to 50 ms.
- `orderBy(…).take(10)` and `sortedBy(…).take(10)` select instead of sorting: 500k rows,
  165 → 25 ms and 132 → 10 ms. `Table.show()` prints a missing cell blank; `select` with a typo
  throws; `numbers()` reads decimals only.
- `glob` supports `{a,b}` and `[…]`. Links are measured, copied and moved as links. Completion
  keeps a choice with a space as one word.
- **Faster start:** `collection` no longer imports `formats` (−125 ms for a collection-only
  script, back to back).

### Programs and docs

- `tk read` is `JsonDocument.read`; `tk get` lost its hand-written status check; `tk find` lists
  files, not directories, over a `Table`. `tk` and `keybox` report 0.0.6. `books` closes its tab.
- README, GUIDE and the FFI library doc follow every change above; GUIDE's `requests.crawl` is
  gone and the lack of HTML foster parenting is documented.

### Not done

- A `run` child orphaned by the parent's `kill -9` is not tracked: its stdin is its own, so it
  cannot be the watchdog's lifeline (Chrome's watchdog is unchanged).
- The FFI mixed, variadic and eight-argument paths are verified on macOS arm64 only. There is
  still no Windows prebuilt.
- In a cross-origin iframe, resource blocking and credential grants do not apply yet.

## 0.0.6

The first full audit of the package, applied everywhere. About ninety findings, and most were silent:
a link whose query string came back altered, a resumed download that was corrupt but reported
done, a bearer token sent to every CDN a page loaded, a parallel job that copied its whole input
into every isolate. Each one is fixed and has a regression test. The short spellings now sit on
classes you can hold (`Pool`, `Crawler`). C gets a namespace of its own (`ffi.dart`), and the
native library is prebuilt for four platforms.

### Upgrading

| Before | After |
|---|---|
| `Console.ask(…)`, `confirm`, `secret`, `select` | `await Console.ask(…)`, since prompts are async and ^C can interrupt them |
| `await run('…', quiet: true).text` | `await run('…').text` |
| `await run('…', strict: false, quiet: true).isOk` | `await run('…').isOk` |
| `el.outerHtml`, `doc.outerXml` | `el.markup`, `doc.markup` |
| `doc['x'].to<bool>() ?? false` | `doc['x'].toOrNull<bool>() ?? false`, because `to<T>()` now throws when the value is missing |
| `doc.isNotNull` | `!doc.isNull` |
| `'---\na: 1\n---\nb: 2'.yaml` was a list | `.yaml` is the first document; `.yaml.documents` is all of them |
| `doc['tags'].list.map((d) => d.to<String>()!)` | `doc['tags'].to<List<String>>()` |
| `Native.isAvailable` | `NativeLib.isAvailable` |
| `zip.path.extractToSync(d)` | `await zip.path.extractTo(d)` |
| `Spinner.run(…)`, `Stages(n)` | `Console.spin(…)`, `Console.stages(n)` |
| `ChromePage.navigating` / `downloading` / `fetching` | `waitForNavigation` / `waitForDownload` / `waitForResponse` |
| `bin/zlib.dart` | deleted. `bin/books.dart` shows the same things against Standard Ebooks |

### Safety

- **Fixed: HTML entities without `;` corrupted URLs.** `?a=1&lang=en&copy=2` came back as
  `?a=1〈=en©=2`. Only the HTML5 legacy names decode without a `;` now, and never inside an
  attribute value when the next character is `=` or a letter or digit, which is how browsers
  read them.
- **Fixed: a scope's credentials reached third-party hosts under Chrome.** `authorization`
  and the cookie jar were tab-wide extra headers, so every `<img>` and script host got the
  bearer token. The cookie now goes to the browser for the page's URL only, and
  `authorization` is added only to same-origin requests.
- **Fixed: a resumed download of a gzip-served file was corrupt, yet reported `Downloaded`.**
  A raw or ranged request now asks for `identity` and is never decoded.
- **Fixed: Chrome's downloads landed in the working directory.** `Browser.setDownloadBehavior`
  applies to the whole browser and was never reset, so Chrome's own background component
  downloads landed in the repo. That is how a 33 MB model got committed here; it is removed.
  Downloads now go to a folder the client owns, and only a finished file is moved into `to:`.
  A download that is given up is cancelled and its partial file erased.
- **Fixed: a launched Chrome outlived the program.** On macOS and Linux it now runs under a small
  `sh` watchdog that holds a pipe from the program. When the program ends, even by `kill -9`,
  the watchdog stops Chrome and erases its profile. Windows is unchanged.
- **Extraction treats an archive as untrusted by default.** setuid, setgid and sticky bits are
  dropped. A link that leads out of the destination is refused. Output is capped at 200× the
  archive's size, and never less than 1 GiB. `trusted: true` lifts all three. A path that
  escapes the destination is always refused.
- **A content-encoding decoder returns at most 256 KiB per call.** A 16 KiB zstd body used to
  decode to a single 512 MiB allocation.
- **`run` children no longer outlive a cancel, a timeout or the program.** The whole process
  tree is stopped with SIGTERM, then SIGKILL after 2 s.

### HTTP and Chrome

- **Added: `Http.scope(retries:)`**, which applies the crawl's retry policy to every `url.get()`
  and download: transport errors, 5xx, and 429/503 honouring `Retry-After`.
- **Added: `Http.scope(delay:)`**, the minimum gap between two requests to one host, downloads
  included. It is the same idea as the crawl's `ctx.delay`, and uses the same word.
- **Added: `ctx.sitemaps = true`**, which seeds a crawl from the sitemaps robots.txt lists, or
  from `/sitemap.xml`. Sitemap indexes and gzipped sitemaps are read too.
- **Added: `Crawler<T>`, the class `url.scrape<T>()` is sugar for.** It has the same five hooks,
  as methods, and `run()` for the stream. A crawl keeps its state in fields and can be built
  in a test. The chain is unchanged and runs on the same engine.
- **Added: `ChromeClient.launch(profile:)`**, a kept user-data directory, so a launched browser
  keeps its login between runs. A profile held by another browser is reported by pid.
- **Added: `ChromeClient(proxy:)`** on all three constructors. The same proxy also carries the
  plain client underneath, so pages and files leave by one route. Proxy credentials are
  answered through `Fetch.authRequired`. **Added: `isNewBrowser`.**
- **Renamed: `navigating`, `downloading` and `fetching` to `waitForNavigation`,
  `waitForDownload` and `waitForResponse`.** Each still takes the action, so the wait is armed
  before the action runs. `waitForDownload`'s `timeout` is now how long the transfer may stay
  quiet, not a deadline on the whole download.
- **Fixed:**
  - Cookie `expires` and `Retry-After` dates in PHP's dashed format threw. They are now parsed
    with RFC 6265's lenient date reading.
  - A scope timeout never returned its connection, so `IoClient(connections: N)` deadlocked
    after N timeouts.
  - A dead browser went unnoticed for 30 s per call. It now fails at once with `The browser
    disconnected`.
  - Under Chrome, a crawl used the URL from before the redirect. Relative links resolved
    wrong, and an offsite redirect got past the scope.
  - Two `files:` uploads to one URL were deduplicated as one.
  - robots.txt was matched as `dart-toolkit` whatever user-agent was actually sent.
  - `/*.php$` did not disallow `/a.php/b.php`.
  - `waitForResponse` swallowed the action's own exception.
  - `IoClient(proxy:)` with credentials never authenticated.
- **Faster:**
  - A small redirect body is now read to the end rather than cancelled, so the connection is
    reused: five GETs over a three-hop chain went from 11 TCP connections to 1.
  - A fresh Chrome profile no longer downloads about 40 MB of components in its first minute.
    A `--disable-features=` of your own is merged with the built-in list.

### Formats

- **Fixed: `<noscript>` or `<template>` in `<head>` moved the rest of head into body.** That is
  the tag-manager snippet on most pages, so `title`, `meta[name=description]` and the
  canonical link came back empty.
- **Fixed: tag soup is now read the way a browser reads it.**
  - `<a>one<a>two` is two links, and `<h1>a<h2>b` is two headings.
  - `<div/>text` puts the text inside the div: `/>` counts only in SVG and MathML.
  - `<pre>` and `<textarea>` drop their first newline.
  - `<!-->` is a comment.
- **Renamed: `outerHtml` and `outerXml` → `markup`.** Serialising is 46 → 21 ms on a 2 MB page.
  A document nested 100 000 deep now reads, queries and serialises without overflowing the stack.
- **XPath is XPath 1.0, and 3–20× faster.**
  - Added:
    - the `*`, `div` and `mod` operators, and subtraction;
    - `translate`, `substring`, `sum`, `floor`, `ceiling` and `round`;
    - the `following` and `preceding` axes.
  - Fixed:
    - positions on reverse axes counted from the wrong end;
    - `//x/*` could come back out of document order.
  - `//article[.//img]` went from 95 to 4 ms, and `(//a)[1]` from 53 to 3 ms.
- **CSS:**
  - Added:
    - escapes (`.md\:flex`);
    - `:is` and `:where`;
    - `:only-of-type` and `:nth-last-of-type`;
    - relative `:has(> img)`, `:has(+ dd)` and `:has(~ p)`.
  - Fixed:
    - a deep descendant chain backtracked exponentially (370 ms → under 1 ms);
    - `[attr^=""]` matched every element with the attribute.
- **`Element.lines` reads the way the page does.** It breaks at block elements, separates cells
  on a row with a tab, and skips `head`, `script`, `style`, `template` and `noscript`.
- **`.table` keeps every column.** A repeated header becomes `Price_2`, and `colspan`/`rowspan`
  fill the cells they cover.
- **`to<T>()` returns the value, or throws an error that says where.** For example
  `StateError('$.server.port is "x" (String), expected int')`. `toOrNull<T>()` is for the
  caller who expects absence. `to<int>()` on 1.7 no longer quietly returns 1.
  `to<List<String>>()` and `to<Map<String, int>>()` convert every element. `isNotNull` is
  deleted.
- **`.yaml` is the first document**, however many `---` markers there are, and `.documents` is
  the whole stream. Several documents used to become a list, which looked the same as a
  one-document list.
- **YAML fixes:**
  - `[a: 1]` hung forever.
  - `--- foo\n--- bar` was read as one string, and `%YAML` directives became data.
  - `"x \" # y"` was cut at the `#`.
  - Multi-line quoted scalars threw.
  - `-   a: 1` lost its siblings.
  - A `[` inside quotes swallowed the next key.
  - Aliases inside `[…]` were not resolved.
  - Block scalars had three off-by-ones.
  - `\U`, `\e`, `\N` and `\_` decoded wrong.
  - `!!str 123` was read as an int.
  - `toYaml()` wrote values that read back as something else.
  - A line of 20 000 spaces took 3.3 s.
  - Parsing is about 2× faster.
- **Fixed:**
  - XML with many bare `&` was quadratic: 240 KB took 12 s and now takes under 2 ms.
  - HTML with many stray `<` was quadratic too.
  - A TOML integer past 64 bits is now a `FormatException` with its line number.
  - An INI value becomes a number only when it reads back as written.
  - `[s] ; comment` is a section.
  - `'a: .nan'.yaml` now serialises instead of throwing.
- **JSONPath:** slices (`[1:3]`, `[::-1]`) and unions (`[0,2]`, `['a','x.y']`). A filter is a
  `FormatException` that points you to `.where`.
- **`test/formats_diff_test.dart`** checks the parsers against package:html, xml and yaml,
  including seeded random documents and round-trips.

### CLI, processes and the terminal

- **Prompts are async**, and ^C at a prompt ends the program. Before, the prompt blocked the
  isolate that handles the signal, returned empty, and the program carried on.
  `await Console.ask('Name')`. A second ^C while an exit hook hangs quits immediately.
- **`Cli.run` fails in one line.** Anything the action throws prints `✖ error` and exits 1. The
  stack trace appears only under `--verbose`. A mistyped subcommand is a usage error with a
  suggestion (`Did you mean "build"?`). It used to print usage and exit 0.
- **Every `Cli` has `-v/--verbose`, `-q/--quiet` and `--completion bash|zsh|fish`**, unless the
  program declares those names itself. The completion script is generated from the declared
  commands and options.
- **Added:**
  - `Opt….many()`: repeated options, collected into a `List`.
  - `Opt….env('NAME')`: falls back to the environment variable, satisfies `required()`, and
    shows `[env: NAME]` in help.
  - `Arg`: positionals as values, beside `Opt`.
- **Fixed:**
  - `--dry=false` set the flag to true. It is false now, `--no-dry` works too, and
    `--dry=maybe` is an error.
  - In `-vj=4 7`, the value 7 went to `--jobs`.
  - `-5` was an unknown option.
  - A subcommand's `--help` now lists the options it inherits, under "Global options".
  - `-h` no longer takes `--help` away with it when another option owns `h`.
- **`run(…)` returns a `ShellRun`**, and the getter you read decides how it runs. `.text` and
  `.lines` imply `quiet`, and `.isOk` also implies `strict: false`. So
  `await run('git diff --quiet').isOk` is a real answer; before, it was always `true` or a
  throw.
- **Fixed:**
  - `run(shell: true)` gave no shell. It now runs `/bin/sh -c` (`cmd /c` on Windows).
  - `run` ignored `Cancel.scope`.
  - Output that was not UTF-8 failed the command.
  - A missing executable is now exit 127.
  - A timeout's partial output is kept, on `ShellTimeoutException.result`.
- **Added: `run(inherit: true)`**, for `git commit`, `ssh` and `vim`.
- **Fixed:**
  - `2>log` wrote colour escapes into the log.
  - Child output garbled a live spinner.
  - `TaskBoard` printed nothing on a terminal with `NO_COLOR` set.
  - `Env.parse` treated every `#` as a comment and cut values at `\"`.
- **Removed second spellings:** `Spinner.run`, the public `Stages` constructor,
  `ProgressBar.formatLine`, `TaskBoard.formatLines`.

### Concurrency

- **Added: `Worker<T, R>` and `Pool`, the class under `parallelize`.** `init()` runs once per
  isolate and `run(item)` once per item. `Pool.spawn(Resize.new, size: 4)` keeps its isolates,
  replaces one that dies, holds at most `size` items in flight, and stops on `Cancel.scope`.
- **Fixed: `parallelize(isolate: true)`.** On a stream it never worked. On an iterable it
  copied the whole input into every isolate: 400 × 50k ints took 20.9 s and now take about 70 ms.
- **Fixed:**
  - `retry` slept through a cancelled scope.
  - `merge` and `flatMap` ignored backpressure.
  - Cancelled stream operators kept the process alive with their timers.
  - `throttle` could emit twice in one window.

### Files, hashing and tables

- **Added:**
  - `extractTo(dest, only: '**/*.txt')`, which extracts only the entries that match.
  - `archive.entry('a/b.txt')`, which reads one entry without extracting.
  - `paths.hash(Hash.xxh3)`, parallel in Rust: 49.5k files in 1.0 s, against 9.3 s one at a time.
  - `dir.duplicates()`.
  - `olderThan(age)`, true when the file is missing.
  - `changes(debounce:)`.
  - `Table.read(path)` and `Table.readRows(path)`, which read CSV, TSV, JSON and NDJSON by
    extension, streaming for `readRows`.
- **Hashing a file is done by the library reading the file.** xxh3 over 1 GiB went from about
  530 ms to 110 ms. BLAKE3 uses every core, going from about 1 s to 110 ms. `hmac` of a file
  streams instead of reading it into memory. `hmac(Hash.blake2b)` works, using BLAKE2's keyed mode.
- **`Table.csv` is 3–4× faster.**
- **Fixed:**
  - `move` onto a non-empty directory merged into it and deleted the source.
  - A `.7z` written inside the folder it archived contained a truncated copy of itself.
  - A stray `"` in the middle of a CSV field swallowed the rest of the file, and a BOM stuck to
    the first header.
  - `glob` returned nothing for an absolute pattern, and stopped at the first unreadable
    directory.
  - Zip lost the modification time of read-only files, and turned symlinks into regular files.
  - `'..'.filename` returned `..`.
  - `hexBytes('-1')` returned `[255]`.
  - A sorted `Sequence` kept returning its first result forever.
  - `windowed` held its whole source in memory.
  - `'1,5'` was read as 15.
- **Removed: `extractToSync`.** The async form already runs off the main thread, and nothing
  called the sync one.

### Native and FFI

- **Added: `package:dart_toolkit/ffi.dart`, in its own namespace.** It calls C without
  codegen:
  ```dart
  final libc = Ffi.open('c');
  libc.fn('strlen', C.i64)('hello');          // 5
  libc.call('getenv', C.str, 'HOME');        // String?
  await libc.fn('usleep', C.i32).async(1000); // on another isolate
  ```
  It needs only one signature. On every 64-bit ABI Dart runs on, the first six integer or
  pointer arguments travel in slots the caller owns, and a callee ignores the slots it doesn't
  declare. So `Int64 Function(Int64 × 6)` can call any such function; this is the same trick as
  Go's `syscall.Syscall6`.
  - Strings go in as scoped `char*`, and typed lists are copied in and back out.
  - `Ffi.scope` is an arena.
  - `lib.own(p, 'free')` frees on garbage collection.
  - `Ffi.callback` hands `qsort` a Dart comparator.
  - Variadics, mixed int/double arguments, structs by value and `float` are refused rather than
    passed in the wrong registers.

  The library is not exported from the barrel: its short names (`Ffi`, `C`, `Lib`, `Fn`) are
  claimed only by a program that imports them.
- **Renamed: `Native` → `NativeLib`.** Under the barrel it silently took the place of `dart:ffi`'s
  `@Native` annotation.
- **Fixed:** a missing library was reported as `no NativeBridge.fileName at …`.
- **Prebuilt for `macos_arm64`, `macos_x64`, `linux_x64` and `linux_arm64`.** Windows is not
  built: unrar needs an MSVC toolchain. The macOS dylib's install name is now `@rpath/…`.
  `make native RUST_TARGET=…` cross-builds with `cargo-zigbuild`.
- **Native assets were measured and not adopted:** +50–65 ms on every `dart run`.

### Programs and docs

- **`bin/books.dart` replaces `bin/zlib.dart`.** It fetches public-domain ebooks from Standard
  Ebooks by title, by one of two routes. The plain route downloads every book at once. The
  `--browser` route clicks each link in Chrome, which is the only route that follows the site's
  meta-refresh download page.
- **`tk`** now hashes through `paths.hash`, and its six commands are one line each (180 → 129
  lines). **`keybox`** runs with `retries: 3`.
- **`CONVENTIONS.md`, `README.md` and `GUIDE.md` are rewritten**: short rules, each with its
  reason, and examples that match this release.
- **`.pubignore` now repeats `.gitignore`.** A `.pubignore` replaces `.gitignore` for pub rather
  than adding to it, so the 0.0.5 dry run was 65 MB.

## 0.0.5

A login that redirects keeps its session, a page that opens a dialog keeps its tab, and an
upload is no longer the size of the heap. The io client asks for what a browser asks for and
walks its own redirects; the browser blocks what it will not read, downloads what it is told
to, answers with the XHR behind the page, and reaches inside an iframe. And there is a guide.

### The guide

- **Added: [`GUIDE.md`](GUIDE.md)** — the manual, where `README.md` is the tour: every module,
  every type worth naming, what each one is for, a cookbook of whole programs, and the
  testing, performance and troubleshooting notes that were only ever in people's heads.

### Two things that were quietly broken

- **A login that redirects no longer loses its session.** `Http.scope(cookies: true)` stored
  `set-cookie` from the response at the *end* of a redirect chain, and `dart:io` reports the
  hops it followed without the headers they carried. The shape that breaks on is the commonest
  one there is — `POST /login` → `302` → `GET /dashboard`, with the session set on the hop that
  vanishes — so the jar stayed empty and every page behind the login came back logged out. The
  jar now walks the chain itself, one hop at a time, and stores what each one sets against the
  host that set it.
- **A page that opens a dialog no longer takes the tab with it.** `Page.enable` turns off
  Chrome's own auto-dismiss, so an `alert()` held the renderer: the wait timed out, and the tab
  went back into the pool still blocked, taking one of the browser's slots with it for good.
  Every dialog is now answered — dismissed by default, and `beforeunload` accepted, because
  dismissing *that* one cancels the navigation that raised it.
- **Added: `ChromePage.onDialog`**, for answering one on purpose. The handler gets a `Dialog`
  and calls `accept([text])` or `dismiss()`; one that does neither, or that throws, leaves the
  default, so a handler that only wants to read the message cannot hang a tab by forgetting.

### The io client

- **Added: `files:`, a `multipart/form-data` body that is never held.** The fifth body word, on
  `Request`, on `post`/`put`/`patch`/`delete`, on the client verbs and on `follow`. It is read
  off disk as it goes out, so the size of an upload is not the size of the heap — where before
  a file had to be read into a `List<int>` and the multipart framing written by hand.

  ```dart
  await api.post(form: {'title': 'holiday'}, files: {'photo': '~/beach.jpg'.path});
  ```

  It is the one body word that pairs: `form` with `files` is not two bodies but the fields and
  the files of one form, which is what a browser sends for a form with a file input on it.
- **Added to the seam: `Request.open()` and `Request.contentLength`.** What a client sends is
  the stream, not `Request.bytes` — which is empty for a body that was never in memory. The
  body is opened again per send rather than replayed, which is what lets a 307 and a retry send
  the same upload twice. `clientConformance` checks it, so an implementation that reads the
  wrong field is told so rather than silently sending nothing under a `content-length` that
  lies.
- **Added: brotli and zstd.** `dart:io` announces `accept-encoding: gzip` and nothing else,
  which is both slower and a thing to be recognised by. `IoClient` now asks for what a browser
  asks for and decodes the answer as it streams — brotli is 15–20% smaller than gzip on markup,
  which a page at a time is the difference between a crawl and a shorter one. brotli and zstd
  are the native library's (`tk_inflate_new`/`push`/`free`, a handle per body, nothing
  buffered); gzip is `dart:io`'s own. A program without the native library asks for neither and
  nothing about it changes. `deflate` is not asked for: it is zlib-wrapped in the specification
  and raw about half the time in practice, and a codec that cannot be read without guessing is
  not worth a token in a header.

  The cost is opening the library on the first request — 12.5 ms, 8 ms of it
  `Isolate.resolvePackageUriSync`, measured back to back three times — paid once per process.
- **`IoClient` walks its own redirect chain.** `dart:io` copies every header onto a hop,
  including a credential, and reports only where it ended up. The policy is now `Request._hop`
  and one rule for all three callers — the client, the jar's walk and the crawl engine, which
  had it written out inline. 303 and a non-GET 301 or 302 become a bodiless GET; 307 and 308
  keep both; `authorization`, `cookie` and `proxy-authorization` stop at another host.
- **Added: `IoClient(proxy:, insecure:)`** — an explicit HTTP proxy with the credentials taken
  from its URL, and a certificate that does not verify, for the self-signed intranet host and
  nothing else.
- **`Request.copy()` shares the body instead of duplicating it.** Every send copies the request
  it was handed, so a 50 MB upload was allocated twice on the way out; what the copy is for is
  the headers a client writes on.

### The browser is a browser

- **Added: `ChromePage.block` and `Resource`** — `page.block(Resource.heavy)`, or
  `ChromeClient.launch(block:)` for every render, or `request[ChromeClient.block]` for one. The
  largest single thing a rendered crawl can do for itself: a page whose images, fonts and media
  never arrive looks nothing like itself and says exactly the same words. Not stylesheets or
  scripts by default, which is where the line is — a page that cannot run its scripts is not
  the page a browser was opened for.
- **Added: `ChromePage.downloading`** — run the action, wait out the download it starts, answer
  the file it wrote. Armed before the action for the reason `navigating` is, and `to:` is the
  directory; the file keeps the name the site gave it. A download that never starts is `null`,
  not a throw.
- **Added: `ChromePage.fetching`** — run the action and answer the XHR it fires, body and all,
  as a `Response`. The JSON behind the page instead of the DOM it eventually becomes, which is
  the scrape most pages actually want.
- **Added: `ChromePage.frame`** — the iframe as a `ChromePage` of its own, so `text`, `click`,
  `fill`, `waitFor`, `eval` and `goto` all work inside it without a second vocabulary. A
  checkout form, a comment widget and a captcha box each live in one and none of them can be
  reached with a selector from the document around it. Closing a frame closes nothing; it is a
  view of part of a tab.
- **Added: `Device`, replacing `userAgent:`** — one argument instead of six. `Device.desktop`
  is what a browser is unless it is told otherwise and `Device.phone` is the other site a great
  many hosts serve, usually a simpler one with the same data in a tenth of the markup; `width`,
  `height`, `scale`, `mobile`, `userAgent`, `locale` and `timezone` are the rest. The
  user-agent still travels to the raw side, so pages and files tell a host one story.
- **Added: `stealth:`, on unless it is turned off.** `--disable-blink-features=AutomationControlled`
  for the browsers this starts, and a script before every document's first line for the rest of
  what an automated Chrome leaves lying around — `navigator.webdriver`, a missing
  `window.chrome`, an empty `plugins`, a `permissions.query` that disagrees with
  `Notification.permission`. These are exactly what an interstitial reads before deciding
  whether to show anyone the page.
- **Added: `ChromePage.upload`, `reload`, `forward`, `screenshot(selector:, full:)`,
  `cookies(restore)` and `ChromeWait.dom`.** `back` without `forward` or `reload` was a grid
  with a hole in it; `cookies()` could read a session and not put one back, which is the half
  that makes logging in by hand once worth doing; a screenshot could only be of the window;
  and the two waits skipped the one a page served whole HTML actually needs.
- **A subframe finishing loading no longer settles the page's wait.** The lifecycle wait took
  any frame's event, so a page whose iframes load first came back before it had.

### The examples are gone; `bin/` is the demonstration

- **Removed: `example/`** — all seven programs. They were a second copy of the README, kept
  in sync by hand and read by no one who had not already read the README. `bin/tk.dart` and
  `bin/keybox.dart` are the programs that have to keep working, so they are the ones that
  show what the library is like to use.
- **`make bench` is `make startup`**, and `make format` no longer walks a directory that is
  not there.

### `tk` and `keybox` say it once

- **`tk`**: `--verbose` is read in one place instead of as the first line of six handlers, a
  missing positional is a `UsageException` — so it prints the usage hint and leaves with 64
  like every other usage error, rather than a bare message and 1 — and `find` and `peek`
  build their filtered list once instead of three and two times.
- **`keybox`**: the patterns are compiled once rather than inside the loops that read them,
  and the asset tables name only the part that differs. An absolute href resolves to itself,
  so the two off-site scans go through the same helper as the ninety on-site ones.

### The terminal lifecycle is two shapes and no others

- **Added: `Lifecycle`**, replacing four top-level functions with one pair. `onExit`
  registers a listener for the exit event and `exit` is the event happening, which is the
  whole surface:
  - `onExit(callback)` registers, and answers a function that removes *that* listener.
    **`onExit(null)` forgets every listener** and stops the signal watch, absorbing
    `clearExitHooks`.
  - `exit([message, code])` runs the listeners and ends the process, absorbing `die`. With a
    message it goes to stderr in red and the code defaults to 1; with none, to 0.
- **Removed: `onExit`, `die`, `runExitHooks`, `clearExitHooks`** as top-level functions. Four
  names for one event, in three different shapes, two of them named after the list they kept
  rather than after anything a caller wants. `runExitHooks` is now private — firing the
  listeners without leaving is what `Cli.run` does on its way out, not something a program
  asks for, and the test that needed it drives `Cli.run` instead.
- **It is a namespace and not two top-level functions on purpose.** A top-level `exit` would
  *silently* shadow `dart:io`'s in every file that imports this package: Dart resolves a name
  to a non-platform library without calling it ambiguous, so `exit(0)` would quietly stop
  meaning what it says. Namespaced, `dart:io`'s `exit` is untouched and does not run the
  listeners — which is what someone who typed it expects.

## 0.0.4

A scope is called a scope, a client you are holding can do everything, and the tab is a tab
all the way down. The browser is called Chrome, the browser can outlive the run, and a
download through it is the file again. One namespace owns the terminal, and the things drawn
on it stopped writing over each other.

### Renamed: `session` → `scope`

- **`Http.session` → `Http.scope`, `Shell.session` → `Shell.scope`, `Cancel.session` →
  `Cancel.scope`**, and `lib/src/http/session.dart` → `scope.dart`. The three read alike
  because they *are* alike, and `scope` is the word that is true of all three: `session` was
  exactly right for HTTP — a cookie jar plus connection reuse is the textbook definition —
  and a metaphor for a workdir and a cancel token. The docs already called every one of them
  "the scope" in prose; the API now agrees with the prose.

### A client in your hand can do what a client in a scope cannot

- **Added: `ClientExtensions`** — `client.get/head/post/put/patch/delete/fetch/json/html/xml`,
  `client.fire(request)`, and `client.scrape<T>(url)` / `client.crawl<T>(requests)`. The same
  verbs `UriExtensions` puts on a `Uri`, on a client you are holding.
  - A scope holds a `Client`, and a `Client` is `send` and `close` — so through a scope,
    everything a particular client can do *beyond* the seam is invisible. `ChromeClient.page`
    was reachable only by keeping the client in a variable, which is the one thing the module
    tells you never to do. Held, the client is the receiver: `page` sits beside `get` and the
    compiler decides whether it exists. Nothing probes, nothing casts, and nothing throws at
    runtime for asking a socket to click a button.
  - A crawl could not take this route through the zone — a `Scrape` is lazy and its engine
    starts in whichever zone finally listens — so `_Hooks` carries the client instead.
  - `Http.scope` is unchanged and is still the only way in for the cases with no receiver to
    hang a client off: `stream.download(concurrency: 4)` over a merged stream of records.

### The tab grew the verbs it was missing

- **Added to `ChromePage`: `text`, `attr`, `has`, `select`, `hover`, `navigating`, `back`,
  `cookies`, `pdf`.** `text` and `attr` read one value off a live page without building a
  whole `HtmlDocument` for it, and `attr` answers what the DOM resolved, so `href` comes back
  absolute. `select` matches an option by value and then by the text a person would read.
  `cookies` hands a logged-in jar to something that is not a browser.
  - **`navigating(action)` takes the action rather than being a bare `waitForNavigation()`.**
    A click is dispatched and returns immediately, and a fast page finishes loading before the
    next line runs — a wait armed *after* the click has already missed the event and sits
    until its timeout. The file said so already, over `_arm`: *arm before navigating*. Taking
    the action is what makes that impossible to get wrong.
  - **Fixed: `back()` hung for its whole timeout on the commonest kind of back.** A page the
    back/forward cache restores is not loaded again and fires no second `load`, so a
    lifecycle wait alone waited 30s for an event that was never coming. The URL moving is the
    other proof the tab went back, and either will do.

### Robustness

- **Fixed: sending a request wrote on the caller's request.** A scope stamps its default
  headers and its `cookie` onto what it sends, so the same `Request` sent twice carried the
  first send's jar the second time — and the jar refresh was then skipped, because the guard
  is *does this request already name a cookie*. `UriExtensions.send` copies before it sends;
  `Client.send`'s contract now says outright that sending consumes a request.
- **Fixed: a raw request through `ChromeClient` named no browser at all.** The rendered side
  drops a caller's `user-agent` on purpose; the plain-socket side — the asset, the download —
  sent none either, so a host saw the pages arrive from Chrome and the files arrive from
  nothing. It now carries Chrome's own, asked once and kept, beside the cookies it already
  carried.
- **`Client.close()` is `Future<void>`, not `FutureOr<void>`.** Every caller had to write
  `if (client.close() case final Future<void> pending)` to find out which it got. A
  synchronous client returns an already-completed future and pays nothing; the seam absorbs
  the difference instead of exporting it.
- **Added: `IoClient(connections:, perHost:, keepAlive:, connectTimeout:, userAgent:)`.**
  `connections` is a total in-flight cap across every host, which `dart:io` has no setting
  for; the permit is held until the body is read to the end, cancelled or thrown, so the cap
  counts transfers rather than handshakes.

### A download through a browser was a rendering of the download

- **Fixed: `path.download(url)` inside `Http.session(client: chrome)` wrote the DOM, not the
  file.** A fresh transfer is a GET with no `range`, which was indistinguishable from a page,
  so Chrome opened it in a tab and handed back the markup it built to display it — 2 KB of
  binary came back as HTML, and the `Content-Length` check then failed the transfer outright.
  Every binary download inside a Chrome session was silently wrong.
  - **Added: `Request.raw`**, the one directive that is not a client's own: *answer with the
    resource, never a rendering of it*. A client that renders must hand it to plain HTTP.
    Every download sets it, so the download layer says what it wants without knowing Chrome
    exists — and a third rendering client written later inherits the fix.
  - **Removed: `ChromeClient.direct`**, which said the same thing one layer too low. The key
    count is unchanged; it moved to where the contract lives.

### A browser that is still there next time

- **Added: `ChromeClient.connect()`** — attaches to the Chrome on the port, and starts one that
  outlives the program when there is none. `launch()` is a fresh browser every time: temporary
  profile, no cookies, process dies with the client. That is right for a crawl and wrong for
  anything that depends on *being someone*. `connect()` keeps one browser and one profile
  (`~/.dart_toolkit/chrome`, or `profile:`) across runs, so the second run attaches in
  milliseconds with the logged-in session still there. `close()` never kills it, whichever run
  started it. Headful by default, because a browser you can see is one you can log into.
  - `attach()` now names the command that would start a Chrome to join, instead of failing
    with whatever the probe threw.

### One namespace for the terminal

- **`Logger` is gone; its verbs are `Console`'s.** `Console.debug`, `.info`, `.ok`, `.warn`,
  `.error`, `.stages`, `.level`, `.silenced` and `LogLevel` all read as before — the class in
  front of them is the only change. Two namespaces wrote to one terminal and neither could see
  the other, which is what made them garble each other; one namespace can hold a live region,
  and two cannot.
  - Removed: `Logger`, and `lib/src/cli/logger.dart` with it.
- **Added: a live region, so the parts compose.** A spinner, bar or board owns the bottom rows
  and says how many. Every durable write — a log line, a rule, a prompt — clears them, writes
  where they stood, and draws them again underneath. `Console.info` during a `Console.spin`
  used to land on the spinner's row; it now scrolls above it and the spinner keeps spinning.
  Indicators nest: the innermost is the one on screen, and the one under it is redrawn when it
  finishes.
  - Added: `Console.writeln`, the unlevelled write that still respects the live region.
- **Added: `Console.spinner(message)`**, the spinner as a handle rather than a wrapped call.
  `Console.spin(msg, action)` was the only way in and ends when the action does; this one has
  a mutable `text` and is ended by the program — `succeed`, `fail`, `warn`, `info`, `stop`.
- **Added: `SpinnerStyle`** — `braille` (the default), `dot`, `line`, `ellipsis`, `bar`, `arc`,
  and a constructor that takes any frames and interval, so the braille loader is directly
  usable and a program with its own frames is not stuck choosing from the list.

### Renamed

- **`BrowserClient` → `ChromeClient`, `BrowserPage` → `ChromePage`, `BrowserWait` →
  `ChromeWait`**, and `lib/src/http/browser.dart` → `chrome.dart`. It drives Chrome over the
  DevTools protocol and nothing else; "browser" promised an abstraction that was never there.
  The directive names on the wire moved with it: `browser.wait-for` is now `chrome.wait-for`.
- **`Console.multiProgress()` → `Console.tasks()`**, and the indicator classes lost the prefix
  the namespace already carries: `ConsoleProgress` → `ProgressBar`, `ConsoleMultiProgress` →
  `TaskBoard`, and the private spinner is now `Spinner`. `multiProgress` named it by contrast
  with the other one rather than by what it is, which is a board of concurrent tasks.

## 0.0.3

A scope is the only way in, a second client is just a client, and the slow paths were measured
rather than argued about. Every ambient setting — the HTTP client, the shell's environment, the
cancellation token — is named once where its scope opens and nowhere else; `cancelToken:` and
`client:` are gone from every signature that took them. A crawl can now keep cookies, obey
`robots.txt`, verify a download and ask whether a file changed, none of which it could do
without writing it by hand. Seven hot paths got between 1.6× and 39× faster, each with two
numbers from the same run. Breaking where it is breaking, and the entries say so.

### A setting every call would carry belongs to the scope, not the call

- **`Cancel.session` makes the cancellation token ambient**, the shape `Http.session` has for
  a client. `download`, `retry` and `.cancellable` read `Cancel.token`; none of them takes a
  `cancelToken:` any more. `Cli.run` opens a session around the action whose token is
  `ctx.cancel`, so a program that wants ^C to stop its downloads writes nothing at all — the
  benchmark program lost a parameter and a threaded argument.
  - Added: `Cancel.session`, `Cancel.token`, `Cancel.isCancelled`.
  - **`cancelWith` is `cancellable`, and it is a getter.** The name was for the argument it no
    longer takes; taking none and doing no IO, it is a getter like `sorted` and `reversed`.
    `stream.cancelWith(token, true)` is `stream.cancellable`, and `future.cancelWith(token)` is
    `future.cancellable`. Outside a session both throw a `StateError` that says so — a token is
    named where the scope opens and nowhere else.
  - **One name now means one thing on both receivers.** `Stream.cancelWith()` closed quietly
    while `Future.cancelWith()` threw, so the call did not say which. `cancellable` ends a
    stream and fails a future, because a future has no quiet ending to offer, and that is the
    whole difference.
  - **Removed: `throwOnCancel:`.** It was a flag on `Stream` alone, selecting between two
    endings. `Cancel.isCancelled` after the loop already says whether the scope fired, which is
    error policy chosen at the use site, where this package puts it.
  - **Added: `Cancel.reason` and `Cancel.throwIfCancelled()`**, so the scope answers all three
    questions its token does — the package itself was reaching through
    `Cancel.token?.throwIfCancelled()` in three places, where the `?.` silently does nothing
    outside a session and looks like it checked. All three readings are quiet outside a
    session; only `.cancellable` refuses there.
  - Removed: `cancelToken:` from `Path.download`, all three batch downloads, `retry` and both
    `parallelize`s.
- **`Shell.session` does the same for processes.** `workdir`, `env`, `timeout`, `encoding`,
  `quiet` and `strict` are set once for a scope and read by `run`, `path.run(args:)` and a
  pipeline alike; a per-call argument still wins, and `env` adds to the enclosing session
  rather than replacing it. The nine-parameter list that was written out four times is written
  once.
  - Renamed: `throwOnError:` → `strict:`, a bare adjective like every other parameter.

### One name per operation

- **`downloadAll` is gone; everything is `download`.** `dest.download(url)`, `pairs.download()`,
  `stream.download()` and `map.download()` are one word over four receivers, streaming the
  same `BatchDownloadProgress` — one file is a batch of one.
- **A request body is named by what it is, everywhere.** `text:`, `bytes:`, `form:` and `json:`,
  at most one, each typed and each carrying its `content-type`. They read the same on
  `Request`, on `get`/`post`/`put`/`patch`/`delete` and on `ctx.follow`, replacing three
  vocabularies — `post(body:, json:)` where `body` was an untyped `Object?` checked at runtime,
  `follow(body:, fields:)`, and `Request(text:, bytes:)` with a `fields` setter.
  - Removed: `body:` and `fields:`; `Request.fields` is `Request.form`, and `Request.json` is
    new.
- **`or` is the one word for a default.** `Console.ask(or:)`, `Console.confirm(or:)` — named
  now, not positional — and `Console.select(or:)`, matching `Opt.…or(value)`.
- **A command is what it is given.** `CliCommand(options:, commands:, handler:)`; `declare()`,
  `action()`, `command(…, build:)` and the public mutable `handler` field are gone, which was
  four ways to say two things. `Cli` takes `commands:` and `handler:` too.
- **Deleted, each one line over something one line away:** `String.stripped` (use
  `Io.stripAnsi`), `Sequence.count` (`length`, or `where(…).length`), `Group.counts`
  (`countBy`), `Table.records` (`Table.rows(items.map(toRow))`), and `Console.spinner` with
  `ConsoleSpinner.start`/`succeed`/`fail`/`stop` (`Console.spin(message, action, done:,
  failed:)` is the only spinner).

### What a crawl could not do without writing it by hand

- **A session can keep cookies.** `Http.session(cookies: true, …)` stores what the responses
  set and sends them back, so a login and the pages behind it are one crawl. The jar lives as
  long as the session, is never written to disk, and a request that names its own `cookie`
  still wins. Path and domain scoping, `Secure`, `Expires` and `Max-Age` are honoured; the
  only vocabulary is the flag.
  - `IoClient` joins a repeated `set-cookie` with a newline rather than a comma, which its
    `Expires` contains. Chrome's DevTools protocol already joined it that way, so
    `BrowserClient` agrees.
- **A crawl can obey `robots.txt`.** `ctx.robots = true` on `Scrape.onInit` fetches each
  host's rules once and drops what they forbid into `ScrapeSummary.dropped`. Longest match
  wins and a tie goes to `Allow`, as RFC 9309 says; `*` and `$` in a path count. A
  `Crawl-delay` raises that host's gap and never lowers it, so robots can slow a crawl but
  not hurry it. A site with no `robots.txt`, or one that cannot be read, forbids nothing.
- **A download can be verified.** `dest.download(url, checksum: (Hash.sha256, '9f86d0…'))`
  fails with a `ChecksumMismatch` and discards the `.part`, which is not what was asked for
  and would never become it. On the single-file form alone: one checksum describes one file.
- **A download can be conditional.** `ifModified: true` sends the destination's timestamp as
  `if-modified-since` instead of skipping because the file is there; a `304` is a
  `DownloadSkipped`. On all four receivers.

### A page is read in the encoding it is written in

- **`Response.text` honours `<meta charset>` and decodes windows-1252.** A page served as
  `text/html` with no charset in the header and `<meta charset="windows-1252">` inside used to
  come back as replacement characters — silently, since nothing throws. The head of the
  document is now read to find out how to read the document, as a browser does, and both
  `<meta charset>` spellings count. `iso-8859-1` decodes as windows-1252, which the HTML
  standard requires and which is what a page labelled either one almost always is. UTF-8 is
  unchanged.

### Measured, not argued

Same process, warm, best of six, against the previous commit.

- **`glob` walks only where the pattern can match** — 143 ms → 3.7 ms on this repo for
  `lib/**/*.dart`. The segments before the first wildcard are a directory, not a pattern, so
  the walk starts there; and a pattern without `**` is never followed deeper than it has
  segments. It was listing the whole tree — `native/target` included — and filtering the
  result.
- **A sibling axis with a pinned position stops at it** — `//li/following-sibling::li[1]` over
  3 000 siblings, 72.5 ms → 2.0 ms. `[k]` on a forward axis needs the k-th match and nothing
  after it, where the axis used to be collected whole and all but one thrown away. A sibling's
  slot also comes from a per-query index now, as the CSS engine has always done, instead of an
  `indexOf` scan per node.
- **`//x` is one axis walk** — `//span` over 8 000 elements, 4.0 ms → 1.2 ms.
  `descendant-or-self::node()/child::x` is exactly `descendant::x` when the step carries no
  predicate, and the descendant axes keep document order, so the collapsed form also skips
  building the order map. `//p[1]` is left alone: it means the first `p` of each parent, where
  `descendant::p[1]` would mean the first in the document.
- **A sort extracts each key once** — `sortedBy` over 20 000 elements, 12.7 ms → 5.6 ms, and
  690 270 selector calls → 20 000. The key was computed inside the comparator, so a selector
  that lowercases a string or parses a date was paid for on every comparison. `Table.orderBy`
  had the same shape, where the coercion is a trim, a separator strip and a parse.
- **A table reads a column once per call** — `texts` over 20 000 rows, 1.3 ms → 0.5 ms. The
  column name was validated inside the row loop, and validating it scans the column list.
- **`:has()` stops at the first match** — 16.3 ms → 7.6 ms where the match is the first child
  of a large subtree. It was building the whole match list to ask whether it was empty.
- **`Element.table` walks the rows once** — a 3 000-row table, 2.1 ms → 1.3 ms. It ran two
  subtree selector queries per row and then filtered the matches back down by their nearest
  ancestor.
- **A download reports at most every 50 ms.** It was allocating two objects and pumping two
  stream controllers per socket chunk — about 16 000 events per gigabyte — for updates the
  frame-limited renderer could not draw, and making the socket wait on the consumer to do it.
  The final state is always reported.
- **The CSS selector cache evicts.** It grew forever; the XPath cache next to it has always
  capped at 256, and now both do.

### Fixed

- **A nested CSS selector reads the markup around it.** `:not()` and `:has()` parsed their
  argument as HTML whatever the document was, so on XML `Root > :not(Item)` kept `<Item>`
  instead of `<item>` — the wrong element — and `Root:has(ITEM)` matched a document with no
  `<ITEM>`.
- **`orderBy(descending: true)` keeps `null` last**, which is what it documents. Negating the
  whole comparison quietly reversed the null rule too, so an empty cell sorted first.
- **Private names no longer reach the caller.** Six `FormatException` and `StateError`
  messages named `_XPath`, and four doc comments named `_entities`.

### An archive is what its bytes say it is

- **The format is read from the file, not from its name.** `extractTo`, `archiveEntries` and
  `decompressTo` sniff the magic number in the native library and fall back to the extension,
  so a download saved as `.bin`, a renamed archive or an extension-less blob still opens —
  every container, `rar` included, and all four single-stream codecs. `archiveTo` and
  `compressTo` still read the destination's extension, because a file that does not exist yet
  has nothing else to go on.
- **`Archive.rar` names the format that was already readable.** The enum now covers everything
  the package reads; `Archive.isWritable` is false for it alone, and `archiveTo` says so
  instead of failing further down.

### What is public is what a caller uses

- **The FFI plumbing moved off `Native`.** `Native` is `isAvailable`, `reason` and `version`;
  `require`, `alloc`, `free`, `withBytes`, `withOut`, `withText`, `take`, `lastError`,
  `fileName` and `target` are on `NativeBridge`, public only because `fs` and `hash` are
  separate libraries and documented as outside the versioning promise.
- **A parser's internals are not API.** `CliOption.parse`/`fallback`/`isRequired`/`choices`/
  `takesValue` and `CliCommand.findOption`/`findAbbr`/`printUsage`/`subcommands`/`parent`/
  `options` are private. `XPath`, `XPathKind` and `JsonPath` are private too: `$` and `$x` are
  how a query is run, and two ways to run one was one too many.
- **Every option kind is behind `Opt`.** `Flag('x')` is `Opt.flag('x')`, so typing `Opt.`
  shows all five kinds rather than four.
- **`Crypto` is `Secure`.** The library doc says this package does not protect data; the class
  holding `token`, `uuid`, random bytes and constant-time `equals` should not have claimed
  otherwise. `Crypto.randomBytes` is `Secure.bytes`.
- **The hash grid is filled.** `hash`, `hashBytes`, `checksum`, `hmac` and `hmacBytes` are on
  `String`, `List<int>` and `Path` alike; `Path.hmac`, `Path.hmacBytes`, `String.hashBytes` and
  `String.hmacBytes` are new. Which receiver had which was previously unguessable.
- **Fixed:** `Http.session`'s doc claimed every entry point takes a `client:` — none does, and
  that is the point. `{@category Crypto}` and `{@category Core}` were undeclared and are now
  `Hashing` and `Utilities`; `Hashing` and `Native` are declared in `dartdoc_options.yaml`.

### A client is the only thing that touches the network, so anything can be one

- **`BrowserClient`, a second built-in client, renders every page in Chrome.** It speaks the
  DevTools protocol over a `dart:io` websocket — no third-party package and no Chromium
  download: `BrowserClient.launch()` runs the Chrome already installed, `attach(port:)` joins
  one already running. The rendered DOM arrives as `Response.bytes`, so `res.html`, `$`, `$x`,
  the scrape engine's scope, dedupe and redirects all work over it with nothing changed but the
  one word in `Http.session(client:)`.
  - Only a GET without a `range` is rendered; a POST, a resumable download and an asset go to
    the plain client underneath, carrying the browser's cookies for that host.
  - `tabs:` bounds how many pages render at once — the crawl's `concurrency` is the engine's
    budget, this is the browser's.
  - Added: `BrowserClient`, `BrowserPage`, `BrowserWait`.
- **A page is never lost.** A wait that expires, a script that matches nothing, an
  interstitial that never clears: none of them throw and none of them close the tab. The DOM
  as it stands comes back under the status the server gave it, and the tab returns to the pool
  still on that page — closing it would throw away a challenge somebody is in the middle of
  solving. Only a navigation Chrome refuses outright — a name that will not resolve, a refused
  connection — is still a `ClientException`, which is what the crawl engine retries.
  - `challenge:` is how long a page that answers with an interstitial (Cloudflare's "just a
    moment", a 503 that reloads itself) is given to become the real page, 20 s by default and
    per request with the `BrowserClient.challenge` key. With `headless: false` that wait is
    also a human's chance to click the box.
- **`BrowserPage`: a tab that is worked rather than fetched.** `browser.open(url)` hands one
  over, `browser.page(url, action)` scopes it, and it is outside the pool `send` draws on, so
  holding one open never starves a crawl.
  - `response()` and `html()` answer with the DOM as it stands, at any moment — mid-challenge,
    mid-form, between clicks.
  - `click` lands real mouse events at the element's centre after scrolling it into view, and
    falls back to the DOM's own `click` for an element with no box; `fill` focuses and inserts
    text; `press` sends a key; `scroll` walks an infinite feed until it stops growing.
  - `waitFor` and `waitWhile` watch with a mutation observer and answer `false` on time rather
    than throwing; `eval` runs JavaScript and can await a promise; `screenshot` is a PNG of
    what the window shows.
- **`RequestKey<T>`: a typed directive a client may honour.** The fields of `Request` describe
  HTTP and nothing else; a client that is not HTTP is told the rest with a key, and **ignores
  every key it does not know** — which is what lets one crawl run over either client.
  `request[BrowserClient.waitFor] = '.item'`, read back as `waitFor(request)`.
  - Added: `RequestKey`, `Request.operator []=`; `BrowserClient.waitFor`, `.waitUntil`,
    `.script`, `.direct`.
- **`Client.close` returns `FutureOr<void>`** and `Http.session` awaits it, so an
  implementation that shuts down over a socket is waited for rather than raced. Breaking for
  implementors only in that the signature widened; a `void close()` still satisfies it.
- **`test/client_conformance.dart` checks an implementation against its own server.** The
  promises the rest of the module relies on, written down and executable: a non-2xx is a
  response and not a throw, `url` is the URL that answered, a body arrives as a stream, an
  unknown directive is ignored, `close` is idempotent. Both built-in clients pass it.

## 0.0.2

A conciseness pass over the whole API. Nothing was removed that cannot still be done; four
places where a caller had to say the same thing twice are gone, and about sixty public members
went with them. Every change below is breaking.

### A name is written once

- **CLI options are values, not strings.** `Flag('verbose')`, `Opt.text`, `Opt.number`,
  `Opt.among(name, values)` and `Opt.by(name, parse)` declare an option; `.or(v)` and
  `.required()` guarantee it; `ctx(option)` reads it at the option's own type.
  `Opt.among('algo', Hash.values)` takes the enum itself, so nothing rebuilds it from a string
  with `firstWhere` afterwards. `Opt.by` parses anything — a `DateTime`, a `Uri` — which the
  old four fixed kinds could not.
  - Removed: `CliContext.flag`, `.option`, `.number`, `.optionOrNull`, `.numberOrNull`, `.values`;
    `CliCommand.option`, `.flag`, `.choice`, `.number`; `CliFlag`, `CliValue`, `CliNumber`,
    `CliChoice`.
  - Added: `Flag`, `Opt`, `OptionalOpt.or`, `OptionalOpt.required`, `CliContext.call`,
    `CliContext.given`, and an `options:` argument on `Cli`, `CliCommand` and `command()`.
- **`Client` left eighteen signatures.** `Http.session` is where a program names its client;
  `get`, `post`, `fetch`, `json`, `html`, `xml`, `send`, `download` and `downloadAll` no longer
  take `client:`. Per-request `headers:` stays. A batch download publishes its own client to
  the transfers inside it, so connection reuse is unchanged.

### One shape for one and for many

- **`Path.download` reports `BatchDownloadProgress`**, the same events `downloadAll` reports,
  with a total of 1. `show()` now renders a single download directly; the per-file state is
  `progress.current`. This deletes the one-entry-map workaround `bin/tk.dart` had to write.

### One markup tree

- **HTML and XML share `Node`, `Element`, `Text`, `Attribute`, `Nodes` and `Elements`.**
  `XmlNode`, `XmlElement`, `XmlText`, `XmlAttribute` and `XmlNodes` are gone; `XmlDocument` and
  `HtmlDocument` remain, holding the same tree. `Element.syntax` decides how an element
  serialises.
- **`$` is CSS and `$x` is XPath, on both.** `XmlDocument.$` was XPath and is now CSS, matching
  XML names as written rather than folded; XPath on XML moves to `$x`. XML gains CSS selectors;
  a prefixed name such as `media:content` is not a CSS identifier and needs `$x`.
- **`XPathTree` is gone.** It existed so one engine could walk two trees; with one tree the
  engine walks `Node` directly, and the type parameter is gone from all of `xpath.dart`.
- Renamed on nodes: `outerHtml`/`outerXml` to `markup`, `innerHtml`/`innerXml` to `innerMarkup`.
  `HtmlDocument.outerHtml` and `XmlDocument.outerXml` are unchanged.
- Added: `Elements.texts` and `Nodes.$`, so the two collections answer the same questions;
  `Element.local` and `Element.prefix` now work for HTML too.

### One spelling per operation

- **Digests.** The twenty-one per-algorithm shortcuts (`.md5`, `.sha1`, `.sha256`, `.sha512`,
  `.blake3`, `.crc32`, `.xxh3` on `Path`, `List<int>` and `String`) are removed. `hash(Hash.x)`,
  `hashBytes`, `checksum`, `hmac` and `hmacBytes` are the whole surface, and they cover all
  twenty algorithms rather than five.
- **Tables.** `Io.table` and `Console.table` are removed; `Table.show()` is the only renderer,
  and `Table.cells(headers, rows)` takes the shape those two took.
- **ANSI.** `Ansi` is removed. `Ansi.enabled` is `Io.color` and `Ansi.strip` was `Io.stripAnsi`;
  `Io` now answers every question about the active sink. The string styling getters (`.red`,
  `.bold`, `.stripped`) are unchanged.
- Removed as pure compositions: `Path.gzipTo`, `Path.gunzipTo` (use `compressTo`/`decompressTo`),
  `Table.tsv`, `Table.toTsv` (use `csv`/`toCsv` with `separator: '\t'`).

### Internal

- `scrape`'s `follow` parameters are spelled once, in a `_Plan`, instead of once per hop
  between the hook and the frontier. No API change.

## 0.0.1

First release. A scripting, automation and web-scraping toolkit for Dart, in ten modules
behind one import, with `path` as its only runtime dependency.

### What is in it

- **`core`** — `Either` for settling failures where the caller decides what they mean, `Env`
  with in-memory overrides and `.env` parsing, the `Io` seam every write goes through, the
  `TaskProgress` interface a producer and a renderer meet on, and duration helpers (`60.s`).
- **`async`** — `parallelize` over an iterable or a stream, bounded and settling every task
  into an `Either`; `retry` with backoff, jitter and a predicate; `CancelToken` that composes
  onto any future or stream; `Mutex` and `Semaphore`; `chunk`, `debounce`, `throttle`,
  `delayBy`, `flatMap`, `merge`.
- **`collection`** — `Sequence`, a lazy query over any `Iterable` or `Map` with LINQ's and
  Kotlin's vocabulary, multi-key sorting, joins and grouping; `Table`, rows of named columns
  from maps, records, JSON, CSV, TSV, NDJSON or an HTML table, with pivots and aggregates.
- **`formats`** — JSON, YAML, TOML and INI decode to one `JsonDocument` with JSONPath, so one
  query language serves all four; HTML with CSS selectors (`$`) and XPath (`$x`); XML with
  XPath. Every parser is the package's own and is checked against the package it replaced,
  on real documents, in the test suite.
- **`fs`** — `Path`, an extension type over `String` that goes anywhere a path string does:
  globbing, streaming reads, atomic-ish writes that create their parents, and zip, 7z, rar,
  tar and gz/xz/zstd/bz2 archives with passwords.
- **`hash`** — sixteen digests and four checksums, HMAC, hex/base64/base32, secure random
  tokens and UUIDs, and a constant-time compare. Files stream, so memory is flat.
- **`http`** — `Request`, `Response` and `Client` over `dart:io`; `Http.session` for one
  client, one timeout and default headers across a whole program; atomic resumable downloads
  with progress; and `url.scrape<T>()`, a crawl as five hooks on a chain and a
  `Stream<Either<ScrapeFailure, T>>`.
- **`cli`** — `Cli` with subcommands and four kinds of option, `Console` (tables, rules,
  spinners, single and multi progress, prompts), levelled `Logger`, ANSI styling, signal
  handling and exit hooks.
- **`process`** — `run` with timeouts and stdin, shell-style pipelines with `pipefail`
  semantics, and `which`.
- **`native`** — the loader for `dart_toolkit_native`, one Rust `cdylib` holding the digests,
  MACs and archive formats. `Native.isAvailable` and `Native.reason` say whether it loaded;
  anything needing it throws `UnsupportedError` naming what and why when it did not.

### What is deliberately not in it

- **Cryptography beyond hashing.** No ciphers, password hashing, key agreement, signatures or
  JWT. This package automates scripts; owning that code means owning its failure modes, which
  are silent and expensive. Hashing, HMAC and the encodings stay, because identifying and
  verifying data is what a script does.
- **A Dart fallback for the native library.** Two implementations of one primitive is two
  places for a bug.
- **Aliases.** One name per operation; when two spellings exist, one is deleted.

### Known limits

- **Only `macos_arm64` is prebuilt.** On every other platform the digests and every archive
  call throw `UnsupportedError`. Cross-compiling the other four targets is `PLAN.md` step 1.
- The HTML parser is tag soup with the implicit closes a scraper meets, not an HTML5 tree
  builder. TOML and YAML cover what scripts use, checked against `package:yaml` and the
  system tools rather than against the specifications' own suites.
- Response bodies decode as UTF-8 or Latin-1; `<meta charset>` is not consulted, so a page in
  another encoding comes back with replacement characters.
- There is no cookie store, so anything behind a login needs the header threaded by hand.

### Conventions

`CONVENTIONS.md` records the rules the API follows — call-site brevity first, speed second —
so that additions do not re-create what the audits behind them found.
