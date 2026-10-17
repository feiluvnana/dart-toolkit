/// Minimal SQLite facade. Thin layer over `package:sqlite3`.
///
/// ```dart
/// final db = Sqlite.open('data.db');
/// db.execute('CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT);');
/// db.execute('INSERT INTO users VALUES (?, ?);', ['u1', 'Alice']);
/// for (final row in db.select('SELECT * FROM users;')) {
///   print(row['name']);
/// }
/// ```
library;

import 'package:sqlite3/sqlite3.dart' as s;

import 'fs.dart';
import 'src/sqlite_ffi.dart';

export 'package:sqlite3/sqlite3.dart' show Database, ResultSet, Row;

/// SQLite database access.
abstract final class Sqlite {
  /// Opens a SQLite database at [path], creating it if missing.
  /// Automatically locates and initializes native SQLite bindings across platforms.
  static s.Database open(String path) {
    initSqlite();
    return s.sqlite3.open(path);
  }

  /// Opens an in-memory SQLite database.
  static s.Database memory() {
    initSqlite();
    return s.sqlite3.openInMemory();
  }
}

/// Open a [File] as a SQLite database.
extension FileSqlite on File {
  /// Open this file as a SQLite database.
  s.Database sqlite() => Sqlite.open(path);
}

/// Open a future [File] as a SQLite database.
extension FutureFileSqlite on Future<File> {
  /// Open this file as a SQLite database.
  Future<s.Database> sqlite() async => Sqlite.open((await this).path);
}
