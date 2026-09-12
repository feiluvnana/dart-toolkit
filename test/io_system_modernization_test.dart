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

    test('File extensions: writeAtomic, readLines, appendLine, readJson, writeJson', () async {
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
    });

    test('Directory extensions: walk, listEntries, ensure', () async {
      final sub = Directory('${tempDir.path}/sub/nested');
      await sub.ensure();
      expect(sub.existsSync(), isTrue);

      final f1 = File('${sub.path}/a.dart');
      final f2 = File('${sub.path}/b.txt');
      f1.writeAsStringSync('void main() {}');
      f2.writeAsStringSync('text');

      final dartFiles = await tempDir.walk(matching: RegExp(r'\.dart$')).toList();
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
      tempPath = Files.tempDirSync('dt_pred_').path;
    });

    tearDown(() {
      try {
        Files.removeSync(tempPath);
      } catch (_) {}
    });

    test('Files sync predicates: isFile, isDir, exists, stat', () {
      final filePath = Files.join(tempPath, 'sample.txt');
      expect(Files.exists(filePath), isFalse);
      expect(Files.isFile(filePath), isFalse);
      expect(Files.isDir(filePath), isFalse);
      expect(Files.stat(filePath)?.size, isNull);

      Files.writeTextSync(filePath, 'hello world');
      expect(Files.exists(filePath), isTrue);
      expect(Files.isFile(filePath), isTrue);
      expect(Files.isDir(filePath), isFalse);
      expect(Files.stat(filePath)?.size, 11);

      expect(Files.isDir(tempPath), isTrue);
      expect(Files.isFile(tempPath), isFalse);
    });

    test('Files async predicates: isFile, isDir, exists, stat', () async {
      final filePath = Files.join(tempPath, 'sample_async.txt');
      expect(Files.exists(filePath), isFalse);
      expect(Files.isFile(filePath), isFalse);
      expect(Files.isDir(filePath), isFalse);
      expect(Files.stat(filePath)?.size, isNull);

      await Files.writeText(filePath, 'hello async');
      expect(Files.exists(filePath), isTrue);
      expect(Files.isFile(filePath), isTrue);
      expect(Files.isDir(filePath), isFalse);
      expect(Files.stat(filePath)?.size, 11);
    });
  });

  group('v8.0 System & Process DX Supercharger', () {
    test('SysResult rich properties: exitCode, isSuccess, stdout, stderr, lines', () async {
      final res = await System.run('dart', ['--version']);
      expect(res.exitCode, 0);
      expect(res.isSuccess, isTrue);
      expect(res.ok, isTrue);
      final output = '${res.stdout} ${res.stderr}';
      expect(output, contains(RegExp('Dart', caseSensitive: false)));
    });

    test('System.runStream execution', () async {
      final lines = await System.runStream('dart', ['--version'], includeStderr: true).toList();
      expect(lines.isNotEmpty, isTrue);
      expect(lines.any((l) => l.toLowerCase().contains('dart')), isTrue);
    });

    test('Typed environment accessors in Env and System.env', () {
      Env.set('TEST_PORT', '9090');
      Env.set('TEST_VERBOSE', 'true');
      Env.set('TEST_SECRET', 'secret_key_123');

      expect(Env.int('TEST_PORT', defaultValue: 3000), 9090);
      expect(Env.int('NON_EXISTENT_PORT', defaultValue: 3000), 3000);
      expect(Env.getInt('TEST_PORT'), 9090);

      expect(Env.bool('TEST_VERBOSE', defaultValue: false), isTrue);
      expect(Env.bool('NON_EXISTENT_FLAG', defaultValue: true), isTrue);
      expect(Env.getBool('TEST_VERBOSE'), isTrue);

      expect(Env.require('TEST_SECRET'), 'secret_key_123');
      expect(() => Env.require('UNKNOWN_VAR'), throwsStateError);

      Env.delete('TEST_PORT');
      Env.delete('TEST_VERBOSE');
      Env.delete('TEST_SECRET');
    });
  });
}
