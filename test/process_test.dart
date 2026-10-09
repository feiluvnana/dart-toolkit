// Command, Shell and the Run task: readings, pipelines, scopes, stopping, input and output, the
// splitters of both platforms, and Runner.fake.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/process.dart';
import 'package:dart_toolkit/src/os.dart';
import 'package:dart_toolkit/src/process/process.dart' show ShellInternals;
import 'package:test/test.dart' hide Retry;

import 'support.dart';

Future<String> _survivors(String marker) async => '${(await Process.run('pgrep', ['-f', marker])).stdout}'.trim();

String _marker(String what) => 'tk_${what}_${pid}_${DateTime.now().microsecondsSinceEpoch}';

void main() {
  group('readings', () {
    test('await is strict: a non-zero exit is a ShellException naming the command and its stderr', () async {
      final result = await Shell.run('echo hello world');
      expect((result.text, result.exitCode, result.isOk), ('hello world', 0, true));
      await expectLater(
        Shell.sh('echo one >&2; echo two >&2; echo three >&2; echo four >&2; exit 3'),
        throwsA(
          isA<ShellException>()
              .having((e) => e.result.exitCode, 'exitCode', 3)
              .having(
                (e) => '$e',
                'message',
                "/bin/sh -c 'echo one >&2; echo two >&2; echo three >&2; echo four >&2; exit 3' sh exited 3: two\n  three\n  four",
              ),
        ),
      );
    }, testOn: '!windows');

    test('text, lines and bytes are stdout; they throw as awaiting does', () async {
      expect(await Shell.run('printf "a\\n\\n  b  \\n"').lines, ['a', '  b']);
      expect(await Shell.run('printf é').bytes, utf8.encode('é'));
      await expectLater(Shell.run('false').text, throwsA(isA<ShellException>()));
    }, testOn: '!windows');

    test('isOk and exitCode answer for an exit code; a program that cannot run still throws (PRC-13)', () async {
      expect(await Shell.run('false').isOk, isFalse);
      expect(await Shell.sh('exit 4').exitCode, 4);
      await expectLater(
        Shell.run('gti status').isOk,
        throwsA(isA<ShellException>().having((e) => e.result.exitCode, 'code', 127)),
      );
      final dir = tempDir();
      final plain = File('$dir/plain.sh')..writeAsStringSync('echo hi\n');
      await expectLater(
        Command.file(plain.path, []).run().exitCode,
        throwsA(isA<ShellException>().having((e) => e.result.exitCode, 'code', 126)),
      );
    }, testOn: '!windows');

    test('a retry never repeats a command that cannot run', () async {
      var tries = 0;
      await expectLater(
        const Retry(3, backoff: Duration.zero).run(() {
          tries++;
          return Shell.run('no_such_program_tk');
        }),
        throwsA(isA<ShellException>()),
      );
      expect(tries, 1);
    });

    test('a missing working directory is a PathNotFoundException (PRC-12)', () async {
      await expectLater(
        Command('ls', [], workdir: '${tempDir()}/missing').run(),
        throwsA(isA<PathNotFoundException>().having((e) => e.path, 'path', endsWith('missing'))),
      );
    });

    test('output that is not UTF-8 does not fail the command', () async {
      expect(await Shell.run(r"printf '\377ok'").text, '\uFFFDok');
    }, testOn: '!windows');

    test('the step is the last line printed, so a spinner can show it', () async {
      final run = Shell.sh('echo first; sleep 0.3; echo second; sleep 0.3');
      final steps = <String>[];
      run.statuses.listen((s) {
        if (s case Running(:final step?)) steps.add(step);
      });
      await run;
      expect(steps, containsAllInOrder(['first', 'second']));
    }, testOn: '!windows');
  });

  group('the command line', () {
    test('Shell.run splits as a POSIX shell does, and appends args unread', () async {
      expect(await Shell.run(r'echo C:\Users\x').text, 'C:Usersx');
      expect(await Shell.run(r"echo 'a\b'").text, r'a\b');
      expect(await Shell.run(r'echo "\d \$ \" \\"').text, r'\d $ " \');
      expect(await Shell.run(r'echo "two words" one').lines, ['two words one']);
      expect(await Shell.run('echo', args: ['a  b', r'$HOME', '|']).text, r'a  b $HOME |');
    }, testOn: '!windows');

    test('shell syntax is refused, not run wrongly; an unclosed quote is a FormatException', () {
      expect(() => Shell.run("echo 'abc"), throwsFormatException);
      for (final line in [
        'echo a | wc -l',
        'true && echo hi',
        'echo a > f',
        r'echo $(id)',
        'a; b',
        'echo *',
        'ls ~',
        r'echo $HOME',
        'echo a # comment',
        r'echo $1 $@',
        r'echo $$',
        'echo {a,b}',
        'echo x{1..3}',
        'FOO=1 env',
      ]) {
        expect(() => Shell.run(line), throwsArgumentError, reason: line);
      }
      expect(ShellInternals.split('find . -exec rm {} + a=b c#d', windows: false), [
        'find', '.', '-exec', 'rm', '{}', '+', 'a=b', 'c#d', //
      ], reason: 'a lone {}, a later a=b and a # inside a word are words');
    }, testOn: '!windows');

    test('the Windows splitter keeps backslashes, so a program path stays whole (X-15)', () {
      List<String> split(String line) => ShellInternals.split(line, windows: true);
      expect(split(r'C:\tools\ffmpeg.exe -i "a b.mp4"'), [r'C:\tools\ffmpeg.exe', '-i', 'a b.mp4']);
      expect(split(r'x "a\"b" c\\\"d "e""f"'), ['x', 'a"b', r'c\"d', 'e"f']);
      expect(split(r'x "C:\dir\\" y'), ['x', r'C:\dir\', 'y']);
      expect(split('x ""'), ['x', '']);
      expect(() => split('a | b'), throwsArgumentError);
      expect(() => split('echo %PATH%'), throwsArgumentError);
      expect(split('echo "%PATH%" 100%'), ['echo', '%PATH%', '100%']);
      expect(() => split('x "open'), throwsFormatException);
    });

    test('a line that is a file with a space in its path is that one program (PRC-1)', () async {
      final dir = Directory('${tempDir()}/with space')..createSync();
      final tool = File('${dir.path}/tool.sh')..writeAsStringSync('#!/bin/sh\necho ran "\$@"\n');
      Process.runSync('chmod', ['+x', tool.path]);
      expect(await Shell.run(tool.path, args: ['x']).text, 'ran x');
    }, testOn: '!windows');

    test('Command.file is that file whatever the workdir, never one on the PATH (PRC-18)', () async {
      final dir = tempDir();
      final tool = File('$dir/tool.sh')..writeAsStringSync('#!/bin/sh\npwd\n');
      Process.runSync('chmod', ['+x', tool.path]);
      Directory('$dir/sub').createSync();
      final command = Command.file('$dir/tool.sh', [], workdir: '$dir/sub');
      expect(await command.run().text, endsWith('sub'));
      expect(command, Command.file('$dir/tool.sh', [], workdir: '$dir/sub'), reason: 'a value');
    }, testOn: '!windows');

    test('Shell.sh is a shell, its args \$1…', () async {
      expect(await Shell.sh(r'printf "%s," "$1" "$2" | tr a-z A-Z', args: ['x y', r'$z']).text, r'X Y,$Z,');
      expect(await Shell.sh('true && echo both').text, 'both');
    }, testOn: '!windows');

    test('a pipeline feeds each stage the one before; the rightmost failure is its exit (pipefail)', () async {
      final pipeline = Command('printf', ['a\\nb\\nc\\n']) | Command('wc', ['-l']);
      expect(await pipeline.run().text, '3');
      expect(pipeline.stages.map((c) => c.program), ['printf', 'wc']);
      expect('$pipeline', r"printf 'a\nb\nc\n' | wc -l");
      final yes = await (Command('yes', []) | Command('head', ['-1'])).run();
      expect((yes.exitCode, yes.text), (0, 'y'), reason: 'a stage stopped by a broken pipe is no failure');
      expect(await (Command('sh', ['-c', 'sleep 0.2; exit 3']) | Command('true', [])).run().exitCode, 3);
    }, testOn: '!windows');
  });

  group('Shell.scope and the environment', () {
    test('the scope gives workdir, env, timeout and quiet; a relative workdir resolves against it', () async {
      final dir = tempDir();
      Directory('$dir/sub').createSync();
      await Shell.scope(
        () async {
          expect(await Shell.run('pwd').text, endsWith(dir.split('/').last));
          expect(await Command('pwd', [], workdir: 'sub').run().text, endsWith('/sub'));
          expect(await Shell.sh(r'echo "$TK_A"').text, 'scoped');
          await Shell.scope(() async {
            expect(await Shell.sh(r'echo "$TK_A $TK_B"').text, 'scoped inner');
          }, env: {'TK_B': 'inner'});
          await expectLater(Shell.run('sleep 5'), throwsA(isA<ShellTimeoutException>()));
        },
        workdir: dir,
        env: {'TK_A': 'scoped'},
        timeout: 200.ms,
      );
    }, testOn: '!windows');

    test('Env.set reaches children; a null env value unsets one', () async {
      await Env.scope(() async {
        Env.set('TK_SET', 'yes');
        expect(await Shell.sh(r'echo "$TK_SET"').text, 'yes');
        expect(await Shell.sh(r'echo "${TK_SET:-unset}"', env: {'TK_SET': null}).text, 'unset');
      });
    }, testOn: '!windows');

    test('which finds a runnable file on the PATH the scope and the call give (PRC-17)', () async {
      final dir = tempDir();
      File('$dir/tk_tool').writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', '$dir/tk_tool']);
      File('$dir/tk_plain').writeAsStringSync('');
      expect(await Shell.which('tk_tool', env: {'PATH': dir}), '$dir/tk_tool');
      await Shell.scope(() async => expect(await Shell.which('tk_tool'), '$dir/tk_tool'), env: {'PATH': dir});
      await expectLater(
        Shell.which('tk_plain', env: {'PATH': dir}),
        throwsA(isA<MissingException>().having((e) => '$e', 'message', 'Missing tk_plain in PATH')),
      );
      expect(await Shell.which('sh'), isNotEmpty);
    }, testOn: '!windows');

    test('bad settings are ArgumentErrors at the call', () {
      expect(() => Shell.run(''), throwsArgumentError);
      expect(() => Shell.run('cat', text: 'a', bytes: [1]), throwsArgumentError);
      expect(() => Shell.run('true', timeout: Duration.zero), throwsArgumentError);
      expect(() => Command('', []), throwsArgumentError);
      expect(() => (Command('a', []) | Command('b', [])).interact(), throwsArgumentError);
    });
  });

  group('stopping a command', () {
    test('a timeout stops it and its children: exit 124, what it printed kept, its stderr said (PRC-14)', () async {
      final marker = _marker('timeout');
      final error = await Shell.sh(
        'echo partial; echo why >&2; sleep 31 & sleep 32; # $marker',
        timeout: 400.ms,
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<ShellTimeoutException>());
      final timedOut = error! as ShellTimeoutException;
      expect((timedOut.result.exitCode, timedOut.result.text), (124, 'partial'));
      expect('$timedOut', contains('timed out after 400ms: why'));
      expect(await _survivors(marker), isEmpty);
    }, testOn: '!windows');

    test('a cancel ends it Stopped, takes its children with it, and holds while one keeps stdout open', () async {
      final marker = _marker('cancel');
      final run = Shell.sh('sleep 31 & echo hi; sleep 32; # $marker');
      await 300.ms.delay();
      final at = DateTime.now();
      run.cancel('enough');
      expect(await run.settled, isA<Stopped<Object?, ShellResult>>());
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(DateTime.now().difference(at), lessThan(2.s));
      expect(await _survivors(marker), isEmpty);
    }, testOn: '!windows');

    test('a cancelled scope stops the command', () async {
      final token = CancelToken();
      Timer(200.ms, token.cancel);
      await expectLater(Cancel.scope(() => Shell.run('sleep 5'), token: token), throwsA(isA<CancelledException>()));
    }, testOn: '!windows');

    test('a timeout stops a grandchild whose parent dies first', () async {
      final marker = _marker('orphan');
      await Shell.sh('sh -c "sleep 34; true # $marker"; true', timeout: 400.ms).settled;
      await 600.ms.delay();
      expect(await _survivors(marker), isEmpty, reason: 'the inner shell is in the tree though the outer one is gone');
    }, testOn: '!windows');

    test('a child that ignores SIGTERM is killed', () async {
      final run = Shell.sh(r'trap "" TERM; sleep 5');
      await 200.ms.delay();
      final at = DateTime.now();
      run.cancel();
      await run.settled;
      expect(DateTime.now().difference(at), lessThan(2.s));
    }, testOn: '!windows');

    test('timeout() stops the command it gives up on', () async {
      final marker = _marker('to');
      await expectLater(Shell.sh('sleep 33; # $marker').timeout(300.ms), throwsA(isA<TimeoutException>()));
      await 600.ms.delay();
      expect(await _survivors(marker), isEmpty);
    }, testOn: '!windows');
  });

  group('output, errors and save', () {
    test('output gives stdout lines live; a cancel stops the command; a failure is its error', () async {
      final lines = <String>[];
      await for (final line in Shell.sh(r'i=0; while :; do echo l$i; i=$((i+1)); sleep 0.02; done').output) {
        lines.add(line);
        if (lines.length == 3) break;
      }
      expect(lines, ['l0', 'l1', 'l2']);
      await expectLater(Shell.sh('echo x; exit 3').output.toList(), throwsA(isA<ShellException>()));
    }, testOn: '!windows');

    test('a reading attached late still gets everything: when it is chained changes nothing (PRC-8)', () async {
      final run = Shell.run('printf "a\\nb\\n"');
      await 300.ms.delay();
      expect(await run.output.toList(), ['a', 'b']);
      final late = Shell.run('echo kept');
      await late;
      expect(await late.text, 'kept');
    }, testOn: '!windows');

    test('output takes stdout: text after it is a StateError, not an empty string (PRC-9)', () async {
      final run = Shell.run('echo a');
      final lines = run.output.toList();
      expect(() => run.text, throwsStateError);
      expect(() => run.save('${tempDir()}/x'), throwsStateError);
      expect(await lines, ['a']);
      await expectLater(run.then((r) => r.stdout), throwsStateError);
    }, testOn: '!windows');

    test('a paused output holds the command, so its lines never pile up', () async {
      final marker = '${tempDir()}/finished';
      final run = Shell.sh(r'yes 0123456789 | head -n 1000000; touch "$1"', args: [marker]);
      var lines = 0;
      final done = Completer<void>();
      late final StreamSubscription<String> listening;
      listening = run.output.listen((_) {
        if (++lines == 1000) listening.pause();
      }, onDone: done.complete);
      await 600.ms.delay();
      // 11 MB is far more than a pipe and a read hold: a child not held would be done by now.
      expect(File(marker).existsSync(), isFalse, reason: 'the paused reader holds the command');
      listening.resume();
      await done.future;
      await run;
      expect(lines, 1000000);
      expect(File(marker).existsSync(), isTrue);
    }, testOn: '!windows');

    test('errors gives stderr lines live, the kept ones first; stdout stays with the result', () async {
      final run = Shell.sh('echo warn >&2; echo out; sleep 0.2; echo late >&2');
      await 100.ms.delay();
      expect(await run.errors.toList(), ['warn', 'late']);
      expect((await run).text, 'out');
    }, testOn: '!windows');

    test('errors listened to before the command says anything gets every line', () async {
      expect(await Shell.sh('sleep 0.1; echo hi >&2').errors.toList(), ['hi']);
      expect(await Shell.run('true').errors.toList(), isEmpty);
    }, testOn: '!windows');

    test('a character split across reads decodes whole in output, text and the echo', () async {
      final euros = File('${tempDir()}/e.txt')..writeAsStringSync('€' * 300000);
      expect(await Shell.run('cat', args: [euros.path]).text, '€' * 300000);
      expect(await Shell.run('cat', args: [euros.path]).output.toList(), ['€' * 300000]);
      final out = StringBuffer();
      await Io.scope(() => Shell.run('cat', args: [euros.path], quiet: false), stdout: out);
      expect('$out', '€' * 300000);
    }, testOn: '!windows');

    test('quiet by default; quiet: false echoes stdout and stderr', () async {
      final out = StringBuffer(), err = StringBuffer();
      await Io.scope(
        () async {
          await Shell.sh('echo hidden; echo hidden >&2');
          await Shell.sh('echo shown; echo said >&2', quiet: false);
        },
        stdout: out,
        stderr: err,
      );
      expect(('$out', '$err'), ('shown\n', 'said\n'));
    }, testOn: '!windows');

    test('save writes stdout atomically: the old file stays when the command fails', () async {
      final dir = tempDir();
      final to = '$dir/out.txt';
      expect(await Shell.run('echo first').save(to), to);
      expect(File(to).readAsStringSync(), 'first\n');
      await expectLater(Shell.sh('echo second; exit 2').save(to), throwsA(isA<ShellException>()));
      expect(File(to).readAsStringSync(), 'first\n');
      expect(Directory(dir).listSync(), hasLength(1), reason: 'no temporary file is left');
    }, testOn: '!windows');

    test('a save that cannot write stops its command, which nothing reads now', () async {
      final locked = tempDir();
      Process.runSync('chmod', ['500', locked]);
      addTearDown(() => Process.runSync('chmod', ['700', locked]));
      final run = Shell.run('sleep 30');
      await expectLater(run.save('$locked/out.txt'), throwsA(isA<FileSystemException>()));
      expect(await run.settled.timeout(10.s), isA<Stopped<Object?, ShellResult>>());
    }, testOn: '!windows');
  });

  group('input', () {
    test('stdin is text, bytes or a stream fed as it arrives', () async {
      expect(await Shell.run('cat', text: 'typed').text, 'typed');
      expect(await Shell.run('cat', bytes: utf8.encode('raw')).text, 'raw');
      expect(await Shell.run('cat', stream: Stream.fromIterable([utf8.encode('a'), utf8.encode('b')])).text, 'ab');
      final big = 'x' * 2000000;
      expect((await Shell.run('cat', text: big).timeout(10.s)).stdout.length, big.length, reason: 'no deadlock');
    }, testOn: '!windows');

    test('an error in the input stream stops the command and is what it throws', () async {
      Stream<List<int>> failing() async* {
        yield utf8.encode('a');
        throw const FormatException('bad input');
      }

      await expectLater(Shell.run('cat', stream: failing()), throwsFormatException);
    }, testOn: '!windows');

    test('a stream input is let go when the command ends, though it has not', () async {
      final released = Completer<void>();
      final input = StreamController<List<int>>(onCancel: released.complete);
      await Shell.run('true', stream: input.stream);
      await released.future.timeout(5.s);
      await input.close();
    }, testOn: '!windows');
  });

  group('Runner.fake', () {
    test('answers each stage instead of running it; readings and the exit-code policy hold', () async {
      final heard = <String>[];
      await Shell.scope(
        () async {
          expect(await Shell.run('git branch --show-current').text, 'main');
          expect(await Shell.run('git diff --quiet').isOk, isFalse);
          await expectLater(Shell.run('git push'), throwsA(isA<ShellException>()));
          expect(await (Command('ls', []) | Command('wc', ['-l'])).run().text, 'main');
          expect(await Shell.run('git log').output.toList(), ['main']);
        },
        runner: Runner.fake((command) {
          heard.add('$command');
          return switch (command.args) {
            ['diff', ...] => ShellResult(command, exitCode: 1),
            ['push'] => ShellResult(command, exitCode: 128, stderr: 'rejected\n'),
            _ => ShellResult(command, stdout: 'main\n'),
          };
        }),
      );
      expect(heard, ['git branch --show-current', 'git diff --quiet', 'git push', 'ls', 'wc -l', 'git log']);
    });

    test('text trims bytes and Unicode spaces alike; lines split as output does', () async {
      await Shell.scope(() async {
        expect(await Shell.run('a').text, 'é b\r\ntwo\rthree');
        expect(await Shell.run('a').lines, ['\u00a0 é b', 'two', 'three']);
      }, runner: Runner.fake((c) => ShellResult(c, stdout: '\u00a0 é b\r\ntwo\rthree\n \n')));
    });

    test('Shell.open hands a URL or a path, made absolute, to the platform\'s opener; a failure throws', () async {
      final heard = <String>[];
      await Shell.scope(
        () async {
          await Shell.open('https://example.com/?a=1&b=2');
          await Shell.open('-a notes.txt');
          await expectLater(Shell.open('missing.txt'), throwsA(isA<ShellException>()));
        },
        workdir: '/work',
        runner: Runner.fake((c) {
          heard.add('$c');
          return ShellResult(c, exitCode: c.args.last.endsWith('missing.txt') ? 1 : 0);
        }),
      );
      final opener = Platform.isMacOS ? 'open' : 'xdg-open';
      expect(heard, [
        "$opener 'https://example.com/?a=1&b=2'",
        "$opener '/work/-a notes.txt'",
        '$opener /work/missing.txt',
      ]);
      expect(() => Shell.open(' '), throwsArgumentError);
    }, testOn: '!windows');

    test('interact runs on the fake too, and is strict', () async {
      await Shell.scope(() async {
        await Shell.interact('vim notes.txt');
        await expectLater(Shell.interact('false'), throwsA(isA<ShellException>()));
      }, runner: Runner.fake((c) => ShellResult(c, exitCode: c.program == 'false' ? 1 : 0)));
    });
  });

  group('process liveness', () {
    test('a live process is alive, another user\'s too; a reaped one is not', () async {
      expect(OsBridge.isPidAlive(pid), isTrue);
      expect(OsBridge.isPidAlive(1), isTrue, reason: 'init is root\'s: EPERM is still alive');
      final child = await Process.start('true', []);
      await child.exitCode;
      expect(OsBridge.isPidAlive(child.pid), isFalse);
    }, testOn: '!windows');
  });

  group('interact', () {
    test('^C is the child\'s: it does not end this program (X-14)', () async {
      final dir = Directory('.dart_tool/tk_interact')..createSync(recursive: true);
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/main.dart').writeAsStringSync('''
import 'package:dart_toolkit/process.dart';

Future<void> main() async {
  await Shell.interact('sh -c "echo up; sleep 1"');
  print('after');
}
''');
      final child = await Process.start(Platform.resolvedExecutable, ['${dir.path}/main.dart']);
      final out = StringBuffer();
      final up = Completer<void>();
      child.stdout.transform(utf8.decoder).listen((text) {
        out.write(text);
        if ('$out'.contains('up') && !up.isCompleted) up.complete();
      });
      final err = child.stderr.transform(utf8.decoder).join();
      await up.future.timeout(20.s); // the child holds the terminal now
      child.kill(ProcessSignal.sigint);
      expect(await child.exitCode.timeout(20.s), 0, reason: await err);
      expect('$out', 'up\nafter\n');
    }, testOn: 'mac-os || linux');

    test('the child gets this process\'s stdio; a non-zero exit throws', () async {
      await Shell.interact('true');
      await expectLater(
        Shell.interact('sh -c "exit 5"'),
        throwsA(isA<ShellException>().having((e) => e.result.exitCode, 'code', 5)),
      );
    }, testOn: '!windows');
  });

  test('ShellException says the command, the code and three lines of stderr', () {
    final result = ShellResult(Command('make', ['all']), exitCode: 2, stderr: 'a\nb\nc\nd\n');
    expect('${ShellException(result)}', 'make all exited 2: b\n  c\n  d');
    expect('$result', 'make all exited 2');
    expect(() => ShellResult(Command('x', []), stdout: 'out').stdout, returnsNormally);
  });
}
