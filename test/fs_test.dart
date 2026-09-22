import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mock_client.dart';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('fs', () {
    late Path dir;
    setUp(() => dir = Path(Directory.systemTemp.createTempSync('fs4_').path));
    tearDown(() => dir.deleteSync(recursive: true));

    test('absolute, relativeTo, withExt, withName', () {
      final f = dir / 'a' / 'song.mp3';
      expect(f.isAbsolute, isTrue);
      expect(Path('x/y').isAbsolute, isFalse);
      expect(Path('x/y').absolute, Path.current / 'x' / 'y');
      expect(f.relativeTo(dir), Path('a/song.mp3'));
      expect(f.withExt('flac').name, 'song.flac');
      expect(f.withExt('.flac').name, 'song.flac');
      expect(f.withExt('').name, 'song');
      expect(f.withName('other.mp3'), dir / 'a' / 'other.mp3');
    });

    test('touch, modified, lines', () async {
      final f = dir / 'deep' / 'notes.txt';
      await f.touch();
      expect(await f.exists(), isTrue);
      final first = await f.modified();
      await f.writeText('one\ntwo\nthree');
      expect(await f.lines().toList(), ['one', 'two', 'three']);
      final g = (dir / 'g.txt')..touchSync();
      expect(g.modifiedSync().difference(first).inSeconds.abs(), lessThan(5));
    });

    test('String.json parses like JsonDocument.parse', () {
      expect('{"a": [1, 2]}'.json.$(r'$.a[1]').first.raw, 2);
    });
  });

  group('FS Automation Extensions', () {
    late Path testDir;

    setUp(() async {
      testDir = Path.temp / 'dart_toolkit_fs_auto_test';
      await testDir.mkdir();
    });

    tearDown(() async {
      if (await testDir.exists()) {
        await testDir.delete(recursive: true);
      }
    });

    test('Path static getters return valid paths', () {
      expect(Path.current.isNotEmpty, isTrue);
      expect(Path.temp.isNotEmpty, isTrue);
      expect(Path.home.isNotEmpty, isTrue);
    });

    test('Path sha256 and md5 checksums calculate correctly', () async {
      final file = testDir / 'test_hash.txt';
      await file.writeText('hello world');

      // echo -n "hello world" | sha256sum -> b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
      expect(await file.hash(Hash.sha256), equals('b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9'));

      // echo -n "hello world" | md5sum -> 5eb63bbbe01eeed093cb22bb8f5acdc3
      expect(await file.hash(Hash.md5), equals('5eb63bbbe01eeed093cb22bb8f5acdc3'));
    });

    test('streamed and in-memory digests agree across chunk boundaries', () async {
      // Larger than one read buffer, so the streaming path really does chunk.
      final file = testDir / 'big_hash.bin';
      await file.writeBytes(List<int>.generate(1 << 20, (i) => i % 251));

      expect(await file.hash(Hash.sha256), equals((await file.readBytes()).hash(Hash.sha256)));
      expect(await file.hash(Hash.md5), equals((await file.readBytes()).hash(Hash.md5)));
    });

    test('Path append and replace edit in-place', () async {
      final file = testDir / 'doc.txt';
      await file.writeText('title: Dart Toolkit\n');

      await file.append('author: feiluvnana\n');
      await file.append('version: 9.0.0\n');

      final lines = await file.readLines();
      expect(lines, equals(['title: Dart Toolkit', 'author: feiluvnana', 'version: 9.0.0']));

      await file.replaceText('9.0.0', '9.1.0');
      expect(await file.readText(), contains('version: 9.1.0'));
    });
  });

  group('FS Path', () {
    final tempDir = Directory.systemTemp.createTempSync('fs_path_test_');

    tearDownAll(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('operator / joins paths and accesses file and dir', () {
      const root = Path('test_dir');
      final sub = root / 'sub' / 'file.txt';

      expect(sub, equals('test_dir/sub/file.txt'.replaceAll('/', Platform.pathSeparator)));
      expect(sub.asFile, isA<File>());
      expect(sub.asDir, isA<Directory>());
      expect(sub.asFile.path, equals(sub));
    });

    test('String extension .path and /', () {
      final p = 'base'.path / 'child';
      expect(p, equals('base/child'.replaceAll('/', Platform.pathSeparator)));
    });

    test('sanitized cleans invalid filename characters', () {
      final p = Path(r'folder/invalid:*?"<>| name.mp3');
      final cleaned = p.sanitized;
      expect(cleaned.contains('*'), isFalse);
      expect(cleaned.contains('?'), isFalse);
      expect(cleaned.contains('<'), isFalse);
    });

    test('filename escapes separators that sanitized keeps', () {
      expect('AIR / Farewell song'.filename, equals('AIR _ Farewell song'));
      expect(r'a\b'.filename, equals('a_b'));
      expect('  spaced   out  '.filename, equals('spaced out'));
      expect('///'.filename, equals('___'));
      expect(''.filename, equals('_'));

      // The point of the distinction: a scraped title can never grow a directory.
      final target = 'Key BOX'.path / 'DISC01' / '${'AIR / Farewell'.filename}.mp3';
      expect(target.segments.length, equals(3));
      expect('AIR / Farewell song'.path.sanitized.contains('/'), isTrue);
    });

    test('type, exist, writeText, readText, writeBytes, readBytes, and size', () async {
      final root = Path(tempDir.path) / 'text_test';
      final file = root / 'hello.txt';

      expect(await file.exists(), isFalse);
      expect(await file.type(), equals(PathType.none));

      await file.writeText('Hello World');
      expect(await file.exists(), isTrue);
      expect(await file.type(), equals(PathType.file));
      expect(await file.readText(), equals('Hello World'));
      expect(await file.size(), equals(11));

      final bytes = [1, 2, 3, 4, 5];
      final binaryFile = root / 'data.bin';
      await binaryFile.writeBytes(bytes);
      expect(await binaryFile.readBytes(), equals(bytes));

      // Sync counterparts
      final syncFile = root / 'sync.txt';
      expect(syncFile.existsSync(), isFalse);
      expect(syncFile.typeSync(), equals(PathType.none));

      syncFile.writeTextSync('Sync Content');
      expect(syncFile.existsSync(), isTrue);
      expect(syncFile.typeSync(), equals(PathType.file));
      expect(syncFile.readTextSync(), equals('Sync Content'));
      expect(syncFile.readLinesSync(), equals(['Sync Content']));

      final syncBin = root / 'sync.bin';
      syncBin.writeBytesSync([10, 20, 30]);
      expect(syncBin.readBytesSync(), equals([10, 20, 30]));
    });

    test('writeText and readText round-trip a JSON file', () async {
      final root = Path(tempDir.path) / 'json_test';
      final jsonFile = root / 'data.json';

      final doc = await jsonFile.writeText(jsonEncode({'title': 'KeyBOX', 'discs': 50}));
      expect(doc, isA<File>());
      expect(doc.existsSync(), isTrue);

      final readDoc = JsonDocument.parse(await jsonFile.readText());
      expect(readDoc.raw, equals({'title': 'KeyBOX', 'discs': 50}));
      expect(readDoc.$(r'$.discs').first.raw, equals(50));
    });

    test('mkdir, copy, move, delete, zip, and unzip', () async {
      final base = Path(tempDir.path) / 'archive_test';
      final folder = base / 'source_dir';
      await folder.mkdir();
      expect(await folder.type(), equals(PathType.dir));

      final docFile = folder / 'note.txt';
      await docFile.writeText('Archive Note');

      // Zip
      final zipFile = base / 'archive.zip';
      await folder.archiveTo(zipFile);
      expect(await zipFile.exists(), isTrue);

      // Unzip
      final extracted = base / 'extracted';
      await zipFile.extractTo(extracted);
      expect(await (extracted / 'note.txt').exists(), isTrue);
      expect(await (extracted / 'note.txt').readText(), equals('Archive Note'));

      // Copy & Move
      final copied = base / 'copied_dir';
      await folder.copy(copied);
      expect(await (copied / 'note.txt').exists(), isTrue);

      final moved = base / 'moved_dir';
      await copied.move(moved);
      expect(await copied.exists(), isFalse);
      expect(await (moved / 'note.txt').exists(), isTrue);

      // Delete
      await moved.delete(recursive: true);
      expect(await moved.exists(), isFalse);
    });

    test('download and downloadAll stream progress correctly', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path == '/file1.txt') {
          return Response('Hello file 1', 200, headers: {'content-length': '12'});
        } else if (path == '/file2.txt') {
          return Response('Hello file 2', 200, headers: {'content-length': '12'});
        }
        return Response('Not Found', 404);
      });

      await Http.session(client: client, () async {
        final base = Path(tempDir.path) / 'download_test';

        // 1. Single download on Path
        final file1 = base / 'file1.txt';
        final updates = await file1.download('https://example.com/file1.txt'.url).toList();
        expect(updates.isNotEmpty, isTrue);
        final lastUpdate = updates.last.current;
        expect(lastUpdate, isA<Downloaded>());
        expect(lastUpdate.received, equals(12));
        expect(await file1.readText(), equals('Hello file 1'));

        // Re-download without overwrite skips
        final skipUpdates = await file1.download('https://example.com/file1.txt'.url).toList();
        expect(skipUpdates.single.current, isA<DownloadSkipped>());
        expect(skipUpdates.single.current.isDone, isTrue);

        // 2. Single download on Uri
        final file1Alt = base / 'file1_alt.txt';
        final uriUpdates = await file1Alt.download('https://example.com/file1.txt'.url).toList();
        expect(uriUpdates.last.current, isA<Downloaded>());
        expect(await file1Alt.readText(), equals('Hello file 1'));

        // 3. Batch downloadAll on a source-to-destination map
        final mapUriPath = {
          'https://example.com/file1.txt'.url: base / 'batch1.txt',
          'https://example.com/file2.txt'.url: base / 'batch2.txt',
        };
        final batch1Updates = await mapUriPath.download(concurrency: 2).toList();
        expect(batch1Updates.isNotEmpty, isTrue);
        final finalBatch1 = batch1Updates.last;
        expect(finalBatch1.completed, equals(2));
        expect(finalBatch1.written, equals(2));
        // 4. A failure is a DownloadFailed, carrying its error
        final fileFail = base / 'not_found.txt';
        final failUpdates = await fileFail.download('https://example.com/404.txt'.url).toList();
        expect(failUpdates.last.current, isA<DownloadFailed>());
        expect((failUpdates.last.current as DownloadFailed).error, isA<HttpException>());

        // 5. The iterable form keeps two destinations for one URL; a Map cannot
        final pairs = [
          (url: 'https://example.com/file1.txt'.url, path: base / 'twice_a.txt'),
          (url: 'https://example.com/file1.txt'.url, path: base / 'twice_b.txt'),
        ];
        final twice = await pairs.download(concurrency: 2).toList();
        expect(twice.last.completed, equals(2));
        expect(twice.last.total, equals(2));
        expect(await (base / 'twice_a.txt').exists(), isTrue);
        expect(await (base / 'twice_b.txt').exists(), isTrue);

        // 6. The stream form overlaps discovery with transfer; total is unknown until it closes
        final discovered = StreamController<({Uri url, Path path})>();
        final events = <BatchDownloadProgress>[];
        final done = discovered.stream.download(concurrency: 2).forEach(events.add);
        discovered.add((url: 'https://example.com/file1.txt'.url, path: base / 'streamed1.txt'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(events.isNotEmpty, isTrue);
        expect(events.first.total, isNull, reason: 'total is unknown while the source is open');
        discovered.add((url: 'https://example.com/file2.txt'.url, path: base / 'streamed2.txt'));
        await discovered.close();
        await done;
        expect(events.last.total, equals(2));
        expect(events.last.completed, equals(2));
        expect(await (base / 'streamed2.txt').readText(), equals('Hello file 2'));
      });
    });

    test('name, stem, ext, parent, and segments properties', () {
      final p = Path('folder/subfolder/track.part.mp3');
      expect(p.name, equals('track.part.mp3'));
      expect(p.stem, equals('track.part'));
      expect(p.ext, equals('mp3'));
      expect(p.parent.path, equals('folder/subfolder'.replaceAll('/', Platform.pathSeparator)));
      expect(p.segments, equals(['folder', 'subfolder', 'track.part.mp3']));

      final noExt = Path('folder/readme');
      expect(noExt.name, equals('readme'));
      expect(noExt.stem, equals('readme'));
      expect(noExt.ext, equals(''));
    });

    test('readHtml, writeHtml, readXml, and writeXml', () async {
      final base = Path(tempDir.path) / 'docs_test';

      // HTML
      final htmlFile = base / 'page.html';
      final initialHtml = HtmlDocument.parse('<!DOCTYPE html><html><body><h1>Header</h1></body></html>');
      await htmlFile.writeText(initialHtml.outerHtml);
      expect(await htmlFile.exists(), isTrue);

      final readHtmlDoc = HtmlDocument.parse(await htmlFile.readText());
      expect(readHtmlDoc.$('h1').firstOrNull?.text, equals('Header'));

      // XML
      final xmlFile = base / 'data.xml';
      final initialXml = XmlDocument.parse('<root><item id="1">Value</item></root>');
      await xmlFile.writeText(initialXml.outerXml);
      expect(await xmlFile.exists(), isTrue);

      final readXmlDoc = XmlDocument.parse(await xmlFile.readText());
      expect(readXmlDoc.$x('//item').text, equals('Value'));

      // Sync document operations
      final syncJsonFile = base / 'sync.json';
      syncJsonFile.writeTextSync(jsonEncode({'key': 'val', 'num': 42}));
      expect(syncJsonFile.existsSync(), isTrue);
      final syncJson = JsonDocument.parse(syncJsonFile.readTextSync());
      expect(syncJson['key'].to<String>(), equals('val'));
      expect(syncJson['num'].to<int>(), equals(42));

      final syncHtmlFile = base / 'sync.html';
      syncHtmlFile.writeTextSync(HtmlDocument.parse('<h2>Sync Header</h2>').outerHtml);
      expect(HtmlDocument.parse(syncHtmlFile.readTextSync()).$('h2').first.text, equals('Sync Header'));

      final syncXmlFile = base / 'sync.xml';
      syncXmlFile.writeTextSync(XmlDocument.parse('<root><node>Sync</node></root>').outerXml);
      expect(XmlDocument.parse(syncXmlFile.readTextSync()).$x('//node').text, equals('Sync'));

      // mkdirSync & deleteSync
      final syncDir = base / 'sync_dir_test';
      syncDir.mkdirSync();
      expect(syncDir.typeSync(), equals(PathType.dir));
      syncDir.deleteSync(recursive: true);
      expect(syncDir.existsSync(), isFalse);
    });

    test('list, files, dirs, links, and glob streams', () async {
      final base = Path(tempDir.path) / 'streams_test';
      final subA = base / 'subA';
      final subB = base / 'subB';
      await subA.mkdir();
      await subB.mkdir();

      final file1 = subA / 'song.mp3';
      final file2 = subA / 'song.flac';
      final file3 = subB / 'cover.jpg';
      await file1.writeText('audio1');
      await file2.writeText('audio2');
      await file3.writeText('image');

      // files()
      final allFiles = await base.files(recursive: true).toList();
      expect(allFiles.length, equals(3));
      expect(allFiles.map((f) => f.name).toSet(), equals({'song.mp3', 'song.flac', 'cover.jpg'}));

      // dirs()
      final allDirs = await base.dirs(recursive: true).toList();
      expect(allDirs.length, equals(2));
      expect(allDirs.map((d) => d.name).toSet(), equals({'subA', 'subB'}));

      // list()
      final topList = await base.list(recursive: false).toList();
      expect(topList.length, equals(2));

      // glob()
      final mp3Glob = await base.glob('**/*.mp3').toList();
      expect(mp3Glob.length, equals(1));
      expect(mp3Glob.first.name, equals('song.mp3'));

      final allAudioGlob = await base.glob('subA/*.*').toList();
      expect(allAudioGlob.length, equals(2));

      // Synchronous equivalents: listSync, filesSync, dirsSync, globSync
      final syncFiles = base.filesSync(recursive: true);
      expect(syncFiles.length, equals(3));
      expect(syncFiles.map((f) => f.name).toSet(), equals({'song.mp3', 'song.flac', 'cover.jpg'}));

      final syncDirs = base.dirsSync(recursive: true);
      expect(syncDirs.length, equals(2));

      final syncList = base.listSync(recursive: false);
      expect(syncList.length, equals(2));

      final syncMp3Glob = base.globSync('**/*.mp3');
      expect(syncMp3Glob.length, equals(1));
      expect(syncMp3Glob.first.name, equals('song.mp3'));

      final syncAudioGlob = base.globSync('subA/*.*');
      expect(syncAudioGlob.length, equals(2));
    });

    test(
      'synchronous filesystem operations (sizeSync, copySync, moveSync, zipSync, unzipSync, hashes, appendSync, replaceSync)',
      () {
        final base = Path(tempDir.path) / 'sync_full_test';
        base.mkdirSync();

        final file1 = base / 'file1.txt';
        file1.writeTextSync('Hello World');
        expect(file1.sizeSync(), equals(11));
        expect(file1.readTextSync(), equals('Hello World'));

        // appendSync & replaceSync
        file1.appendSync('!!!');
        expect(file1.readTextSync(), equals('Hello World!!!'));
        file1.replaceTextSync('World', 'Dart');
        expect(file1.readTextSync(), equals('Hello Dart!!!'));

        // hashes
        expect(file1.readBytesSync().hash(Hash.sha256).isNotEmpty, isTrue);
        expect(file1.readBytesSync().hash(Hash.md5).isNotEmpty, isTrue);

        // copySync & moveSync
        final copyDest = base / 'file1_copy.txt';
        file1.copySync(copyDest.path);
        expect(copyDest.existsSync(), isTrue);
        expect(copyDest.readTextSync(), equals('Hello Dart!!!'));

        final moveDest = base / 'file1_moved.txt';
        copyDest.moveSync(moveDest.path);
        expect(copyDest.existsSync(), isFalse);
        expect(moveDest.existsSync(), isTrue);
        expect(moveDest.readTextSync(), equals('Hello Dart!!!'));
      },
    );

    test('glob matches relative to the root, not through the absolute path', () {
      final base = Path(tempDir.path) / 'glob_rel' / 'assets';
      (base / 'song.mp3').writeTextSync('x');

      expect(base.globSync('*.mp3').length, equals(1));
      // 'assets' is a segment of the absolute path but not of any relative one,
      // so it must not match. The old two-pass matcher let it through.
      expect(base.globSync('assets/*.mp3'), isEmpty);
    });

    test('atomic download handles short read, keeps the partial for a resume, never gets stuck', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        // Advertises 1000 bytes but sends only 10 bytes
        return StreamedResponse(
          Stream.value(List<int>.filled(10, 65)),
          200,
          contentLength: 1000,
          headers: {'content-length': '1000'},
        );
      });

      await Http.session(client: client, () async {
        final base = Path(tempDir.path) / 'atomic_dl_test';
        final target = base / 'truncated.dat';

        final progressEvents = await target.download('https://example.com/truncated.dat'.url).toList();
        final last = progressEvents.last.current;
        expect(last, isA<DownloadFailed>());
        expect(last.isDone, isTrue);

        // Target file must NOT exist on disk; the partial stays as the resume point.
        expect(await target.exists(), isFalse);
        expect(File('${target.path}.part').lengthSync(), 10);

        // Subsequent download attempt is not falsely skipped; a server that ignores the Range
        // request (200, not 206) makes it start over rather than append.
        final reattempt = await target.download('https://example.com/truncated.dat'.url).toList();
        expect(reattempt.first.current, isNot(isA<DownloadSkipped>()));
        expect(reattempt.last.current, isA<DownloadFailed>());
        expect(File('${target.path}.part').lengthSync(), 10);
      });
    });

    test('glob supports caseSensitive parameter and platform defaults', () {
      final base = Path(tempDir.path) / 'glob_case_test';
      base.mkdirSync();
      (base / 'song.mp3').writeTextSync('data');

      // Case insensitive match
      expect(base.globSync('*.MP3', caseSensitive: false).length, equals(1));
      // Case sensitive match
      expect(base.globSync('*.MP3', caseSensitive: true).isEmpty, equals(true));
      expect(base.globSync('*.mp3', caseSensitive: true).length, equals(1));
    });

    test('Path normalization and equality', () {
      final p1 = Path('a/b/c');
      final p2 = Path('a/b/../b/c');
      expect(p1.normalized, equals(p2.normalized));
      expect(Path('a/./b//c').normalized.path, equals(p.normalize('a/./b//c')));

      // normalized returns a Path, so it composes back into a Path-keyed map.
      expect(p1 == p2, isFalse);
      final byPath = <Path, int>{p1.normalized: 1};
      expect(byPath[p2.normalized], equals(1));
    });
  });

  group('move validates before it creates', () {
    test('moving a file that is not there leaves no directories behind', () async {
      final dir = Directory.systemTemp.createTempSync('move_');
      addTearDown(() => dir.deleteSync(recursive: true));
      await expectLater(
        () => '${dir.path}/absent.txt'.path.move('${dir.path}/made/up/here.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory('${dir.path}/made').existsSync(), isFalse);
      expect(
        () => '${dir.path}/absent.txt'.path.moveSync('${dir.path}/also/here.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory('${dir.path}/also').existsSync(), isFalse);
    });
  });

  group('glob walks only where the pattern can match', () {
    late Path root;

    setUp(() async {
      root = Path(Directory.systemTemp.createTempSync('tk_glob_').path);
      for (final f in [
        'lib/a.dart',
        'lib/src/b.dart',
        'lib/src/deep/c.dart',
        'lib/notes.txt',
        'build/junk.dart',
        'build/nested/more/junk.dart',
        'top.dart',
        'README.md',
      ]) {
        await Path(p.join(root.path, f)).writeText('x');
      }
    });

    tearDown(() => root.delete(recursive: true));

    /// The whole tree, filtered — what glob did before it learned where to start.
    Future<List<String>> byWalkingEverything(String pattern) async {
      final matcher = _globLike(pattern);
      final out = <String>[];
      await for (final e in root.asDir.list(recursive: true, followLinks: false)) {
        if (matcher.hasMatch(p.relative(e.path, from: root.path))) out.add(e.path);
      }
      return out..sort();
    }

    for (final pattern in [
      'lib/**/*.dart',
      'lib/*.dart',
      'lib/src/*.dart',
      '**/*.dart',
      '*.md',
      '*.dart',
      'lib/src/deep/c.dart',
      'build/**/*.dart',
    ]) {
      test('$pattern matches what a whole-tree walk matches', () async {
        final got = (await root.glob(pattern).toList()).map((e) => e.path).toList()..sort();
        expect(got, equals(await byWalkingEverything(pattern)), reason: pattern);
        expect(root.globSync(pattern).map((e) => e.path).toList()..sort(), equals(got), reason: '$pattern, sync');
      });
    }

    test('a prefix directory that is not there matches nothing rather than throwing', () async {
      expect(await root.glob('nope/**/*.dart').toList(), isEmpty);
      expect(root.globSync('nope/*.dart'), isEmpty);
    });

    test('a pattern without ** does not descend past its own segments', () async {
      expect((await root.glob('lib/*.dart').toList()).map((e) => e.name), unorderedEquals(['a.dart']));
      expect((await root.glob('*.dart').toList()).map((e) => e.name), unorderedEquals(['top.dart']));
    });
  });
}

/// The pattern rules `glob` documents — `*`, `**` and `?` — as one regular expression.
RegExp _globLike(String pattern) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '*' && i + 1 < pattern.length && pattern[i + 1] == '*') {
      if (i + 2 < pattern.length && pattern[i + 2] == '/') {
        buffer.write('(?:.+/)?');
        i += 2;
      } else {
        buffer.write('.*');
        i += 1;
      }
    } else if (c == '*') {
      buffer.write('[^/]*');
    } else if (c == '?') {
      buffer.write('[^/]');
    } else if (r'.+()^$[]{}|\'.contains(c)) {
      buffer.write('\\$c');
    } else {
      buffer.write(c);
    }
  }
  return RegExp('$buffer\$');
}
