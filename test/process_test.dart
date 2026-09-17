import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Process & Shell Execution', () {
    test(r'run() and run(...) execute system commands and capture stdout', () async {
      final resRun = await run('echo hello_world', quiet: true);
      expect(resRun.ok, isTrue);
      expect(resRun.ok, isTrue);
      expect(resRun.exitCode, equals(0));
      expect(resRun.text, equals('hello_world'));
      expect(resRun.lines, equals(['hello_world']));

      // Top-level $ shorthand
      final resDollar = await run('echo from_dollar', quiet: true);
      expect(resDollar.text, equals('from_dollar'));

      // Future<ShellResult> extension getters
      expect(await run('echo direct_text', quiet: true).text, equals('direct_text'));
      expect(await run('echo "line1\nline2"', quiet: true).lines, equals(['line1', 'line2']));
      expect(await run('echo true', quiet: true).ok, isTrue);
    });

    test('String.run() and Path.run() execute concise commands with workdir', () async {
      final res = await 'echo "hello from extension"'.run(quiet: true);
      expect(res.ok, isTrue);
      expect(res.text, equals('hello from extension'));

      final temp = Path.temp / 'test_proc_run';
      await temp.mkdir();
      try {
        final resDir = await 'pwd'.run(workdir: temp, quiet: true);
        if (!Platform.isWindows) {
          expect(resDir.text, contains(temp.name));
        }

        final echoPath = (await which('echo')) ?? 'echo'.path;
        final resPath = await echoPath.run(args: ['direct_path_run'], quiet: true);
        expect(resPath.text, equals('direct_path_run'));
      } finally {
        await temp.delete(recursive: true);
      }
    });

    test('ShellResult.json parses JSON output correctly', () async {
      final res = await 'echo \'{"name":"toolkit","version":9}\''.run(quiet: true);
      final json = res.json as Map<String, dynamic>;
      expect(json['name'], equals('toolkit'));
      expect(json['version'], equals(9));
      expect(res.json, isA<Map<String, dynamic>>());
    });

    test(r'run(...) throws ShellException when throwOnError is true (default)', () async {
      expect(() => run('dart --non-existent-flag-xyz', quiet: true), throwsA(isA<ShellException>()));
    });

    test(r'run(...) returns ShellResult without throwing when throwOnError is false', () async {
      final res = await run('dart --non-existent-flag-xyz', quiet: true, throwOnError: false);
      expect(res.ok, isFalse);
      expect(res.ok, isFalse);
      expect(res.ok, isFalse);
      expect(res.exitCode, isNot(equals(0)));
    });

    test('which() locates system executables', () async {
      final dartPath = await which('dart');
      expect(dartPath, isNotNull);
      expect(await dartPath!.exists(), isTrue);

      final nonExistent = await which('non_existent_binary_xyz_123');
      expect(nonExistent, isNull);
    });

    test('CommandPipeline and pipe operator | pipe stdout between processes', () async {
      if (!Platform.isWindows) {
        final pipeline = 'echo "alpha\nbeta\ngamma"'.pipe('grep beta');
        final res = await pipeline.run(quiet: true);
        expect(res.ok, isTrue);
        expect(res.text, equals('beta'));
      }
    });

    test('Path.run preserves arguments in ShellResult.command', () async {
      final echoPath = (await which('echo')) ?? 'echo'.path;
      final res = await echoPath.run(args: ['arg1', 'arg2'], quiet: true);
      expect(res.command, contains('arg1 arg2'));
      expect(res.command.startsWith(echoPath.path), isTrue);
    });

    test('Subprocesses receive environment variables set via Env.set', () async {
      if (!Platform.isWindows) {
        Env.set('DART_TOOLKIT_TEST_VAR', 'propagated_value');
        try {
          final res = await run('printenv DART_TOOLKIT_TEST_VAR', quiet: true);
          expect(res.text, equals('propagated_value'));
        } finally {
          Env.remove('DART_TOOLKIT_TEST_VAR');
        }
      }
    });
  });
}
