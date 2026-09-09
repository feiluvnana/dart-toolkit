# Environment & `.env` Files (`system.env.*`)

Reads process environment variables with an overlay of values loaded from a file or set at runtime.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() {
  system.env.load();   // reads .env if present

  final host = system.env.get('DB_HOST', 'localhost');
  final port = system.env.get('DB_PORT', 5432);
  final debug = system.env.get('DEBUG', false);

  print('Connecting to $host:$port (debug: $debug)');
}
```

---

## 1. Reading

### `get<T>(key, fallback)`

One typed getter covers every conversion. `T` is inferred from `fallback`, which is required — so the result is never null:

```dart
system.env.get('HOST', 'localhost');   // String
system.env.get('PORT', 8080);          // int
system.env.get('RATE', 1.0);           // double
system.env.get('DEBUG', false);        // bool
```

Booleans accept `true/1/yes/on` and `false/0/no/off`, case-insensitively. An absent, empty or unparseable value yields the fallback. A `T` other than these four throws `ArgumentError`.

```dart
system.env.has('API_KEY');   // present and non-empty
system.env.map();            // process environment with overrides applied
```

---

## 2. Loading a File

```dart
system.env.load();                       // '.env'
system.env.load('config/prod.env');
system.env.load('.env', true);           // overwrite real process variables
```

Returns `false` when the file does not exist, so it is safe to call unconditionally. Real process variables win unless you pass `overwrite`.

Supported syntax:

```sh
# a comment
export DB_HOST=localhost
DB_PORT=5432
DB_NAME="my_db"
API_KEY='secret_123'   # inline comment
MULTILINE="line1\nline2"
```

- `export` prefixes are ignored.
- Quoted values keep whitespace and `#`; `\n` and `\t` are unescaped.
- Unquoted values end at a trailing ` #` comment.

To inspect a file without applying it:

```dart
final pairs = system.env.parse(io.read('.env'));
```

---

## 3. Runtime Overrides

Overrides live in this process only — the real environment is never mutated.

```dart
system.env.set('APP_MODE', 'release');
system.env.delete('APP_MODE');   // exposes the real value again, if any
system.env.clear();              // drops every override
```

This makes tests straightforward:

```dart
system.env.clear();
system.env.set('PORT', '9000');
expect(system.env.get('PORT', 0), 9000);
```
