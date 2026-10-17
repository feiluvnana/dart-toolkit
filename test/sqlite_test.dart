import 'dart:io' as io;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/sqlite.dart';
import 'package:test/test.dart';

void main() {
  test('Sqlite.memory executes DDL and queries', () {
    final db = Sqlite.memory();
    db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT);');
    db.execute('INSERT INTO kv VALUES (?, ?);', ['author', 'feiluvnana']);

    final rows = db.select('SELECT * FROM kv WHERE k = ?;', ['author']);
    expect(rows.length, 1);
    expect(rows.first['v'], 'feiluvnana');
    db.close();
  });

  test('DatabaseHelpers: get, exists, row, upsert, transaction', () {
    final db = Sqlite.memory();
    db.execute('CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, age INT);');

    // exists on empty table
    expect(db.exists('SELECT 1 FROM users WHERE id = ?;', ['u1']), isFalse);
    expect(db.get<int>('SELECT count(*) FROM users;'), 0);
    expect(db.row('SELECT * FROM users WHERE id = ?;', ['u1']), isNull);

    // upsert insert
    db.upsert('users', {'id': 'u1', 'name': 'Alice', 'age': 30});
    expect(db.exists('SELECT 1 FROM users WHERE id = ?;', ['u1']), isTrue);
    expect(db.get<int>('SELECT count(*) FROM users;'), 1);
    expect(db.get<String>('SELECT name FROM users WHERE id = ?;', ['u1']), 'Alice');
    final r1 = db.row('SELECT * FROM users WHERE id = ?;', ['u1']);
    expect(r1?['name'], 'Alice');
    expect(r1?['age'], 30);

    // upsert update
    db.upsert('users', {'id': 'u1', 'name': 'Alice Updated', 'age': 31});
    expect(db.get<String>('SELECT name FROM users WHERE id = ?;', ['u1']), 'Alice Updated');
    expect(db.get<int>('SELECT age FROM users WHERE id = ?;', ['u1']), 31);
    expect(db.get<int>('SELECT count(*) FROM users;'), 1);

    // transaction commit
    db.transaction(() {
      db.upsert('users', {'id': 'u2', 'name': 'Bob', 'age': 25});
    });
    expect(db.get<int>('SELECT count(*) FROM users;'), 2);

    // transaction rollback
    expect(() {
      db.transaction(() {
        db.upsert('users', {'id': 'u3', 'name': 'Charlie', 'age': 40});
        throw Exception('abort transaction');
      });
    }, throwsA(isA<Exception>()));
    expect(db.exists('SELECT 1 FROM users WHERE id = ?;', ['u3']), isFalse);

    db.close();
  });

  test('File.sqlite opens file database, creates parent, applies wal, and persists records', () async {
    final tmp = await io.Directory.systemTemp.createTemp('sqlite_test_');
    try {
      final dbFile = Fs.dir(tmp.path) / 'deep/nested/subfolder';
      final file = dbFile.file('test.db');
      final db = file.sqlite();
      db.execute('CREATE TABLE items (id INT, val TEXT);');
      db.execute("INSERT INTO items VALUES (1, 'one'), (2, 'two');");
      db.close();

      // Reopen
      final db2 = file.sqlite();
      final rows = db2.select('SELECT COUNT(*) AS count FROM items;');
      expect(rows.first['count'], 2);
      expect(db2.get<int>('SELECT COUNT(*) FROM items;'), 2);
      db2.close();
    } finally {
      for (var i = 0; i < 5; i++) {
        try {
          await tmp.delete(recursive: true);
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  });
}
