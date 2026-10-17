// SQLite storage, WAL ledger, and perceptual deduplication for MediaLoader.
library;

import 'package:dart_toolkit/fs.dart' as fs;
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/sqlite.dart';

import 'engine.dart' show Kind;

final class MediaDb {
  MediaDb._(this._db);

  final Database _db;

  /// Open or create database at [path], applying WAL mode and schema tables.
  static Future<MediaDb> open(String path) async {
    final parent = fs.Fs.file(path).parent();
    if (!await parent.exists()) {
      await parent.create();
    }
    final db = Sqlite.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    _initSchema(db);
    return MediaDb._(db);
  }

  /// Open an in-memory database for testing.
  static MediaDb memory() {
    final db = Sqlite.memory();
    _initSchema(db);
    return MediaDb._(db);
  }

  static void _initSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS targets (
        platform TEXT NOT NULL,
        user TEXT NOT NULL,
        id TEXT,
        display_name TEXT,
        avatar_url TEXT,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (platform, user)
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS posts (
        id TEXT NOT NULL,
        platform TEXT NOT NULL,
        user TEXT NOT NULL,
        caption TEXT,
        posted_at INTEGER,
        item_count INTEGER,
        seen_at INTEGER NOT NULL,
        PRIMARY KEY (platform, id)
      );
    ''');

    // Auto-migrate legacy assets table if id was primary key
    final existingAssets = db.select("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'assets';");
    if (existingAssets.isNotEmpty) {
      final sql = existingAssets.first['sql'] as String? ?? '';
      if (sql.contains('id TEXT PRIMARY KEY')) {
        db.execute('''
          CREATE TABLE assets_v2 (
            file_path TEXT PRIMARY KEY,
            id TEXT,
            post_id TEXT,
            platform TEXT NOT NULL,
            user TEXT NOT NULL,
            category TEXT NOT NULL,
            url TEXT,
            sha256 TEXT,
            phash TEXT,
            file_size INTEGER,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL
          );
        ''');
        db.execute('''
          INSERT OR REPLACE INTO assets_v2 (file_path, id, post_id, platform, user, category, url, sha256, phash, file_size, status, created_at)
          SELECT file_path, id, post_id, platform, user, category, url, sha256, phash, file_size, status, created_at FROM assets;
        ''');
        db.execute('DROP TABLE assets;');
        db.execute('ALTER TABLE assets_v2 RENAME TO assets;');
      }
    } else {
      db.execute('''
        CREATE TABLE IF NOT EXISTS assets (
          file_path TEXT PRIMARY KEY,
          id TEXT,
          post_id TEXT,
          platform TEXT NOT NULL,
          user TEXT NOT NULL,
          category TEXT NOT NULL,
          url TEXT,
          sha256 TEXT,
          phash TEXT,
          file_size INTEGER,
          status TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
      ''');
    }

    db.execute('CREATE INDEX IF NOT EXISTS idx_assets_phash ON assets(phash);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_assets_sha256 ON assets(sha256);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_assets_user ON assets(platform, user, category);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_assets_id ON assets(platform, id);');

    db.execute('''
      CREATE TABLE IF NOT EXISTS cursors (
        platform TEXT NOT NULL,
        user TEXT NOT NULL,
        category TEXT NOT NULL,
        cursor TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (platform, user, category)
      );
    ''');
  }

  /// Check whether [filePath] has already been recorded.
  bool hasFile(String filePath) {
    final rows = _db.select('SELECT 1 FROM assets WHERE file_path = ? LIMIT 1;', [filePath]);
    return rows.isNotEmpty;
  }

  /// Check whether an asset by [id] is recorded.
  bool hasAsset(String id, {String? platform, String? user}) {
    if (platform != null && user != null) {
      final rows = _db.select(
        'SELECT 1 FROM assets WHERE id = ? AND platform = ? AND user = ? LIMIT 1;',
        [id, platform, user],
      );
      return rows.isNotEmpty;
    }
    final rows = _db.select('SELECT 1 FROM assets WHERE id = ? LIMIT 1;', [id]);
    return rows.isNotEmpty;
  }

  /// Check whether an asset matches an existing entry by SHA-256 or pHash Hamming distance.
  String? findDuplicate({String? sha256, String? phash, int threshold = 5}) {
    if (sha256 != null && sha256.isNotEmpty) {
      final exact = _db.select('SELECT file_path FROM assets WHERE sha256 = ? LIMIT 1;', [sha256]);
      if (exact.isNotEmpty) return exact.first['file_path'] as String?;
    }

    if (phash != null && phash.length == 16) {
      final rows = _db.select('SELECT file_path, phash FROM assets WHERE phash IS NOT NULL;');
      for (final row in rows) {
        final existingPhash = row['phash'] as String?;
        if (existingPhash != null && existingPhash.length == 16) {
          try {
            final dist = Image.distance(phash, existingPhash);
            if (dist <= threshold) {
              return row['file_path'] as String?;
            }
          } catch (_) {}
        }
      }
    }
    return null;
  }

  /// Record an asset to the database using file_path as unique key.
  void recordAsset({
    required String id,
    required String platform,
    required String user,
    required Kind category,
    required String filePath,
    String? postId,
    String? url,
    String? sha256,
    String? phash,
    int? fileSize,
    String status = 'done',
  }) {
    _db.execute(
      '''
      INSERT INTO assets (file_path, id, post_id, platform, user, category, url, sha256, phash, file_size, status, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(file_path) DO UPDATE SET
        id = excluded.id,
        post_id = excluded.post_id,
        platform = excluded.platform,
        user = excluded.user,
        category = excluded.category,
        url = excluded.url,
        sha256 = excluded.sha256,
        phash = excluded.phash,
        file_size = excluded.file_size,
        status = excluded.status;
    ''',
      [
        filePath,
        id,
        postId,
        platform,
        user,
        category.name,
        url,
        sha256,
        phash,
        fileSize,
        status,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// Check whether a post has already been recorded.
  bool isPostSeen(String platform, String user, String postId) {
    final rows = _db.select('SELECT 1 FROM posts WHERE platform = ? AND id = ? LIMIT 1;', [platform, postId]);
    return rows.isNotEmpty;
  }

  /// Record a post to the database.
  void recordPost({
    required String platform,
    required String user,
    required String postId,
    String? caption,
    DateTime? postedAt,
    int? itemCount,
  }) {
    _db.execute(
      '''
      INSERT INTO posts (id, platform, user, caption, posted_at, item_count, seen_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(platform, id) DO UPDATE SET
        caption = COALESCE(excluded.caption, posts.caption),
        posted_at = COALESCE(excluded.posted_at, posts.posted_at),
        item_count = COALESCE(excluded.item_count, posts.item_count),
        seen_at = excluded.seen_at;
    ''',
      [
        postId,
        platform,
        user,
        caption,
        postedAt?.millisecondsSinceEpoch,
        itemCount,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// Record or update a target user profile.
  void recordTarget({
    required String platform,
    required String user,
    String? id,
    String? displayName,
    String? avatarUrl,
  }) {
    _db.execute(
      '''
      INSERT INTO targets (platform, user, id, display_name, avatar_url, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(platform, user) DO UPDATE SET
        id = COALESCE(excluded.id, targets.id),
        display_name = COALESCE(excluded.display_name, targets.display_name),
        avatar_url = COALESCE(excluded.avatar_url, targets.avatar_url),
        updated_at = excluded.updated_at;
    ''',
      [platform, user, id, displayName, avatarUrl, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// Save pagination cursor for clean restarts.
  void saveCursor({
    required String platform,
    required String user,
    required Kind category,
    required String cursor,
  }) {
    _db.execute(
      '''
      INSERT INTO cursors (platform, user, category, cursor, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(platform, user, category) DO UPDATE SET
        cursor = excluded.cursor,
        updated_at = excluded.updated_at;
    ''',
      [platform, user, category.name, cursor, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// Get saved cursor for clean restarts.
  String? getCursor({
    required String platform,
    required String user,
    required Kind category,
  }) {
    final rows = _db.select(
      'SELECT cursor FROM cursors WHERE platform = ? AND user = ? AND category = ? LIMIT 1;',
      [platform, user, category.name],
    );
    if (rows.isEmpty) return null;
    return rows.first['cursor'] as String?;
  }

  ResultSet select(String sql, [List<Object?> parameters = const []]) => _db.select(sql, parameters);

  void execute(String sql, [List<Object?> parameters = const []]) => _db.execute(sql, parameters);

  /// Summary statistics for the database.
  ({int assets, int totalBytes, int users, int uniqueHashes}) stats() {
    final a = _db.select('SELECT COUNT(*) as count, SUM(file_size) as bytes FROM assets;').first;
    final u = _db.select('SELECT COUNT(*) as count FROM targets;').first;
    final h = _db.select('SELECT COUNT(DISTINCT sha256) as count FROM assets WHERE sha256 IS NOT NULL;').first;
    return (
      assets: (a['count'] as int?) ?? 0,
      totalBytes: (a['bytes'] as int?) ?? 0,
      users: (u['count'] as int?) ?? 0,
      uniqueHashes: (h['count'] as int?) ?? 0,
    );
  }

  void close() {
    _db.close();
  }
}
