# dart_toolkit

Scripting in Dart without the boilerplate: HTTP, HTML, files, archives, shells, prompts, terminal UIs and a browser, as small modules that each work alone and compose through one model: `reader | pipe & probe > writer`. `|` changes bytes, `&` watches the work (a progress bar on anything that takes time), `>` stores. Pure Dart, no codegen; ffmpeg and 7-Zip are downloaded on first use (pinned by sha256) for media and heavy archives.

```yaml
dependencies:
  dart_toolkit: ^0.1.0
```

## Tour

```dart
import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/pool.dart';

Future<void> main() async {
  // Settings live on the client: stated once, not on every call.
  final http = Http.client(retries: 3, rate: Rate(4, 1.seconds), check: true);

  // Download, verify and unpack in one pass; a bad checksum never lands.
  await (http.get('https://example.com/tool.tar.xz') | Hash.sha256(expect: sum) > Archive.unarchive('opt'));

  // Fetch pages in parallel, watched; one failure never stops the rest.
  final pages = await (Pool.settle(urls, (u) => http.get(u).html().$('h1').text()) & Console.bar('pages'));
  final titles = pages.values();

  // Save, archive with a password (watched: the bar learns the total), and tell the human.
  await Fs.file('titles.txt').write(titles.join('\n'));
  await (Archive.archive(['titles.txt'], format: .sevenzip, password: 'pw') & Console.bar('7z') > Fs.file('titles.7z'));
  Console.notify('done: ${titles.length} pages');
}
```

## Four patterns

| Pattern | Shape | Example |
|---|---|---|
| read | `source.reading()` | `http.get(u).json()`, `Fs.file(p).text()` |
| flow | `reader \| pipe & probe > writer` | `http.get(iso) & Console.bar('iso') \| hash > Fs.file('a.iso')` |
| watch | `work & probe` | `Pool.map(urls, fetch) & bar`, `dir.copy(to) & bar`, `Shell.run(cmd) & bar` |
| act | `receiver.action(…)`, options named | `page.fill('#q', 'x').click('#go')` |

A probe shows the whole run it is in: a flow's source bytes against the source's length (learned, never passed), an encode in media time, a pool's jobs, a plain future as a spinner.

## Modules

| Import | For | Highlights |
|---|---|---|
| `core` | the shared model | `Reader` (`bytes` `text` `lines` `cookies`), `Writer`, `Pipe`, `Probe` (`&`), `Task`, `Meter`, `Closeable`, `Origin`, `Cookies`, `Rate` (`perHost:`), `3.seconds`, `now.format(…)`, `d.human()` |
| `http` | requests | `Http.client(base:, headers:, cookies:, rate:, proxy:, resume:, max:, …)` (Chrome user-agent, `socks5://`), `get(u) & bar > file` that skips and resumes, safe retries, `Body.multipart`, `sent()`, `Http.pool`, `Feed` (page a newest-first listing up to what you have, resuming an interrupted run), `browser: .page`/`.api` headers, `login:` paths that throw `SessionException` |
| `html` | parsing and selectors | in-house HTML5 parser, `$('a').attrs('href')`, `ul.$('> li')`, absolute `srcset`/`og:image`, `json()` `table()` `form()` `markup()`, `text()` that reads like a page; re-exports `json` |
| `json` | reading JSON | dotted paths with `*`, `**`, `-1`, whole-path `a\|b.c`, typed `value<T>()` (`DateTime` from ISO or Unix time), `or('')`, `text()`, `texts()`, `max`, `reader.ndjson()` |
| `csv` | CSV | RFC 4180 `parse`, `encode`, `reader.csv(or:)`, streamed `reader.rows()` |
| `yaml` | reading YAML | in-house YAML 1.2 reader, `file.yaml().$('version').text()`: the `json` reading API |
| `fs` | files and folders | sealed `File`/`Dir`/`Link`, atomic writes, `text(or:)`, `list(match: '**/*.jpg')`, `dir.size()`, watchable `copy`/`move`/`list`, `Fs.tempDir`, `file.lock(timeout:)`, `modified()`/`touch(t)`, `Fs.sanitize(name)` |
| `archive` | zip, tar, tgz, 7z, RAR, bz2/zst, cab/ar/xar | `archive(paths, password:)` (zip and tar stream, 7z via 7-Zip LZMA2; a probe sees the input packed), `unarchive(dir)` for zip/tar/tgz/.tar.xz/7z/RAR4/RAR5 in Dart, big or exotic ones via 7-Zip; modes, mtimes and inside links kept |
| `hash` | md5 … sha512, HMAC | in a pipe, `expect:` to verify, `key:` for HMAC, `hex()` `bytes()` |
| `shell` | programs | `Shell.run(cmd, timeout:, cancel:)` (a `Task`; `.check()`), `Shell.read(cmd)` live as a `Reader`, `Shell.filter` as a `Pipe`, `Shell.which`, `Shell.open` |
| `pool` | fan-out | `Pool.map` (fail fast), `Pool.settle` (an outcome per item), both watchable `Task`s, `retries:` `isolates:`, held `Pool(limit:).run(job)` lanes (a `Task` too) |
| `cli` | command lines | typed `Opt`/`Flag`/`Arg`/`Rest`, `min:`/`max:`, subcommands, `env:`, `dotenv:`, `version:`, suggestions |
| `console` | prompts and progress | `ask` `confirm` `choose` `key` (all take `or:` and `timeout:`), `bar(label)` (a probe), `log(failed:)`, `logged()` (the run's log as content), `table` `notify` `copy`, `out()`/`input()` for stdout/stdin |
| `tui` | full-screen apps | state-driven `Tui.run`, widgets, `write(inline:)` spans, `bar(meter)`, `bars()` and `log()` panes for Console's bars and log, mouse, markdown, ASCII and no-colour fallbacks |
| `image` | read, resize, crop, encode, compress | ffmpeg engine: HEIC/AVIF/WebP, EXIF kept |
| `video` | probe, remux, encode, trim, frames, compress | h264/h265/AV1/VP9, HLS/DASH, encodes a probe watches in media time; pinned FFmpeg |
| `chrome` | a real browser | pages, screenshots, PDFs, downloads with the browser's progress, evaluated JS, `cookies()` for http, `responses()` capture |

Each module is one import and pays only for what it loads (a script that imports `html` does not load Chromium's driver). [docs/VISION.md](docs/VISION.md) is the full API with its rules; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the module graph and startup costs.

## License

See [LICENSE](LICENSE).
