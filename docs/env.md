# Environment & Configuration Subsystem (`system.env.*`)

The `system.env` sub-namespace in **Dart Script Toolkit** provides zero-dependency reading, type-safe casting, session overriding, and `.env` file parsing for automation scripts.

All methods strictly adhere to the **1-word method naming convention**.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() {
  // 1. Load .env file (supports comments, quotes, multiline escapes)
  system.env.load();

  // 2. Type-casted reads with fallbacks
  final port = system.env.int('PORT', 8080);
  final host = system.env.get('HOST', 'localhost');
  final debug = system.env.bool('DEBUG', false);
  final timeout = system.env.double('TIMEOUT_SEC', 30.0);

  // 3. Mutate session environment
  system.env.set('APP_ENV', 'production');
  if (system.env.has('API_KEY')) {
    util.console.logger.ok('Running on $host:$port (debug=$debug)');
  }
}
```

---

## 1. Loading `.env` Files (`system.env.load`)

### `system.env.load([path, overwrite = false])`
Loads key-value pairs from a `.env` file into the active session overrides:
- `path`: Target `.env` file path (defaults to `'.env'` in the current working directory). Accepts `String` or `File`.
- `overwrite`: When `true`, overwrites existing system environment variables. When `false` (default), preserves system values if already present.
- Returns `bool`: `true` if the file existed and was loaded, `false` otherwise.

```dart
// Load default .env without overwriting system variables
system.env.load();

// Load specific environment file and overwrite existing system variables
system.env.load('.env.production', true);
```

### Parsing Features
The parser built into `system.env.parse(content)` supports:
- Blank lines and comment lines starting with `#`
- Bash-style `export KEY=val` syntax
- Single-quoted (`'val'`) and double-quoted (`"val"`) values
- Escaped newlines (`\n`) and tabs (`\t`) in quotes
- Inline comments (e.g. `PORT=8080 # default port`)

---

## 2. Reading Environment Variables

All getters return a typed value, falling back gracefully to the provided default if the variable is missing or empty.

| Method | Return Type | Default Fallback | Description |
| :--- | :--- | :--- | :--- |
| `system.env.get(key, [fallback = ''])` | `String` | `''` | Returns the raw string value. |
| `system.env.int(key, [fallback = 0])` | `int` | `0` | Parses integer value (e.g. `'8080'` &rarr; `8080`). |
| `system.env.double(key, [fallback = 0.0])` | `double` | `0.0` | Parses double floating-point value. |
| `system.env.bool(key, [fallback = false])` | `bool` | `false` | Evaluates `'true'`, `'1'`, `'yes'`, `'on'` as `true`, and `'false'`, `'0'`, `'no'`, `'off'` as `false` (case-insensitive). |

### Example
```dart
final port = system.env.int('PORT', 3000);
final rate = system.env.double('SAMPLE_RATE', 1.0);
final isDev = system.env.bool('DEVELOPMENT', true);
```

---

## 3. Session Overrides & State Management

Modify or inspect environment variables for the current Dart process:

- `system.env.has(key)`: Checks whether a variable exists and has a non-empty value.
- `system.env.set(key, value)`: Sets or overrides a session environment variable.
- `system.env.delete(key)`: Removes a session override.
- `system.env.clear()`: Clears all session overrides.
- `system.env.map()`: Returns a merged snapshot `Map<String, String>` containing both system environment variables and session overrides.

```dart
system.env.set('FEATURE_FLAG', true);
util.console.logger.info('Feature enabled: ${system.env.bool('FEATURE_FLAG')}');

// Inspect entire merged environment map
final allVars = system.env.map();
print('Total variables: ${allVars.length}');
```
