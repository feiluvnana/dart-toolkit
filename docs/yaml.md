# YAML & TOML (`format.yaml.*`, `format.toml.*`)

The configuration formats everything else a script coordinates with is written
in — `pubspec.yaml` first, then CI, then Docker Compose, then Kubernetes; and
`Cargo.toml`, `pyproject.toml` for the other half.

[`io.dump`](io.md) covers the format this library *writes*. These are the
ones everything else *reads*, and they are spelled member for member like
[`format.json`](json.md).

A format belongs in `format` for the same reason `format.zip` does: knowing what a
YAML file looks like is knowledge Dart does not have. Rule 1's definition of a
subject is the format or the binary — and after 3.2.0, `format` holds only the
formats. Wrapping a binary is `system.run` plus arguments.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final pubspec = await format.yaml.read('pubspec.yaml');

  system.console.logger.info('${pubspec.text('name')} ${pubspec.text('version')}');
  system.console.logger.info('deps: ${pubspec.at('dependencies').count}');
}
```

---

## 1. Three members, twice

All three namespaces are spelled member for member, and all three mirror
[`io.csv`](csv.md) — so the format namespaces are learnable from each other:

| Member | Gives |
| :--- | :--- |
| `format.json.parse(text)` | `Json` |
| `format.json.read(path)` | `Future<Json>` |
| `format.json.format(value, {indent})` | `String` |
| `format.yaml.parse(text)` | `Json` |
| `format.yaml.read(path)` | `Future<Json>` |
| `format.yaml.format(value, {indent})` | `String` |
| `format.toml.parse(text)` | `Json` |
| `format.toml.read(path)` | `Future<Json>` |
| `format.toml.format(value)` | `String` |

---

## 2. Reading gives the `Json` cursor

That is this page's best property, and the reason it is cheap: YAML, TOML and
JSON all decode to the same maps, lists and scalars, so a second cursor would be
two spellings of one operation. Everything on [`Json`](json.md) works here,
JSONPath included:

```dart
final cfg = await format.yaml.read('config.yaml');

cfg.text('database.host');                       // String?
cfg.number('database.port');                     // num?
cfg.flag('features.strict');                     // bool?
cfg.at('hosts').texts();                         // Sequence<String>
cfg.jsonpath(r'$..sdk').transform(.map.nonnull((n) => n.text()));   // every sdk constraint

final cargo = await format.toml.read('Cargo.toml');
cargo.text('package.version');
cargo.text('bin[0].name');
```

A file that is not there, and text that is not the format, both read as the
empty cursor rather than throwing — so a missing optional config needs no
`io.has` in front of it.

The cursor holds plain maps and lists, not `YamlMap` views, so what comes out of
a YAML file re-encodes as JSON without any conversion:

```dart
io.dump('config.json', (await format.yaml.read('config.yaml')).raw);
```

---

## 3. Writing

`format` writes block style — the shape the files in the wild are written in:

```dart
format.yaml.format({
  'name': 'scraper',
  'version': '1.0',
  'tags': ['fast', 'polite'],
  'limits': {'rate': 10, 'burst': 20},
});
```

```yaml
name: scraper
version: '1.0'
tags:
  - fast
  - polite
limits:
  rate: 10
  burst: 20
```

Note `'1.0'`. A plain scalar that would read back as a number, a boolean, a
null or a structure is quoted, so the document says what it was handed rather
than something adjacent to it — `on`, `yes`, `no` and `~` included.

`format.toml.format` takes a map, because TOML has no way to write a bare list or
scalar as a whole document; anything TOML cannot carry gives an empty string
rather than throwing.

---

## 4. The dependency

`format.yaml` uses `package:yaml` and `format.toml` uses `package:toml`. YAML in
particular is not a format to reimplement — the subset boundary is exactly where
the bugs live — and `yaml` is maintained by the SDK team. Both are hidden behind
these two accessors: no caller names a `YamlMap` or a `TomlDocument`.

---

## See Also

- [`format.json`](json.md) — the cursor these return
- [`io.*`](io.md) — `io.dump`, the format this library writes
- [`format.json.*`](json.md) — the third codec, and the `Json` cursor
- [`format.zip.*`](zip.md) — the archive format
