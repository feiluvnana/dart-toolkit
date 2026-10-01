import 'dart:async';
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
          Env.set('DART_TOOLKIT_TEST_VAR', '');
        }
      }
    });
  });

  group('Shell.scope', () {
    test('the scope supplies workdir, env, quiet and strict, so a command repeats none of them', () async {
      final dir = Path(Directory.systemTemp.createTempSync('shell_').path);
      addTearDown(() => dir.deleteSync(recursive: true));

      await Shell.scope(
        () async {
          expect(await run('pwd').text, endsWith(dir.name));
          expect(await run('printenv TK_MARKER').text, 'set-once');
          // `strict: false` at the scope level, so a failing command comes back instead.
          final bad = await run('false');
          expect(bad.isOk, isFalse);
        },
        workdir: dir,
        env: {'TK_MARKER': 'set-once'},
        quiet: true,
        strict: false,
      );
    });

    test('a per-call argument still wins over the scope', () async {
      await Shell.scope(
        () async {
          expect(() => run('false', strict: true), throwsA(isA<ShellException>()));
          expect(await run('true', strict: true).isOk, isTrue);
        },
        quiet: true,
        strict: false,
      );
    });

    test('env is added to the enclosing scope, not swapped for it', () async {
      await Shell.scope(
        () async {
          await Shell.scope(() async {
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

      await Shell.scope(
        () async {
          expect(await ('echo a b c' | 'tr " " "\n"').run().lines, ['a', 'b', 'c']);
          expect(await (dir / 'hello.sh').run().text, 'from-script');
        },
        workdir: dir,
        quiet: true,
      );
    });

    test('outside a scope the documented defaults hold', () async {
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

  group('what a command owes its caller', () {
    test(r'shell: true is a shell: $VAR, pipes and && work', () async {
      expect(await run(r'echo $HOME | tr a-z A-Z', shell: true).text, Platform.environment['HOME']!.toUpperCase());
      expect(await run('true && echo both', shell: true).text, 'both');
    }, testOn: '!windows');

    test('a cancelled scope stops the command and says so', () async {
      final token = CancelToken();
      Timer(200.ms, token.cancel);
      final watch = Stopwatch()..start();
      await expectLater(
        Cancel.scope(() => run('sleep 30', quiet: true), token: token),
        throwsA(isA<CancelledException>()),
      );
      expect(watch.elapsed, lessThan(10.s));
      await expectLater(Cancel.scope(() => run('true'), token: token), throwsA(isA<CancelledException>()));
    }, testOn: '!windows');

    test("a timeout stops the child's children too, and keeps what they printed", () async {
      final marker = 'tk_timeout_${pid}_${DateTime.now().microsecondsSinceEpoch}';
      final error = await run(
        "sh -c 'echo partial; sleep 31 # $marker'",
        timeout: 1.s,
        quiet: true,
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<ShellTimeoutException>().having((e) => e.result.stdout.trim(), 'stdout', 'partial'));
      final left = await Process.run('pgrep', ['-f', marker]);
      expect((left.stdout as String).trim(), isEmpty, reason: 'no orphan outlives the timeout');
    }, testOn: '!windows');

    test('output that is not UTF-8 does not fail the command', () async {
      final r = await run(r"printf '\377ok'", quiet: true);
      expect(r.stdout, endsWith('ok'));
    }, testOn: '!windows');

    test('a missing executable is exit 127, and throws only when strict', () async {
      final r = await run('no-such-tool-tk-xyz', strict: false, quiet: true);
      expect(r.exitCode, 127);
      expect(r.stderr, isNotEmpty);
      await expectLater(run('no-such-tool-tk-xyz', quiet: true), throwsA(isA<ShellException>()));
    });

    test('isOk answers instead of throwing, and text and lines do not echo', () async {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);
      expect(await run('false').isOk, isFalse);
      expect(await run('echo hidden').text, 'hidden');
      expect(await run('echo a; echo b', shell: true).lines, ['a', 'b']);
      expect(out.toString(), isEmpty);
      await run('echo shown');
      expect(out.toString(), contains('shown'));
      await expectLater(run('false', strict: true).isOk, throwsA(isA<ShellException>()), reason: 'an argument wins');
    }, testOn: '!windows');

    test('inherit: true hands the child this process\'s stdio', () async {
      expect((await run('true', inherit: true)).exitCode, 0);
      expect(() => run('cat', inherit: true, input: 'x'), throwsArgumentError);
    }, testOn: '!windows');
  });

  group('second audit', () {
    test('a timeout holds while a background child keeps stdout open', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        run('sh -c "sleep 5 & echo hi"', timeout: 300.ms, quiet: true),
        throwsA(isA<ShellTimeoutException>()),
      );
      expect(watch.elapsed, lessThan(4.s));
    }, testOn: '!windows');

    test('cancel holds while a background child keeps stdout open', () async {
      final stop = CancelToken();
      final watch = Stopwatch()..start();
      final done = Cancel.scope(() => run('sh -c "sleep 5 & echo hi"', quiet: true), token: stop);
      Timer(200.ms, stop.cancel);
      await expectLater(done, throwsA(isA<CancelledException>()));
      expect(watch.elapsed, lessThan(4.s));
    }, testOn: '!windows');

    test('a stage stopped by the broken pipe of the one it feeds is not a failure', () async {
      final result = await ('yes' | 'head -1').run(quiet: true);
      expect((result.exitCode, result.text), (0, 'y'));
      expect((await ('false' | 'cat').run(strict: false, quiet: true)).exitCode, 1); // a real failure stays one
    }, testOn: '!windows');

    test('an unterminated quote and shell syntax are refused, not run wrongly', () async {
      await expectLater(run("echo 'abc"), throwsFormatException);
      for (final command in [
        'echo a | wc -l',
        'true && echo hi',
        'echo a > f',
        r'echo $(id)',
        'a; b',
        'echo *',
        'echo ?',
        'echo [ab]',
        'ls ~',
        r'echo $HOME',
        r'echo ${PATH}',
      ]) {
        await expectLater(run(command), throwsArgumentError, reason: command);
      }
      expect(await run("echo 'a | b' \"c && d\"").text, 'a | b c && d'); // quoted, they are text
      expect(await run("echo '*' '?' '[a]' '~' '\$HOME'").text, '* ? [a] ~ \$HOME');
    }, testOn: '!windows');

    test('args are appended as they are, and are \$1… under shell: true', () async {
      expect(await run('echo', args: ['a  b', r'$HOME', '|']).text, r'a  b $HOME |');
      expect(await run(r'printf "%s," "$1" "$2"', shell: true, args: ['x y', r'$z']).text, r'x y,$z,');
    }, testOn: '!windows');

    test('which finds only files it could run', () async {
      expect(await which('lib'), isNull); // a directory on no PATH entry, and ./lib is not a program
      expect(await which('sh'), isNotNull);
      final dir = await Directory.systemTemp.createTemp('which');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/tool').writeAsStringSync('#!/bin/sh\necho hi');
      final path = Env.get('PATH');
      Env.set('PATH', dir.path);
      addTearDown(() => Env.set('PATH', path));
      expect(await which('tool'), isNull);
    }, testOn: '!windows');

    test('a file that is there but cannot be run is 126', () async {
      final dir = await Directory.systemTemp.createTemp('noexec');
      addTearDown(() => dir.delete(recursive: true));
      final script = File('${dir.path}/s.sh')..writeAsStringSync('echo hi');
      expect((await Path(script.path).run(strict: false, quiet: true)).exitCode, 126);
      expect((await run('surely-not-a-command-x', strict: false, quiet: true)).exitCode, 127);
    }, testOn: '!windows');

    test('stream gives the lines as they are printed, and cancelling stops the command', () async {
      final lines = <String>[];
      await for (final line in run(r'sh -c "i=0; while :; do echo l$i; i=$((i+1)); sleep 0.02; done"').stream) {
        lines.add(line);
        if (lines.length == 3) break;
      }
      expect(lines, ['l0', 'l1', 'l2']);
      expect(await run('printf "a\\nb\\nc"').stream.toList(), ['a', 'b', 'c']);
      await expectLater(run('sh -c "echo x; exit 3"').stream.toList(), throwsA(isA<ShellException>()));
    }, testOn: '!windows');

    test('a child that traps SIGTERM is reaped with SIGKILL on stop (PROC-1)', () async {
      final token = CancelToken();
      final future = Cancel.scope(() => run(r'sh -c "trap \"\" TERM; sleep 5"'), token: token);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel();
      await expectLater(future, throwsA(isA<CancelledException>()));
      await killHaltedProcesses();
    }, testOn: '!windows');

    test('ShellResult.lines preserves leading whitespace (PROC-4)', () {
      final res = ShellResult(command: 'test', exitCode: 0, stdout: '  col1  col2\n    indent\n', stderr: '');
      expect(res.lines, ['  col1  col2', '    indent']);
    });

    test('ShellException.toString is concise with last stderr line (PROC-6)', () {
      final res = ShellResult(command: 'false', exitCode: 1, stdout: '', stderr: 'first line\nerror: not found');
      expect(ShellException(res).toString(), '"false" exited with code 1: error: not found');
    });

    test('missing workdir reports 127 with clear message (PROC-8)', () async {
      final r = await run('ls', workdir: Path('/nonexistent/path/xyz'), strict: false, quiet: true);
      expect(r.exitCode, 127);
      expect(r.stderr, contains('No such working directory'));
    });

    test('pipefail does not hide real failure of upstream stage (PROC-5)', () async {
      final res = await (r'sh -c "sleep 0.2; exit 3"' | 'true').run(strict: false, quiet: true);
      expect(res.exitCode, 3);
    }, testOn: '!windows');

    test('stream does not silence stderr (PROC-9)', () async {
      final err = StringBuffer();
      Io.err = err;
      try {
        final lines = await run(r'sh -c "echo warn >&2; echo out"').stream.toList();
        expect(lines, ['out']);
        expect(err.toString(), contains('warn'));
      } finally {
        Io.reset();
      }
    }, testOn: '!windows');
  });

  group('fourth audit', () {
    Future<String> survivors(String marker) async =>
        ((await Process.run('pgrep', ['-f', marker])).stdout as String).trim();

    test('kill() stops a command and what it started, and settles the run', () async {
      final marker = 'tk_kill_${pid}_${DateTime.now().microsecondsSinceEpoch}';
      final server = run("sh -c 'sleep 31 & sleep 32; # $marker'", quiet: true);
      await 300.ms.delay();
      expect(await survivors(marker), isNotEmpty, reason: 'it is running before the kill');
      await server.kill();
      expect(await survivors(marker), isEmpty, reason: 'no child outlives kill()');
      await expectLater(server, throwsA(isA<CancelledException>()));
    }, testOn: '!windows');

    test('kill() before the command is up still stops it, and after it ended changes nothing', () async {
      final early = run('sleep 30', quiet: true);
      await early.kill();
      await expectLater(early, throwsA(isA<CancelledException>()));

      final done = run('echo hi', quiet: true);
      expect((await done).text, 'hi');
      await done.kill();
      expect((await done).text, 'hi');
    }, testOn: '!windows');

    test('kill() ends a stream without an error on it', () async {
      final tail = run('sh -c "echo ready; sleep 30"');
      final lines = <String>[];
      final listening = tail.stream.listen(lines.add).asFuture<void>();
      await 300.ms.delay();
      await tail.kill();
      await listening;
      expect(lines, ['ready']);
    }, testOn: '!windows');
  });
}
