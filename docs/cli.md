# Command-Line Interface Subsystem (`cli.*`)

The `cli` namespace in **Dart Script Toolkit** provides clean, zero-configuration parsing of command-line arguments, short and long flags, typed options with defaults, and positional argument lists.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> rawArgs) {
  // 1. Bind arguments
  cli.parse(rawArgs);

  // 2. Check boolean flags and aliases
  final force = cli.has('force', 'f');
  final verbose = cli.has('verbose', 'v');

  // 3. Read typed options with defaults
  final port = cli.get('port', 8080);
  final host = cli.get('host', '127.0.0.1');

  // 4. Access positional non-option arguments
  final targets = cli.list();

  console.logger.info('Running on $host:$port (force: $force, targets: $targets)');
}
```

---

## 1. Boolean Flags (`cli.has()`)

Checks for the presence of long flags or short aliases:

```dart
// Matches --force, -f, --no-cache
final force = cli.has('force', 'f');
final dryRun = cli.has('dry-run');
```

---

## 2. Typed Options (`cli.get()`)

Reads values from `--key=value` or `--key value` or `-k value`, automatically casting to default's type:

```dart
// Infers int
final concurrency = cli.get('concurrency', 4);

// Infers double
final threshold = cli.get('threshold', 0.75);

// Infers String
final output = cli.get('out', 'dist');

// Nullable if default is omitted
final apiKey = cli.get<String?>('api-key');
```

---

## 3. Positional Arguments (`cli.list()`)

Collects all non-option arguments passed to the script:

```bash
dart run my_tool.dart --force build app.dart
```

```dart
final commands = cli.list(); // ['build', 'app.dart']
```
