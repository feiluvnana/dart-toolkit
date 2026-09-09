# CLI Arguments (`system.cli.*`)

A dependency-free command line parser supporting flags, options, subcommands, automatic help generation, and strict validation.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) async {
  // Declarative definition
  system.cli
    ..flag('force', alias: 'f', desc: 'Overwrite existing files')
    ..option('concurrency', alias: 'c', desc: 'Worker count', def: '4');

  system.cli.parse(args);

  system.cli.subcommand('build', (sub) {
    print('Building with concurrency ${sub.get('concurrency', 4)}');
  });

  if (system.cli.has('help', 'h')) {
    print(system.cli.usage(syntax: 'dart run tool.dart [options] <files...>'));
    return;
  }

  final force = system.cli.has('force');
  final size = system.cli.get('concurrency', 4);
  final command = system.cli.command; // 'build', 'serve', or null
  final files = system.cli.list();

  print('force: $force, workers: $size, cmd: $command, files: ${files.length}');
}
```

Call `parse` before reading arguments. Declarations (`flag`, `option`, `subcommand`) can be registered before `parse` to enable automatic help formatting and `require` validation.

---

## 1. Supported Shapes

| Input | Parsed as |
| :--- | :--- |
| `--force` | flag `force` |
| `-f` | flag `f` |
| `-abc` | bundled short flags `a`, `b`, `c` |
| `--name=value` | option `name` = `value` |
| `--name value` | option `name` = `value` |
| `-p 8` | option `p` = `8` |
| `--offset -5` | option `offset` = `-5` (negative numbers parsed as values, not flags) |
| `--no-cache` | negative flag `no-cache` |
| `-- file.txt` | bare `--` ends option parsing; remaining tokens treated as positionals |
| `file.txt` | positional argument |

---

## 2. Declarative Definitions & Validation

Declare options and flags to specify descriptions, defaults, and aliases:

```dart
system.cli
  ..flag('verbose', alias: 'v', desc: 'Enable debug output')
  ..option('output', alias: 'o', desc: 'Destination directory', def: 'dist')
  ..require(['output']); // Throws ArgumentError if missing and has no default
```

### Auto-Generated Help (`usage`)

```dart
final help = system.cli.usage(
  syntax: 'tool [command] [options]',
  desc: 'Automation utility for building and deployment.',
);
print(help);
```

### Manual Help Formatting (`help`)

```dart
system.cli.help(
  syntax: 'dart run tool.dart [options] <files...>',
  desc: 'Processes files concurrently.',
  flags: {'-f, --force': 'Overwrite existing output', '-h, --help': 'Show help'},
  options: {'-c, --concurrency <n>': 'Simultaneous workers (default 4)'},
);
```

---

## 3. Subcommands

When using subcommands like `git commit -m ...`:

```dart
system.cli.parse(args);

final command = system.cli.command;          // e.g. 'commit'
final rest = system.cli.rest;  // e.g. ['-m', 'message']
```

---

## 4. Reading Values

### `get<T>(name, fallback, [alias])`

`T` is inferred from `fallback`, which is required — so the result is never null and never needs an explicit type argument:

```dart
system.cli.get('concurrency', 4);      // int
system.cli.get('name', '');            // String
system.cli.get('rate', 1.5);           // double
system.cli.get('cache', true);         // bool
```

For `bool`, `--no-x` yields `false`, a bare `--x` yields `true`, and `--x=true|1` is honoured.

### `has(name, [alias])`

```dart
system.cli.has('force', 'f');    // --force or -f
```

> `--no-force` does **not** make `has('force')` true. Test for the negative form with `no('force')`, or read the boolean with `get('force', true)`.

### `no(name)`

```dart
system.cli.no('cache');    // --no-cache or --nocache
```

### `all<T>(name, [alias])`

Every value of a repeated option:

```dart
// --tag a --tag b
system.cli.all<String>('tag');   // ['a', 'b']
// --id 1 --id 2
system.cli.all<int>('id');       // [1, 2]
```

### `list()` and `raw`

```dart
system.cli.list();   // positional arguments, in order
system.cli.raw;      // the argument list exactly as parsed
```

Leading dashes are optional: `has('--force')` and `has('force')` are identical queries.

---

## 5. Testing CLI Parsers

Construct a `Cli` directly to parse an argument list other than the process's own:

```dart
final cli = Cli(['--mode=release', '-v', 'target.dart']);
expect(cli.get('mode', ''), 'release');
expect(cli.list(), ['target.dart']);
```

