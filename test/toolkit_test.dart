import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Console & Terminal Namespaces', () {
    test('namespaced Console.terminal.width and height', () {
      expect(Console.terminal.width, greaterThan(0));
      expect(Console.terminal.height, greaterThan(0));
      expect(console.terminal.width, greaterThan(0));
    });

    test('console.writer formats box and table', () {
      final table = console.writer.table(['A', 'B'], [
        ['1', '2']
      ]);
      expect(table.render(), contains('A'));
      expect(table.render(), contains('1'));

      // Check box method doesn't throw
      console.writer.box('Hello World\nLine 2', title: 'Box Title');
      console.writer.rule('Test Rule');
    });

    test('console.reader and console.logger are accessible and console.logger.task runs task', () async {
      expect(console.reader, isNotNull);
      expect(console.logger, isNotNull);
      expect(Console.logger, isNotNull);
      final res = await console.logger.task('Running quick task', () async => 42);
      expect(res, equals(42));
    });

    test('console.logger methods execute without errors', () {
      expect(() => console.logger.info('Test info'), returnsNormally);
      expect(() => console.logger.ok('Test ok'), returnsNormally);
      expect(() => console.logger.success('Test success'), returnsNormally);
      expect(() => console.logger.warn('Test warn'), returnsNormally);
      expect(() => console.logger.warning('Test warning'), returnsNormally);
      expect(() => console.logger.error('Test error'), returnsNormally);
      expect(() => console.logger.fail('Test fail'), returnsNormally);
      expect(() => console.logger.step(1, 2, 'Test step'), returnsNormally);
      expect(() => console.logger.debug('Test debug'), returnsNormally);
      expect(() => console.logger.write(''), returnsNormally);
      expect(() => console.logger.writeln('Test line'), returnsNormally);
      expect(() => console.logger.line('Test line 2'), returnsNormally);
    });
  });

  group('Ansi Utilities', () {
    test('strip removes ANSI sequences', () {
      Ansi.enabled = true;
      final styled = 'Hello'.red().bold();
      expect(Ansi.strip(styled), equals('Hello'));
      expect(Ansi.visibleLength(styled), equals(5));
      expect(styled.stripAnsi, equals('Hello'));
      expect(styled.visibleLength, equals(5));
    });
  });

  group('fs Namespace & Fs Utilities', () {
    test('fs.sanitize removes or replaces illegal characters (1-word)', () {
      const raw = 'Key: "Box" / 20th * Edition? <Special> | Path\\';

      // Default ASCII replacement
      final sanitizedAscii = fs.sanitize(raw);
      expect(sanitizedAscii.contains(':'), isFalse);
      expect(sanitizedAscii.contains('"'), isFalse);
      expect(sanitizedAscii.contains('/'), isFalse);
      expect(sanitizedAscii.contains('\\'), isFalse);
      expect(sanitizedAscii.contains('*'), isFalse);
      expect(sanitizedAscii.contains('?'), isFalse);
      expect(sanitizedAscii.contains('<'), isFalse);
      expect(sanitizedAscii.contains('>'), isFalse);
      expect(sanitizedAscii.contains('|'), isFalse);

      // Full-width Japanese/Unicode replacement
      final sanitizedFull = fs.sanitize(raw, full: true);
      expect(sanitizedFull, contains('：'));
      expect(sanitizedFull, contains('”'));
      expect(sanitizedFull, contains('／'));
      expect(sanitizedFull, contains('＼'));
      expect(sanitizedFull, contains('＊'));
      expect(sanitizedFull, contains('？'));
      expect(sanitizedFull, contains('＜'));
      expect(sanitizedFull, contains('＞'));
      expect(sanitizedFull, contains('｜'));
    });

    test('fs.size and fs.parse (1-word)', () {
      expect(fs.size(0), equals('0 B'));
      expect(fs.size(1024), equals('1.0 KB'));
      expect(fs.size(1024 * 1024 * 5), equals('5.0 MB'));
      expect(fs.size(1024 * 1024 * 1024 * 2), equals('2.0 GB'));

      expect(fs.parse('500 B'), equals(500));
      expect(fs.parse('10 KB'), equals(10 * 1024));
      expect(fs.parse('2.5 MB'), equals((2.5 * 1024 * 1024).round()));
      expect(fs.parse('1 GB'), equals(1024 * 1024 * 1024));
    });

    test('fs.time formats mm:ss and hh:mm:ss (1-word)', () {
      expect(fs.time(const Duration(seconds: 45)), equals('00:45'));
      expect(
        fs.time(const Duration(minutes: 3, seconds: 12)),
        equals('03:12'),
      );
      expect(
        fs.time(const Duration(hours: 2, minutes: 15, seconds: 30)),
        equals('02:15:30'),
      );
    });

    test('fs.write, fs.has, fs.read, fs.copy, fs.move atomically (1-word)', () async {
      final tempDir = fs.temp('keybox_toolkit_test_');
      try {
        final file = File('${tempDir.path}/sub/test.txt');
        await fs.write(file, 'Hello Dart Toolkit!');

        expect(fs.has(file), isTrue);
        expect(fs.read(file.path), equals('Hello Dart Toolkit!'));
        expect(File('${file.path}.part').existsSync(), isFalse);

        // Test copy and move
        final copyFile = File('${tempDir.path}/sub/copy.txt');
        fs.copy(file, copyFile);
        expect(fs.has(copyFile), isTrue);
        expect(fs.read(copyFile.path), equals('Hello Dart Toolkit!'));

        final movedFile = File('${tempDir.path}/sub2/moved.txt');
        fs.move(copyFile, movedFile);
        expect(fs.has(copyFile), isFalse);
        expect(fs.has(movedFile), isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('fs path helpers join, base, name, ext, dir (1-word)', () {
      final p = fs.join('parent', 'sub', 'file.mp3');
      expect(p.replaceAll('\\', '/'), equals('parent/sub/file.mp3'));
      expect(fs.base(p), equals('file.mp3'));
      expect(fs.name(p), equals('file'));
      expect(fs.ext(p), equals('.mp3'));
      expect(fs.dir(p).replaceAll('\\', '/'), equals('parent/sub'));
    });
  });

  group('sys & proc Namespaces', () {
    test('sys.which finds dart (1-word)', () {
      final dartExe = sys.which('dart');
      expect(dartExe, isNotNull);
      expect(File(dartExe!).existsSync(), isTrue);

      expect(proc.which('dart'), equals(dartExe));
    });

    test('sys.clock starts stopwatch', () {
      final clock = sys.clock();
      expect(clock.isRunning, isTrue);
    });

    test('sys.run executes command and returns output (1-word)', () async {
      final result = await sys.run('dart', ['--version']);
      expect(result.code, equals(0));
      expect(result.ok, isTrue);
    });
  });

  group('parallel Namespace', () {
    test('parallel.run executes tasks concurrently', () async {
      final items = [1, 2, 3, 4, 5];
      final processed = await parallel.run(items, (n) async {
        await Future.delayed(const Duration(milliseconds: 10));
        return n * 10;
      }, size: 2);

      expect(processed, containsAll([10, 20, 30, 40, 50]));
    });

    test('parallel.map maps items', () async {
      final items = ['a', 'b', 'c'];
      final mapped = await parallel.map(items, (s) => s.toUpperCase());
      expect(mapped, containsAll(['A', 'B', 'C']));
    });
  });

  group('cli Namespace', () {
    test('cli.parse reads flags, options, and lists', () {
      cli.parse(['--force', '-p', '8', '--name=test', 'file1', 'file2']);

      expect(cli.has('force'), isTrue);
      expect(cli.has('p'), isTrue);
      expect(cli.get('p', 0), equals(8));
      expect(cli.get('name'), equals('test'));
      expect(cli.list(), equals(['file1', 'file2']));
    });
  });
}
