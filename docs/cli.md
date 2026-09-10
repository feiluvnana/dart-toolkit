# CLI Arguments (`cli.*`)

A dependency-free command line parser: flags, options, clustered short
switches, subcommands, defaults, environment fallbacks, automatic help and
strict validation.

Declaring an option hands back an `Opt<T>`. Calling it reads the value. The
type and the default are settled at the declaration and nowhere else.

---

## Quick Overview

Two ways in. Declare an interface and read it yourself:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) {
  final force = cli.flag('force', alias: 'f', desc: 'Overwrite existing files');
  final size = cli.number('concurrency', alias: 'c', desc: 'Worker count', def: 4);
  cli.parse(args);

  print('force: ${force()}, workers: ${size()}, files: ${cli.args}');
}
```

Or declare commands and let `run` do the rest — parse, print `--help`,
validate, pick the handler and return its exit code:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

late final Opt<String> out;
late final Opt<int> workers;

Future<int> build(Cli cli) async {
  print('building ${out()} with ${workers()}');
  return 0;
}

void main(List<String> args) async {
  out = cli.option('out', alias: 'o', desc: 'Output directory', def: 'dist');
  final command = cli.handle('build', build, desc: 'Build the project');
  workers = command.number('workers', alias: 'w', desc: 'Parallel workers', def: 4);

  await system.shutdown(await cli.run(args, version: '1.1.0'));
}
```

Call `parse` before reading arguments; `run` calls it for you. Declarations can
be registered in any order, but they must exist before parsing — declaring is
what tells the parser that `--verbose main.dart` is a flag plus a positional
rather than an option and its value.

> **Declare inside `main`.** A top-level `final` in Dart is lazy: it runs its
> initialiser the first time something reads it. A declaration hidden in one
> would not exist when `run` builds `--help`, so the option would be missing
> from the usage block and from `strict` and `require`. Declare in `main` (or a
> function it calls) and keep the handles in `late final` top-level variables,
> as above.

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

## 2. Declaring

Eight declarations, one per shape a value can have. Each returns the `Opt<T>`
that reads it.

```dart
final verbose = cli.flag('verbose', alias: 'v', desc: 'Enable debug output');
final out = cli.option('output', alias: 'o', desc: 'Destination', def: 'dist');
final size = cli.number('concurrency', alias: 'c', desc: 'Workers', def: 4);
final rate = cli.decimal('rate', desc: 'Requests per second', def: 1.5);
final tags = cli.list('tag', desc: 'Repeatable tag', csv: true);
final mode = cli.choice('mode', Mode.values, def: Mode.debug, desc: 'Build mode');
final timeout = cli.duration('timeout', desc: 'Give up after', def: 30.s);
final since = cli.date('since', desc: 'Only rows after this date');
```

| Declaration | Reads |
| :--- | :--- |
| `flag` | `Opt<bool>` |
| `option` | `Opt<String>` |
| `number` | `Opt<int>` |
| `decimal` | `Opt<double>` |
| `list` | `Opt<List<String>>` |
| `choice` | `Opt<E>` for an enum `E` |
| `duration` | `Opt<Duration>` |
| `date` | `Opt<DateTime?>` |

| Parameter | Effect |
| :--- | :--- |
| `alias` | A short name, honoured wherever the option is read |
| `desc` | The description printed in the usage block |
| `def` | What the option reads when nothing supplied a value |
| `required` | `require` throws when nothing supplies a value |
| `allowed` | `require` throws when a given value is not in the list |
| `env` | An environment variable to read when the argument is absent — on `flag` as well, so a boolean can come from the shell |
| `csv` | On `list`: splits one comma-separated value into repeats |

A flag never consumes the token after it, so declaring `verbose` is what keeps
`main.dart` a positional in `--verbose main.dart`.

`choice` takes the enum's own values, so the accepted spellings, the usage
block and the validation all come from the type rather than a second list that
can drift from it.

`duration` and `date` read their values through
[`util.time.span`](util.md#reading-the-other-direction) and `util.time.parse`,
so every spelling those accept works on the command line:

```dart
// --timeout 30s   --timeout 1h30m   --timeout 30   (bare means seconds)
// --since 2024-03-09   --since 09/03/2024   --since '9 Mar 2024'
```

A value that is not a duration or a date reads as `def`, and `require` reports
it rather than letting the script run on a timeout nobody asked for. `date` has
no sensible default, so it reads `null` when nothing was given — `--since`
exists precisely so a script can tell *not given* from *the beginning of time*:

```dart
rows.keep((r) => since() == null || r.at.isAfter(since()!));
```

### Value Resolution

Calling an `Opt` tries each source in turn — the command line, then `env`, then
the declared `def`:

```dart
final out = cli.option('out', def: 'dist', env: 'OUT_DIR');

out();          // whatever --out gave, else $OUT_DIR, else 'dist'
out.given();    // did the *command line* carry it?
out.count();    // how many times
```

Because the default lives in the declaration, it is written once instead of at
every call site. `given` stays literal: it asks only what the command line
carried, so a value that arrived through `env` or `def` does not make it true.

An option declared on a `Command` reads from the scope that command was run
with, so a handler calls it with no argument. Outside its run there is nothing
to read and it throws `StateError` — pass a `Cli` explicitly if you need one:
`out(someCli)`.

---

## 3. Validation

### `require([names])`

Checks that every option declared `required: true` — or just `names` — resolved
to a value, that every value given is within its `allowed` list, and that every
value given for a `number` or `decimal` is actually one. A `def`, or an `env`
variable that is set, counts as supplied. Throws `ArgumentError` naming
everything that failed.

```dart
cli
  ..option('output', required: true)
  ..option('mode', allowed: ['debug', 'release'])
  ..number('concurrency', def: 4)
  ..parse(args);

try {
  cli.require();
} on ArgumentError catch (error) {
  print(error.message);   // missing --output, --concurrency must be a number...
}
```

That last check is the one worth having: `--concurrency=fast` used to read back
as the default and run on four workers without a word.

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
late final Opt<bool> verbose;
late final Opt<bool> release;
late final Opt<String> url;

void main(List<String> args) async {
  verbose = cli.flag('verbose', alias: 'v', desc: 'Log every step');

  final build = cli.handle('build', _build, desc: 'Build the project');
  release = build.flag('release', desc: 'Optimise the output');

  final remote = cli.group('remote', desc: 'Manage remotes');
  final add = remote.handle('add', _add, desc: 'Add a remote');
  url = add.option('url', required: true);

  await system.shutdown(await cli.run(args));
}

Future<int> _build(Cli cli) async => release() && verbose() ? 0 : 1;
Future<int> _add(Cli cli) async => url().isEmpty ? 1 : 0;
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
5. awaits the handler and returns what it returned.

`--help`, `-h` and `--version` are declared automatically unless you declare
them yourself. `body` is what lets a script with no commands at all still get
automatic help and validation.

### Exit Codes

A handler returns `FutureOr<int>`, and that number is the exit code. A command
line `run` could not understand returns `Cli.usageExit` (`64`) after printing
the reason and the usage block to stderr. Only `ArgumentError` is caught, so a
genuine failure inside a handler still reaches the caller with its stack trace
intact.

### `subcommand`

The low-level primitive, for scripts that would rather branch by hand:

```dart
final cli = Cli(args);
final command = cli.command;   // e.g. 'commit'
final rest = cli.rest;         // e.g. ['-m', 'message']
cli.subcommand('commit', (sub) => print(sub.rest));
```

---

## 5. Reading

Everything declared is read through its `Opt`:

```dart
final verbose = cli.flag('verbose', alias: 'v');
final size = cli.number('concurrency', def: 4);
final tags = cli.list('tag', csv: true);

verbose();          // bool
size();             // int
tags();             // List<String>

verbose.count();    // how many times: -vvv counts three
verbose.given();    // was it on the command line at all
verbose.negated();  // was --no-verbose given
```

`count` is how a command line spells a level:

```dart
system.console.logger.level = switch (verbose.count()) {
  0 => LogLevel.warn,
  1 => LogLevel.info,
  _ => LogLevel.debug,
};
```

### Positionals and the raw line

```dart
cli.args;   // positional arguments, in order
cli.rest;   // positionals after the subcommand name
cli.raw;    // the argument list exactly as parsed
```

### `switches`

The parser's own answer, before any declaration is consulted — names without
dashes, in the order they were first seen, each with the value it was given:

```dart
Cli(['-abc', 'x']).switches.keys;   // ('a', 'b', 'c')
Cli(['--out=dist']).switches;       // {'out': 'dist'}
```

This is for inspecting an argument list you did not declare. Reading a declared
option is `Opt`'s job, and keeps the type.

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
  assert(cli.option('mode')() == 'release');
  assert(cli.args.contains('target.dart'));

  var built = '';
  final app = Cli(['build', 'main.dart']);
  app.handle('build', (sub) {
    built = sub.args.join();
    return 0;
  });
  assert(await app.run() == 0);
  assert(built == 'main.dart');
}
```
