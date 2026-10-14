# dart_toolkit

Scripting in Dart without the boilerplate: HTTP, HTML, files, archives, shells, prompts, terminal UIs and a browser, as small modules that each work alone and compose through one `Reader | Pipe > Writer` model. Pure Dart (no native code, no codegen).

```yaml
dependencies:
  dart_toolkit: ^0.0.4
```

## Tour

```dart
import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/scrape.dart';

Future<void> main() async {
  // Download, verify and unpack in one pass; a bad checksum never lands.
  await (Http.get('https://example.com/tool.tar.xz') | Hash.sha256(expect: sum) > Archive.unarchive('opt'));

  // Crawl a site into records, staying inside it, with a progress bar.
  final bar = Console.bar(null, label: 'pages');
  final titles = await Scrape.crawl<String>(['https://docs.example/'], (v) async {
    final doc = await v.html();
    v.emit(doc.$('h1').text());
    v.follow(doc.$('a').attrs('href'), (w) async => w.emit((await w.html()).$('h1').text()), under: 'https://docs.example/');
  }, onProgress: (done, total) => bar.setTotal(total).tick()).toList();

  // Save, archive with a password, and tell the human.
  await Fs.file('titles.txt').write(titles.join('\n'));
  await (Archive.archive(['titles.txt'], format: .sevenZip, password: 'pw') > Fs.file('titles.7z'));
  Console.notify('done: ${titles.length} pages');
}
```

## Modules

| Import | For | Highlights |
|---|---|---|
| `core` | the shared model | `Reader` (`bytes` `text` `lines`), `Writer`, `Pipe`, `Closeable`, `Origin` |
| `http` | requests | Future mirrors (`Http.get(u).json()`), retries, `query:`, cookies, streamed bodies, `check:` |
| `html` | parsing and selectors | `Html.parse(s).$('a').attrs('href')`, `text()` that reads like a page |
| `json` | reading JSON | dotted paths with `*`, typed `value<T>()`, `asList<T>()` |
| `fs` | files and folders | sealed `File`/`Dir`/`Link`, atomic writes, merging copies, `Fs.sanitize(name)` |
| `archive` | zip, tar, tgz, 7z, RAR | `archive(paths, password:)`, `unarchive(dir)` for zip/tar/tgz/.tar.xz/7z/RAR4/RAR5 |
| `hash` | md5 … sha512 | in a pipe, `expect:` to verify, `of(reader)` |
| `shell` | programs | `Shell.run(cmd, check:, onLine:)`, `Shell.filter` as a `Pipe`, `Shell.open` |
| `pool` | fan-out | `Pool.map` (I/O lanes), `Pool.runAll` (worker isolates) |
| `cli` | command lines | typed `Opt`/`Flag`/`Arg`, subcommands, `env:`, suggestions |
| `console` | prompts and progress | `ask` `confirm` `choose` `spin` `bar` `log` `notify` `copy` |
| `tui` | full-screen apps | state-driven `Tui.run`, widgets, mouse, markdown, diffs, ASCII and no-colour fallbacks |
| `image` | decode, resize, encode | off the main isolate when large, EXIF orientation |
| `chrome` | a real browser | pages, screenshots, PDFs, downloads, evaluated JS |
| `scrape` | crawls | `Scrape.crawl` with a cache, retries, `follow(under:, skip:)`, browser mode |

Each module is one import and pays only for what it loads (a script that imports `scrape` does not load Chromium's driver). [VISION.md](VISION.md) is the full API with its rules; [ARCHITECTURE.md](ARCHITECTURE.md) has the module graph and startup costs.

## License

See [LICENSE](LICENSE).
