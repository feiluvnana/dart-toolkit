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

---

## 3. Progress Bars

```dart
final bar = Progress(total: files.length, message: 'Downloading');
for (final f in files) {
  await fetch(f);
  bar.tick(1, f.name);
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
final bar = Progress(total: contentLength, unit: ProgressUnit.bytes);
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
  options: platforms,
  label: (p) => p.displayName,
);
```

- `ask` re-prompts until `validator` accepts the answer; an empty answer takes `fallback`.
- `pick` re-prompts until a valid index is entered.
- `picks` accepts `1, 3`, `all`, or an empty answer for nothing.

```dart
await system.console.reader.ask('Port', validator: (v) => int.tryParse(v) != null);
```

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
Ansi.strip(styled);           // remove every escape sequence
Ansi.width(styled);   // length ignoring escapes
styled.plain;             // extension forms
styled.width;
```

---

## 7. Testable Console Output

`ConsoleWriter` and `ConsoleLogger` accept custom `StringSink` streams for easy testing without polluting stdout/stderr:

```dart
final outBuffer = StringBuffer();
final errBuffer = StringBuffer();
final writer = ConsoleWriter(out: outBuffer, err: errBuffer);
final logger = ConsoleLogger(writer: writer);

logger.ok('All tests passed');
expect(outBuffer.toString(), contains('All tests passed'));
```

---

## 8. Terminal & Cursor

```dart
system.console.terminal.width;    // columns, or 80
system.console.terminal.height;   // rows, or 24
system.console.terminal.clear();
system.console.terminal.line();   // erase the current line
system.console.terminal.bell();

system.console.cursor.hide();
system.console.cursor.show();
system.console.cursor.up(2);
system.console.cursor.save();
system.console.cursor.restore();
```

Every method is a no-op when stdout is not a terminal.
