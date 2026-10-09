// A pool's folder store: jobs a run left are continued by the next, and detached jobs run in a
// runner process that outlives the program (test/fixtures/pool_runner.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/async.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

final class _Echo extends Worker<String, String> {
  @override
  String run(String item, Work work) => item;
}

void main() {
  group('a folder store', () {
    test('what another version wrote is a FormatException naming the file, on changes', () async {
      final home = tempDir();
      File('$home/jobs.json').writeAsStringSync(jsonEncode({'version': 99, 'jobs': <Object>[]}));
      final pool = Pool(_Echo.new, store: Store(home));
      addTearDown(pool.close);
      final error = await pool.changes.first.then<Object?>((_) => null, onError: (Object e) => e).timeout(5.s);
      expect(error, isA<FormatException>().having((e) => e.message, 'message', allOf(contains(home), contains('99'))));
    });

    test('jobs a closed pool stopped stay in its record; finished ones do not', () async {
      final home = tempDir();
      final pool = Pool(_Echo.new, store: Store(home));
      expect(await pool.add('done'), 'done');
      await pool.close();
      expect(File('$home/local/$pid.json').existsSync(), isFalse, reason: 'nothing left to continue');
    });
  });

  group('detached jobs', () {
    late String home;
    Future<ProcessResult> fixture(List<String> args, {bool cli = false}) async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/fixtures/pool_runner.dart', ...args],
        environment: {'POOL_HOME': home, if (cli) 'VIA_CLI': '1'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return result;
    }

    List<Map<String, Object?>> jobsOf(ProcessResult result) =>
        (jsonDecode('${result.stdout}'.trim()) as List).cast<Map<String, Object?>>();

    Future<void> gone(String path) async {
      for (var i = 0; i < 100 && File(path).existsSync(); i++) {
        await 200.ms.delay();
      }
    }

    setUp(() => home = tempDir());
    // A runner a failed test left behind ends once idle; its folder goes with the test.
    tearDown(() => gone('$home/runner.json'));

    test('a detached job outlives its program; the next run continues the foreground one', () async {
      final added = await fixture(['add', 'book']);
      final app = int.parse('${added.stdout}'.trim());
      expect(File('$home/book-here.stopped').readAsStringSync(), '$app', reason: 'closing stopped it');
      expect(File('$home/runner.json').existsSync(), isTrue, reason: 'a runner is up');

      final waited = await fixture(['wait', 'book', 'book-here']);
      expect(
        jobsOf(waited),
        unorderedEquals([
          {'item': 'book', 'detached': true, 'status': '$home/book.out'},
          {'item': 'book-here', 'detached': false, 'status': '$home/book-here.out'},
        ]),
      );
      final runner = int.parse(File('$home/book.out').readAsStringSync().split(' ').last);
      final continued = int.parse(File('$home/book-here.out').readAsStringSync().split(' ').last);
      expect(runner, isNot(app));
      expect(continued, isNot(runner), reason: 'the foreground job ran in the program that continued it');

      // Idle, the runner ends and takes its port file with it.
      await gone('$home/runner.json');
      expect(File('$home/runner.json').existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('under Cli(pools:), a runner launch serves the pool instead of the handler', () async {
      await fixture(['add', 'cli'], cli: true);
      final jobs = jobsOf(await fixture(['wait', 'cli'], cli: true));
      expect(jobs.firstWhere((j) => j['item'] == 'cli')['status'], '$home/cli.out');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a detached failure comes back as the type it was (ASY-14)', () async {
      await fixture(['add', 'fail-1']);
      final jobs = jobsOf(await fixture(['wait', 'fail-1']));
      expect(jobs.firstWhere((j) => j['item'] == 'fail-1')['status'], startsWith('PathNotFoundException: '));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('another program removes a detached job: the runner stops it and its cleanup runs', () async {
      await fixture(['add', 'long']);
      await fixture(['remove', 'long']);
      await gone('$home/runner.json');
      expect(File('$home/long.stopped').existsSync(), isTrue);
      expect(File('$home/long.out').existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'a runner killed mid-job is started again, and runs the job again',
      () async {
        await fixture(['add', 'long']);
        final runner = (jsonDecode(File('$home/runner.json').readAsStringSync()) as Map)['pid'] as int;
        Process.killPid(runner, ProcessSignal.sigkill);
        await 300.ms.delay();
        final jobs = jobsOf(await fixture(['wait', 'long']));
        expect(jobs.firstWhere((j) => j['item'] == 'long')['status'], '$home/long.out');
        expect(int.parse(File('$home/long.out').readAsStringSync().split(' ').last), isNot(runner));
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: Platform.isWindows ? 'SIGKILL is POSIX' : false,
    );

    test('a program started as the runner of a store none of its pools keeps says so and ends', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/fixtures/pool_runner.dart'],
        environment: {'POOL_HOME': home, 'DART_TOOLKIT_POOL': '$home/elsewhere'},
      );
      expect(result.exitCode, 1);
      expect(File('$home/elsewhere/runner.log').readAsStringSync(), contains('Pool.serve'));
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
