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

  test('File.sqlite opens file database and persists records', () async {
    final tmp = await io.Directory.systemTemp.createTemp('sqlite_test_');
    try {
      final file = Fs.file('${tmp.path}/test.db');
      final db = file.sqlite();
      db.execute('CREATE TABLE items (id INT, val TEXT);');
      db.execute("INSERT INTO items VALUES (1, 'one'), (2, 'two');");
      db.close();

      // Reopen
      final db2 = file.sqlite();
      final rows = db2.select('SELECT COUNT(*) AS count FROM items;');
      expect(rows.first['count'], 2);
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
