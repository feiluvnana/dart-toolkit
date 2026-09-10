# CLI Arguments (`cli.*`)

A dependency-free command line parser: flags, options, clustered short
switches, subcommands, defaults, environment fallbacks, automatic help and
strict validation.

---

## Quick Overview

Two ways in. Declare an interface and read it yourself:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) {
  cli
    ..flag('force', alias: 'f', desc: 'Overwrite existing files')
    ..option('concurrency', alias: 'c', desc: 'Worker count', def: 4)
    ..parse(args);

  final force = cli.has('force');
  final size = cli.get('concurrency', 0); // 4 unless given
  print('force: $force, workers: $size, files: ${cli.list()}');
}
```

Or declare commands and let `run` do the rest — parse, print `--help`,
validate, pick the handler and turn what it returns into an exit code:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

Future<int> build(Cli cli) async {
  print('building ${cli.get('out', '')} with ${cli.get('workers', 0)}');
  return 0;
}

void main(List<String> args) async {
  cli.option('out', alias: 'o', desc: 'Output directory', def: 'dist');

  cli.handle('build', build, desc: 'Build the project')
    ..option('workers', alias: 'w', desc: 'Parallel workers', def: 4);

  await system.shutdown(await cli.run(args, version: '1.1.0'));
}
```

Call `parse` before reading arguments; `run` calls it for you. Declarations
(`flag`, `option`, `handle`, `group`) can be registered in any order, but they
must exist before parsing — declaring is what tells the parser that
`--verbose main.dart` is a flag plus a positional rather than an option and its
value.

---

## 1. Supported Shapes

| Input | Parsed as |
| :--- | :--- |
| `--force` | flag `force` |
| `-f` | flag `f` |
| `-abc` | clustered short flags `a`, `b`, `c` |
| `-vo dist` | flag `v`, then option `o` = `dist` (when `o` declares a value) |
| `-vodist` | the same, with the value taken from the rest of the cluster |
| `-rf` | one flag `rf`, if `rf` itself is declared |
| `--name=value` | option `name` = `value` |
| `--name value` | option `name` = `value` |
| `-p 8` | option `p` = `8` |
| `--offset -5` | option `offset` = `-5` (negative numbers parsed as values) |
| `--no-cache` | negative flag `no-cache` |
| `-- file.txt` | bare `--` ends option parsing; the rest are positionals |
| `file.txt` | positional argument |

Only all-letter tokens cluster, so `-p8` stays the single switch `p8`. A
multi-letter short name is never split once you declare it: declare
`flag('rf')` and `-rf` stays one switch.

---

## 2. Declaring Flags and Options

```dart
cli
  ..flag('verbose', alias: 'v', desc: 'Enable debug output')
  ..option('output', alias: 'o', desc: 'Destination directory', def: 'dist')
  ..option('mode', desc: 'Build mode', allowed: ['debug', 'release'])
  ..option('token', desc: 'API token', env: 'API_TOKEN', required: true)
  ..option('tag', desc: 'Repeatable tag', csv: true);
```

| Parameter | Effect |
| :--- | :--- |
| `alias` | A short name, honoured by every later `get`, `has` and `all` |
| `desc` | The description printed in the usage block |
| `def` | The value `get` reports when the argument is absent |
| `required` | `require` throws when nothing supplies a value |
| `allowed` | `require` throws when a given value is not in the list |
| `env` | An environment variable to read when the argument is absent — on `flag` as well as `option`, so a boolean can come from the shell |
| `csv` | Splits one comma-separated value into repeats for `all` |

A flag never consumes the token after it, so declaring `verbose` is what keeps
`main.dart` a positional in `--verbose main.dart`.

### Value Resolution

`get` tries each source in turn — the command line, then `env`, then `def`,
then the fallback at the call site:

```dart
cli.option('out', def: 'dist', env: 'OUT_DIR');

cli.get('out', '');  // 'dist', or $OUT_DIR, or whatever --out gave
```

Because the default lives in the declaration, it is written once instead of at
every call site. `has` stays literal: it asks only what the *command line*
carried, so a value that arrived through `env` or `def` does not make it true.

---

## 3. Validation

### `require([names])`

Checks that every option declared `required: true` — or just `names` — resolved
to a value, and that every value given is within its `allowed` list. A `def`,
or an `env` variable that is set, counts as supplied. Throws `ArgumentError`
naming everything that failed.

```dart
cli
  ..option('output', required: true)
  ..option('mode', allowed: ['debug', 'release'])
  ..parse(args);

try {
  cli.require();
} on ArgumentError catch (error) {
  print(error.message);   // missing --output, --mode must be one of debug, ...
}
```

### `strict()` and `unknown()`

Without a strict check, `--verbse` parses happily as a flag nothing reads.
`unknown` returns every switch no declaration covers; `strict` throws on them.
A negative form counts as covered once its positive name is declared, so
`--no-cache` is known as soon as `cache` is.

```dart
final cli = Cli(['--verbose', '--verbse'])..flag('verbose');
print(cli.unknown());   // ['verbse']
cli.strict();           // throws ArgumentError
```

`run` applies it for you with `strict: true`.

---

## 4. Commands

`handle` registers a command and returns it, so the arguments only that command
uses are declared right there. Nest with `group`.

```dart
Future<int> add(Cli cli) async => 0;

void main(List<String> args) async {
  cli.flag('verbose', alias: 'v', desc: 'Log every step');

  cli.handle('build', (cli) async => 0, desc: 'Build the project')
    ..flag('release', desc: 'Optimise the output')
    ..option('out', alias: 'o', def: 'dist');

  final remote = cli.group('remote', desc: 'Manage remotes');
  remote.handle('add', add, desc: 'Add a remote')
    ..option('url', required: true);

  await system.shutdown(await cli.run(args));
}
```

`tool remote add origin --url git@host -v` resolves `remote add`, hands the
handler a `Cli` with the command name stripped from the positionals, and gives
it the command's own `url` alongside the global `verbose`. Naming a group on
its own prints that group's usage block.

### `run`

```dart
await cli.run(
  args,
  syntax: 'tool <command> [options]',  // the Usage: line
  desc: 'What this program does.',     // shown above it
  version: '1.1.0',                    // enables --version
  strict: true,                        // reject undeclared switches
  body: (cli) async => 0,              // runs when no command matches
);
```

In order, `run`:

1. resolves the deepest registered command,
2. re-reads the remaining arguments against that command's declarations plus
   the global ones,
3. prints `--help` or `--version` if asked and returns `0`,
4. applies `strict` and `require`,
5. awaits the handler and converts its result to an exit code.

`--help`, `-h` and `--version` are declared automatically unless you declare
them yourself. `body` is what lets a script with no commands at all still get
automatic help and validation.

### Exit Codes

| Return | Exit code |
| :--- | :--- |
| `null` or `true` | `0` |
| `false` | `1` |
| `int` | as given |
| a command line `run` could not understand | `Cli.usageExit` (`64`) |

`run` prints the reason and the usage block to stderr before returning
`Cli.usageExit`. Only `ArgumentError` is caught, so a genuine failure inside a
handler still reaches the caller with its stack trace intact.

### `subcommand`

The low-level primitive, for scripts that would rather branch by hand:

```dart
final cli = Cli(args);
final command = cli.command;   // e.g. 'commit'
final rest = cli.rest;         // e.g. ['-m', 'message']
cli.subcommand('commit', (sub) => print(sub.rest));
```

---

## 5. Reading Values

### `get<T>(name, fallback, [alias])`

`T` is inferred from `fallback`, which is required — so the result is never
null and never needs an explicit type argument:

```dart
cli.get('concurrency', 4);      // int
cli.get('name', '');            // String
cli.get('rate', 1.5);           // double
cli.get('cache', true);         // bool
```

For `bool`, `--no-x` yields `false`, a bare `--x` yields `true`, and
`--x=true|1` is honoured.

### `has(name, [alias])`

```dart
cli.has('force', 'f');    // --force or -f
```

> `--no-force` does **not** make `has('force')` true. Test for the negative
> form with `no('force')`, or read the boolean with `get('force', true)`.

### `no(name)`

```dart
cli.no('cache');    // --no-cache or --nocache
```

### `count(name, [alias])`

How many times a switch was given, which is how a command line spells a level.
`-vvv` and `--verbose --verbose --verbose` both count three:

```dart
cli.flag('verbose', alias: 'v');

system.console.logger.level = switch (cli.count('verbose')) {
  0 => LogLevel.warn,
  1 => LogLevel.info,
  _ => LogLevel.debug,
};
```

Zero when the switch was never given, so it reads as `has` with a number
attached.

### `all<T>(name, [alias])`

Every value of a repeated option. An option declared `csv: true` contributes
each comma-separated part, so `--tag a,b` and `--tag a --tag b` read the same:

```dart
// --tag a --tag b
cli.all<String>('tag');   // ['a', 'b']
// --id 1 --id 2
cli.all<int>('id');       // [1, 2]
```

### `list()` and `raw`

```dart
cli.list();   // positional arguments, in order
cli.raw;      // the argument list exactly as parsed
```

Leading dashes are optional: `has('--force')` and `has('force')` are identical
queries.

---

## 6. Help Output

`usage` formats a block from the declarations; `help` prints it. Both wrap to
the terminal width and list commands, defaults, allowed values and environment
fallbacks:

```dart
final cli = Cli(['--help'])
  ..flag('verbose', alias: 'v', desc: 'Log every step')
  ..option('out', alias: 'o', def: 'dist', desc: 'Output directory')
  ..option('mode', desc: 'Build mode', allowed: ['debug', 'release'])
  ..option('token', desc: 'API token', env: 'API_TOKEN', required: true);
cli.handle('build', (_) async => 0, desc: 'Build the project');

print(cli.usage(syntax: 'tool <command> [options]', desc: 'An example.'));
```

```text
An example.

Usage: tool <command> [options]

Commands:
  build                Build the project

Flags:
  -v, --verbose        Log every step

Options:
  -o, --out <value>    Output directory [default: dist]
      --mode <value>   Build mode (debug|release)
      --token <value>  API token (required) [env: API_TOKEN]
```

Pass `flags:` or `options:` to write the sections by hand instead:

```dart
cli.help(
  syntax: 'dart run tool.dart [options] <files...>',
  desc: 'Processes files concurrently.',
  flags: {'-f, --force': 'Overwrite existing output'},
  options: {'-c, --concurrency <n>': 'Simultaneous workers (default 4)'},
);
```

---

## 7. Testing CLI Parsers

Construct a `Cli` directly to parse an argument list other than the process's
own. Everything — declarations, commands, `run` — works on it, so a command
tree is testable without touching the global accessor or the process exit code:

```dart
Future<void> main() async {
  final cli = Cli(['--mode=release', '-v', 'target.dart']);
  assert(cli.get('mode', '') == 'release');
  assert(cli.list().contains('target.dart'));

  var built = '';
  final app = Cli(['build', 'main.dart']);
  app.handle('build', (sub) {
    built = sub.list().join();
    return 0;
  });
  assert(await app.run() == 0);
  assert(built == 'main.dart');
}
```
