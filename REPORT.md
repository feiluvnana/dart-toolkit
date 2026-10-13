# REPORT.md — bugs and perf vs VISION.md v2

Scope: `lib/` vs `VISION.md` §§1–7. Verified by code read + `dart run probe_bug.dart`
(`ab` vs `a\nb`, `pre` trimmed, `without('.x')` kept, `$('+1')==2`,
`-2^63.0==null`, `Map<String,List<bool>>==null`).
Severity: **C**ritical (wrong result / data loss / leak / hang), **M**edium, **L**ow.
`file:line` is the fix site.

## 0. Top fixes first (highest value)

1. `lib/html.dart:205` `text()` drops block/`br` boundaries — scraped text joins (`ab`).
2. `lib/html.dart:223` `text()` `trim()` kills `<pre>` — violates keeps-whitespace.
3. `lib/scrape.dart:131` `Visit.text()` UTF-8-only, loses `Response` charset — CJK mojibake.
4. `lib/http.dart:309` `Response.close()` unbounded `drain()` — hangs on stalled body.
5. `lib/http.dart:694` redirect `location` case-sensitive — missed redirects.
6. `lib/archive.dart:182` `_moveInto` deletes on type collision — violates never-deleting merge.
7. `lib/archive.dart:503` `gunzip` buffers all — OOMs, violates §6 streaming.
8. `lib/console.dart:526` `Bar` throttle dead (`force=true` default) — every `tick()` syscalls.
9. `lib/fs.dart:117,504` `copy` kind-blind + lexical `_checkSource` — symlink bypass, dest-symlink overwrite outside tree.
10. `lib/chrome.dart:170,45` `close()` flag-before-await + no signal handler — orphan Chromium/profile.
11. `lib/tui.dart` immediate mode makes the app own the loop, key polling and widget state — replace with the state-driven API (§15), then overhaul rawfree on it (§15.7).

## 1. core (`lib/core.dart`)

- [BUG-C] `core.dart:48` `to()`: `final s = stream()` outside `try`. Sync `transform` throw (poisoned `Hasher`, `hash.dart:114`) leaks source stream/handle. Move inside `try`.
- [BUG-M] `core.dart:49` null-writer path `await for (s)` has no writer-error cancel path; sync-factory throw never poisons pipes.
- [BUG-L] `core.dart:67` second-`listen().cancel()` assumes single-subscription. Broadcast `Reader.stream()` would run pipeline twice.
- [PERF-L] `core.dart:124` `_FutureReader.stream` `yield*` per chunk + `_PipedReader` nesting = extra microtasks on 10 GB pipe. Spec §6: mirror costs one `await`. `to()` avoids it, `bytes()/pipe()` don't.

## 2. hash (`lib/hash.dart`)

- [BUG-C] `hash.dart:91` no concurrent guard. Two `r>h` / `r|h` before `_done` interleave `_in.add` → wrong digest, `hex()` succeeds. Need sync `_running` flag.
- [SPEC] `hash.dart:113` `transform` throws sync, `consume` throws async. Fragile; relies on `Reader.pipe` deferring to `stream()`.
- OK: `_tee:123` poisons on input-error + downstream-cancel, `hex:79` idempotent, `add-after-hex:50` `StateError`.

## 3. pool (`lib/pool.dart`)

- [BUG-M] `pool.dart:125` `onResult?.call(r)` inside job `try`. Caller `bar.tick()` throw stops new jobs, reported as `items[i]` failure.
- [BUG-M] `pool.dart:279` `_sendableError` substring match (`send`+`message`, `isolate`, …). False-negative (`sent`), false-positive (job `throw 'isolate failed'`). Masks real errors, leaks engine wording (§1r13).
- [BUG-M] `pool.dart:256` sync `start()` throw not mapped; async path maps. Raw engine error leaks.
- [SPEC-M] `pool.dart:196` `close()` idempotence relies on `workerManager.dispose()` idempotent. Should guard/swallow itself (§1r12).
- [PERF-L] `pool.dart:70` `run/map` `_active++` then `await _ensureInit()`. `close()` in gap still boots then disposes — wasted isolates.
- [SPEC-L] `pool.dart:62` boot/dispose infra errors leak unwrapped (§1r13, §5).

## 4. http (`lib/http.dart`)

- [BUG-C] `http.dart:309` `close()`: `await _resp.stream.drain()` no timeout. Stalled `/stall` hangs `close()`; spec: drop. Need cancel + timeout.
- [BUG-M] `http.dart:694` `resp.headers['location']` lowercase only. `Location` missed → 301 returned as final. Rest of file is case-insensitive (`header()`, `_hasHeader`, `_headerValue`).
- [BUG-M] `http.dart:699` too-many-redirects `drain()` no timeout — hangs forever, no `TimeoutException`/retry.
- [BUG-L] `http.dart:709` redirect `drain().timeout(limit, onTimeout(){})` swallows timeout, background drain holds socket, blocks reuse.
- [BUG-L] `http.dart:725` streamed-body redirect throw does not drain; relies on outer `client.close()`.
- [BUG-L] `http.dart:238` `bytes()` returns mutable cached `List` identity; `Stream.value(cached)` same. Caller mutates cache.
- [SPEC-L] `http.dart:780,322` timeout message `${limit.inSeconds}s` reports `0s` for 300 ms. Render full `limit`.
- [SPEC-L] `http.dart:561` `Http.get('notaurl')` parses as relative `Uri`, retried as network error. Should upfront `ArgumentError` unless http/https absolute.
- [SPEC-L] `lib/json.dart:348` `json()` annotates `(HTTP 200)` on 2xx; spec: only error page.

## 5. scrape (`lib/scrape.dart`)

- [BUG-C] `scrape.dart:131` `Visit with Reader` only `stream()=>Stream.value(_body)`. `text()` UTF-8-only, discards `content-type`. Spec §4.14: decoded like `Response.text()`. CJK pages mojibake; `html()/json()` inherit.
- [SPEC-M] `scrape.dart:84` `Visit` missing `name()` (+`size()/ok()`). Spec §4.14 + §3 table. `v.name()` → `NoSuchMethod`.
- [BUG-M] `scrape.dart:114` `follow()` `_crawl.normalize` `FormatException` escapes → `_fail()` ends run. One bad `href=":bad"` kills crawl; should skip like non-http. Start URLs correctly fail.
- [SPEC-M] `scrape.dart:401,358` exhausted 5xx/429 `throw StateError('HTTP $status')`. §5: status never caller bug; should be `HttpException`. Hides from `on HttpException`.
- [BUG-L] `scrape.dart:404` error uses pre-redirect `task.url`, not `res.url()`. `http` pipe error uses final URL.
- [PERF-M] `scrape.dart:377` `_backoff: 1<<attempt` uncapped vs `http.dart:636` cap 10. `retries:30` → ~34 yr `Duration`.
- [PERF-L] `scrape.dart:278` `_drain` unconditional 50 ms + `247` 20 ms busy-poll. Every run pays ~50–70 ms; workers wake 50×/s when idle. Use completer/signal.

## 6. html (`lib/html.dart`)

- [BUG-C] `html.dart:205` `walk()` only recurses, never emits space/`\n` for block/`br`. `<div><p>a</p><p>b</p></div>` → `ab` want `a\nb`; `<div>a<br>b</div>` → `ab`.
- [BUG-C] `html.dart:223` unconditional `trim()` strips `<pre>`. `<pre>  x  </pre>` → `x` want `  x  `.
- [BUG-M] `html.dart:157` `Element.without()` only `clone.querySelectorAll` (descendants), no `matches(clone)`. Self match kept, unlike `Elements.without:93`.
- [BUG-M] `html.dart:87` `Elements.without()` per-item clone+keep, no dedupe. Overlapping roots (`div,p`) duplicate shared subtree.
- [BUG-M] `html.dart:244` `parent()`: `Element._(p)` assumes `Element`. Parent `Document/Fragment` throws; should `p is dom.Element ? Element._ : null`.
- [SPEC-L] `html.dart:286,102` `Elements.$/without` `on FormatException {rethrow}` leaks engine message without `invalid selector '<s>'` wrapper. `Element.without:162` wraps. Latent (current bad selectors throw via `_parseSelector`).
- [PERF-L] `html.dart:87` N clones + N `querySelectorAll`, not one O(n) clone as documented.

## 7. json (`lib/json.dart`)

- [SPEC-M] `json.dart:52` path `split('.')`, `*` always wildcard. No escaping. `{"a.b":1}. $('a.b')==2` (shadows key), `{"*":5}.$('*')==[5]`.
- [BUG-M] `json.dart:129` `int.tryParse(seg)` accepts `+1,01," 1"`. `$('+1')==2`.
- [BUG-M] `json.dart:78,194` `abs()<2^63` excludes valid `-2^63`. `-9223372036854775808.0.value<int>()==null`.
- [SPEC-M] `json.dart:237` `value<List<T>>/value<Map<String,T>>` hard-coded shapes only. `Map<String,List<bool>>`, `List<Map<String,bool>>`, `Map<String,Map<String,bool>>` → `null` though §4.4 says check each element.
- [PERF-M] `json.dart:60` `Map []` = `values.elementAt(i)` O(n), not O(1). Indexed object loop O(n²).

## 8. image (`lib/image.dart`)

- [BUG-M] `image.dart:76` `crop` `width<=0||height<=0` → `RangeError`. §5: bad size = `ArgumentError`, outside = `RangeError`.
- [SPEC-M] `image.dart:130` `_Encoded.stream()=>Stream.value(_encode(...))` evaluates sync at `stream()`, throws sync not as stream error. Breaks `to()/pipe` cleanup. `_FutureEncoded:141` correctly defers via `async*`.
- [SPEC-L] `image.dart:152` `quality.clamp(1,100)` silently clamps; should be `ArgumentError`.
- [PERF-L] `image.dart:40` `Uint8List.fromList(bytes)` copies even when already `Uint8List`.
- OK: `decode` unknown → `FormatException`, EXIF `bakeOrientation:47`, GIF `frame:0`, `resize` aspect math, `encode` lazy (throws at `bytes()`, `.ico>256` `ArgumentError`).

## 9. fs (`lib/fs.dart`)

- [BUG-C] `fs.dart:106,287,404` `delete()` no kind check. `File.delete` on dir → `EISDIR` not no-op; `Link.delete` (`unlink`) deletes regular file.
- [BUG-C] `fs.dart:117,126` `copy/move` only `_checkSource!=notFound`. Symlink source copies target as file; dest symlink truncates target outside tree instead of replacing link.
- [SPEC-C] `fs.dart:151` `append` in-place `writeAsBytes(append)`, not temp+rename atomic. Partial on crash; spec: atomic + old content kept.
- [BUG-M] `fs.dart:181` `_atomicWrite`: `openWrite()` no `O_EXCL` (racy tmp name), `rename:219` then `_chmod:222` (umask window; chmod tmp first), broken-link fallback replaces link with file undocumented, rename breaks hardlinks undocumented.
- [BUG-M] `fs.dart:270` sorts `a.path()` not `name()`. Recursive diverges (`a/z.txt<b.txt` vs `z.txt>b.txt`).
- [BUG-M] `fs.dart:256` `Dir.list` on symlink-to-dir lists target though `exists()==false`. `followLinks:false` only stops interior descent.
- [BUG-M] `fs.dart:298` `Dir.copy(file)` creates empty `to` dir then throws — violates throws-before-writes.
- [BUG-M] `fs.dart:587` `_copyDir`: link dest `EEXIST` no retry (files overwrite), file-onto-symlink follows, file-onto-dir half-copies then throws.
- [BUG-M] `fs.dart:504` `_checkSource` `normalize(absolute)` lexical only, no `resolveSymbolicLinks`. `link->real` + `to=real/sub` passes → self-copy. No kind check.
- [BUG-M] `fs.dart:499` `_isExdev==18` POSIX only. Windows cross-device (`17/null`) never copy-then-deletes.
- [BUG-L] `fs.dart:574` `_strip` `"C:\\"` → `"C:"` (different). Root handling `/`-only.
- [PERF-M] `fs.dart:521,547` `_chmod/_setDirMtime` fork `chmod/touch` per file/dir. Large tree O(n) processes; batch or native binding.
- [BUG-L] `fs.dart:547` `touch -t/-d @secs` truncates to seconds; sub-second lost though spec keeps timestamps.

## 10. shell (`lib/shell.dart`)

- [BUG-M] `shell.dart:286` `_isEpipe` `toString().contains('broken pipe/epipe')` on any error. Upstream `StateError('broken pipe test')` misclassified as early-close, `inputError` swallowed.
- [BUG-M] `shell.dart:228,244` `kill()` = `SIGTERM`; ignoring child survives 2 s timeouts; `stdinDone` await in `finally` unbounded — teardown can hang. Need `SIGKILL` on cancel path.
- [BUG-M] `shell.dart:89` `open` unawaited drains, never awaits/checks `exitCode`. Zombie + `xdg-open` failure invisible.
- [PERF-L] `shell.dart:197` `stderrBuf BytesBuilder` unbounded (spec requires full stderr, but GB stderr OOMs; needs cap).
- OK: `text():147` strips one `\n`/`\r\n` only, `bytes()/>` verbatim.

## 11. archive (`lib/archive.dart`)

- [BUG-C] `archive.dart:182` `_moveInto` on type collision deletes dest (`Directory.delete(recursive:true)` / `File.delete`). Archive file over existing dir `rm -rf`s it. Spec + test only disjoint; should throw/merge.
- [BUG-M] `archive.dart:125` `f.isSymbolicLink` misses zip symlink as regular file with `S_IFLNK` mode; tar hardlink `typeflag 1` unchecked → extracts as file.
- [BUG-M] `archive.dart:69` pack `prefix=_dir+sep` not normalized. `site//, ./site, site/./sub/..` → wrong top-level in archive.
- [BUG-M] `archive.dart:342` `_looksLikeTar: bytes.isEmpty=>true`. Zero-byte unpack creates target, succeeds; should be `unknown format`.
- [BUG-M] `archive.dart:393` `_verifyGzip` last-8-bytes single-member check. Concatenated gzip (valid) false `FormatException`. `length<18` assumes single member.
- [BUG-L] `archive.dart:145,321` check `replaceAll('\\','/')` vs extract `split('/')` only — inconsistent layout on Windows.
- [BUG-L] `archive.dart:287` `PK` path no `try`/empty check; truncated zip raw `ArchiveException` or empty archive → empty dir, unlike fallback path.
- [BUG-L] `archive.dart:239` `_copyTree` drops links (no link branch), used cross-device. `fs._copyDir` handles links.
- [PERF-C] `archive.dart:503` `_gunzipChecked` buffers all input + all output, yields one chunk. 10 GB `gunzip>file` OOMs; doc says streaming `Pipe`. Compress path streams via `io.gzip.encoder`.
- [PERF-M] `archive.dart:393` `_verifyGzip(io.gzip.decode)` + `GZipDecoder.decodeBytes` decompress twice, hold twice.
- [PERF-L] `archive.dart:106` `tgz` holds tar+gz+model (3×) + `readAsBytes` per file.

## 12. chrome (`lib/chrome.dart`)

- [BUG-C] `chrome.dart:170` `close()` `_closed=true` before `await _browser.close()`. Throw → second `close()` no-ops, process leaks.
- [BUG-M] `chrome.dart:113,543` `_known/_wrappers` never pruned. `open` failure leaves wrapper; `Page.close()` never removes. Unbounded retain + stale subs.
- [SPEC-C] `chrome.dart:45` no SIGINT/SIGTERM/Ctrl-C handler, only puppeteer temp-dir hook. Crash without `close()` orphans Chromium + profile. Violates never-leaves-Chromium + §1r12.
- [SPEC-M] `chrome.dart:143` `headers` only `setExtraHTTPHeaders`; `user-agent` never `setUserAgent` → `navigator.userAgent` unchanged.
- [BUG-M] `chrome.dart:202` `_detach` only `cancel()`s sub, never `setRequestInterception(false)`. Page keeps interception with no handler → future requests hang. Retains old `block` on `goto`.
- [PERF-L] `chrome.dart:146` `block:[]` still enables interception → CDP round-trip per request. Skip when empty.
- [SPEC-L] `chrome.dart:203` `block` lowercased, no validation. `'images'` typo silently loads all; should be `ArgumentError`.
- [BUG-M] `chrome.dart:247` `waitIdle` `+1 request / -1 finished|failed` misses aborted/blocked/`data:`/WS-SSE → `_inflight>0` forever → always 30 s timeout.
- [BUG-M] `chrome.dart:573` `_attached/_visible` `catch=>TimeoutException`. Invalid selector waits 30 s not fast `FormatException` (§5).
- [BUG-M] `chrome.dart:332` TOCTOU: `_actionable` then fresh `click/focus/type/select`. Hide/disable in gap throws raw engine error, not `TimeoutException`.
- [BUG-M] `chrome.dart:344` `fill` sets `el.value=""` on any element, no-ops `contenteditable`, double `focus()`, raw `querySelector` `SyntaxError` unmapped.
- [BUG-M] `chrome.dart:420` `select` ignores `List<String>` return; missing option silent.
- [BUG-C] `chrome.dart:429` `upload` deletes staging `tmp` in `finally` right after `uploadFile`. Browser reads at submit → staged non-`File` readers broken. Non-empty path never dispatches `input/change` (only empty-array does).
- [SPEC-M] `chrome.dart:676` `_key` missing `insert, shift/control/alt/meta, wheelup/wheeldown` from §4.12 shared names. `press('insert')` → `ArgumentError` though valid.
- [BUG-M] `chrome.dart:514` concurrent `download()` `onDownloadWillBegin.first` unfiltered → both resolve to same event, one file lost. Needs guid/URL filter.
- [BUG-M] `chrome.dart:523` only `completed` awaited; `cancelled/error` waits full 30 s not fast throw.
- [PERF-M] `chrome.dart:514,523,661` triple `limit` (willBegin+progress+stable → 90 s for 30 s timeout) + `_stableFile` two 100 ms polls after CDP `completed` (+100 ms/download).
- [BUG-L] `chrome.dart:324` `cookies()` `${name}=${value}` no encoding of `;/= /space`; `data:/about:blank` `url()` may throw unmapped.
- OK: `screenshot/pdf:779` lazy (`_ShotReader` captures on read, re-readable fresh bytes) — correct per captured-when-read.

## 13. cli (`lib/cli.dart`, 1131 lines)

- [BUG-M] `cli.dart:932` short `-n=` strips `=` → absent. `-n= NEXT` → `NEXT`, `-n=` at end → needs-value; long `--n=` → `""`.
- [BUG-M] `cli.dart:848,911` `--help=x` ignores `inline` → help; `-h=x` → `Unknown option -=`. `--opt --help` consumes `--help` as value, never helps.
- [BUG-M] `cli.dart:985` required checks before `help`. `Opt required + --help` → 64 not 0. `help <cmd>` bypasses — inconsistent.
- [BUG-M] `cli.dart:818` parent `Arg` + subcommand name: dispatch wins, `Arg` never binds (`[go]` → `Missing argument`, not `arg=go`).
- [BUG-M] `cli.dart:819` command named `help` unreachable (`token=='help'` precedes `_findSub`); leaf `help` positional (handler runs, not help).
- [BUG-M] `cli.dart:225` `Ctx(Multi)` returns stored list alias; `ctx(tag).add()` mutates cache. `rest()` copies.
- [BUG-M] `cli.dart:622` `_parseDuration` rejects `+5s,1H,1h 30m` (lower-only, no `+`/inner-space).
- [SPEC-M] `cli.dart:598` `Uri` requires `hasScheme`. Relative `/foo` → 64 though `Uri.parse` accepts.
- [SPEC-M] `cli.dart:919,553` unknown short never suggests; `_closest` prefix `0` over-generous, single-char typo never suggests.
- [BUG-L] `cli.dart:961` `Multi` merge errors always `--name` even for `-t`.
- [SPEC-L] `cli.dart:397,411` one-line rule only generic `Exception`. `FormatException/UsageException` raw multi-line prints two lines.
- OK: handler `UsageException→64`, `Exception→1`, `Error` propagates.

## 14. console / terminal

`lib/console.dart`, `lib/src/terminal.dart` (tui-only bugs moved to §15.6):

- [BUG-C] `terminal.dart:48` `onDone` never forwarded. `_input` never closes → `ask` `onDone:233`, `choose stdinDone:260` never fire; EOF without `\n` hangs not `StdinException`.
- [BUG-M] `console.dart:211` `_readLine` `return` after first `\n/\r` drops rest of chunk. Piped `2\n3\n` loses next line.
- [BUG-M] `console.dart:217` secret backspace `buf.removeLast()` byte-level; multibyte password corrupts.
- [BUG-C] `console.dart:526,439` throttle dead: `_render({force=true})`, `tick()` → `_render()` true, `if(!force...)` never taken. Every `tick()` writes stderr. `Pool.map(10k,tick)` = 10k syscalls.
- [BUG-M] `console.dart:148` `spin` no `truncateWidth`/`_columns`/SIGWINCH — long label overflows; only `\x1b[K` not fit.
- [SPEC-M] `console.dart:460` non-animated `close()` prints `done/total` no rate; spec null-total shows count+rate.
- [BUG-M] `console.dart:518` `_fail()` `writeln('\r✗ …')` no `\x1b[K`; longer bar tail remains.
- [BUG-M] `console.dart:167` `bar()` `_claim` then `_render()` throw leaks `_live` — all later bars `StateError`.
- [BUG-M] `console.dart:179` prompts trap only `SIGINT`; no `SIGTERM/SIGHUP` → kill in `ask(secret)` leaves terminal raw/no-echo.
- [BUG-M] `console.dart:372` `_nextKey` `stdinDone` inside ESC-quiet returns `escape` not `null`; `choose` accepts instead of `StdinException`.
- [BUG-M] `terminal.dart:126,168` `ascii.decode` on mouse SGR/CSI params throws on `>=0x80`; should `allowMalformed`/ignore per unknown-sequences-ignored.
- [BUG-M] `terminal.dart:132` drag (`32`) `btn&3==0` as left press; spec drag not clicks. Mask `32`.
- [BUG-L] `terminal.dart:36` `_startInput` fallback creates `_ttySub` on stale session (check only in `try` success) — leaks stdin listener keeping process alive.
- [BUG-L] `console.dart:569,582` `room<=0` tiny width still `>cols`; violates always-fits for `cols<~15`.

## 15. tui — new API: state-driven (replaces VISION §4.12)

### 15.1 Why

Immediate mode leaves the whole app to the caller. In `example/rawfree.dart`, about 170 lines of
UI code do jobs the library should do:

| The app does today                                                                 | The library does instead (§15.2)                       |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------ |
| the frame loop and a `quit` flag (`while (!st.quit) await screen.frame(…)`)        | `Tui.run(state, screen)` owns the loop                 |
| polls `s.pressed(…)` in the middle of drawing; ordering bugs between keys and widgets | `keys:` map, routed by focus                           |
| stores widget state by hand (`sel = list(items, sel)`, `query = input(query)`, `csel`) | `Pick<T>` / `Field` live in the state object           |
| switches views by nulling fields (`series = null`)                                  | a state object per view, `app.go(next)`                |
| writes the key-help header that repeats the key handling                            | the status row shows the labels from `keys:`           |
| writes `.catchError((e) { statusErr = true; status = '✗ …'; })` four times          | an exception from a handler goes to the status row     |
| draws its own spinner/progress text (`searching…`, `↓ ch 3/40`)                     | `Console.spin` / `Console.bar` draw in the status row  |
| writes "press again to quit" logic                                                  | `Console.confirm` shows as a popup                     |
| maps items to labels (`[for (final h in hits) h['title'] ?? '']`)                   | `list(pick, (h) => h.title)`                           |

It keeps every widget the old (master) Tui had: `box`, `text`, `spinner`, `bar`, `list`, `split`,
`button`, `field`, `tabs`, `table`, `popup`, `markdown`, `picture`, with colours and styles, but in
v2 syntax: positional inputs, named options, typed colours, and widget state as objects.

### 15.2 Surface

```dart
abstract final class Tui {
  static Future<S> run<S>(S state, Screen Function(S state, App<S> app) screen, {Color accent = .orange});
}
final class App<S> {
  S state();
  void go(S state);              // switch state; the next redraw calls screen(state, app)
  void say(String message);      // status row, until the next say or error
  void quit();                   // run() returns state()
}
final class Screen {
  Screen(void Function(Region r) draw, {String? title, Map<String, Bind> keys = const {}});
}
typedef Bind = (String label, FutureOr<void> Function() action);

final class Pick<T> {                       // a list's items and selection
  Pick([List<T> items = const []]);
  List<T> items();  int index();  T? selected();          // null when empty
  Pick<T> set(List<T> items);                             // keeps the selected item if still there, else 0
  Pick<T> select(int index);                              // clamped
}
final class Field {                         // an input's text and cursor
  Field([String text = '']);
  String text();  Field set(String text);                 // cursor to the end
}

final class Region {
  int width();  int height();
  // text
  Region write(String text, {Color? color, Color? background, Set<Style> style = const {}});
  Region markdown(String source);
  // layout: each returns the new area
  Region box(String title);
  List<Region> rows(List<int> sizes);  List<Region> cols(List<int> sizes);
  Region tabs<T>(Pick<T> tabs, String Function(T tab) label);   // the area below the tab row
  Region popup(String title, {int width = 40, int height = 10});
  // widgets: each returns the receiver
  Region list<T>(Pick<T> pick, String Function(T item) label, {String empty = ''});
  Region table<T>(Pick<T> pick, List<String> Function(T item) cells, {List<String>? header, String empty = ''});
  Region input(Field field, {String hint = ''});
  Region button(String label, FutureOr<void> Function() action);
  Region bar(int done, int? total, {String? label});
  Region spin(String label);
  Region picture(Image image);
}

final class Color {
  static const Color black, red, green, yellow, blue, magenta, cyan, white, gray, orange;
  const factory Color.index(int index);            // 0–255, else ArgumentError
  const factory Color.rgb(int r, int g, int b);
}
enum Style { bold, dim, italic, underline, reverse }
```

Public surface is exactly: `Tui`, `App`, `Screen`, `Bind`, `Pick`, `Field`, `Region`, `Color`,
`Style`. `Screen.frame`, `pressed`, `typed`, and the `ScreenFuture` mirror go away.

### 15.3 Rules

- **The state is the app's own value**, usually a sealed class with one subclass per view, so
  `screen` is an exhaustive `switch`. Going back is `app.go(previous)`. The previous object still
  holds its `Pick`/`Field`, so the query, the selection and the focus come back as they were.
- **`screen` runs on every redraw** and only describes the screen. It never blocks, and widgets
  never return state.
- **Redraws are event-driven.** A redraw happens after each input event, after each handler
  call and when its future settles, and on `go`, `say` and resize. It also runs at most every
  80 ms while a handler future is pending or a spinner or bar is visible. An idle app uses no
  CPU. Only changed cells are written.
- **Keys.** `keys` maps a key name (VISION key names; alternatives are separated by spaces:
  `'b escape'`) to `(label, action)`. A key goes to the first of these that takes it:
  1. an open popup;
  2. the focused widget;
  3. `Tab`/`Shift+Tab` to move the focus, unless `keys` binds them;
  4. the `keys` map;
  5. any other drawn widget that uses the key, drawn order first (so `↑↓` reach the only list
     while the input has focus);
  6. unbound `ctrl+c`, which quits.
- **Widget keys:**
  - `list`/`table`: `up` `down` `pageup` `pagedown` `home` `end`, the wheel (the list under the
    pointer), and a click (selects and focuses).
  - `input`: printable keys, paste, `backspace`/`delete` (by grapheme), `left` `right` `home`
    `end`.
  - `tabs`: `left` `right` when focused, and a click.
  - `button`: `enter`/`space` when focused, and a left click.
- **Focus** is the widget's `Pick`/`Field` object (a button's is its label), not a frame index,
  so it survives redraws and state switches. When the focused widget isn't drawn, the first
  focusable one is focused. A focused list's selection uses the accent; unfocused, it is dim
  reversed. A focused input shows the hardware cursor.
- **Handlers** may be sync or async, and every press runs one, even while an earlier run is
  pending (a download doesn't block adding the next one); the app guards where it must. An `Exception` from a handler shows as
  `✗ <first line>` in red in the status row, and the app keeps running. An `Error` (a bug) ends
  `run` and is rethrown, the same rule as `cli`.
- **Rows.** `title` is the top row, in the accent. The status row is always the bottom row. On
  the left it shows the error, the `say` message, or the running spinners and bars. On the right
  it shows the key help (`enter search · ctrl+o browser · esc quit`), with `escape` shown as
  `esc` and an empty label hidden. When the row is too narrow, the help is cut first.
- **Console inside the Tui.** While `run` is active, `Console.spin` and `Console.bar` draw in the
  status row instead of stderr, and several can run at once. `Console.ask`/`confirm`/`choose`
  open a modal popup over the screen. `Escape` there is EOF: it throws `StdinException`, and a
  handler that ends with it shows nothing. This adds no new progress or prompt names.
- **Drawing.** `write` wraps at the region edge, `\n` breaks a line, `\t` expands, controls show
  as `�`, and text that runs past the last row ends with `…`. `popup` is drawn last, centered.
  `rows`/`cols`: a size above 0 is fixed, and 0 shares what is left. `bar` lays out like
  `Console.bar`. `picture` draws half-block cells and scales down to fit.
- **Colours.** They are downgraded to the terminal's level (truecolor → 256 → 16). `NO_COLOR`
  drops colours and keeps styles. `LANG=C`/no UTF-8 switches boxes, bars and spinners to ASCII.
- **Terminal life**, Ctrl-Z, resize repaint, synchronized output, restart, and `StdoutException`
  stay as in VISION §4.12. A second `Tui.run` while one is active throws `StateError`.
- **After `quit`**, `run` returns without waiting for pending handlers (futures can't be
  cancelled). rawfree keeps its `exit(0)`.

### 15.4 rawfree straight port (UI part: ~80 lines instead of ~170; the overhaul is §15.7)

```dart
typedef Hit = ({String title, String url});
sealed class Page {}
final class Search extends Page { final query = Field(); final hits = Pick<Hit>(); var searched = ''; }
final class Series extends Page {
  Series(this.back, this.hit);
  final Search back;  final Hit hit;  final chapters = Pick<Chapter>();
}
var _downloads = 0;

Future<void> main() async {
  try {
    await Tui.run<Page>(Search(), _screen);
  } on StdoutException {
    stderr.writeln('rawfree needs a terminal');
    exit(1);
  }
  exit(0);
}

Screen _screen(Page page, App<Page> app) => switch (page) {
  Search s => Screen(title: '✻ rawfree', (r) {
      final [body, foot] = r.rows([0, 3]);
      body.list(s.hits, (h) => h.title, empty: 'type a manga title, press enter');
      foot.box('search').input(s.query);
    }, keys: {
      'enter': s.query.text().trim() != s.searched ? ('search', () => _search(s)) : ('open', () => _open(s, app)),
      'ctrl+o': ('browser', () => _browse(s.hits.selected()?.url, app)),
      'escape': ('quit', () => _quit(app)),
    }),
  Series c => Screen(title: '✻ ${c.hit.title}',
      (r) => r.list(c.chapters, (ch) => ch.title, empty: 'no chapters'),
      keys: {
        'enter': ('download', () => _download(c, app)),
        'o': ('browser', () => _browse(c.hit.url, app)),
        'b escape': ('back', () => app.go(c.back)),
      }),
};

Future<void> _search(Search s) async {
  s.searched = s.query.text().trim();
  s.hits.set(await Console.spin('searching', () => searchManga(s.searched)));
}

Future<void> _open(Search s, App<Page> app) async {
  if (s.hits.selected() case final hit?) {
    final page = Series(s, hit);
    app.go(page);
    page.chapters.set(await Console.spin('loading chapters', () => resolveChapters(hit.url)));
  }
}

Future<void> _browse(String? url, App<Page> app) async {
  if (url == null) return;
  await Shell.open(url);
  app.say('opened in browser');
}

Future<void> _quit(App<Page> app) async {
  if (_downloads == 0 || await Console.confirm('A download is running. Quit?')) app.quit();
}

Future<void> _download(Series c, App<Page> app) async {
  final ch = c.chapters.selected();
  if (ch == null) return;
  final dir = Fs.dir('downloads/${_safe(c.hit.title)}/${_safe(ch.title)}');
  final imgs = await Console.spin('finding pages', () => chapterImages(ch.postId));
  if (imgs.isEmpty) throw Exception('${ch.title}: no images found');
  final bar = Console.bar(imgs.length, label: '↓ ${ch.title}');
  var failed = 0;
  _downloads++;
  try {
    for (final (i, u) in imgs.indexed) {
      final img = await Http.get(u, headers: {..._headers, 'referer': '$_base/'}, retries: 2);
      final data = img.ok() ? await img.bytes() : const <int>[];
      if (data.length < 1024) {
        failed++;                                    // error page or expired-URL stub
      } else {
        await dir.file('${'${i + 1}'.padLeft(3, '0')}${_imgExt(data, img)}').write(data);
      }
      bar.tick();
    }
  } finally {
    _downloads--;
    await bar.close();
  }
  app.say('✓ ${ch.title} → ${dir.path()}${failed > 0 ? ' · $failed failed, retry the chapter' : ''}');
}
```

The `_apiGet` and `resolveChapters` throws change from `StateError` to `Exception`/`HttpException`,
so they show in the status row instead of ending the run.

### 15.5 Decisions taken (no backward compat)

- `keys:` is rebuilt with the screen, so collection `if` makes bindings (and the help) depend on
  the state: `if (tab == .add) 'enter': ('add', …)`.
- `tabs` takes a `Pick<T>` plus a label like `list`, so an enum `Pick(Tab.values)` makes the
  tab `switch` typed.
- `go` instead of handlers returning the next state: one way to switch, from sync and async
  code alike, and every handler stays an arrow.
- Progress and prompts reuse `Console`, with no `app.spin`/`app.bar`/`app.confirm`. This adds
  zero names and keeps one vocabulary, and a `Console.bar` is still a `Pipe`
  (`res | Console.bar(res.size()) > file` works inside the Tui).
- Widget state lives in objects (`Pick`, `Field`). Drawing is still a function of the state on
  every redraw, so VISION §7 "retained TUI widgets" stays out: there's no widget tree.
- `picture(Image)` makes `tui` import `image`. A/B the startup with and without it
  back to back. If it costs anything, `picture` moves to `image.dart` as a
  `Region` extension.
- VISION §4.12, the §3 table row (`tui`) and §7 get rewritten from this section when it's
  implemented. `test/tui_test.dart` and `test/tui_pty/` get rewritten against it, and
  `example/rawfree.dart` becomes the §15.7 download manager.

### 15.6 Old `src/tui.dart` bugs vs the new API

- Gone with the redesign:
  - `:501` the input edits while undrawn: a `Field` only edits when routed to.
  - `:269,148` the focus jumps: focus is object identity.
  - `:470` two lists scroll on one key: keys are routed by focus.
  - `:282` the 60 fps full scan: redraws are event-driven.
- Still to fix in the new code (each gets a regression test):
  - [BUG-M] `:234` a split `ESC [` resolves to `alt+[` after 30 ms; hold it up to 1000 ms for
    the CSI to complete.
  - [BUG-L] `:385` `write('a\n')` draws a trailing empty row.
  - [BUG-L] `:526` backspace leaves a dangling `ZWJ` (`1F468 200D 1F469` → `200D`); use
    grapheme clusters.
  - [SPEC-M] `:20` a concurrent `Tui.run` must throw `StateError`.
  - [PERF-L] `_leave` cancels sequentially; use `Future.wait`.

### 15.7 Plan: rawfree overhaul (the example that proves §15)

§15.4 is only the straight port. The finished `example/rawfree.dart` is a download manager that
uses every part of §15. Any workaround it needs is a gap in §15, fixed in the library and not in
the example.

**Features:**

| Feature             | Behaviour                                                                                                                                                                          | Uses                                                  |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Views               | `Search` → `Series` (chapters) → back; `Queue` from any view on `ctrl+d`, and back returns where you were                                                                          | sealed states, `app.go`, `title:`                     |
| Download queue      | `enter` on a chapter queues it and never refuses; `a` queues every chapter not yet on disk; a chapter already queued or downloaded isn't queued again                                | `Pick<Job>`, an in-app worker                         |
| Worker              | one chapter at a time, 4 pages in parallel; it starts when the queue gets a job and idles when the queue is empty                                                                  | plain `Future`s, no `Pool` (isolates are overkill)    |
| Progress            | the status row shows the live `Console.bar` (`↓ ch.12 ━━━╸── 14/40 pages  1.8 MB/s`) and `⇣ 2/5 chapters`; the `Queue` view has a table (chapter · status · pages) and a `bar` for the active job | `Console.bar` in the Tui, `table`, `Region.bar`       |
| On disk             | chapters already in `downloads/<series>/<chapter>/` show `✓` in the chapter list and are skipped                                                                                   | `Fs.dir(…).exists()` when the chapters load           |
| Failures            | a page that fails (non-2xx, or a <1 KB stub) counts as failed, the job ends `failed (n)`, and `r` in `Queue` re-queues only the missing pages                                       | `Job.missing`, the status row `✗`                     |
| Queue editing       | `delete` removes a queued job (the active one can't be cancelled, since futures can't be); `c` clears the finished jobs                                                            | collection-`if` `keys:`                               |
| Quit                | `escape`/`ctrl+c` quits at once when the queue is empty, and otherwise asks `N downloads left. Quit?`                                                                              | `Console.confirm` popup                               |
| Errors              | `_apiGet`/`resolveChapters` throw `HttpException`/`FormatException`, never `StateError`, so they show in the status row                                                            | handler `Exception` rule                              |

**Model:**

```dart
enum JobStatus { queued, active, done, failed }
final class Job {
  Job(this.series, this.chapter);
  final Hit series;  final Chapter chapter;
  var status = JobStatus.queued, done = 0, total = 0;
  final missing = <int>[];                 // page indexes to (re)fetch
}
final queue = Pick<Job>();                 // shared by every view
```

**Steps.** Each step ends green before the next starts.

1. **Library.** Implement §15.2/§15.3 in `lib/src/tui.dart`, and the Console-in-Tui routing in
   `console.dart` through a session hook in `terminal.dart`. Fix the §15.6 carry-overs.
2. **Tests.** Write a pty test per member and rule in `test/tui_test.dart` and `test/tui_pty/`:
   key routing order, focus surviving `go`, `keys:` help, a handler `Exception` going to the
   status row, `Console.bar`/`confirm` inside `run`, idle without redraws, and a second `run`
   throwing `StateError`.
3. **rawfree.** Rewrite it as above. The UI part's target is ≤ 150 lines with the queue (today
   it's ~170 lines without one), and the API part stays as it is apart from the exception types.
4. **Verify by running.** Drive rawfree in a pty (`test/tui_pty/drive.py`): search, open a
   series, queue 3 chapters with `a`, watch the status row and the `Queue` table advance, kill
   the network for one page, check `failed (1)` and that `r` refetches only that page, and check
   that quitting with jobs left asks first. Check the result by screen state, and the files in
   `downloads/`.
5. **Docs.** Rewrite VISION §4.12, its §3 row and §7 from §15; update the README/CHANGELOG
   table row; delete §15.1–§15.6 here once they're done.

## 16. Charset (`lib/src/charset.dart`, 2559 lines)

- [PERF-M] `charset.dart:65,215` `sublist` + `[...tail,...chunk]` per `add()` O(n²) streaming; `IncrementalDecoder` not chunk-friendly as advertised.
- [PERF-M] `charset.dart:438` `GB18030 queue.insert(i-1)` shifts tail per error byte — error-heavy CJK quadratic. Use index pushback.
- OK: `content-type → meta → UTF-8`, unknown → UTF-8, bad bytes `�`, Latin-1/CJK coverage; single-shot `decode` tolerable.

## 17. Perf summary (violates §6 constant-memory / throughput)

1. `gunzip` buffers all + double-decompress — OOM on large (archive).
2. `Bar` throttle dead — O(ticks) syscalls (console).
3. `chmod/touch` fork per entry — O(n) processes (fs/archive).
4. Charset per-chunk copies + `insert` — O(n²) (charset).
5. Scrape 20 ms poll + 50 ms drain; chrome `waitIdle` 50 ms poll, download +100 ms; tui full-screen 60 fps scan (gone with §15).
6. `tgz` 3× hold; `stderrBuf` unbounded; `Map []` O(n²); `_FutureReader` per-chunk hop; `image` copy.
