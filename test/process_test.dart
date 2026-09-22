import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Process & Shell Execution', () {
    test(r'run() and run(...) execute system commands and capture stdout', () async {
      final resRun = await run('echo hello_world', quiet: true);
      expect(resRun.isOk, isTrue);
      expect(resRun.isOk, isTrue);
      expect(resRun.exitCode, equals(0));
      expect(resRun.text, equals('hello_world'));
      expect(resRun.lines, equals(['hello_world']));

      // Top-level $ shorthand
      final resDollar = await run('echo from_dollar', quiet: true);
      expect(resDollar.text, equals('from_dollar'));

      // Future<ShellResult> extension getters
      expect(await run('echo direct_text', quiet: true).text, equals('direct_text'));
      expect(await run('echo "line1\nline2"', quiet: true).lines, equals(['line1', 'line2']));
      expect(await run('echo true', quiet: true).isOk, isTrue);
    });

    test('run() and Path.run() execute commands with workdir', () async {
      final res = await run('echo "hello from extension"', quiet: true);
      expect(res.isOk, isTrue);
      expect(res.text, equals('hello from extension'));

      final temp = Path.temp / 'test_proc_run';
      await temp.mkdir();
      try {
        final resDir = await run('pwd', workdir: temp, quiet: true);
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

    test('command output parses as JSON through text.json', () async {
      final res = await run('echo \'{"name":"toolkit","version":9}\'', quiet: true);
      expect(res.text.json['name'].to<String>(), equals('toolkit'));
      expect(res.text.json['version'].to<int>(), equals(9));
      expect((await run('echo \'[1,2]\'', quiet: true).text).json.list.length, equals(2));
    });

    test('run feeds input to stdin and splits on any whitespace', () async {
      if (!Platform.isWindows) {
        expect(await run('cat', input: 'fed', quiet: true).text, equals('fed'));
        expect(await run('echo\ta\tb', quiet: true).text, equals('a b'));
      }
    });

    test(r'run(...) throws ShellException when throwOnError is true (default)', () async {
      expect(() => run('dart --non-existent-flag-xyz', quiet: true), throwsA(isA<ShellException>()));
    });

    test(r'run(...) returns ShellResult without throwing when throwOnError is false', () async {
      final res = await run('dart --non-existent-flag-xyz', quiet: true, strict: false);
      expect(res.isOk, isFalse);
      expect(res.isOk, isFalse);
      expect(res.isOk, isFalse);
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
        final res = await ('echo "alpha\nbeta\ngamma"' | 'grep beta').run(quiet: true);
        expect(res.isOk, isTrue);
        expect(res.text, equals('beta'));

        // pipefail: an upstream failure is the pipeline's failure.
        final failed = await ('false' | 'cat').run(quiet: true, strict: false);
        expect(failed.isOk, isFalse);
        expect(() => ('false' | 'cat').run(quiet: true), throwsA(isA<ShellException>()));
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

  group('Shell.session', () {
    test('the scope supplies workdir, env, quiet and strict, so a command repeats none of them', () async {
      final dir = Path(Directory.systemTemp.createTempSync('shell_').path);
      addTearDown(() => dir.deleteSync(recursive: true));

      await Shell.session(
        () async {
          expect(await run('pwd').text, endsWith(dir.name));
          expect(await run('printenv TK_MARKER').text, 'set-once');
          // `strict: false` at the session level, so a failing command comes back instead.
          final bad = await run('false');
          expect(bad.isOk, isFalse);
        },
        workdir: dir,
        env: {'TK_MARKER': 'set-once'},
        quiet: true,
        strict: false,
      );
    });

    test('a per-call argument still wins over the session', () async {
      await Shell.session(
        () async {
          expect(() => run('false', strict: true), throwsA(isA<ShellException>()));
          expect(await run('true', strict: true).isOk, isTrue);
        },
        quiet: true,
        strict: false,
      );
    });

    test('env is added to the enclosing session, not swapped for it', () async {
      await Shell.session(
        () async {
          await Shell.session(() async {
            expect(await run('printenv OUTER').text, 'o');
            expect(await run('printenv INNER').text, 'i');
          }, env: {'INNER': 'i'});
        },
        env: {'OUTER': 'o'},
        quiet: true,
      );
    });

    test('a pipeline and Path.run read the same scope', () async {
      final dir = Path(Directory.systemTemp.createTempSync('shell_').path);
      addTearDown(() => dir.deleteSync(recursive: true));
      (dir / 'hello.sh').writeTextSync('#!/bin/sh\necho from-script\n');
      await run('chmod +x ${dir / 'hello.sh'}', quiet: true);

      await Shell.session(
        () async {
          expect(await ('echo a b c' | 'tr " " "\n"').run().lines, ['a', 'b', 'c']);
          expect(await (dir / 'hello.sh').run().text, 'from-script');
        },
        workdir: dir,
        quiet: true,
      );
    });

    test('outside a session the documented defaults hold', () async {
      expect(() => run('false', quiet: true), throwsA(isA<ShellException>()));
      expect(await run('true', quiet: true).isOk, isTrue);
    });
  });

  group('process', () {
    test('a child that echoes a large stdin does not deadlock', () async {
      final big = 'x' * 2000000;
      final r = await run('cat', input: big, quiet: true).timeout(const Duration(seconds: 10));
      expect(r.stdout.length, big.length);
    });

    test('the splitter reads quotes and backslashes as a POSIX shell does', () async {
      expect(await run(r'echo C:\Users\x', quiet: true).text, 'C:Usersx');
      expect(await run(r"echo 'a\b'", quiet: true).text, r'a\b');
      expect(await run(r'echo "\d \$ \" \\"', quiet: true).text, r'\d $ " \');
      expect((await run(r'printf %s ""', quiet: true)).stdout, '');
      expect(await run(r'echo "two words" one', quiet: true).lines, ['two words one']);
    });
  });
}
