# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.8%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A toolkit for Dart scripts: processes, files, archives, hashes, HTML, JSON, HTTP, a real
browser, images, a CLI and terminal apps. One way to do each thing, every part plugs into every
other through `Source`/`Target` pipes, and digests, archives, images and the browser run in native
libraries. No third-party package at runtime.

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

Import the topics you use.

| Import              | Holds                                                                               |
| ------------------- | ----------------------------------------------------------------------------------- |
| `core.dart`         | `Source`, `Target`, `Reader`, `Writer`, `pipe`, `text`/`bytes`/`lines`, errors      |
| `path.dart`         | `File`, `Dir`: read, write, copy, move, find, watch; atomic writes                  |
| `archive.dart`      | `dir.pack`, `source.unpack`, `file.entries`/`entry`; in-memory `Archive.zip`/`unzip`/`gzip`/`gunzip` |
| `hash.dart`         | `Hash.sha256(data, key:)`, `source.hash(algo)`, `.hex`/`.base64`/`.toInt()`, `Hex`/`Base64.decode` |
| `async.dart`        | `Task.run`, `Pool`, `Chan`                                                          |
| `process.dart`      | `Process(cmd, args)`, `text`/`lines`, `check`, `close`, `pipe`                  |
| `json.dart`         | `Json`: `parse`, `get`, `encode`, `save`; `source.json()`                           |
| `html.dart`         | `Html.parse`, `find`/`all`, `drop`, CSS selectors; `source.html()`                 |
| `http.dart`         | `Http.get/post/put/delete`, lazy `Request`, `Response`, `pipe(resume:)`                |
| `chrome.dart`       | `Chrome()`/`Chrome(port:)`, `open`, `Page` drive, `screenshot`, `pdf`, `page.html()` |
| `image.dart`        | `Image.empty/decode`, transforms, `save`; `source.image()`                             |
| `cli.dart`          | `ask`, `confirm`, `choose`, `bar`, `spin`, ANSI colours                              |
| `tui.dart`          | `Tui.run` terminal apps, widgets (`FakeTerminal` in `testing.dart`)                 |
| `native.dart`       | `Native.ok`/`reason`; the three cdylib seams                                        |
| `testing.dart`      | Test seams: `FakeTerminal`, `CliFake`, `BufferReader`/`BufferWriter`, `NativeReset` |

Hashing, archives and images run in the `dart_toolkit_native` cdylib, the browser in
`dart_toolkit_chrome`, the terminal in `dart_toolkit_tui`. Build them with `make native`
(`dart run tool/build_native.dart`), which needs Rust and a C compiler; `make native-release`
uploads the set a first use would fetch. Without a library those calls are `UnsupportedError`.

---

## Processes

**I want a command's output, or to know whether it worked.**

```dart
final branch = await Process('git', ['rev-parse', '--abbrev-ref', 'HEAD']).text();
if (!await Process('git', ['diff', '--quiet']).check()) Cli.print('dirty tree');
```

and

```dart
final proc = Process('ping', ['127.0.0.1']);
await for (final line in proc.lines()) {
  Cli.print(line);
  break;
}
await proc.close();
```

A process starts on its first call. Readings throw a ProcessException on a non-zero exit;
check() answers yes or no. close() kills the whole tree; wait(timeout:) throws TimeoutException
after one.

---

## Files and archives

**I want to read and write files.**

```dart
final f = File('conf.json');
await f.write('{"a": 1}');
Cli.print(await f.text());
await f.copy(File('conf.bak'));
await File('conf.bak').drop();
```

`write` replaces atomically (a sibling renamed over the target, with the Windows retry);
`pipe(File(…))` streams into a file the same way.

**I want to zip a folder or unpack an archive.**

```dart
await Dir('site').pack(File('site.tar.zst'));
await File('site.tar.zst').unpack(Dir('out'));
final names = await File('site.tar.zst').entries();
await Http.get('https://site.com/bundle.tar.gz').unpack(Dir('bundle'));
```

The format is the extension when packing and the magic bytes when unpacking
(.zip, .tar, .tar.gz, .tar.xz, .tar.zst, .tar.bz2, .gz). Members are sandbox-checked before
anything is written: escapes are a SecurityException, and every link member is refused
unless `unpack(dir, trusted: true)` lifts that and the size cap. Unpacking a download streams,
and a failed stream removes what it created. `dir.pack`, `source.unpack`, `file.hash`,
`file.copy` and `file.move` take `onProgress:` (units done and total).

**I want a checksum or a MAC.**

```dart
final hex = Hash.sha256('hello world').hex;
final fileHex = (await File('disc.iso').hash(Hash.sha256)).hex;
final mac = Hash.sha256('body', key: 'secret').hex;
```

---

## Documents

**I want values from JSON.**

```dart
final data = Json.parse('{"a": {"b": 42}}');
final port = data.get<int>('a.b', or: 8080);
Cli.print(Json({'ok': true}).encode());
```

**I want to scrape a page.**

```dart
final doc = Html.parse('<ul><li><a>one</a></li><li><a>two</a></li></ul>');
final titles = [for (final a in doc.all('a')) a.text];
final clean = doc.drop('script, style');
```

---

## The network and the browser

**I want to fetch a page or an API.**

```dart
final data = await Http.get('https://api.site.com/users').json();
await Http.get('https://site.com/file.zip').pipe(File('file.zip'));
await Http.get('https://site.com/big.iso').pipe(File('big.iso'), resume: true);
```

A request is sent when you first read it, so `resume: true` can ask for the rest. A non-2xx
reading throws an `HttpException`; `await Http.get(u)` gives the `Response` (status, headers).

**I want pages a browser renders.**

```dart
final chrome = Chrome();
final page = await chrome.open('https://example.com');
Cli.print(await page.title());
final doc = await page.html();
await page.screenshot().pipe(File('shot.png'));
await chrome.close();
```

Chrome() launches on the first open; Chrome(port: 9222) attaches to a running one. close
kills the whole tree and drops the temp profile. page.pdf() prints to PDF. The drive calls
run on native threads, so the event loop stays free while a page hangs; closing a page
fails its in-flight calls with `StateError('closed')`.

---

## Media

**I want to edit an image.**

```dart
final img = Image.empty(100, 50);
await img.fit(48, 48).save(File('thumb.png'));
await File('photo.jpg').image().fit(800, 600).save(File('photo.webp'), quality: 80);
```

`quality` (0–100) applies to JPEG/WebP only; PNG ignores it.

---

## Work in parallel

**I want one background result, or a channel of them.**

```dart
final answer = await Task.run(() => 40 + 2);
final pool = Pool(4);
final squares = await pool.map([1, 2, 3], (n) => n * n);
await pool.close();
final chan = Chan<int>(10);
await chan.send(1);
await chan.close();
```

`Task.run` leaves the event loop live; `Pool` maps items over worker
isolates; `Chan` bounds memory between producers and the consumer.

---

## The terminal

**I want to ask, confirm, and show progress.**

```dart
final name = await Cli.ask('Your name?');
final ok = await Cli.confirm('Proceed?');
final bar = Cli.bar(100, label: 'Downloading', unit: 'B');
try {
  bar.set(50);
} finally {
  bar.close();
}
final pick = await Cli.choose('Pick one', ['alpha', 'beta']);
await Cli.spin('Fetching', () async => 'data');
```

Prompts, bars and spinners write to stderr; `Cli.print` writes to stdout, so
`app --json | jq` gets only data. Piped output or `NO_COLOR` disables the live
region (each bar prints one line when it ends); without Unicode, `ok`/`failed`
and ASCII glyphs stand in.

**I want a terminal app.**

```dart
await Tui.run((term) async {
  while (true) {
    term.draw((ui) {
      ui.box(
        title: 'App',
        build: (box) => box.text('Press "q" to exit.'),
      );
    });
    if (await term.poll() case final ev? when ev.key == 'q') break;
  }
});
```

Widgets (box, text, bar, spinner, list, split, button, field, tabs, table, popup, markdown, picture …) paint a cell grid; only
changed cells are written. term.listen(stream) turns a stream (a Chan's recv()) into Post
events. Tests drive the same loop on a FakeTerminal (import testing.dart).

---

## Native libraries

```dart
if (!Native.ok) Cli.print(Native.reason ?? 'no native library');
```

`Native.ok` checks all three libraries (`dart_toolkit_native`, `dart_toolkit_chrome`,
`dart_toolkit_tui`), opened from `native/lib/<os>_<arch>/` (or beside the
executable, or what `DART_TOOLKIT_NATIVE`, `DART_TOOLKIT_CHROME_LIB`,
`DART_TOOLKIT_TUI_LIB` name). A stale ABI is refused at load. Programmatic first-use
install is follow-up work; until then build with `make native` or fetch the release asset
for your target into that folder.

---

## Examples

- [`example/keybox`](example/keybox): downloads a whole box set (artwork, scans and a soundtrack
  found by following links) with a worker `Pool`, then zips it.
- [`example/puremedia`](example/puremedia): scrapes a shop's catalog into a JSON cache and
  mirrors every album's thumbnail; `--volume N` keeps one.
- [`example/annasarchive`](example/annasarchive): a terminal app that searches a site through
  a real browser and downloads books in the background, resuming partial files.

Plain `dart run` recompiles what a script imports on every start.

[`CONVENTIONS.md`](CONVENTIONS.md) has the rules; [`CHANGELOG.md`](CHANGELOG.md) the releases.
MIT — see [LICENSE](LICENSE).
