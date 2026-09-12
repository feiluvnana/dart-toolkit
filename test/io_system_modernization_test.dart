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

  group('v7.0 Restored File System Predicates', () {
    late String tempPath;

    setUp(() {
      tempPath = io.dir.temp('dt_pred_').path;
    });

    tearDown(() {
      try {
        io.remove(tempPath);
      } catch (_) {}
    });

    test('io sync predicates: isFile, isDir, isLink, exists, size', () {
      final filePath = io.path.join(tempPath, 'sample.txt');
      expect(io.exists(filePath), isFalse);
      expect(io.isFile(filePath), isFalse);
      expect(io.isDir(filePath), isFalse);
      expect(io.size(filePath), isNull);

      io.write(filePath, 'hello world');
      expect(io.exists(filePath), isTrue);
      expect(io.isFile(filePath), isTrue);
      expect(io.isDir(filePath), isFalse);
      expect(io.size(filePath), 11);

      expect(io.isDir(tempPath), isTrue);
      expect(io.isFile(tempPath), isFalse);
    });

    test('io.async predicates: isFile, isDir, isLink, exists, size', () async {
      final filePath = io.path.join(tempPath, 'sample_async.txt');
      expect(await io.async.exists(filePath), isFalse);
      expect(await io.async.isFile(filePath), isFalse);
      expect(await io.async.isDir(filePath), isFalse);
      expect(await io.async.size(filePath), isNull);

      await io.async.write(filePath, 'hello async');
      expect(await io.async.exists(filePath), isTrue);
      expect(await io.async.isFile(filePath), isTrue);
      expect(await io.async.isDir(filePath), isFalse);
      expect(await io.async.size(filePath), 11);
    });
  });

  group('v7.0 System & Process DX Supercharger', () {
    test('SysResult rich properties: exitCode, isSuccess, stdout, stderr, lines', () async {
      final res = await system.run('dart', ['--version']);
      expect(res.exitCode, 0);
      expect(res.isSuccess, isTrue);
      expect(res.ok, isTrue);
      // dart --version writes to stderr or stdout depending on platform
      final output = '${res.stdout} ${res.stderr}';
      expect(output, contains(RegExp('Dart', caseSensitive: false)));
    });

    test('system.stream execution', () async {
      final lines = await system.stream('dart', ['--version'], includeStderr: true).toList();
      expect(lines.isNotEmpty, isTrue);
      expect(lines.any((l) => l.toLowerCase().contains('dart')), isTrue);
    });

    test('Typed environment accessors in system.env', () {
      system.env.set('TEST_PORT', '9090');
      system.env.set('TEST_VERBOSE', 'true');
      system.env.set('TEST_SECRET', 'secret_key_123');

      expect(system.env.int('TEST_PORT', defaultValue: 3000), 9090);
      expect(system.env.int('NON_EXISTENT_PORT', defaultValue: 3000), 3000);
      expect(system.env.getInt('TEST_PORT'), 9090);

      expect(system.env.bool('TEST_VERBOSE', defaultValue: false), isTrue);
      expect(system.env.bool('NON_EXISTENT_FLAG', defaultValue: true), isTrue);
      expect(system.env.getBool('TEST_VERBOSE'), isTrue);

      expect(system.env.require('TEST_SECRET'), 'secret_key_123');
      expect(() => system.env.require('UNKNOWN_VAR'), throwsStateError);

      system.env.delete('TEST_PORT');
      system.env.delete('TEST_VERBOSE');
      system.env.delete('TEST_SECRET');
    });
  });
}
