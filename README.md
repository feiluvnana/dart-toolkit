# dart_toolkit

Scripting in Dart without the boilerplate: HTTP, HTML, files, archives, shells, prompts, terminal UIs and a browser, as small modules that each work alone and compose through one `Reader | Pipe > Writer` model. Pure Dart, no codegen; ffmpeg and 7-Zip are downloaded on first use (pinned by sha256) for media and heavy archives.

```yaml
dependencies:
  dart_toolkit: ^0.0.5
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

  // Fetch pages in parallel with a progress bar; one failure never stops the rest.
  final bar = Console.bar(urls.length, label: 'pages');
  final pages = await Pool.settle(urls, (u) => http.get(u).html().$('h1').text(), onDone: bar.tick);
  final titles = pages.values();

  // Save, archive with a password, and tell the human.
  await Fs.file('titles.txt').write(titles.join('\n'));
  await (Archive.archive(['titles.txt'], format: .sevenzip, password: 'pw') > Fs.file('titles.7z'));
  Console.notify('done: ${titles.length} pages');
}
```

## Modules

| Import | For | Highlights |
|---|---|---|
| `core` | the shared model | `Reader` (`bytes` `text` `lines`), `Writer`, `Pipe`, `Closeable`, `Origin`, `Cookies` (`load` a session file), `Rate` (`perHost:`), `3.seconds`, `now.format(…)`, `d.human()` |
| `http` | requests | `Http.client(base:, headers:, cookies:, rate:, proxy:, resume:, limit:, …)` (Chrome user-agent, `socks5://`), `get(u) \| bar > file` that skips and resumes, safe retries, `cache:` with ETag revalidation, `Body.multipart`, `sent()`, `Http.pool`, `Http.serve` |
| `html` | parsing and selectors | in-house HTML5 parser, `$('a').attrs('href')`, `ul.$('> li')`, absolute `srcset`/`og:image`, `json()` `table()` `form()` `html()`, `text()` that reads like a page; re-exports `json` |
| `json` | reading JSON | dotted paths with `*`, `**`, `-1`, whole-path `a\|b.c`, typed `value<T>()`, `or('')`, `text()`, `max`/`min`, `reader.ndjson()` |
| `csv` | CSV | RFC 4180 `parse`, `records`, `encode`, `reader.csv()`, streamed `reader.rows()` |
| `yaml` | reading YAML | in-house YAML 1.2 reader, `file.yaml().$('version').text()`: the `json` reading API |
| `fs` | files and folders | sealed `File`/`Dir`/`Link`, atomic writes, `text(or:)`, `list(match: '**/*.jpg')`, `watch()`, `dir.size()`, `Fs.tempDir`, `file.lock`, `modified()`/`touch(t)`, `Fs.sanitize(name)` |
| `archive` | zip, tar, tgz, 7z, RAR, bz2/zst, cab/ar/xar | `archive(paths, password:)` (zip and tar stream, 7z via 7-Zip LZMA2), `unarchive(dir)` for zip/tar/tgz/.tar.xz/7z/RAR4/RAR5 in Dart, big or exotic ones via 7-Zip; modes, mtimes and inside links kept |
| `hash` | md5 … sha512, HMAC | in a pipe, `expect:` to verify, `key:` for HMAC, `hex()` `base64()` `bytes()`, `of(reader)` |
| `shell` | programs | `Shell.run(cmd, check:, timeout:, cancel:, onLine:)`, `Shell.which`, `Shell.filter` as a `Pipe`, `Shell.open` |
| `pool` | fan-out | `Pool.map` (fail fast), `Pool.settle` (an outcome per item), `retries:` `rate:` `isolates:`, held `Pool(limit:).run(job)` lanes |
| `cli` | command lines | typed `Opt`/`Flag`/`Arg`/`Rest`, `min:`/`max:`, subcommands, `env:`, `dotenv:`, `version:`, suggestions |
| `console` | prompts and progress | `ask(timeout:)` `confirm` `choose` `spin` `bar` `log` `table` `notify` `copy`, `Speed` meter |
| `tui` | full-screen apps | state-driven `Tui.run`, widgets, `write(inline:)` spans, `bar(since:)`, mouse, markdown, diffs, ASCII and no-colour fallbacks |
| `image` | read, resize, crop, encode, compress | ffmpeg engine: HEIC/AVIF/WebP, EXIF kept |
| `video` | probe, remux, encode, trim, frames, compress | h264/h265/AV1/VP9, HLS/DASH, progress; pinned FFmpeg |
| `chrome` | a real browser | pages, screenshots, PDFs, downloads, evaluated JS, `cookies()` for http, `responses()` capture |

Each module is one import and pays only for what it loads (a script that imports `html` does not load Chromium's driver). [docs/VISION.md](docs/VISION.md) is the full API with its rules; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the module graph and startup costs.

## License

See [LICENSE](LICENSE).
