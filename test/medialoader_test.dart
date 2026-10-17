// Tests for MediaLoader core, database, extractors, and engine.
import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

import '../projects/medialoader/dashboard.dart';
import '../projects/medialoader/db.dart';
import '../projects/medialoader/engine.dart';
import '../projects/medialoader/platforms/facebook.dart';
import '../projects/medialoader/platforms/instagram.dart';
import '../projects/medialoader/platforms/twitter.dart';

void main() {
  group('MediaDb', () {
    test('creates schema and manages targets, posts, assets, and cursors', () {
      final db = MediaDb.memory();

      // Targets
      db.recordTarget(platform: 'ins', user: 'nature', displayName: 'Nature Photos');
      var stats = db.stats();
      expect(stats.users, 1);

      // Posts
      expect(db.isPostSeen('ins', 'nature', 'post123'), isFalse);
      db.recordPost(
        platform: 'ins',
        user: 'nature',
        postId: 'post123',
        postedAt: DateTime.utc(2026, 1, 1),
        caption: 'A sunny day',
      );
      expect(db.isPostSeen('ins', 'nature', 'post123'), isTrue);

      // Cursors
      expect(db.getCursor(platform: 'ins', user: 'nature', category: Kind.posts), isNull);
      db.saveCursor(platform: 'ins', user: 'nature', category: Kind.posts, cursor: 'cur_abc');
      expect(db.getCursor(platform: 'ins', user: 'nature', category: Kind.posts), 'cur_abc');

      // Assets
      db.recordAsset(
        id: 'img1.jpg',
        platform: 'ins',
        user: 'nature',
        category: Kind.posts,
        filePath: 'downloads/ins/nature/posts/img1.jpg',
        sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        phash: '0000000000000000',
        fileSize: 1024,
      );

      stats = db.stats();
      expect(stats.assets, 1);
      expect(stats.totalBytes, 1024);
      expect(stats.uniqueHashes, 1);

      // Exact duplicate via sha256
      final dupSha = db.findDuplicate(sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(dupSha, 'downloads/ins/nature/posts/img1.jpg');

      // Perceptual duplicate (pHash Hamming distance 1 from '0000000000000000')
      // '0000000000000001' has distance 1 <= threshold 5
      final dupPhash = db.findDuplicate(phash: '0000000000000001', threshold: 5);
      expect(dupPhash, 'downloads/ins/nature/posts/img1.jpg');

      // Multiple assets with same id across categories or users do not fail UNIQUE constraint
      db.recordAsset(
        id: 'img1.jpg',
        platform: 'fbk',
        user: 'nature',
        category: Kind.photos,
        filePath: 'downloads/fbk/nature/photos/img1.jpg',
        fileSize: 2048,
      );
      db.recordAsset(
        id: 'avatar',
        platform: 'ins',
        user: 'user1',
        category: Kind.profiles,
        filePath: 'downloads/ins/user1/profiles/2026-10-17_avatar',
        fileSize: 512,
      );
      db.recordAsset(
        id: 'avatar',
        platform: 'fbk',
        user: 'user2',
        category: Kind.profiles,
        filePath: 'downloads/fbk/user2/profiles/2026-10-17_avatar',
        fileSize: 512,
      );
      stats = db.stats();
      expect(stats.assets, 4);

      db.close();
    });
  });

  group('Extractors & Target parsing', () {
    test('Instagram extractor matches and parses URLs and handles', () {
      final ext = InstagramExtractor();
      expect(ext.matches('https://www.instagram.com/nasa/'), isTrue);
      expect(ext.matches('instagram.com/p/C_abc123/'), isTrue);

      final t1 = ext.parse('https://www.instagram.com/nasa/');
      expect(t1.platformCode, 'ins');
      expect(t1.user, 'nasa');
      expect(t1.post, isNull);

      final t2 = ext.parse('https://www.instagram.com/p/C_abc123/');
      expect(t2.platformCode, 'ins');
      expect(t2.post, 'C_abc123');
    });

    test('Twitter extractor matches and parses URLs and handles', () {
      final ext = TwitterExtractor();
      expect(ext.matches('https://x.com/dart_lang'), isTrue);
      expect(ext.matches('https://twitter.com/dart_lang/status/1234567890'), isTrue);

      final t1 = ext.parse('https://x.com/dart_lang');
      expect(t1.platformCode, 'twt');
      expect(t1.user, 'dart_lang');

      final t2 = ext.parse('https://twitter.com/dart_lang/status/1234567890');
      expect(t2.platformCode, 'twt');
      expect(t2.user, 'dart_lang');
      expect(t2.post, '1234567890');
    });

    test('Facebook extractor matches and parses profile URLs', () {
      final ext = FacebookExtractor();
      expect(ext.matches('https://www.facebook.com/zuck'), isTrue);

      final t = ext.parse('https://www.facebook.com/zuck');
      expect(t.platformCode, 'fbk');
      expect(t.user, 'zuck');
    });

    test('parseTarget parses prefixed targets and URLs, and errors on missing platform', () {
      final tIns = parseTarget('https://www.instagram.com/google/');
      expect(tIns.platformCode, 'ins');
      expect(tIns.user, 'google');

      final tTwt = parseTarget('https://x.com/google');
      expect(tTwt.platformCode, 'twt');
      expect(tTwt.user, 'google');

      // Prefixed syntax: fbk:user, twt:user, ins:user
      final tFbkPrefixed = parseTarget('fbk:xudiep1508');
      expect(tFbkPrefixed.platformCode, 'fbk');
      expect(tFbkPrefixed.user, 'xudiep1508');

      final tTwtPrefixed = parseTarget('twt:elonmusk');
      expect(tTwtPrefixed.platformCode, 'twt');
      expect(tTwtPrefixed.user, 'elonmusk');

      final tInsPrefixed = parseTarget('ins:leomessi');
      expect(tInsPrefixed.platformCode, 'ins');
      expect(tInsPrefixed.user, 'leomessi');

      // Platform code lookups
      expect(findExtractor('fbk').code, 'fbk');
      expect(findExtractor('twt').code, 'twt');
      expect(findExtractor('ins').code, 'ins');

      // Error when platform cannot be detected (does NOT default to ins)
      expect(() => parseTarget('plain_username_without_prefix'), throwsA(isA<FormatException>()));
      expect(() => parseTarget('leomessi'), throwsA(isA<FormatException>()));
      expect(() => findExtractor('unknown_platform'), throwsA(isA<FormatException>()));
    });
  });

  group('IngestionEngine', () {
    test('enqueues and drains assets in dry-run mode without downloading', () async {
      final db = MediaDb.memory();
      final engine = IngestionEngine(
        db: db,
        options: (
          all: false,
          dry: true,
          compress: false,
          since: null,
        ),
      );

      final asset = MediaAsset(
        id: 'sample.jpg',
        platform: 'ins',
        user: 'dry_user',
        category: Kind.posts,
        to: Fs.file('test_tmp/sample.jpg'),
        url: 'https://example.com/sample.jpg',
        at: DateTime.now(),
      );

      await engine.enqueue([asset]);
      await engine.drain();

      final user = engine.getOrCreateUser('dry_user', 'ins');
      expect(user.categories['posts']?.queued, 1);
      expect(user.categories['posts']?.added, 1);

      await engine.close();
    });

    test('pipes logs directly to downloads logFile without memory buffering', () async {
      final tempDir = Fs.dir('test_tmp/loader_log_test');
      await tempDir.create();
      final logFile = tempDir.file('medialoader.log');
      if (await logFile.exists()) await logFile.delete();

      final db = MediaDb.memory();
      final engine = IngestionEngine(
        db: db,
        options: (
          all: false,
          dry: false,
          compress: false,
          since: null,
        ),
        logFile: logFile,
      );

      engine.log('Starting ingestion for targets', platform: 'ins');
      engine.log('Network failure occurred', platform: 'twt', failed: true);
      await engine.close();

      expect(await logFile.exists(), isTrue);
      final content = await logFile.text();
      expect(content, contains('[ins] Starting ingestion for targets'));
      expect(content, contains('✗ [twt] Network failure occurred'));

      db.close();
      await tempDir.delete();
    });
  });

  group('Dashboard', () {
    test('formats title string with metrics accurately', () {
      final db = MediaDb.memory();
      final engine = IngestionEngine(
        db: db,
        options: (
          all: false,
          dry: false,
          compress: false,
          since: null,
        ),
      );

      final dashboard = Dashboard(engine: engine, db: db);
      expect(dashboard.title(), contains('medialoader'));
      expect(dashboard.title(), contains('0 users'));

      db.close();
    });
  });
}
