# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.8%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A toolkit for Dart scripts: processes, files, archives, hashes, documents, tables, HTTP, a real
browser, images, a CLI and terminal apps. One way to do each thing, every part plugs into every
other through `Reader`/`Writer` pipes, and digests, archives, images and the browser run in native
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
| `core.dart`         | `Reader`, `Writer`, `Closer`, `Seeker`, `pipe`, errors                              |
| `path.dart`         | `File`, `Dir`, `Path`: read, write, copy, move, atomic renames, find                |
| `archive.dart`      | `Archive.pack/unpack/list/extract/open`, in-memory `zip`/`unzip`, `gzip`/`gunzip`   |
| `hash.dart`         | `Hash` digests, `.mac(key)`, `.writer()`, `Hex`, `Base64`                           |
| `async.dart`        | `Task.run`, `Pool`, `Worker`, `Chan`                                                |
| `process.dart`      | `Process.run/exec`, streaming `Process` with `wait(timeout:)` and tree-kill `cancel`|
| `json.dart`         | `Json.parse/dump/get/read/write`                                                    |
| `html.dart`         | `Html.parse/read`, `find`/`all`, CSS selectors                                      |
| `xml.dart`          | `Xml.parse`, the shared markup tree                                                 |
| `xpath.dart`        | `$x` XPath on an `Element`, a `Selection`, an `Html` or an `Xml`                    |
| `collection.dart`   | `Table`: CSV/TSV/JSON rows, `where`/`orderBy`/`groupBy`/`agg`, save                 |
| `http.dart`         | `Http.get/post/put/delete`, streaming `Resp`, resumable `download`                  |
| `chrome.dart`       | `Chrome.launch/connect`, `Browser.open`, `Page` drive, `shot`, `pdf`                |
| `image.dart`        | `Image` raster, transforms, codec load/save                                         |
| `cli.dart`          | `ask`, `confirm`, `choose`, `bar`, `spin`, ANSI colours                              |
| `tui.dart`          | `Tui.run` terminal apps, widgets, `FakeTerminal`                                    |
| `native.dart`       | The `dart_toolkit_native` seam (`Lib2Native`)                                       |

Hashing, archives and images run in the `dart_toolkit_native` cdylib, the browser in
`dart_toolkit_chrome`, the terminal in `dart_toolkit_tui`. Build them with `make native`
(`dart run tool/build_native.dart`), which needs Rust and a C compiler; `make native-release`
uploads the set a first use would download. Without a library those calls are `UnsupportedError`.

---

## Processes

**I want a command's output, or to know whether it worked.**

```dart
final r = await Process.run('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
Cli.print(r.out.trim());
if (r.code != 0) Cli.print('git failed: ${r.err}');
```

**I want to stream output, or stop it.**

```dart
final proc = Process('ping', ['127.0.0.1']);
await for (final line in proc.lines()) {
  Cli.print(line);
  break;
}
await proc.cancel();
```

A cancel kills the whole process tree; `wait(timeout:)` throws `TimeoutException` after one.

---

## Files and archives

**I want to read and write files.**

```dart
await File('conf.json').write('{"a": 1}');
Cli.print(await File('conf.json').text());
await File('conf.json').copy('conf.bak');
await File('conf.bak').drop();
```

Writes replace atomically (a sibling renamed over the target); `move` retries over a
Windows-held target.

**I want to zip a folder or unpack an archive.**

```dart
await Archive.pack('site', 'site.tar.zst');
await Archive.unpack('site.tar.zst', 'out');
final names = await Archive.list('site.tar.zst');
```

The format is the extension (`.zip`, `.tar`, `.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2`,
`.gz`). Members are sandbox-checked before anything is written: escapes and links are a
`SecurityException`.

**I want a checksum or a MAC.**

```dart
final hex = Hash.sha256('hello world').hex;
final fileHex = (await Hash.sha256.file('disc.iso')).hex;
final mac = Hash.sha256.mac('secret')('body');
```

Streaming sinks a pipe: `await File('big.iso').pipe(Hash.sha256.writer())`.

---

## Documents

**I want values from JSON.**

```dart
final data = Json.parse('{"a": {"b": 42}}');
final port = Json.get<int>(data, 'a.b', 8080);
Cli.print(Json.dump({'ok': true}));
```

**I want to scrape a page.**

```dart
final doc = Html.parse('<ul><li><a>one</a></li><li><a>two</a></li></ul>');
final titles = [for (final a in doc.all('a')) a.text];
```

**I want XML and XPath.**

```dart
final xml = Xml.parse('<r><i id="a">1</i><i id="b">2</i></r>');
final first = xml.$x('//i').first.text;
final second = xml.$x('//i[@id="b"]').attr('id');
```

**I want to query a CSV.**

```dart
final t = Table.cells(['name', 'price'], [
  ['apple', 3],
  ['bread', 12],
]);
final top = t.where((r) => r.get<num>('price') > 10).take(10);
await top.show();
```

---

## The network and the browser

**I want to fetch a page or an API.**

```dart
final data = await (await Http.get('https://api.site.com/users')).json();
await Http.download('https://site.com/file.zip', File('file.zip'));
```

A non-2xx throws; a `Resp` is itself a `Reader`, so `Http.get(url).pipe(File('huge.iso'))`
streams without buffering.

**I want pages a browser renders.**

```dart
final chrome = await Chrome.launch();
final page = await chrome.open('https://example.com');
Cli.print(await page.title());
await page.shot().pipe(File('shot.png'));
await chrome.close();
```

`close` kills the whole tree and drops the temp profile. `page.html()` feeds `Html.parse`;
`page.pdf()` prints to PDF.

---

## Media

**I want to edit an image.**

```dart
final img = Image.blank(width: 100, height: 50);
await img.fit(48, 48).save('thumb.png');
```

`quality` (0–100) applies to JPEG/WebP only; PNG ignores it.

---

## Work in parallel

**I want one background result, or a channel of them.**

```dart
final answer = await Task.run(() async => 40 + 2);
final chan = Chan<int>(cap: 10);
await chan.send(1);
final first = chan.tryRecv();
await chan.close();
```

`Task.run(..., isolate: true)` leaves the event loop live; `Pool` maps items over worker
isolates; `Chan` bounds memory between producers and the consumer.

---

## The terminal

**I want to ask, confirm, and show progress.**

```dart
final name = await Cli.ask('Your name?');
final ok = await Cli.confirm('Proceed?');
final bar = Cli.bar(total: 100);
bar.set(50);
bar.done();
```

Everything drawn goes to stderr, so `app --json | jq` gets only data.

**I want a terminal app.**

```dart
await Tui.run((term) async {
  while (true) {
    term.draw((ui) {
      ui.box(title: 'App');
      ui.text('Press "q" to exit.');
    });
    if (await term.poll() case final ev? when ev.key == 'q') break;
  }
});
```

Widgets (`box`, `text`, `bar`, `list`, `split`, `button`, `field`, `picture` …) paint a cell
grid; only changed cells are written. Tests drive the same loop on a `FakeTerminal` (frames,
injected keys, no terminal needed).

---

## Native libraries

```dart
if (!Lib2Native.isAvailable) Cli.print(Lib2Native.reason ?? 'no native library');
```

`Lib2Native`, `Lib2Chrome` and `Lib2Tui` open `native2/lib/<os>_<arch>/` (or beside the
executable, or what `DART_TOOLKIT_NATIVE`, `DART_TOOLKIT_CHROME_LIB`,
`DART_TOOLKIT_TUI_LIB` name). A stale ABI is refused at load. Programmatic first-use
install is follow-up work; until then build with `make native` or fetch the release asset
for your target into that folder.

---

## Examples

- [`example/monitor`](example/monitor): a live TUI dashboard — a `Chan` of stats drained
  into a board at the poll pace.

Plain `dart run` recompiles what a script imports on every start.

[`CONVENTIONS.md`](CONVENTIONS.md) has the rules; [`CHANGELOG.md`](CHANGELOG.md) the releases.
MIT — see [LICENSE](LICENSE).
