// Tests for MediaLoader core, database, extractors, and engine.
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/utils.dart';
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

    test('isPostSeen ensures interruption resilience by verifying completed item count', () {
      final db = MediaDb.memory();

      db.recordPost(platform: 'ins', user: 'nature', postId: 'post_multi', itemCount: 2);
      // 0/2 assets recorded -> considered NOT seen yet so it resumes cleanly if interrupted
      expect(db.isPostSeen('ins', 'nature', 'post_multi'), isFalse);

      db.recordAsset(
        id: 'img_part1.jpg',
        postId: 'post_multi',
        platform: 'ins',
        user: 'nature',
        category: Kind.posts,
        filePath: 'downloads/ins/nature/posts/img_part1.jpg',
      );
      // 1/2 assets recorded -> still not complete
      expect(db.isPostSeen('ins', 'nature', 'post_multi'), isFalse);

      db.recordAsset(
        id: 'img_part2.jpg',
        postId: 'post_multi',
        platform: 'ins',
        user: 'nature',
        category: Kind.posts,
        filePath: 'downloads/ins/nature/posts/img_part2.jpg',
      );
      // 2/2 assets recorded -> now fully complete!
      expect(db.isPostSeen('ins', 'nature', 'post_multi'), isTrue);

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
      final engine = IngestionEngine(db: db, options: (all: false, dry: true, compress: false, since: null));

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
      final logFile = tempDir.file('.medialoader.log');
      if (await logFile.exists()) await logFile.delete();

      final db = MediaDb.memory();
      final engine = IngestionEngine(
        db: db,
        options: (all: false, dry: false, compress: false, since: null),
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
    test('flags deduplicated files with [dedupe] prefix instead of removing', () async {
      final tempDir = Fs.dir('test_tmp/loader_dedupe_test');
      await tempDir.create();
      final db = MediaDb.memory();

      // Record an existing asset with known sha256
      const existingSha = 'a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e';
      db.recordAsset(
        id: 'orig.txt',
        platform: 'twt',
        user: 'author',
        category: Kind.posts,
        filePath: 'test_tmp/loader_dedupe_test/orig.txt',
        sha256: existingSha,
        fileSize: 11,
      );

      final engine = IngestionEngine(
        db: db,
        options: (all: false, dry: false, compress: false, since: null),
        logFile: tempDir.file('.medialoader.log'),
      );

      // Asset with same content (Hello World) to trigger deduplication
      final newFile = tempDir.file('new_item.txt');
      final asset = MediaAsset(
        id: 'new_item.txt',
        platform: 'twt',
        user: 'author',
        category: Kind.posts,
        to: newFile,
        text: 'Hello World', // sha256 is a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e
        at: DateTime.now(),
      );

      await engine.enqueue([asset]);
      await engine.drain();

      // The duplicate file should NOT be deleted, but renamed with [dedupe] prefix
      final dedupePrefixedFile = tempDir.file('[dedupe] new_item.txt');
      expect(await dedupePrefixedFile.exists(), isTrue);
      expect(await newFile.exists(), isFalse); // original moved to prefixed
      expect(await dedupePrefixedFile.text(), 'Hello World'); // content preserved, NOT deleted!
      expect(engine.deduplicatedCount, 1);

      // Database should record the asset with status 'dedupe' and prefixed path
      final relPrefixed = dedupePrefixedFile.path.replaceAll(r'\', '/');
      expect(db.hasFile(relPrefixed), isTrue);

      await engine.close();
      db.close();
      await tempDir.delete();
    });

    test('JobCtx.init pre-populates category stats from database so files/bytes do not start at 0', () async {
      final db = MediaDb.memory();
      db.recordAsset(
        id: 'photo1.jpg',
        platform: 'ins',
        user: 'photographer',
        category: Kind.posts,
        filePath: 'downloads/ins/photographer/posts/photo1.jpg',
        fileSize: 1048576, // 1 MB
      );
      db.recordAsset(
        id: 'photo2.jpg',
        platform: 'ins',
        user: 'photographer',
        category: Kind.posts,
        filePath: 'downloads/ins/photographer/posts/photo2.jpg',
        fileSize: 2097152, // 2 MB
      );

      final engine = IngestionEngine(db: db, options: (all: false, dry: false, compress: false, since: null));
      final ctx = JobCtx(
        target: const Target('ins', 'photographer'),
        kinds: {Kind.posts},
        api: Http.client(),
        root: Fs.dir('test_tmp/ins'),
        options: (all: false, dry: false, compress: false, since: null),
        db: db,
        engine: engine,
      );

      await ctx.init();

      final user = engine.getOrCreateUser('photographer', 'ins');
      final cat = user.category('posts');

      // Baseline stats must count existing downloaded files and memory
      expect(cat.had, 2);
      expect(cat.queued, 2);
      expect(cat.stored, 3145728); // 3 MB

      final dash = Dashboard(engine: engine, db: db);
      expect(dash.total.had, 2);
      expect(dash.total.bytes, 3145728);

      await engine.close();
      db.close();
    });

    test('JobCtx.profileAsset preserves original name from URL and saves with proper extension', () async {
      final db = MediaDb.memory();
      final engine = IngestionEngine(db: db, options: (all: false, dry: true, compress: false, since: null));
      final tmp = Fs.dir('test_tmp/profile_test');
      final ctx = JobCtx(
        target: const Target('ins', 'bigbadgirlt'),
        kinds: {Kind.profiles},
        api: Http.client(),
        root: tmp,
        options: (all: false, dry: true, compress: false, since: null),
        db: db,
        engine: engine,
      );

      ctx.profileAsset('https://instagram.f...net/v/t51.2885-19/44884218_3456789_n.jpg?stp=dst-jpg_s150x150');
      await engine.drain();

      final user = engine.getOrCreateUser('bigbadgirlt', 'ins');
      final cat = user.category('profiles');
      expect(cat.added, 1);

      final today = DateTime.now().format('yyyy-MM-dd');
      final expectedFile = ctx.folder(Kind.profiles).file('${today}_44884218_3456789_n.jpg');
      expect(expectedFile.name(), '${today}_44884218_3456789_n.jpg');
      expect(expectedFile.name().endsWith('.jpg'), isTrue);

      await engine.close();
      db.close();
    });

    test('JobCtx.profileAsset handles URLs without extension and format parameters', () async {
      final db = MediaDb.memory();
      final engine = IngestionEngine(db: db, options: (all: false, dry: true, compress: false, since: null));
      final tmp = Fs.dir('test_tmp/profile_ext_test');
      final ctx = JobCtx(
        target: const Target('twt', 'chunmomo0127'),
        kinds: {Kind.profiles},
        api: Http.client(),
        root: tmp,
        options: (all: false, dry: true, compress: false, since: null),
        db: db,
        engine: engine,
      );

      // Twitter banner URL has no extension in path, should default to .jpg
      ctx.profileAsset('https://pbs.twimg.com/profile_banners/123/1650723873/1500x500', id: 'banner_1650723873');

      // Twitter image URL with format=png parameter
      ctx.profileAsset('https://pbs.twimg.com/profile_images/123/avatar?format=png', id: 'avatar');
      await engine.drain();

      final today = DateTime.now().format('yyyy-MM-dd');
      final bannerFile = ctx.folder(Kind.profiles).file('${today}_banner_1650723873.jpg');
      expect(bannerFile.name().endsWith('.jpg'), isTrue);

      final avatarFile = ctx.folder(Kind.profiles).file('${today}_avatar.png');
      expect(avatarFile.name().endsWith('.png'), isTrue);

      await engine.close();
      db.close();
    });

    test('IngestionEngine migrateLegacyFiles renames extensionless image files based on magic bytes', () async {
      final db = MediaDb.memory();
      final engine = IngestionEngine(db: db, options: (all: false, dry: false, compress: false, since: null));
      final tmp = Fs.dir('test_tmp/legacy_migration_test');
      await tmp.create();

      // Create a mock extensionless JPEG file with JPEG magic bytes (FF D8 FF E0)
      final legacyFile = tmp.file('2026-10-17_old_avatar');
      await (Reader.of([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]) > legacyFile);
      final oldRel = legacyFile.path.replaceAll(r'\', '/');

      db.recordAsset(
        id: 'old_avatar',
        platform: 'ins',
        user: 'testuser',
        category: Kind.profiles,
        filePath: oldRel,
        fileSize: 10,
      );
      expect(db.hasFile(oldRel), isTrue);

      // Run migration
      await engine.migrateLegacyFiles(tmp);

      final migratedFile = tmp.file('2026-10-17_old_avatar.jpg');
      final newRel = migratedFile.path.replaceAll(r'\', '/');

      expect(await legacyFile.exists(), isFalse);
      expect(await migratedFile.exists(), isTrue);
      expect(db.hasFile(oldRel), isFalse);
      expect(db.hasFile(newRel), isTrue);

      await engine.close();
      db.close();
      await tmp.delete();
    });

    test('IngestionEngine initializes cdn client and worker lanes with high concurrency settings', () async {
      final db = MediaDb.memory();
      final engine = IngestionEngine(
        db: db,
        options: (all: false, dry: true, compress: false, since: null),
        downloadLanes: 8,
        transcodeLanes: 2,
      );

      expect(engine.lanes.length, 10);
      expect(engine.cdn, isNotNull);

      await engine.close();
      db.close();
    });
  });

  group('Dashboard', () {
    test('formats title string with metrics accurately', () {
      final db = MediaDb.memory();
      final engine = IngestionEngine(db: db, options: (all: false, dry: false, compress: false, since: null));

      final dashboard = Dashboard(engine: engine, db: db);
      expect(dashboard.title(), contains('medialoader'));
      expect(dashboard.title(), contains('0 users'));

      db.close();
    });
  });
}
