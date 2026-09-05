# Console & Terminal Subsystem (`console.*`)

The `console` namespace in **Dart Script Toolkit** provides rich terminal formatting, responsive tables, real-time progress bars, spinners, ANSI color extensions, and interactive command-line prompts.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Step headers and status icons
  console.logger.step(1, 3, 'Preparing environment...');
  console.logger.ok('Dependencies installed.');
  console.logger.warn('Memory usage high.');
  console.logger.fail('Could not bind port 8080.');
  console.logger.info('Using default fallback configuration.');

  // 2. Interactive user prompt
  final proceed = console.reader.confirm('Do you want to continue?', true);
  if (!proceed) return;

  // 3. Formatted Unicode table
  console.writer.table(
    ['Name', 'Status', 'Latency'],
    [
      ['us-east-1', 'ONLINE'.green(), '24ms'],
      ['eu-west-1', 'ONLINE'.green(), '89ms'],
      ['ap-south-1', 'DEGRADED'.yellow(), '210ms'],
    ],
  );

  // 4. Progress bar
  final bar = console.bar(100, 'Uploading');
  for (var i = 0; i < 100; i++) {
    await Future.delayed(const Duration(milliseconds: 20));
    bar.tick(1, 'Chunk #${i + 1}');
  }
  bar.done('Upload completed!');
}
```

---

## 1. Status Loggers (`console.logger.*`)

High-visibility visual feedback indicators:

- `console.logger.step(step, total, message)`: Formats step progress headers like `[1/5] Building source...`.
- `console.logger.ok(message)`: Success indicator with green checkmark `✔ Success message`.
- `console.logger.warn(message)`: Warning indicator with yellow symbol `⚠ Warning message`.
- `console.logger.fail(message)` / `console.logger.error(message)`: Error indicator with red symbol `✖ Failure message`.
- `console.logger.info(message)`: Informational notice with cyan/blue symbol `ℹ Notice message`.
- `console.logger.debug(message)`: Debug message with dimmed symbol `⚙ Debug message`.
- `console.logger.task(name, fn)`: Wraps an async task with automatic spinner and ok/fail completion indicator:
  ```dart
  await console.logger.task('Running migrations', () async {
    await runMigrations();
  });
  ```

---

## 2. Structured Output (`console.writer.*`)

### Formatted Tables (`console.writer.table`)
Renders auto-aligned ASCII or Unicode tables with configurable alignments:

```dart
console.writer.table(
  ['Package', 'Version', 'License'],
  [
    ['dart_toolkit', '1.0.0', 'MIT'],
    ['http', '1.6.0', 'BSD-3-Clause'],
    ['html', '0.15.7', 'MIT'],
  ],
  [ColumnAlign.left, ColumnAlign.center, ColumnAlign.right],
  TableStyle.unicode, // or TableStyle.ascii
);
```

### Callout Boxes (`console.writer.box`)
Draws text inside a bordered box with optional title:

```dart
console.writer.box(
  'Server listening on http://localhost:3000\nEnvironment: production',
  title: 'Service Ready',
);
```

### Horizontal Divider Rules (`console.writer.rule`)
```dart
console.writer.rule('Diagnostics');
```

### Interactive Progress Bars (`console.writer.bar` / `console.bar`)
Real-time dynamic terminal progress bar with automatic speed, percentage, elapsed time, and ETA calculations:

```dart
final bar = console.bar(500, 'Processing items');

for (var i = 0; i < 500; i++) {
  // Update progress
  bar.tick(1, 'Item #$i');
}

bar.done('Processing finished!');
```

Dynamic updates:
- `bar.tick([delta = 1, message])`: Advance progress by delta.
- `bar.update(current, {newTotal, message})`: Set absolute progress value and dynamic total.
- `bar.total++`: Dynamically increment total as new tasks are discovered.
- `bar.fail([message])`: Terminate with failure symbol.

### Animated Spinners (`console.writer.spin`)
```dart
final spinner = console.spin('Connecting to database...');
await Future.delayed(const Duration(seconds: 1));
spinner.update('Authenticating...');
await Future.delayed(const Duration(seconds: 1));
spinner.ok('Connected!');
```

---

## 3. Interactive Prompts (`console.reader.*`)

### `console.reader.ask(prompt, [default])`
Prompts for user text input with fallback default:
```dart
final name = console.reader.ask('Enter deployment environment', 'staging');
```

### `console.reader.confirm(prompt, [default])`
Boolean Yes/No prompt:
```dart
final runMigrations = console.reader.confirm('Apply pending schema migrations?', false);
```

### `console.reader.pick(prompt, options)`
Select an item from a list with numbered menu:
```dart
final region = console.reader.pick(
  'Choose AWS region:',
  ['us-east-1', 'eu-west-1', 'ap-southeast-1'],
);
```

### `console.reader.secret(prompt)`
Prompts for sensitive input (passwords, tokens) without terminal echo:
```dart
final token = console.reader.secret('Enter API secret key');
```

---

## 4. ANSI Color Extensions on `String`

Apply colors and styles directly to strings:

```dart
print('Bold white'.bold());
print('Dim text'.dim());
print('Underlined'.underline());

// Colors
print('Red alert'.red());
print('Green success'.green());
print('Yellow warning'.yellow());
print('Blue notice'.blue());
print('Cyan accent'.cyan());
print('Magenta'.magenta());

// Bright variants
print('Bright Green'.brightGreen());
print('Bright Red'.brightRed());
print('Bright Cyan'.brightCyan());

// Chaining
print('CRITICAL FAILURE'.brightRed().bold());
```

---

## 5. Terminal Geometry & Cursor Control

```dart
// Dimensions
final cols = console.terminal.width;
final rows = console.terminal.height;

// Clear
console.terminal.clear();
console.terminal.line();

// Cursor Manipulation
console.cursor.hide();
console.cursor.show();
console.cursor.up(2);
console.cursor.down(1);
console.cursor.home();
```
