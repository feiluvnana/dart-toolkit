import 'dart:io';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('v7.0 Native dart:io Extensions', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dt_native_io_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'File extensions: writeAtomic, readLines, appendLine, readJson, writeJson',
      () async {
        final file = File('${tempDir.path}/test.txt');
        await file.writeAtomic('line 1\nline 2');

        expect(file.existsSync(), isTrue);
        final lines = await file.readLines();
        expect(lines, ['line 1', 'line 2']);

        await file.appendLine('line 3');
        final updatedLines = file.readLinesSync();
        expect(updatedLines, ['line 1', 'line 2', 'line 3']);

        final jsonFile = File('${tempDir.path}/data.json');
        await jsonFile.writeJson({'greeting': 'hello', 'count': 100});
        final json = await jsonFile.readJson();
        expect(json.text('greeting'), 'hello');
        expect(json.number('count'), 100);

        final decoded = await jsonFile.readDecoded<Map<String, dynamic>>();
        expect(decoded['greeting'], 'hello');
        expect(decoded['count'], 100);

        final jsonSync = jsonFile.readJsonSync();
        expect(jsonSync.text('greeting'), 'hello');
        expect(jsonSync.number('count'), 100);

        final decodedSync = jsonFile.readDecodedSync<Map<String, dynamic>>();
        expect(decodedSync['greeting'], 'hello');
        expect(decodedSync['count'], 100);
      },
    );

    test('Directory extensions: walk, listEntries, ensure', () async {
      final sub = Directory('${tempDir.path}/sub/nested');
      await sub.ensure();
      expect(sub.existsSync(), isTrue);

      final f1 = File('${sub.path}/a.dart');
      final f2 = File('${sub.path}/b.txt');
      f1.writeAsStringSync('void main() {}');
      f2.writeAsStringSync('text');

      final dartFiles = await tempDir
          .walk(matching: RegExp(r'\.dart$'))
          .toList();
      expect(dartFiles.length, 1);
      expect(dartFiles.first.path, endsWith('a.dart'));

      final entries = await sub.listEntries().toList();
      expect(entries.length, 2);
      expect(entries.any((e) => e.name == 'a.dart'), isTrue);
    });

    test('FileSystemEntity extensions: isFile, isDir, entry', () {
      final file = File('${tempDir.path}/entity_test.txt');
      file.writeAsStringSync('content');

      expect(file.isFile, isTrue);
      expect(file.isDir, isFalse);
      expect(file.isLink, isFalse);
      expect(file.entry.name, 'entity_test.txt');
      expect(tempDir.isDir, isTrue);
      expect(tempDir.isFile, isFalse);
    });
  });

  group('v8.0 File System Predicates & Operations', () {
    late String tempPath;

    setUp(() {
      tempPath = tempDirSync('dt_pred_').path;
    });

    tearDown(() {
      try {
        removePathSync(tempPath);
      } catch (_) {}
    });

    test('Files sync predicates: isFile, isDir, exists, stat', () {
      final filePath = joinPath(tempPath, 'sample.txt');
      expect(pathExists(filePath), isFalse);
      expect(fileExists(filePath), isFalse);
      expect(dirExists(filePath), isFalse);
      expect(fileStat(filePath)?.size, isNull);

      writeTextSync(filePath, 'hello world');
      expect(pathExists(filePath), isTrue);
      expect(fileExists(filePath), isTrue);
      expect(dirExists(filePath), isFalse);
      expect(fileStat(filePath)?.size, 11);

      expect(dirExists(tempPath), isTrue);
      expect(fileExists(tempPath), isFalse);
    });

    test('Files async predicates: isFile, isDir, exists, stat', () async {
      final filePath = joinPath(tempPath, 'sample_async.txt');
      expect(pathExists(filePath), isFalse);
      expect(fileExists(filePath), isFalse);
      expect(dirExists(filePath), isFalse);
      expect(fileStat(filePath)?.size, isNull);

      await writeText(filePath, 'hello async');
      expect(pathExists(filePath), isTrue);
      expect(fileExists(filePath), isTrue);
      expect(dirExists(filePath), isFalse);
      expect(fileStat(filePath)?.size, 11);
    });
  });

  group('v8.0 System & Process DX Supercharger', () {
    test(
      'SysResult rich properties: exitCode, isSuccess, stdout, stderr, lines',
      () async {
        final res = await run('dart', ['--version']);
        expect(res.exitCode, 0);
        expect(res.ok, isTrue);
        expect(res.ok, isTrue);
        final output = '${res.stdout} ${res.stderr}';
        expect(output, contains(RegExp('Dart', caseSensitive: false)));
      },
    );

    test('runStream execution', () async {
      final lines = await runStream('dart', [
        '--version',
      ], includeStderr: true).toList();
      expect(lines.isNotEmpty, isTrue);
      expect(lines.any((l) => l.toLowerCase().contains('dart')), isTrue);
    });

    test('Typed environment accessors in Env and env', () {
      env.set('TEST_PORT', '9090');
      env.set('TEST_VERBOSE', 'true');
      env.set('TEST_SECRET', 'secret_key_123');

      expect(env.get<int>('TEST_PORT', 3000), 9090);
      expect(env.get<int>('NON_EXISTENT_PORT', 3000), 3000);
      expect(env.get<int>('TEST_PORT', 0), 9090);

      expect(env.get<bool>('TEST_VERBOSE', false), isTrue);
      expect(env.get<bool>('NON_EXISTENT_FLAG', true), isTrue);
      expect(env.get<bool>('TEST_VERBOSE', false), isTrue);

      expect(env.require('TEST_SECRET'), 'secret_key_123');
      expect(() => env.require('UNKNOWN_VAR'), throwsStateError);

      env.delete('TEST_PORT');
      env.delete('TEST_VERBOSE');
      env.delete('TEST_SECRET');
    });
  });
}
