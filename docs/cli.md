# Command-Line Interface Subsystem (`system.cli.*`)

The `system.cli` sub-namespace in **Dart Script Toolkit** provides clean, zero-configuration parsing of command-line arguments, short and long flags, typed options with defaults, and positional argument lists.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> rawArgs) {
  // 1. Bind arguments
  system.cli.parse(rawArgs);

  // 2. Check boolean flags and aliases
  final force = system.cli.has('force', 'f');
  final verbose = system.cli.has('verbose', 'v');

  // 3. Read typed options with defaults
  final port = system.cli.get('port', 8080);
  final host = system.cli.get('host', '127.0.0.1');

  // 4. Access positional non-option arguments
  final targets = system.cli.list();

  util.console.logger.info('Running on $host:$port (force: $force, targets: $targets)');
}
```

---

## 1. Boolean Flags (`system.cli.has()`)

Checks for the presence of long flags or short aliases:

```dart
// Matches --force, -f, --no-cache
final force = system.cli.has('force', 'f');
final dryRun = system.cli.has('dry-run');
```

---

## 2. Typed Options (`system.cli.get()`)

Reads values from `--key=value` or `--key value` or `-k value`, automatically casting to default's type:

```dart
// Infers int
final concurrency = system.cli.get('concurrency', 4);

// Infers double
final threshold = system.cli.get('threshold', 0.75);

// Infers String
final output = system.cli.get('out', 'dist');

// Nullable if default is omitted
final apiKey = system.cli.get<String?>('api-key');
```

---

## 3. Positional Arguments (`system.cli.list()`)

Collects all non-option arguments passed to the script:

```bash
dart run my_tool.dart --force build app.dart
```

```dart
final commands = system.cli.list(); // ['build', 'app.dart']
```
