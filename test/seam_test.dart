import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// The injectable IO seam must cover every path that writes to the console,
/// and must also drive the decision about *what* to render.
void main() {
  group('ConsoleIo seam', () {
    late StringBuffer out;

    setUp(() {
      out = StringBuffer();
      ConsoleIo.stdoutOverride = out;
    });

    tearDown(() {
      ConsoleIo.reset();
      Ansi.enabled = null;
      Env.remove('NO_COLOR');
    });

    test('captures subprocess output, not just Logger output', () async {
      Logger.ok('via Logger');
      await run('echo SUBPROCESS_MARKER');

      expect(out.toString(), contains('via Logger'));
      expect(out.toString(), contains('SUBPROCESS_MARKER'));
    });

    test('quiet: true still suppresses subprocess output', () async {
      final result = await run('echo QUIET_MARKER', quiet: true);

      expect(result.stdout, contains('QUIET_MARKER'));
      expect(out.toString(), isNot(contains('QUIET_MARKER')));
    });

    test('a redirected sink is never treated as a terminal', () {
      expect(ConsoleIo.isTerminal, isFalse);
      expect(ConsoleIo.columns, isNull);
    });

    test('a redirected sink disables ANSI unless explicitly overridden', () {
      expect(Ansi.enabled, isFalse);

      Ansi.enabled = true;
      expect(Ansi.enabled, isTrue);
    });

    test('Ansi resolves override, then NO_COLOR, then the sink', () {
      ConsoleIo.reset();

      // 1. An explicit override wins over everything.
      Ansi.enabled = true;
      Env.set('NO_COLOR', '1');
      expect(Ansi.enabled, isTrue, reason: 'explicit override beats NO_COLOR');

      // 2. With no override, NO_COLOR read from Env disables styling. The value
      //    lives in Env only -- Platform.environment never sees it -- so this
      //    pins Env as the source Ansi consults.
      Ansi.enabled = null;
      expect(Platform.environment.containsKey('NO_COLOR'), isFalse);
      expect(Env.has('NO_COLOR'), isTrue);
      expect(Ansi.enabled, isFalse);
    });

    test('ConsoleMultiProgress reports each completion without a terminal', () {
      final progress = Console.multiProgress(3, slots: 2, message: 'files', terminalColumns: 80);

      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        progress.updateTask(name, label: name, ratio: 0.5, received: 512, total: 1024);
        progress.tick();
        progress.updateTask(name, label: name, ratio: 1.0, received: 1024, total: 1024, isDone: true);
      }
      progress.done('finished');

      final lines = out.toString().trim().split('\n');
      expect(lines.length, greaterThanOrEqualTo(4));
      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        expect(lines.where((l) => l.contains(name)).length, equals(1), reason: '\$name reported exactly once');
      }
      expect(lines.last, contains('finished'));
    });

    test('ConsoleProgress still reports a line per tick without a terminal', () {
      final progress = Console.progress(3, message: 'files', terminalColumns: 80);
      progress
        ..tick()
        ..tick()
        ..tick();
      progress.done('finished');

      expect(out.toString().trim().split('\n').length, equals(4));
    });
  });
}
