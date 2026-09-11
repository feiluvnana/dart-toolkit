# Terminal Output & Input (`system.console.*`)

Terminal IO, split into sub-namespaces: `logger` for status lines, `writer` for structured output, `reader` for prompts, plus `terminal` and `cursor` for raw control.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final log = system.console.logger;

  log.step(1, 2, 'Fetching');
  final data = await log.task('Downloading', () async => ['item1', 'item2']);
  log.ok('Got ${data.length} records');

  system.console.writer.table(
    Table(headers: ['Metric', 'Value'])..add(['Records', data.length]),
  );

  if (await system.console.reader.confirm('Write to disk?')) {
    io.dump('out.json', data);
  }
}
```

---

## 1. Status Logging (`system.console.logger`)

| Method | Badge | Stream |
| :--- | :--- | :--- |
| `info(msg)` | ℹ | stdout |
| `ok(msg)` | ✔ | stdout |
| `warn(msg)` | ⚠ | stdout |
| `step(n, total, msg)` | `[n/total]` | stdout |
| `debug(msg)` | ⚙ | stdout |
| `error(msg, [exception, stack])` | ✖ | stderr |

Errors go to stderr so a script's diagnostics survive piping.

### Severity filtering

```dart
system.console.logger.level = LogLevel.warn;   // drop info/ok/step/debug
system.console.logger.level = LogLevel.none;   // silence everything
```

`LogLevel` runs `none < error < warn < info < debug`.

### Timestamps and JSON

```dart
system.console.logger.stamp = true;              // prefix each line with the time
system.console.logger.format = LogFormat.json;   // one JSON object per line
```

`LogFormat.plain` (default) draws a badge for a person reading a terminal. `LogFormat.json` writes `{"level":"ok","message":"Done"}` for a machine reading a file — badges become a named `level`, escape codes are stripped, `step` carries `step` and `total` fields, `error` carries `error` and `stack`, and `stamp` adds a `time` field rather than a prefix.

Where the lines go is the writer's business, so a run logs to a file the same way it logs to a screen:

```dart
system.console.logger.writer = ConsoleWriter(out: File('run.log').openWrite());
```

### `task`

Runs an action behind a spinner, resolving to a tick or a cross. The error is rethrown either way:

```dart
final result = await system.console.logger.task('Resolving', () async {
  return await expensiveWork();
});
```

---

## 2. Structured Output (`system.console.writer`)

```dart
system.console.writer.write('no newline');
system.console.writer.writeln('with newline');
system.console.writer.rule();                 // full-width line
system.console.writer.rule('Summary');        // captioned
system.console.writer.box('multi\nline', title: 'Notes');
system.console.writer.table(table);
```

### Tables

Build a `Table`, then render or print it. Building and printing are separate, so a table is never printed out from under you:

```dart
final table = Table(
  headers: ['File', 'Size'],
  alignments: [ColumnAlign.left, ColumnAlign.right],
)..addAll([
  ['track01.mp3', util.size.format(5242880)],
  ['track02.mp3', util.size.format(4194304)],
]);

system.console.writer.table(table);   // print it
final text = table.render();        // or keep the string
```

Column widths are measured with `Ansi.width`, so coloured cells still align. `TableStyle.unicode` (default) and `TableStyle.ascii` are available.

A cell may hold newlines, and `width` caps the rendered width — the widest columns are narrowed first, and their cells wrap to fit:

```dart
final table = Table(headers: ['URL', 'Error'], width: system.console.writer.width)
  ..add(['$url', 'Connection reset\nRetried 3 times']);
```

Wrapping measures terminal columns rather than code units, so a wrapped cell of CJK or emoji still fits the column it was cut for. `Ansi.wrap(text, width)` does the same job on its own.

---

## 3. Progress Bars

```dart
final bar = Progress(total: files.collect(.count()), message: 'Downloading');
for (final f in files.collect(.list())) {
  await io.async.read(f.path);
  bar.tick(1, f.path);
}
bar.done('Complete');
```

```dart
bar.update(50, total: 200, message: 'Resized');
bar.fail('Aborted');
bar.current;
```

Set `unit: ProgressUnit.bytes` to render byte totals and a transfer rate:

```dart
final bar = Progress(total: 1024, unit: ProgressUnit.bytes);
await net.http.download(url, dest, onProgress: (got, total) => bar.update(got));
bar.done();
```

Rate and ETA appear once there is enough elapsed time to be meaningful. The bar repaints at most every 80 ms, and renders only to a terminal, so piped output stays clean.

---

## 4. Spinners

```dart
final spinner = Spinner()..start('Resolving dependencies');
spinner.update('Downloading');
spinner.ok('Resolved');    // or spinner.fail('Failed')
```

---

## 5. Prompts (`system.console.reader`)

Input is read from a single non-blocking stdin subscription, so a spinner or progress bar **keeps animating** while a prompt waits.

```dart
final name = await system.console.reader.ask('Project name', fallback: 'demo');
final go = await system.console.reader.confirm('Continue?');
final token = await system.console.reader.secret('API token');   // no echo

final env = await system.console.reader.pick(
  'Target environment',
  options: ['dev', 'staging', 'prod'],
);

final targets = await system.console.reader.picks(
  'Platforms',
  options: const ['macos', 'linux', 'windows'],
  label: (p) => p.toUpperCase(),
);
```

- `ask` re-prompts until `validator` accepts the answer; an empty answer takes `fallback`.
- `pick` re-prompts until a valid index is entered.
- `picks` accepts `1, 3`, `all`, or an empty answer for nothing.

```dart
await system.console.reader.ask('Port', validator: (v) => int.tryParse(v) != null);
```

### Reading a pipe

A tool is often given its input rather than asked for it — `cat urls.txt | mytool`. `lines` is that input, and `piped` is how a tool tells which mode it is in:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final reader = system.console.reader;

  final urls =
      reader.piped
          ? await reader.lines.collect(.list())
          : [await reader.ask('URL')];

  for (final url in urls) {
    system.console.logger.info(url.trim());
  }
  await reader.close();
}
```

`lines` shares the one stdin subscription with `line` and the prompts, so a tool can read a pipe and still ask a question. It ends at end of input; against a terminal that means it waits for the reader to end the input themselves, which is what `piped` is for.

---

## 6. Colours (`Ansi`)

String extensions apply ANSI codes, and no-op when colour is unavailable:

```dart
'text'.red().bold();
'text'.brightgreen();
'text'.dim().italic();
'text'.bgblue();
```

Colour is disabled automatically when `NO_COLOR` is set or stdout is not a terminal. Force or override with `Ansi.enabled = true` or `Ansi.forceColor = true`.

Advanced palette and truecolor:

```dart
'text'.color256(208);                 // 256-color palette index
'text'.bgcolor256(235);               // 256-color background
'text'.rgb(255, 100, 50);             // 24-bit truecolor RGB
'text'.hex('#ff6432');                // Hex color code
```

```dart
// setup: final styled = Ansi.red + 'red' + Ansi.reset;
Ansi.strip(styled);       // remove every escape sequence
Ansi.width(styled);       // width in terminal columns, escapes ignored
styled.plain;             // extension forms
styled.width;
```

---

## 7. Testable Console Output

Everything here that writes to the screen writes through a `ConsoleWriter`. Give one a `StringBuffer` and the output becomes a value:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() {
  final out = StringBuffer();
  final err = StringBuffer();
  final writer = ConsoleWriter(out: out, err: err, tty: true, width: 40);

  ConsoleLogger(writer).ok('All tests passed');
  Progress(total: 2, writer: writer)
    ..tick()
    ..done('Finished');
  Spinner(writer: writer)
    ..start('Working')
    ..ok('Worked');
  Terminal(writer).bell();

  assert(out.toString().contains('All tests passed'));
  assert(out.toString().contains('Finished'));
}
```

| Constructor argument | What it decides |
| :--- | :--- |
| `out`, `err` | Where the two streams go. Default `stdout` and `stderr`. |
| `tty` | Whether anything screen-only — escape codes, a repainting bar, a spinner frame — is written at all. Defaults to whether **stdout** is a terminal for a writer using stdout, and to `false` for one given a sink of its own. |
| `width`, `height` | Override the terminal's size, so a table or a rule renders at a size a test can predict. |

`tty` is the switch that keeps a redirected run clean: a piped script carries no escape codes, no repainted bars and no spinner frames. Pass `tty: true` with a buffer to capture exactly what a terminal would have received.

`Progress`, `Spinner`, `Terminal`, `Cursor` and `ConsoleLogger` all take a `writer`, and `system.console.*` binds them to `system.console.writer`.

---

## 8. Terminal & Cursor

```dart
system.console.writer.width;      // columns, or 80
system.console.writer.height;     // rows, or 24

system.console.terminal.clear();
system.console.terminal.line();   // erase the current line
system.console.terminal.bell();

system.console.cursor.hide();
system.console.cursor.show();
system.console.cursor.up(2);
system.console.cursor.save();
system.console.cursor.restore();
```

Geometry belongs to the writer — the thing that knows where the output is going, and the thing a test can size. Control codes belong to `Terminal` and `Cursor`, and every one of them is a no-op when the writer is not a terminal.
