# Architecture & Base Interfaces

## Core Vision
1. **Dead simple APIs**: Minimal parameters, sane defaults, no over-engineering.
2. **Seamless integration**: Modules connect via shared base interfaces.
3. **1-word naming**: Short, consistent methods (`read`, `write`, `pipe`, `get`, `run`, `pack`, `unpack`, `load`, `save`).
4. **Top-notch performance (Option B)**: Rust Core Engine (FFI) for heavy lifting (archive, image, hash, Chrome CDP, ratatui TUI) wrapped by dead-simple Dart APIs.
5. **No fluff**: Removed XML, YAML, TOML, INI, XPath, and Table abstractions. Kept core web formats: JSON and HTML DOM.

---

## 1. Rust-Like Base Interfaces

All I/O across filesystem, HTTP, process, archive, and image builds on two base traits:

```dart
abstract interface class Reader {
  Future<int> read(Uint8List buf);
}

abstract interface class Writer {
  Future<int> write(Uint8List buf);
  Future<void> flush();
}

abstract interface class Closer {
  Future<void> close();
}

abstract interface class Seeker {
  Future<int> seek(int offset);
}
```

### The `pipe` Primitive
Everything connects through `pipe`:

```dart
Future<int> pipe(Reader src, Writer dst, {int buf = 64 * 1024}) async {
  final chunk = Uint8List(buf);
  var total = 0;
  while (true) {
    final n = await src.read(chunk);
    if (n <= 0) break;
    await dst.write(chunk.sublist(0, n));
    total += n;
  }
  await dst.flush();
  return total;
}
```

---

## 2. Cross-Module Integration

Because every module implements `Reader` and `Writer`, they chain directly:

```dart
// HTTP download directly to file
await Http.get('https://example.com/file.zip').pipe(File('data.zip'));

// HTTP response directly to archive unpacker
await Http.get('https://example.com/bundle.tar').pipe(Archive.unpack(dst: 'out'));

// Process output directly to file
await Process.run('git', ['log']).pipe(File('git.log'));

// File directly into image processing
final img = await File('photo.jpg').pipe(Image.load());
await img.fit(400, 300).pipe(File('thumb.webp'));
```

---

## 3. Naming Conventions

| Action | Method | Parameter Names |
|---|---|---|
| Read data | `read()` | `dst`, `len` |
| Write data | `write()` | `src` |
| Transfer data | `pipe()` | `dst` |
| HTTP Request | `get()`, `post()` | `url`, `body` |
| HTML DOM | `parse()`, `find()`, `all()` | `src`, `css` |
| Process Run | `run()` | `cmd`, `args` |
| Archive | `pack()`, `unpack()` | `src`, `dst` |
| Image | `load()`, `save()`, `fit()`, `crop()` | `src`, `dst`, `w`, `h` |
| JSON | `parse()`, `dump()`, `get()` | `src`, `val`, `key` |
| Hash / Digest | `sha256()`, `blake3()`, `crc32()` | `data`, `key` |
| Chrome | `open()`, `click()`, `type()`, `shot()` | `url`, `css`, `val` |
| TUI | `run()`, `draw()`, `poll()`, `box()` | `fn`, `title`, `sel` |
| CLI / Terminal | `ask()`, `bar()`, `print()` | `msg`, `val`, `total` |

---

## 4. Reading Order

1. [01_io.md](./01_io.md) - Files, directories, and path manipulation
2. [02_async.md](./02_async.md) - Async tasks, pools, and channels
3. [03_http.md](./03_http.md) - Minimal HTTP client and streaming
4. [04_json.md](./04_json.md) - High-speed JSON parsing and querying
5. [05_html.md](./05_html.md) - HTML document parsing and DOM queries
6. [06_archive.md](./06_archive.md) - Native compression and extraction
7. [07_process.md](./07_process.md) - Process execution and piping
8. [08_image.md](./08_image.md) - Native image transformation
9. [09_cli.md](./09_cli.md) - Terminal output, prompts, and progress
10. [10_hash.md](./10_hash.md) - Cryptographic digests, checksums, and encodings
11. [11_chrome.md](./11_chrome.md) - Headless Chrome automation via native CDP
12. [12_tui.md](./12_tui.md) - Terminal UI applications powered by native ratatui
13. [13_plan.md](./13_plan.md) - Step-by-step implementation plan (Option B)
