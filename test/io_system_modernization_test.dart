import 'dart:io';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Path: one type, no dart:io wrapper layer', () {
    late Path root;

    setUp(() {
      root = SyncPath.tempDir('dt_path_test_');
    });

    tearDown(() {
      try {
        root.sync.delete();
      } catch (_) {}
    });

    test('text, lines and appending, async and under .sync', () async {
      final file = root / 'test.txt';
      await file.writeText('line 1\nline 2');

      expect(file.isFile, isTrue);
      expect(await file.readLines(), ['line 1', 'line 2']);

      await file.appendText('\nline 3');
      expect(file.sync.readLines(), ['line 1', 'line 2', 'line 3']);
    });

    test('JSON round-trips through the same path', () async {
      final file = root / 'data.json';
      await file.writeJson({'greeting': 'hello', 'count': 100});

      final json = await file.readJson();
      expect(json.text('greeting'), 'hello');
      expect(json.number('count'), 100);

      final sync = file.sync.readJson();
      expect(sync.text('greeting'), 'hello');
      expect(sync.number('count'), 100);

      // The same file through the codec seam, with a leading dot.
      expect((await file.read(.json)).text('greeting'), 'hello');
    });

    test('`/` composes, and the pieces come back apart', () {
      final file = root / 'sub' / 'nested' / 'a.dart';
      expect(file.name, 'a.dart');
      expect(file.stem, 'a');
      expect(file.ext, '.dart');
      expect(file.parent.name, 'nested');
      expect(file.parent.parent.name, 'sub');
    });

    test('makeDir, walk and list', () async {
      final sub = root / 'sub' / 'nested';
      await sub.makeDir();
      expect(sub.isDir, isTrue);

      await (sub / 'a.dart').writeText('void main() {}');
      await (sub / 'b.txt').writeText('text');

      final dartFiles = await root.walk(match: '*.dart');
      expect(dartFiles.length, 1);
      expect(dartFiles.first.path, endsWith('a.dart'));

      final entries = await sub.list();
      expect(entries.length, 2);
      expect(entries.any((e) => e.name == 'a.dart'), isTrue);
    });

    test('a Path is a String, so dart:io takes it unchanged', () async {
      final file = root / 'entity_test.txt';
      await file.writeText('content');

      expect(File(file).readAsStringSync(), 'content');
      expect(file.endsWith('.txt'), isTrue);
      expect('$file', file.raw);
      expect(file.isFile, isTrue);
      expect(file.isDir, isFalse);
      expect(file.isLink, isFalse);
      expect(file.stat?.name, 'entity_test.txt');
      expect(root.isDir, isTrue);
      expect(root.isFile, isFalse);
    });
  });

  group('v8.0 File System Predicates & Operations', () {
    late String tempPath;

    setUp(() {
      tempPath = SyncPath.tempDir('dt_pred_').path;
    });

    tearDown(() {
      try {
        Path(tempPath).sync.delete();
      } catch (_) {}
    });

    test('Files sync predicates: isFile, isDir, exists, stat', () {
      final filePath = Path(tempPath) / 'sample.txt';
      expect(Path(filePath).exists, isFalse);
      expect(Path(filePath).isFile, isFalse);
      expect(Path(filePath).isDir, isFalse);
      expect(Path(filePath).stat?.size, isNull);

      Path(filePath).sync.writeText('hello world');
      expect(Path(filePath).exists, isTrue);
      expect(Path(filePath).isFile, isTrue);
      expect(Path(filePath).isDir, isFalse);
      expect(Path(filePath).stat?.size, 11);

      expect(Path(tempPath).isDir, isTrue);
      expect(Path(tempPath).isFile, isFalse);
    });

    test('Files async predicates: isFile, isDir, exists, stat', () async {
      final filePath = Path(tempPath) / 'sample_async.txt';
      expect(Path(filePath).exists, isFalse);
      expect(Path(filePath).isFile, isFalse);
      expect(Path(filePath).isDir, isFalse);
      expect(Path(filePath).stat?.size, isNull);

      await Path(filePath).writeText('hello async');
      expect(Path(filePath).exists, isTrue);
      expect(Path(filePath).isFile, isTrue);
      expect(Path(filePath).isDir, isFalse);
      expect(Path(filePath).stat?.size, 11);
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
      env['TEST_PORT'] = '9090';
      env['TEST_VERBOSE'] = 'true';
      env['TEST_SECRET'] = 'secret_key_123';

      expect(env.value<int>('TEST_PORT', 3000), 9090);
      expect(env.value<int>('NON_EXISTENT_PORT', 3000), 3000);
      expect(env.value<int>('TEST_PORT', 0), 9090);

      expect(env.value<bool>('TEST_VERBOSE', false), isTrue);
      expect(env.value<bool>('NON_EXISTENT_FLAG', true), isTrue);
      expect(env.value<bool>('TEST_VERBOSE', false), isTrue);

      expect(env.require('TEST_SECRET'), 'secret_key_123');
      expect(() => env.require('UNKNOWN_VAR'), throwsStateError);

      env.remove('TEST_PORT');
      env.remove('TEST_VERBOSE');
      env.remove('TEST_SECRET');
    });
  });
}
