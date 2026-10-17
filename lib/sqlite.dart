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

import 'dart:io' as io;

import 'package:sqlite3/sqlite3.dart' as s;

import 'fs.dart';
import 'src/sqlite_ffi.dart';

export 'package:sqlite3/sqlite3.dart' show Database, ResultSet, Row;

/// SQLite database access.
abstract final class Sqlite {
  /// Opens a SQLite database at [path].
  /// - Automatically creates parent directory if missing.
  /// - When [wal] is true (default), sets PRAGMA journal_mode = WAL and synchronous = NORMAL.
  static s.Database open(String path, {bool wal = true, bool createParent = true}) {
    initSqlite();
    if (createParent) {
      final parent = io.File(path).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
    }
    final db = s.sqlite3.open(path);
    if (wal) {
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA synchronous = NORMAL;');
    }
    return db;
  }

  /// Opens an in-memory SQLite database.
  static s.Database memory() {
    initSqlite();
    return s.sqlite3.openInMemory();
  }
}

/// Hardened query and persistence helpers on [Database].
extension DatabaseHelpers on s.Database {
  /// Returns a single scalar value of type [T], or null if no row matches.
  ///
  /// ```dart
  /// final count = db.get<int>('SELECT count(*) FROM assets;') ?? 0;
  /// final cursor = db.get<String?>('SELECT cursor FROM cursors WHERE user = ?;', [user]);
  /// ```
  T? get<T>(String sql, [List<Object?> parameters = const []]) {
    final rows = select(sql, parameters);
    if (rows.isEmpty || rows.first.isEmpty) return null;
    return rows.first.values.first as T?;
  }

  /// Returns true if [sql] yields at least one matching row.
  ///
  /// ```dart
  /// if (db.exists('SELECT 1 FROM assets WHERE file_path = ? LIMIT 1;', [path])) ...
  /// ```
  bool exists(String sql, [List<Object?> parameters = const []]) =>
      select(sql, parameters).isNotEmpty;

  /// Returns the first matching [Row], or null if none.
  s.Row? row(String sql, [List<Object?> parameters = const []]) {
    final rows = select(sql, parameters);
    return rows.isEmpty ? null : rows.first;
  }

  /// Upserts a record into [table] with column [values].
  /// [keys] specifies conflict columns (defaults to first column or primary key).
  void upsert(String table, Map<String, Object?> values, {List<String>? keys}) {
    if (values.isEmpty) return;
    final cols = values.keys.toList();
    final conflictCols = keys ?? [cols.first];
    final placeholders = List.filled(cols.length, '?').join(', ');
    final updates = cols
        .where((c) => !conflictCols.contains(c))
        .map((c) => '$c = excluded.$c')
        .join(', ');

    final updateClause = updates.isNotEmpty ? 'DO UPDATE SET $updates' : 'DO NOTHING';
    final sql = '''
      INSERT INTO $table (${cols.join(', ')})
      VALUES ($placeholders)
      ON CONFLICT(${conflictCols.join(', ')}) $updateClause;
    ''';
    execute(sql, values.values.toList());
  }

  /// Executes [action] inside a BEGIN IMMEDIATE...COMMIT transaction.
  /// Automatically rolls back on any thrown exception.
  T transaction<T>(T Function() action) {
    execute('BEGIN IMMEDIATE;');
    try {
      final result = action();
      execute('COMMIT;');
      return result;
    } catch (_) {
      execute('ROLLBACK;');
      rethrow;
    }
  }
}

/// Open a [File] as a SQLite database.
extension FileSqlite on File {
  /// Open this file as a SQLite database.
  s.Database sqlite({bool wal = true, bool createParent = true}) =>
      Sqlite.open(path, wal: wal, createParent: createParent);
}

/// Open a future [File] as a SQLite database.
extension FutureFileSqlite on Future<File> {
  /// Open this file as a SQLite database.
  Future<s.Database> sqlite({bool wal = true, bool createParent = true}) async =>
      Sqlite.open((await this).path, wal: wal, createParent: createParent);
}
