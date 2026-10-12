# PLAN — hardening after the redesign

The redesign (see CHANGELOG `Unreleased`) shipped. Then a review of the whole library, with probes
run against the real code, found about 60 problems. Some lose data or crash the process, some cost
throughput by two orders of magnitude, and some break the API's own rules. This plan fixes all of
them.

Every design decision is made (§1). **Do not redesign.** Where this plan is unclear, CONVENTIONS.md
is the authority. When a question can't be answered from either, stop and ask the owner. Don't
guess.

---

## 0. Rules for the executor

| # | Rule |
|---|---|
| X1 | **Phase by phase, in order.** Each phase ends with `make` green (analyze `--fatal-infos`, format, catch check, tests). Never start a phase while the gate is red. |
| X2 | **Every fix has a regression test that fails before the fix** (CONVENTIONS rule on fixed bugs). Name the test after the behaviour, not the item number. Put it in `test/<library>_test.dart`. |
| X3 | **Reproduce first.** Each item gives the evidence the review saw. Turn that evidence into the failing test, *then* fix. If you can't reproduce an item, say so in the report and skip it; don't fix blind. |
| X4 | **No backward compatibility.** Rename and delete outright. Update README, CHANGELOG (`## Unreleased`) and CONVENTIONS (when a rule changes) in the same phase. |
| X5 | **Don't commit or push** unless the owner says so. If they allow it: one commit per phase, `fix: <phase title>` / `perf: …` / `feat!: …`, with no trailer. |
| X6 | **Native edits:** run `make native` after each one. An export change bumps that library's ABI (`exports!(n)` and the Dart constant together). End the report with "run `make native-release`". |
| X7 | **Measure perf claims back to back** (old vs new in one sitting, medians). Each perf item states its target; report the before and after numbers. |
| X8 | **Probes** go in `example/_probe/` and are deleted before the phase ends. |

---

## 1. Decisions (owner, 2026-10-12)

| # | Decision |
|---|---|
| N1 | **Long native work runs on native threads** and reports back through a Dart `NativeCallable.listener`. Nothing that can take more than ~1 ms blocks the event loop. `onProgress:` and stopping (via the existing stop bytes) come with it. Short in-memory calls stay synchronous. |
| N2 | **`Resp` becomes `Response`.** |
| N3 | **Decouple the startup regressions** with small interfaces in core: `process` stops importing `fs`, and `tui` stops importing `image`. The APIs stay the same. |
| N4 | **annasarchive shows a visible Chrome window** when the site's browser check doesn't pass headless. The user clicks once; the kept profile lets later runs pass headless. |
| N5 | **Console look: "minimal line"** (§7 shows the exact output). It honours `NO_COLOR` and pipes, throttles redraws, and ends lines with `✓`/`✗`. |
| N6 | **HTTP retries only idempotent requests:** GET/HEAD/PUT/DELETE, or a body that can be re-read (a `File`). Exponential backoff, honouring `Retry-After`. A POST is retried only when `retry:` is passed explicitly. |
| N7 | **Archives refuse every link member** on both paths (file and stream). `trusted: true` lifts that and the size cap. |
| N8 | **`find`/`all` search descendants only,** like `querySelector`. `matches` tests the element itself. |
| N9 | **Implement `Suspend`/`Resume`** on POSIX: ^Z restores the terminal and stops; `fg` re-enters and redraws. |
| N10 | **`unpack(dir, trusted: true)`** is the escape hatch, and the cap's error message names it. |
| N11 | **`Image.fit` never enlarges;** `resize` does. |
| N12 | **`Json.get<T>`:** int and double convert to each other; any other type mismatch is a `FormatException` naming the path and both types. `or:` covers only a missing value and is typed `T?`. |

**Settled by me** (the owner can overrule any of them):

| # | Decision |
|---|---|
| M1 | `Chan(cap)` requires `cap >= 1` (an `ArgumentError` otherwise). A rendezvous channel isn't worth its own mode. |
| M2 | `Response.headers` is an unmodifiable `Map<String, List<String>>`; `header(name)` gives the first value. |
| M3 | `Process.kill` goes (`close()` is the end verb). `pid` and `exitCode` become private; `wait()` gives the outcome. |
| M4 | `Image.decode` becomes synchronous (in-memory parsing is sync). |
| M5 | `digest.toInt()` throws `StateError` for digests over 8 bytes. |
| M6 | The `Element` constructor becomes private, so a script can't build an unwired tree. The synthetic `#document` root never appears in results. |
| M7 | An unknown pseudo-class is a `FormatException` naming it. |
| M8 | `Cli.choose` picks with the arrow keys on a terminal (pure Dart raw stdin, no TUI import); piped, it falls back to numbered input. |
| M9 | `BufferReader`/`BufferWriter` become a `Source`/`Target`, so tests can pipe through them. |
| M10 | `html`'s `Text` and `Node` keep their names: HTML is the only DOM now. |
| M11 | Stopping a native job: a timeout completes it with `TimeoutException`; closing the resource that owns it completes it with `StateError('closed')`. The error table gets no cancel type. |

---

## 2. Phase 1 — data loss and crashes (do these first)

Each item: **Where** · **Problem** (with the review's evidence) · **Fix** · **Test**.

### 1.1 `pipe` corrupts every file bigger than 64 KiB
- **Where:** `lib/src/core/pipe.dart` (`pipe` loop), `lib/src/fs/io.dart` (the File writers), `lib/src/process/process.dart` (the stdin writer).
- **Problem:** `pipe` reuses one 64 KiB chunk for every read. The writers call `IOSink.add` on a *view* of that chunk and return without waiting, so the next read overwrites bytes that haven't been written yet. Evidence: a 50 MB File piped into a File came out with **47,393,508 differing bytes** (re-verified). A File piped into `Process('shasum')` gave the wrong digest.
- **Fix:** File writers use `RandomAccessFile.writeFrom` and await it (it copies at the call, and the await gives backpressure). The Process stdin writer adds `Uint8List.fromList(data)` and awaits `flush()` every 1 MiB. **The `Writer.write` contract:** the caller may reuse `data` once the future completes. Write that into the `Writer` doc.
- **Test:** pipe 8 MiB of random bytes File→File, File→`Process('cat')`→File, and `BufferReader`→File, then compare bytes.

### 1.2 A failed `pipe` replaces the old file with partial content
- **Where:** `pipe.dart` (the `finally` calls `w.close()`), `io.dart` (`_AtomicWriter.close` renames).
- **Problem:** a source that throws after 3 chunks turned `OLD CONTENT` into 196,608 bytes of `A`. Also, `dst.writer()` is opened outside the `try`, so the reader leaks when it throws.
- **Fix:** add `abort()` to `Writer` (temp file deleted, no rename; for others it is the same as close). `pipe` opens both ends inside the `try`, calls `close()` only on success, and `abort()` on error. A resume writer (append mode) never truncates on abort.
- **Test:** a source that throws mid-way leaves the old content and no temp file. `file.pipe(Process(...), resume: true)` (an ArgumentError) leaves no open reader: the source's `close` was called.

### 1.3 `Archive.zip` double-free and panic
- **Where:** `lib/src/archive/archive.dart` (`Archive.zip`: `catch (_) { packFree(h) }`), `native/engine/src/archive.rs` (`tk_archive_pack_finish` takes ownership before it can fail; `pack_add` with a name over 65535 bytes).
- **Problem:** finish fails → Dart frees again → the process aborts (exit 134). `Archive.zip({'x'*70000: …})` panics inside the zip crate (non-unwinding) and aborts the process.
- **Fix:** a `finished` flag, so `packFree` runs only when finish was never called. `tk_archive_pack_add` rejects names over 65535 bytes with an error; Dart maps it to `ArgumentError`.
- **Test:** an invalid member name (`'../x'` in a tar) throws, and the process lives on; a 70,000-byte name throws `ArgumentError`.

### 1.4 Streaming unpack: valid tars fail, and real errors are hidden
- **Where:** `archive.rs` (`unpack_stream` tar branch, `push`), `archive.dart` (`SourceUnpack.unpack`).
- **Problem:**
  - The worker returns at the end-of-archive block and drops the receiver, so trailing padding (10 KiB is standard) or the gzip trailer is refused with "the worker already failed". A valid tar fed in 512-byte chunks fails.
  - Any mid-stream failure (zip-slip, absolute path, link) surfaces as `FormatException … worker already failed`, never `SecurityException`, because Dart never calls `finish`, which holds the real error.
- **Fix:** after a successful extract, the worker drains `input` to EOF into `io::sink()`. When `tk_unpack_write` sees a closed channel, it joins the worker and sets the worker's message as the last error. Dart maps that through `_archiveError` (so `SecurityException` stays `SecurityException`).
- **Test:** a tar with 10 KiB of padding, streamed in 100 B / 512 B / 4 KiB chunks with a 2 ms delay, succeeds. `../evil.txt`, `/abs` and a link member, streamed in 100-byte chunks, each throw `SecurityException`.

### 1.5 One link rule for both unpack paths (N7) and no partial output on failure
- **Where:** `archive.rs` (`extract_tar`, `extract`), `archive.dart` (`_unpackFile` pre-check).
- **Problem:** File unpack refuses links; stream unpack allows in-root links. A streamed `../evil.txt` leaves `ok.txt` behind; a source failing at 60% leaves a 1.9 MB partial member.
- **Fix:** both paths refuse every symlink/hardlink member unless `trusted: true` (N10: add the parameter, which sets `TRUSTED`). A streamed unpack records the paths it created and removes them when it fails. Correct the size-cap message to name `trusted: true`.
- **Test:** an archive with `b → a.txt` is refused from a File and from a stream, and accepted with `trusted: true`. A stream failing mid-way leaves the destination as it was.

### 1.6 `Process` hangs
- **Where:** `lib/src/process/process.dart`.
- **Problem and evidence:**
  - (a) `line()`/`lines()` spin at 100% CPU when stdout ends without a newline (`printf abc; sleep 1; printf "def\n"`), because `_more()` returns at once whenever the buffer is non-empty.
  - (b) `input:` over the pipe buffer deadlocks (`cat` with 10 MB input), and small input to a process that exits early throws `SocketException: Broken pipe`.
  - (c) `text()`/`lines()` never close stdin, so `Process('cat', []).text()` hangs.
  - (d) `errors()` after stderr has ended hangs.
  - (e) `close()` after a normal exit still runs the tree kill on a pid that may already be reused.
- **Fix:**
  - (a) `_more()` waits for *new* data unless stdout is done (track bytes seen).
  - (b) Start the stdout and stderr pumps before writing `input`; write it concurrently; treat EPIPE as "the child stopped reading".
  - (c) Readings close stdin first, unless a writer was taken.
  - (d) `errors()` yields the buffered tail and ends when the stderr pump is already done.
  - (e) Skip the kill once the exit code has completed.
- **Test:** one test per hang, each with a 5 s test timeout so a hang fails rather than blocks. `Process('sort', [], input: 10 MB)` returns. `Process('true', [], input: 1 MB).check()` is true.

### 1.7 `Task.run`, `Pool` and `Chan` hangs and leaks
- **Where:** `lib/src/async/task.dart`, `pool.dart`, `chan.dart`.
- **Problem and evidence:**
  - `Task.run(() => ReceivePort())` (an unsendable result) hangs forever, and so does a job with an uncaught async error.
  - `Pool` leaks a dead worker's ports (`_onGone` never disposes them), so the script never exits after `close()`.
  - `Chan`:
    - `Chan<int?>` drops `null`.
    - `Chan.post` after `close()` hangs.
    - Cancelling a `recv()` subscription while it waits hangs, and the orphaned waiter swallows the next `send`.
    - `Chan(0)` is unbounded.
- **Fix:**
  - `Task.run` listens on the isolate's `onExit`/`onError` and completes with a `StateError` (unsendable result) or the remote error and its stack.
  - `_onGone` calls `dispose()`.
  - `Chan`:
    - Use a private sentinel, not `null`, for closed.
    - Keep the port open after close and answer `false`.
    - Build `recv()` on a `StreamController` whose `onCancel` removes its waiter.
    - M1: `Chan(0)` is an `ArgumentError`.
- **Test:** each case returns or throws within 5 s; a script with a crashed `Pool` worker exits after `close()` (`Process('dart', [probe]).check()` within 10 s).

### 1.8 `Native.ok` lies
- **Where:** `lib/src/core/native.dart`, `native_status.dart`.
- **Problem:** with `DART_TOOLKIT_NATIVE=/nonexistent.dylib`, `Native.ok` is `true`. It only checks the seams already used, so in a fresh script the answer is vacuously true.
- **Fix:** `Native.ok` loads the engine itself, and checks the chrome and tui library files exist (by path, without compiling their seams), reporting the first missing one in `reason`.
- **Test:** the env var pointing at a missing file gives `ok == false` and a `reason` naming it.

### 1.9 Chrome closes the user's tabs; a failed launch leaks a profile
- **Where:** `lib/src/chrome/chrome.dart` (`pages()`, the finalizer), `native/chrome/src/cdp.rs` (`tk_cdp_release_page` does `PUT /json/close/<id>`), `chrome.dart` launch.
- **Problem:** pages from `Chrome(port:).pages()` closed the owner's 3 tabs when the script exited. A failed launch leaves its temp profile (11 left in `$TMPDIR`).
- **Fix:** a page carries `owned`, true only when `open()` created it. Release closes the tab only when owned; otherwise it frees the struct. Delete `dir` when the launch fails and the profile is owned.
- **Test:** with an owner process holding 3 tabs, a second script calls `Chrome(port:).pages()` and exits; the owner still sees 3 tabs. A launch with a bogus `executable` leaves no new `tk_chrome_profile_*` dir.

### 1.10 `doc.drop()` builds a tree that crashes
- **Where:** `lib/src/html/dom.dart` (`_copyExcept`; `parent` is `late final`).
- **Problem:** on `Html.parse('<div><p>x</p><script>s</script></div>').drop('script')`, `.all('section p')`, `:root` and `*:first-child` all throw `LateInitializationError`.
- **Fix:** `parent` is a nullable field set once by `_wire`. `drop` wires the copy (`_wire(copy, src.parent)`). M6: make the `Element` constructor private.
- **Test:** every selector of the selector test table runs on a `drop()`ed doc.

### 1.11 HTML serialisation corrupts markup
- **Where:** `dom.dart` (`Text.toString` returns raw data; `Element.toString`; `_escapeAttr`).
- **Problem:** `<p>a &lt;b&gt; &amp; c</p>` serialises as `a <b> & c`, and reparsing creates a `<b>` (an injection path when saving scraped content). Void tags come out as `<br></br>`. The doctype and comments are dropped. Attributes escape `"` but not `&`.
- **Fix:** escape `& < >` in text (not inside `script`/`style`/`textarea`/`title`), and `& "` in attributes. Void elements have no closer. Keep the doctype.
- **Test:** `parse(x).html` reparsed gives the same tree, for a fixture with entities, void tags, script content and attributes containing `&` and `"`.

### 1.12 The HTML parser misreads `<` and `>`, and crashes on bad entities
- **Where:** `lib/src/html/parser.dart`.
- **Problem:**
  - `<p>1 < 2 and 3 > 2</p>` creates an element named `2`.
  - `<a title="x>y">` ends the tag at the quoted `>`.
  - `&#99999999;` throws `RangeError` out of `Html.parse`.
  - `&#0;` gives NUL.
  - Only 11 named entities are known (`&rsquo; &eacute; &euro;` stay literal).
- **Fix:**
  - A tag starts only at `<` followed by a letter, `/`, `!` or `?`.
  - The tag scan skips quoted attribute values.
  - Invalid or out-of-range code points and lone surrogates become U+FFFD.
  - Ship the full HTML5 named-entity table as a `const Map` in `lib/src/html/entities.dart` (generated once by a script you run by hand; commit the table, not the script).
- **Test:** each case above, plus `Html.parse` of `test/fixtures/hn.html` is unchanged.

### 1.13 HTTP: timeouts, retries, double reads, leaks, redirects, resume
- **Where:** `lib/src/http/http.dart`.
- **Problem and evidence:**
  - (a) The timeout doesn't cover the body: a server that stalls after the headers made `.text()` take 4 s with `timeout: 1s`. A timeout surfaces as `HttpException`, not `TimeoutException`. Error messages repeat the URL ("… from URL from URL").
  - (b) A retry re-sends an already-consumed body (data lost silently), and POST is retried with no backoff.
  - (c) Reading a `Request` twice gives `''` the second time.
  - (d) An awaited-but-unread `Response` leaks its socket and `HttpClient` (`if ((await Http.get(u)).ok)` leaks one each time).
  - (e) After a redirect, `url` is relative (`/final?q=1`).
  - (f) Resuming a complete file throws on the server's 416. A 206 whose `Content-Range` start differs from the request isn't checked.
  - (g) `lengthHint` reports the *compressed* length after dart:io gunzips.
- **Fix:**
  - (a) The timeout applies to each `moveNext()` of the body as well. Rethrow `TimeoutException` unwrapped. Drop "from $url" from the messages (`toString` adds it).
  - (b) N6: retry only idempotent methods or a re-readable body; backoff `250 ms × 2^attempt` with jitter; honour `Retry-After` (seconds or HTTP date, capped at 30 s).
  - (c) A second `reader()` on the same `Request`/`Response` throws `StateError('body already read')`.
  - (d) A non-2xx `Response` releases its connection once the status is read. Add a `Finalizer` that releases an unread body.
  - (e) Resolve each redirect hop against the previous URL.
  - (f) A 416 whose `Content-Range: */N` equals the local size is "already complete" (0 bytes copied). Check that a 206's `Content-Range` start equals `from`, else `HttpException`.
  - (g) `lengthHint` is null when `content-encoding` is set.
- **Test:** one per letter, against a local `io.HttpServer`.

### 1.14 `Json` equality and its hash disagree
- **Where:** `lib/src/json/json.dart` (`_deepHash` is order-sensitive while `_deepEquals` isn't).
- **Problem:** `{"a":1,"b":2}` and `{"b":2,"a":1}` are equal but hash differently.
- **Fix:** hash map entries with `Object.hashAllUnordered`.
- **Test:** both are equal, have equal hashes, and make a one-element `Set`.

### 1.15 `File.write` resets mode bits and replaces symlinks
- **Where:** `io.dart` (`write`, `_AtomicWriter`).
- **Problem:** a 0755 script becomes 0644 after `write`. Writing through a symlink replaces the link with a regular file.
- **Fix:** before the rename, give the temp file the target's mode (`stat`, then `chmod` through the native call). When the target is a link, resolve it and write next to the real file.
- **Test:** POSIX-only: the mode is kept after `write`, and a link is still a link and its target holds the new content.

### 1.16 Already fixed while checking the examples: add their tests
These landed in the working tree before this plan. They need regression tests only:
- **HTTP bodies decode in their declared charset** (`Content-Type`, else `<meta charset>`, else UTF-8) through the native WHATWG decoder (`lib/src/core/decoding.dart`, `http.dart _decodeBody`, `core/native.dart decodeCharset`). Test: a local server serving EUC-KR and Shift_JIS bodies, with the charset in the header and with it only in `<meta>`; `text()` and `html()` give the right characters.
- **Chrome hides automation marks** (the `--disable-blink-features=AutomationControlled` launch flag and the per-navigation stealth script in `native/chrome/src/cdp.rs`). Test: `await page.eval('navigator.webdriver')` is not `true`, on a `data:` URL page.

### Verify
```sh
make        # green, with every new test
```

---

## 3. Phase 2 — throughput

Targets are measured back to back against the previous commit (X7).

| # | Where | Problem (evidence) | Fix | Target |
|---|---|---|---|---|
| 2.1 | `http.dart` `Response.read` | a `List<int>` carry trimmed with `removeRange`: 200 MB from localhost took 13,360 ms with `pipe` vs 101 ms with plain dart:io | keep the current `Uint8List` and an offset; `buf.setRange(0, n, chunk, off)` | within 2× of plain dart:io |
| 2.2 | `http.dart` | a new `HttpClient` per request means no keep-alive (200 GETs: 135 ms on 200 sockets vs 31 ms on 1) | one shared client per isolate, `idleTimeout` 15 s | 200 GETs on 1 socket |
| 2.3 | `process.dart` stdout buffer | `List<int>`, `removeRange` from the front, `indexOf` from the start each line: `text()` on 100 MB took 1046 ms vs 106 ms | a queue of `Uint8List` chunks with a head offset; the newline search resumes where it stopped | within 2× of `io.Process.run` |
| 2.4 | `pool.dart` | `_queue.removeAt(0)` is quadratic (80k items: 6.6 s) | `ListQueue` | linear: 80k in under 1 s |
| 2.5 | `pipe.dart` `lines()` | ignores cancellation and reads the whole source after a `break`; buffers a whole HTTP body even when it is UTF-8 | a controller with `onCancel`/`onPause`; stream through `utf8.decoder` unless the charset is a legacy one | a `break` after line 1 stops reading; NDJSON lines arrive as sent |
| 2.6 | `parser.dart` `_indexOfIgnoreCase` | lowercases the whole document per script/style element (a 5 MB page with 29k scripts: 77 s) | lowercase once per parse, or compare in place at each `</` | the same page in under 0.5 s |
| 2.7 | `dom.dart` `prev`/`next`/`:nth-child`/`+`/`~` | rebuild the children list and run `indexOf` per call, so they are quadratic (34k siblings, `div:first-child`: 34.7 s) | store each element's sibling index and cache the element-children list at wiring | under 100 ms |
| 2.8 | `json.dart` `Json.parse` | deep-copies after `jsonDecode` (20 MB: 540 ms vs 215 ms) | wrap the decoded maps in `UnmodifiableMapView`/`UnmodifiableListView` lazily, without a second copy | within 1.3× of `jsonDecode` |
| 2.9 | `archive.rs` zip/7z stepper and `write_file` | each `next` reopens the zip and decompresses whole members, skipped ones included (2000 × 100-byte entries: `unzip` 10.2 s); a 600 MB member raises RSS from 264 MB to 822 MB | keep the open archive and index in the Stepper; decompress lazily in `entry_read`; `write_file` streams with `io::copy` through a writer capped at the limit | `unzip` of the same archive under 0.3 s; RSS stays flat |
| 2.10 | `image.dart` `blur`/`resize`/`fit`/`crop` | pure Dart: box blur `blur(10)` on 2000×1500 took 4.5 s; nearest-neighbour resize aliases | call the existing native `tk_image_blur`/`resize` (Lanczos3)/`crop` through the RGBA handle | `blur(10)` under 200 ms |
| 2.11 | `cli.dart` `Bar.set` | redraws on every call (200k `set`s wrote 21.9 MB) | redraw only when the rendered line changes, at most every 80 ms, plus a final draw | 200k `set`s write under 50 KB |

---

## 4. Phase 3 — native work off the event loop (N1)

### 3.1 The job protocol (in `native/common`, shared by every library)

```rust
/// A long call's outcome, held until Dart takes it.
pub struct Job { rc: i32, out: Vec<u8>, err: String }

pub type Done = extern "C" fn(job: *mut Job);                     // called from the worker thread
pub type Progress = extern "C" fn(id: i64, done: u64, total: u64);

/// Runs `work` on a thread from a small shared pool (num_cpus, at least 2), then calls `done`.
pub fn spawn(done: Done, work: impl FnOnce() -> Result<Vec<u8>, String> + Send + 'static);

#[no_mangle] pub unsafe extern "C" fn tk_job_rc(j: *mut Job) -> i32;
#[no_mangle] pub unsafe extern "C" fn tk_job_take(j: *mut Job, out: *mut *mut u8, len: *mut usize) -> i32; // `give` buffer
#[no_mangle] pub unsafe extern "C" fn tk_job_error(j: *mut Job, buf: *mut u8, cap: usize) -> i32;
#[no_mangle] pub unsafe extern "C" fn tk_job_free(j: *mut Job);
```

Each long export gets an async form and **the blocking one is deleted** (one way to do each
thing): `tk_x(args…, done: Done, stop: *const u8, progress: Progress, id: i64) -> i32`. It returns
0 once queued and <0 if the arguments are invalid. The error stays on the `Job`, never in the
thread-local last error, because the work ran on another thread.

On the Dart side there is one helper, `lib/src/core/jobs.dart`, used by every seam:

```dart
/// Runs a native long call: [start] queues it with the listener's pointer and a stop byte; the
/// future completes when the native thread calls back. The listener keeps the isolate alive only
/// while jobs are in flight (`keepIsolateAlive` switched on with the first job, off after the last).
Future<Uint8List> nativeJob(
  String op,
  int Function(Pointer<NativeFunction<DoneFn>> done, Pointer<Uint8> stop, int id) start, {
  void Function(int done, int total)? onProgress,
  Duration? timeout,
});
```

The stop byte is a `Pointer<Uint8>` allocated per job. M11: a timeout sets it and completes with
`TimeoutException`; closing the owning resource sets it and completes with `StateError('closed')`.

### 3.2 What moves

| Library | Calls that become jobs |
|---|---|
| `dart_toolkit_native` | `tk_archive_create`, `tk_archive_extract`, `tk_archive_list`, `tk_unpack_finish` (and `tk_unpack_write` when the queue is full), `tk_digest_file`, `tk_copy_file`, `tk_rename` (Windows retry sleeps), `tk_image_load_memory`, `tk_image_encode_memory`, `tk_compress`/`tk_decompress` over 1 MiB |
| `dart_toolkit_chrome` | every `tk_cdp_*` call except `alive`/`free`/`release` |
| `dart_toolkit_tui` | `tk_tui_poll` becomes `tk_tui_listen(event_fn)`: a reader thread pushes each event through a listener. `Term.poll` awaits the next event from a Dart queue that `post`/`listen` also feed, so a post wakes a waiting poll at once |

Bump the ABI of all three libraries.

### 3.3 `onProgress:`
Add `onProgress: void Function(int done, int total)` to `dir.pack`, `source.unpack`,
`file.hash`, `file.copy` and `file.move`. It is fed by the native progress callback, throttled to
every 50 ms on the native side.

### 3.4 Tests
- A 5 ms `Timer.periodic` keeps ticking (worst gap under 50 ms) during `Dir.pack` of 200 MB, `File.hash` of 500 MB, and a `page.navigate`.
- `term.post(1)` is received by a `poll()` within 50 ms (real backend, under `script` in a pty test that is skipped when no pty is available).
- `onProgress` is called at least twice for a 200 MB pack and ends at `total`.

---

## 5. Phase 4 — the TUI

| # | Where | Problem (evidence) | Fix | Test |
|---|---|---|---|---|
| 4.1 | `term.dart` | after a double ^C or `term.close()`, `poll` returns `null` forever (null also means a timeout), so the documented loop spins and never restores the terminal; on the real backend, the next `draw` throws "null handle" | once closed, `poll` and `draw` throw a private `_Closed` that `Tui.run` swallows; `close()` only sets the flag, and teardown happens in `Tui.run`'s `finally` | FakeTerminal: two `interrupt()`s end `Tui.run` within 100 ms and restore the terminal |
| 4.2 | `term.dart` defer/listen | a failing `defer` or a `listen` stream error goes through `Zone.handleUncaughtError` (fatal) before the terminal is restored | collect cleanup errors, close the backend, then rethrow the first; `listen`'s default `onError` delivers the error from the next `poll` | the terminal is restored and the error reaches the caller |
| 4.3 | `term.dart:79,228` vs `native/tui/src/term.rs` | Dart binds `tk_tui_start` with 3 arguments `(80, 24, pointer)`, but Rust takes `(mouse: u8)`, so the mouse is always captured | bind `Pointer<Void> Function(Uint8)` and pass `pointer ? 1 : 0` | `pointer: false` emits no `\e[?1000h` |
| 4.4 | `native/tui/src/term.rs:234` | wheel up and down are swapped | swap 4 and 5; fix the doc comment | SGR `\e[<64;…M` → `scrollUp` |
| 4.5 | `term.dart`, `term.rs` | N9: ^Z arrives as `ctrl+z`, and Suspend/Resume are never produced | POSIX: on ^Z, emit `Suspend`, restore the terminal, `SIGTSTP` self; on `SIGCONT`, re-enter raw mode, emit `Resume`, full redraw. Windows: ^Z stays a key | FakeTerminal sees Suspend then Resume; a pty test checks the mode is restored |
| 4.6 | `term.dart` click routing, `canvas.dart` popup | clicks go through popups to buttons behind them | hit-test clickables in reverse paint order; a popup registers a rect that swallows clicks | a tap on an empty popup row fires nothing behind it |
| 4.7 | `canvas.dart` markdown | each inline run goes on its own row | write runs on the same row, advancing x, and wrap the combined line | `'Hello **world** and \`code\`'` is one row |
| 4.8 | `width.dart`, `buffer.dart Grid.write`, `FieldState`, `FakeTerminal.type` | whole symbol ranges count as wide (`✓` is 1 column, the grid says 2); ZWJ sequences, skin tones and flags count per rune; field backspace splits graphemes; a field doesn't scroll; `type` splits surrogate pairs | East-Asian-Width + Emoji_Presentation tables (generated once, committed as const data); a grapheme cluster (ZWJ, modifier, regional pair, combining mark) is one cell; edit by grapheme; scroll the field to keep the cursor in view | the width table from the review (`✓ ok\|`, `🇯🇵 x\|`, `👨‍👩‍👧 x\|`, `👍🏽 x\|`, `日本 x\|`) matches the terminal column |
| 4.9 | `tui.dart` exports | internals reachable: `Canvas(Grid)`, `grid`, `bounds`, `clickables`, `paintOverlays`, `Term(TermBackend)`; `colorLevel` is typed `ColorLevel`, which isn't exported, so `FakeTerminal(colorLevel:)` can't be called | private constructors and fields; export `ColorLevel` from `testing.dart` only | the names list shows none of them |
| 4.10 | `canvas.dart` | `box()` has a flat form plus `end()` (two ways); `tabs(selected:)` is required while `list(selected:)` defaults to 0 | keep only `box(build:)`; `selected` defaults to 0 everywhere | README's TUI example uses `box(build:)` |
| 4.11 | docs | `term.dart:1-23` mentions `Term.quit` and the Tui statics; the `Interrupt` doc is wrong; the `listen` doc is wrong; the Canvas doc says `sel` | rewrite them to the current behaviour | — |

---

## 6. Phase 5 — API and developer experience

| # | Where | Change |
|---|---|---|
| 5.1 | http | N2: `Resp` → `Response` everywhere (code, tests, README, CHANGELOG). M2: `headers` is an unmodifiable `Map<String, List<String>>`; `header(name)` is the first value. Remove `reason` from the public surface (it's in the error message). `decode()` stays internal (`Decoding` isn't exported) |
| 5.2 | html | N8: `find`/`all` search descendants only. M6: the `Element` constructor is private, and `#document` never appears in results (`doc.find('*')` is the `<html>` element). M7: an unknown pseudo-class is a `FormatException`; `:has(> li)` honours `>` |
| 5.3 | json | N12: `get<T>` converts int↔double; any other mismatch is a `FormatException('price is a String, not a double')`; `or:` is `T?`. `Json(value)` validates (only null, bool, num, String, List, Map with String keys), else `ArgumentError`. `get('')` returns the root value; a key containing `.` is reached as `get(r'a\.b')` |
| 5.4 | image | N11: `fit` never enlarges. Immutability: store a copy of `rgba` and expose it as `asUnmodifiableView()`; `fromRgba` copies. `pixel` is bounds-checked (`RangeError`). M4: `Image.decode` is synchronous. `save` maps `.tif`/`.tiff` to TIFF; any other unknown extension is an `ArgumentError`. JPEG/BMP drop alpha: document it on `encode` and `save` |
| 5.5 | archive | `dir.pack(File('x.rar'))` and `.7z` are an `ArgumentError` (formats it can't write); `Dir.pack(File('one.gz'))` is an `ArgumentError` (a directory needs a container). Validate `level` (0–9) in Dart. Every native failure goes through `_archiveError`: `Archive.unzip(garbage)` is a `FormatException`; `File('nope.zip').unpack` is a `PathNotFoundException` |
| 5.6 | hash | M5: `toInt()` throws `StateError` when `length > 8`. `source.hash` opens the native digest only after `reader()` succeeds, and frees it in `finally` |
| 5.7 | archive | `_EntryReader` gets a `NativeFinalizer` for its stepper; `source.unpack` opens the native sink inside the `try` |
| 5.8 | process | M3: remove `kill`; make `pid` and `exitCode` private. `ProcessException.command` and `Process.cmd` become one name: `command` on both |
| 5.9 | path | `File.text()` on malformed UTF-8 is a `FormatException` (decode the bytes yourself). Windows: `_isCrossVolume` also matches os error 17. M9: `BufferReader`/`BufferWriter` are a `Source`/`Target` |
| 5.10 | async | `Chan.len` goes (it's not in the surface); M1 |
| 5.11 | chrome | Stealth: the UA override is per session and wears off. Instead, read the version with `exe --version` before launching and pass `--user-agent=` with `HeadlessChrome` replaced by `Chrome`. Eval errors show `exception.description`, not the raw JSON. `page.html()` needs `html.dart`: say so in the chrome dartdoc |
| 5.12 | startup (N3) | core gets `abstract interface class Located { String get path; }` (implemented by `File` and `Dir`) and `abstract interface class Frame { int get w; int get h; Uint8List get rgba; }` (implemented by `Image`). `Process(dir:)` takes `Located`; `Canvas.picture` takes `List<Frame>`. Remove the `fs` import from `process.dart` and the `image` import from `canvas.dart`. **Target:** `process` and `tui` back to their old cost (measured back to back with the old commit: today `process` is +74 ms over core vs +57 before, `tui` +118 vs +95) |
| 5.13 | docs | `lib/core.dart` still says "the universal pipe primitive" between Reader and Writer; `lib/path.dart` says "one-word methods". Rewrite both to the current API |

---

## 7. Phase 6 — the console look (N5)

### 6.1 What it prints

On a terminal, with colour:
```
⠹ Downloading  ━━━━━━━━━━━━╸──────────  50%  50.0/100 MB · 12.3 MB/s · 4s left
✓ Downloading  100 MB in 8.1s
✗ Extracting   failed: not a tar stream
? Proceed? (y/N)
? Pick one
  ❯ alpha
    beta
```

| Part | Style |
|---|---|
| Spinner frame, `?`, `❯` and the filled bar | accent: 256-colour 173 (`TuiColor.rgb(217,119,87)` on truecolor) |
| Bar track `─`, details (`50.0/100 MB · 12.3 MB/s · 4s left`), the hint `(y/N)` | dim |
| `✓` | green |
| `✗` and the failure text | red |
| Label | plain |

Labels are padded to the longest live label, so bars line up.

- **Without a terminal, or with `NO_COLOR` set:** no live region and no SGR. Each bar prints one line when it ends: `✓ Downloading  100 MB in 8.1s` (`ok`/`failed` instead of `✓`/`✗` when the terminal can't draw Unicode). Prompts print plain.
- **Units:** with `unit: 'B'` (bytes), values are shown human-readable (`50.0/100 MB`), plus a speed and an ETA from one meter (an EWMA over 3 s). With other units, `50/100 items`.
- **At 0%,** no `╸` head: the bar is all track.

### 6.2 Behaviour

| Item | Change |
|---|---|
| `Cli.spin(label, fn)` | animates with `SpinGlyphs.dots` (80 ms) on stderr; ends with `✓ label 1.2s`, or `✗ label failed: <error>` and rethrows |
| `Bar.close()` | `✓ …` only when `value >= max`, else `✗ label stopped at 50/100`; the double and leading spaces go |
| A bar left live by an exception | document "close a bar in `finally`". The live region redraws only bars still open, so the next print or prompt never lands under a stale bar |
| Output while bars are live | `Cli.print`, `ask`, `confirm` and `choose` go through the live region: clear the bars, write, redraw (the review saw a log line overwritten and a stale bar left behind) |
| `confirm` | shows the default: `(y/N)` or `(Y/n)` |
| `choose` | M8: arrow keys and Enter on a terminal, `❯` on the current line; numbered input when piped; invalid numbered input re-asks once, then uses the default |
| Colours | the `AnsiText` getters return plain text when `NO_COLOR` is set or stdout isn't an ANSI terminal; nested colours keep the outer colour after an inner reset |
| Layout | `Cli.bar` and `ui.bar` lay out the same way: `label  bar  pct  details` |

### 6.3 Tests
- A golden test of each line above through a fake stderr (a `CliFake` mode that captures it), with colour on and with `NO_COLOR`.
- The live-region test from the review: two bars, then `Cli.print('log line')`, then more `set`s. The final screen holds the log line and two `✓` lines, and no stale bar.

---

## 8. Phase 7 — examples

| # | Change |
|---|---|
| 7.1 | annasarchive (N4): when the browser check doesn't pass within 20 s headless, close that Chrome and reopen with `Chrome(visible: true, profile: <a kept folder under ~/.cache/annasarchive/profile>)`, showing "Solve the check in the browser window once" until it passes. Later runs reuse the profile headless. Verify it by hand on the live site and say whether it worked |
| 7.2 | keybox: a site that can't be reached prints `✗ Can't reach key.visualarts.gr.jp: <reason>` and exits 1, with no stack trace |
| 7.3 | puremedia: run it once by hand (`--volume 1`) after Phase 1, to confirm the HTTP changes kept it working |

---

## 9. Phase 8 — docs and the final gate

1. CHANGELOG `## Unreleased`: a **Fixed** list (one line per item from Phases 1 and 4), a
   **Faster** list with the before and after numbers, and a **Changed** list (Phases 3, 5 and 6).
2. CONVENTIONS: add or adjust the rules these phases change:
   - `Writer.write` lets the caller reuse `data` once the future completes, and `abort()` exists.
   - Long native calls are jobs on native threads.
   - HTTP retries only idempotent requests.
   - Archives refuse every link unless `trusted`.
   - `find`/`all` search descendants only.
   - The console rules (`NO_COLOR`, throttled redraws, output through the live region).
3. README: every changed call (`Response`, `trusted:`, `onProgress:`, the console sample).
4. `UPDATE_API_NAMES=1 dart test test/api_names_test.dart`, then review the diff.
5. `make` green and `make bench`; report the startup table.
6. Report to the owner: phases done, the before and after numbers, anything you couldn't reproduce, the manual example results, and "run `make native-release`".
7. When everything here is done and green, delete this file (CONVENTIONS: a plan lives in the repo only while its work is open).
