// SQLite storage, WAL ledger, and perceptual deduplication for MediaLoader.
library;

import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/sqlite.dart';

import 'engine.dart' show Kind;

final class MediaDb {
  MediaDb._(this._db);

  final Database _db;

  /// Open or create database at [path], applying WAL mode and schema tables.
  static Future<MediaDb> open(String path) async {
    final db = Sqlite.open(path);
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
  bool hasFile(String filePath) => _db.exists('SELECT 1 FROM assets WHERE file_path = ? LIMIT 1;', [filePath]);

  /// Check whether an asset by [id] is recorded.
  bool hasAsset(String id, {String? platform, String? user}) {
    if (platform != null && user != null) {
      return _db.exists('SELECT 1 FROM assets WHERE id = ? AND platform = ? AND user = ? LIMIT 1;', [
        id,
        platform,
        user,
      ]);
    }
    return _db.exists('SELECT 1 FROM assets WHERE id = ? LIMIT 1;', [id]);
  }

  /// Check whether an asset matches an existing entry by SHA-256 or pHash Hamming distance.
  String? findDuplicate({String? sha256, String? phash, int threshold = 5, String? excludePath}) {
    if (sha256 != null && sha256.isNotEmpty) {
      final sql = excludePath != null
          ? 'SELECT file_path FROM assets WHERE sha256 = ? AND file_path != ? LIMIT 1;'
          : 'SELECT file_path FROM assets WHERE sha256 = ? LIMIT 1;';
      final params = excludePath != null ? [sha256, excludePath] : [sha256];
      final match = _db.get<String?>(sql, params);
      if (match != null) return match;
    }

    if (phash != null && phash.length == 16) {
      final sql = excludePath != null
          ? 'SELECT file_path, phash FROM assets WHERE phash IS NOT NULL AND file_path != ?;'
          : 'SELECT file_path, phash FROM assets WHERE phash IS NOT NULL;';
      final params = excludePath != null ? [excludePath] : const <Object?>[];
      final rows = _db.select(sql, params);
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

  /// Get counts and total bytes for a given user's category.
  ({int files, int bytes}) categoryStats({required String platform, required String user, required Kind category}) {
    final row = _db.row(
      'SELECT COUNT(*) AS cnt, COALESCE(SUM(file_size), 0) AS total_bytes FROM assets WHERE platform = ? AND user = ? AND category = ?;',
      [platform, user, category.name],
    );
    return (files: (row?['cnt'] as int?) ?? 0, bytes: (row?['total_bytes'] as int?) ?? 0);
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
  }) => _db.upsert(
    'assets',
    {
      'file_path': filePath,
      'id': id,
      'post_id': postId,
      'platform': platform,
      'user': user,
      'category': category.name,
      'url': url,
      'sha256': sha256,
      'phash': phash,
      'file_size': fileSize,
      'status': status,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    },
    keys: ['file_path'],
  );

  /// Check whether a post has already been recorded and completed.
  bool isPostSeen(String platform, String user, String postId) {
    final row = _db.row('SELECT item_count FROM posts WHERE platform = ? AND id = ? LIMIT 1;', [platform, postId]);
    if (row == null) return false;
    final itemCount = row['item_count'] as int?;
    if (itemCount == null || itemCount == 0) return true;
    final downloaded =
        _db.get<int>('SELECT COUNT(*) FROM assets WHERE platform = ? AND post_id = ?;', [platform, postId]) ?? 0;
    return downloaded >= itemCount;
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
  void saveCursor({required String platform, required String user, required Kind category, required String cursor}) =>
      _db.upsert(
        'cursors',
        {
          'platform': platform,
          'user': user,
          'category': category.name,
          'cursor': cursor,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        keys: ['platform', 'user', 'category'],
      );

  /// Get saved cursor for clean restarts.
  String? getCursor({required String platform, required String user, required Kind category}) => _db.get<String?>(
    'SELECT cursor FROM cursors WHERE platform = ? AND user = ? AND category = ? LIMIT 1;',
    [platform, user, category.name],
  );

  ResultSet select(String sql, [List<Object?> parameters = const []]) => _db.select(sql, parameters);

  void execute(String sql, [List<Object?> parameters = const []]) => _db.execute(sql, parameters);

  /// Summary statistics for the database.
  ({int assets, int totalBytes, int users, int uniqueHashes}) stats() => (
    assets: _db.get<int>('SELECT COUNT(*) FROM assets;') ?? 0,
    totalBytes: _db.get<int>('SELECT SUM(file_size) FROM assets;') ?? 0,
    users: _db.get<int>('SELECT COUNT(*) FROM targets;') ?? 0,
    uniqueHashes: _db.get<int>('SELECT COUNT(DISTINCT phash) FROM assets WHERE phash IS NOT NULL;') ?? 0,
  );

  void close() {
    _db.close();
  }
}
