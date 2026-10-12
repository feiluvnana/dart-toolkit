# Conventions

**Dead-simple calls; one form for each thing; every part works alone and plugs into every other
through sources and targets.** The package optimises for these, in this order:

1. **How fast it runs:** throughput and memory first, then startup, always measured (§8).
2. **How little a script writes, and how easily its author finds the way**, ranked equal.
3. Coherence, documentation and feature count.

This file states rules. What a release changed is in `CHANGELOG.md`.

---

## 1. Shape

| # | Rule |
|---|---|
| 1 | **Objects first.** Values (`Image`, `Doc`, `Json`) and resources (`File`, `Dir`, `Process`, `Chrome`, `Pool`, `Chan`) are objects you call methods on. A static exists only as an entry point with no value to hold: `Http.get/post/put/delete`, `Task.run`, `Tui.run`, `Cli.*`, `File.temp`/`Dir.temp`/`Dir.script`/`Dir.home`, `File.safeName`, `Task.all`, and the in-memory builders (`Json.parse`, `Html.parse`, `Html.escape`, `Image.decode/empty/fromRgba/formatOf`, `Hash.sha256(data)`, `Archive.zip/unzip/gzip/gunzip`, `Hex`/`Base64.decode`, `Chan.post`). |
| 2 | **One form per operation.** No aliases, no `@Deprecated` names, no backward-compatibility shims. The public names are a reviewed list (`test/api_names.txt`). |
| 3 | **Topic imports.** One public library per topic, and a script imports what it uses. Every topic re-exports core (traits, readings, errors). `lib/` imports only `dart:` and relative paths; shared private code lives once in `src/`. Test seams are in `testing.dart` only. `test/layering_test.dart` enforces the graph. |
| 4 | **The shared interfaces are one list:** `Source`, `Target`, `Reader`, `Writer`, `Closer`, `Seeker`. A module implements them and adds no parallel one. A `Writer.write` copies or pins `data` at the call: the caller may reuse it once the future completes. `Writer.abort` drops a write without completing it (a file's temp is deleted, the old content stays; a resume writer never truncates). A failed `pipe` aborts, never closes. |
| 5 | **Constructors are synchronous and start nothing.** Work starts at the first method: `Process(…)` spawns, `Chrome()` launches and `Http.get(…)` sends on first use. |
| 6 | **`close()` is the only end verb,** and it is idempotent. Nothing is called `cancel`, `kill`, `quit`, `done`, `stop` or `dispose`. Closing a process or a browser kills its whole tree; closing a writer completes its target. |
| 7 | **Values are immutable.** An operation returns a new value: `img.fill(c)`, `doc.drop(css)`, `j['a']`. |
| 8 | **I/O is async, and pure computation in memory is sync.** There are no `…Sync` twins. A reading that does I/O is a method, never a getter (`file.size()`, `file.exists()`). |
| 9 | **The receiver is the source:** `file.copy(dst)`, `dir.pack(zip)`, `file.symlink(link)`, `src.pipe(dst)`. |
| 10 | **Arguments are objects:** `File`, `Dir`, `Source`, `Target`. A path is a `String` only in a constructor (`File('a.txt')`). |
| 11 | **Sources and targets.** Anything readable is a `Source` (a file, a request, a response, a process's stdout, a page, an archive entry); anything writable is a `Target` (a file, a process's stdin). `pipe` opens them. `Reader`/`Writer` are the chunk level beneath, and a script rarely sees them. |
| 12 | **The same readings work on every source, with one meaning each:** `text()` (the whole body as text), `bytes()`, `lines()`, `json()` (a `Json`), `html()` (a `Doc`), `image()` (an `Image`), `hash(algo)`, `unpack(dir)`, `pipe(dst, resume:)`. Each lives in the module of its result type. Readings that return a value chain on its `Future` (`Http.get(u).json()`, `File(p).image().fit(…).save(…)`). |
| 13 | **Building and storing values:** `X.parse(text)` for text, `X.decode(bytes)` for bytes, `x.encode()` back to text or bytes, and `x.save(target)` to store it atomically. |
| 14 | **Requests are lazy.** `Http.get(u)` is sent on its first reading or pipe, so `pipe(file, resume: true)` can ask for the rest with `Range`. `await Http.get(u)` gives the `Resp` (status, headers). |

## 2. Parameters

| # | Rule |
|---|---|
| 15 | **Named parameters only** for options; required arguments are positional (`fit(w, h)`, `Pool(4)`). No option objects or builders, and no optional positional parameters, except a trailing one that lets a tear-off fit a callback (`Bar.set(done, [total])` is an `onProgress`). |
| 16 | **One parameter, one meaning; one behaviour per method.** A mode is a separate method (`text()` vs `check()`), never a flag that switches the algorithm or the result type. An invalid combination or an out-of-range value is an `ArgumentError` at the call. |
| 17 | **No `Object` parameter,** with one exception: data that is text or bytes takes a `String` (UTF-8) or a `List<int>`, checked; anything else is an `ArgumentError`. |
| 18 | **Defaults are one table:** 30 s per response, per browser call and per `wait`; 2 retries on network errors and 5xx; UTF-8; `find`/`all` search descendants only (`matches` tests the element itself); links are never followed. `Duration.zero` never means "none". Environment variables are `DART_TOOLKIT_<NAME>`. |
| 19 | **Callbacks are `on<Event>`** (`onProgress:`, `onPress:`, `onError:`). A progress callback is a display aid, not a status source; every one is `(int done, int total)`, total 0 while unknown, so `Cli.bar().set` fits it. |

## 3. Names

| # | Rule |
|---|---|
| 20 | **The clearest name wins;** a multi-word name is fine when it is clearer. Common abbreviations are allowed: `w`, `h`, `Resp`, `Chan`, `recv`, `attr`, `prev`, `eval`, `html`, `json`, `url`, `id`, `pdf`, `chmod`, `gzip`/`gunzip`, `temp`. |
| 21 | **Getters are nouns, actions are verbs, bools are adjectives or `isX`.** Readings are named for what they return (`json()`, `title()`); widgets are nouns (`ui.box`); colour getters are adjectives (`'x'.red`). |
| 22 | **One word per idea, everywhere:** `or:` (the value when nothing is there, or the default answer), `timeout:`, `retry:`, `headers:`, `resume:`, `selected:`, `label:`, `value`/`max` (progress), `close()`, `text()`. A word never means two things (`print` is stdout, `poll` is a TUI wait). |
| 23 | **A name never repeats its receiver,** and there are no filler verbs. Extensions on core types add no processing: on `String`, only the terminal colours; on `List<int>`, only `hex`, `base64` and `toInt()`. |

## 4. Outcomes and errors

| # | Rule |
|---|---|
| 24 | **`await` means success or throw.** The readings of a request or a process are strict: a non-2xx is an `HttpException(status:)`, a non-zero exit a `ProcessException(code:, err:)`. `check()` answers yes or no instead. |
| 25 | **The error table is complete.** `MissingException(what, where:)`: a reading found nothing. `SecurityException`: refused (an escape, a link, a NUL byte). `NativeException(op, message)`: valid input the native layer failed on. `HttpException(message, uri:, status:, cause:)`. `ProcessException(command, code, err)`. Dart's `FormatException` (invalid content), `TimeoutException`, `UnsupportedError` (no native library, no terminal), and `ArgumentError`/`StateError` for the caller's mistakes only. No other public exception type. |
| 26 | **A bug is never turned into a value.** An `Error` from your code is rethrown as it is. |
| 27 | **Every failure names its subject:** the file, URL, selector, key or command. A wrapper keeps its cause. |
| 28 | **Nothing is swallowed unexplained.** An empty `catch` is typed where it can be and says why on its line; `make catches` refuses one without. |
| 29 | **Retry never repeats what would fail the same way:** an `Error`, a `FormatException`, a `MissingException`, a 4xx. HTTP retries only idempotent requests (GET/HEAD/PUT/DELETE, or a re-readable body such as a `File`): anything else retries only with an explicit `retry:`, and a consumed stream body never retries. |
| 30 | **Exit codes:** usage 64, timeout 124, cannot run 126, not found 127 (a command that can't start is `ProcessException(code: 127)`), ^C 130. |

## 5. Robustness

| # | Rule |
|---|---|
| 31 | **Every write is atomic.** It goes to a temporary sibling renamed over the target (with the Windows held-target retry); an overwrite is a rename-over, never delete-first. A failed write leaves the old content and no temporary file. A move has its destination complete before the source is gone. Only `resume:` writes into a partial file. Every write (and `copy`/`move`) makes the missing folders. |
| 32 | **Nothing lands in the working directory unless asked:** a destination is always given. |
| 33 | **Untrusted archives are contained.** Every member is checked before it is written: absolute paths, NUL bytes, `..` escapes and every link are refused, on the file and stream paths alike. `unpack(dir, trusted: true)` lifts the link refusal and the size cap. A failed stream removes what it created. Output is capped relative to the input, and setuid/setgid don't survive. |
| 34 | **A child never outlives its `close`:** processes and browsers die as a tree on `close` and on a timeout. The library installs no signal handling of its own. |
| 35 | **Parse the real world,** bound every depth, and make an unterminated construct a `FormatException`, never a hang. |
| 36 | **Every wait is bounded:** network, browser and process waits all have a timeout (rule 18). |

## 6. The terminal

| # | Rule |
|---|---|
| 37 | **Two UIs, never mixed:** `Cli` prints inline (prompts, bars, a spinner); `Tui` owns the screen through the `Tui.run` loop (draw, then poll). |
| 38 | **Where lines go:** `Cli.print` writes to stdout; prompts, bars and spinners write to stderr. So `app \| jq` gets only data. While bars are live, every one of these goes through the live region (bars clear, the text writes, bars redraw); a bar is closed in `finally`, or the next print lands under a stale one. |
| 39 | **Live drawing happens only on an ANSI terminal without `NO_COLOR`;** elsewhere a bar prints one line when it ends. ASCII glyphs are used where the terminal can't draw Unicode. Redraws are throttled (a changed line, at most every 80 ms), and end lines say `✓`/`✗`. |
| 40 | **A TUI app is a loop over events,** each named by a noun: `Start`, `KeyPress`, `Paste`, `Pointer`, `Resize`, `Focus`, `Blur`, `Suspend`, `Resume`, `Interrupt`, `Post`. Side effects go through the `Term`: `post`, `listen`, `defer`, `close`. ^C reaches the app, and a second ^C within 2 s always quits. |
| 41 | **One seam per side effect, with a shipped fake,** all in `testing.dart`: `FakeTerminal`, `CliFake`, `BufferReader`/`BufferWriter`, `NativeReset`. |

## 7. Native

| # | Rule |
|---|---|
| 42 | **The native libraries do what Dart can't do fast:** digests, archives and streaming unpack, content decoding, images, file syscalls, the process tree kill, the browser engine, the terminal engine and torrents. There is no Dart fallback: without the library, the call is an `UnsupportedError` saying how to build it. |
| 43 | **One library per subsystem** (`dart_toolkit_native`, `_chrome`, `_tui`, `_torrent`), so an import compiles only the FFI it needs. `dart:ffi` appears only in the seam files. |
| 44 | **One handle protocol.** `tk_x_new` does no long work and returns null with `tk_last_error` on failure. Every call returns ≤ 0 on an error, with the message in `tk_last_error`. `tk_x_free` is idempotent and null-safe. The Dart owner holds a `NativeFinalizer`, and `close()` waits for work in flight. Errors are mapped to the table (rule 25) at the boundary. Long native calls are jobs on native threads (a `Done` listener, a stop byte, throttled progress): a timeout completes with `TimeoutException`, closing the owning resource with `StateError('closed')`. |
| 45 | **An export change bumps its library's ABI** (`exports!(n)` and the Dart constant together), so a stale library is refused at load. |
| 46 | **No binary in git, in the package or in CI.** Libraries are built with `make native` or fetched from the release `native-<hash of native/>`. The loader looks in `native/lib/<os>_<arch>/`, beside the executable, or where `DART_TOOLKIT_NATIVE`, `DART_TOOLKIT_CHROME_LIB` or `DART_TOOLKIT_TUI_LIB` point; `DART_TOOLKIT_CHROME` names the browser executable. Any change to `native/` wants a `make native-release` once committed. |
| 47 | **Native code never spawns a helper process to inspect processes:** dart:io reaps every child of the VM, so the helper's exit races it. Use the OS (libproc, `/proc`); `taskkill` on Windows is the exception. |
| 48 | **Cryptography beyond hashing is out of scope.** |

## 8. Performance

| # | Rule |
|---|---|
| 49 | **Measure back to back, or not at all.** A claim is the median of alternating rounds from one sitting (`tool/module_bench.dart`), measured on a cold `dart run`. |
| 50 | **A topic import costs at most 15 ms of startup over `core`.** A module doesn't import another to add one method, and a reading lives in the module of its result type, so importing `http` doesn't compile the HTML parser. |
| 51 | **Nothing third-party at runtime.** |
| 52 | **Small work stays on the caller; heavy work goes to `Task.run` or a `Pool`.** An isolate is sent only what it needs: a job is a top-level function bound to plain values, never a closure built inside `main`. |

## 9. Tests, docs and release

| # | Rule |
|---|---|
| 53 | **A fixed bug keeps a test that fails before the fix;** a Windows-only change keeps a Windows test. |
| 54 | **Tests are one file per library** (`test/<library>_test.dart`), with groups named for what they test and no upper-bound timing assertions. Tests may import `src/`. |
| 55 | **`make` is the gate** (analyze `--fatal-infos`, format, catch check, tests), run by hand; there is no CI. |
| 56 | **Docs move with the code.** `README.md` is organised by use case (*I want to … → snippet → what to know*), and every README example compiles. A dartdoc says what the signature can't (what it throws, its defaults, when work starts). An API change updates README, CHANGELOG and, where it is a rule, this file, in the same change. |
| 57 | **The repo keeps rules and releases, not process.** A decision becomes a rule here, and a change becomes a CHANGELOG entry. One `PLAN.md` may exist while its work is open, and is deleted when that work is done; audits, proposals and reports never live in files. |
| 58 | **`example/` holds real scripts on the public API only.** They are analyzed and formatted, not tested. |
| 59 | **The version number is the owner's.** |
