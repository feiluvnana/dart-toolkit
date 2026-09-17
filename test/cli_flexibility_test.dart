import 'dart:async';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Logger levels', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
      ConsoleIo.stdoutOverride = out;
      ConsoleIo.stderrOverride = err;
      Ansi.enabled = false;
    });

    tearDown(() {
      ConsoleIo.reset();
      Ansi.enabled = null;
      Logger.level = LogLevel.info;
    });

    test('default level emits info and above but not debug', () {
      Logger.debug('nope');
      Logger.info('yes');
      Logger.warn('warned');
      Logger.error('boom');

      expect(out.toString(), isNot(contains('nope')));
      expect(out.toString(), contains('yes'));
      expect(out.toString(), contains('warned'));
      expect(err.toString(), contains('boom'));
    });

    test('debug level includes verbose diagnostics', () {
      Logger.level = LogLevel.debug;
      Logger.debug('verbose detail');
      expect(out.toString(), contains('verbose detail'));
    });

    test('warn level suppresses info and ok', () {
      Logger.level = LogLevel.warn;
      Logger.info('hidden');
      Logger.ok('hidden too');
      Logger.step(1, 2, 'hidden step');
      Logger.warn('visible');

      expect(out.toString(), isNot(contains('hidden')));
      expect(out.toString(), contains('visible'));
    });

    test('silent suppresses everything including errors', () {
      Logger.level = LogLevel.silent;
      Logger.info('x');
      Logger.error('y');
      expect(out.toString(), isEmpty);
      expect(err.toString(), isEmpty);
    });

    test('silenced() restores the previous level afterwards', () {
      Logger.level = LogLevel.info;
      final result = Logger.silenced(() {
        Logger.info('muted');
        return 42;
      });
      expect(result, equals(42));
      expect(out.toString(), isEmpty);
      expect(Logger.level, equals(LogLevel.info));

      Logger.info('audible');
      expect(out.toString(), contains('audible'));
    });
  });

  group('Prompt flexibility', () {
    late StringBuffer out;

    setUp(() {
      out = StringBuffer();
      ConsoleIo.stdoutOverride = out;
      Ansi.enabled = false;
    });

    tearDown(() {
      ConsoleIo.reset();
      Ansi.enabled = null;
    });

    /// Feeds [lines] to prompts, then end-of-input.
    void feed(List<String> lines) {
      final queue = List<String>.from(lines);
      ConsoleIo.stdinLineReader = () => queue.isEmpty ? null : queue.removeAt(0);
    }

    test('select works with non-String choices via display', () {
      feed(['2']);
      final servers = [(name: 'alpha', region: 'us'), (name: 'beta', region: 'eu')];
      final picked = Prompt.select('Target', servers, display: (s) => '${s.name} (${s.region})');
      expect(picked.name, equals('beta'));
      expect(out.toString(), contains('alpha (us)'));
      expect(out.toString(), contains('beta (eu)'));
    });

    test('select infers String choices exactly as before', () {
      feed(['3']);
      final env = Prompt.select('Environment', ['dev', 'staging', 'prod']);
      expect(env, equals('prod'));
    });

    test('select returns the default on empty input', () {
      feed(['']);
      final env = Prompt.select('Environment', ['dev', 'staging'], defaultTo: 'staging');
      expect(env, equals('staging'));
      expect(out.toString(), contains('(default)'));
    });

    test('ask re-prompts until validate accepts', () {
      feed(['abc', '8080']);
      final port = Prompt.ask('Port', validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
      expect(port, equals('8080'));
      expect(out.toString(), contains('Must be a number'));
    });

    test('ask falls back to the default at end of input instead of hanging', () {
      ConsoleIo.stdinLineReader = () => null; // immediate end of input
      final value = Prompt.ask('Name', defaultTo: 'fallback');
      expect(value, equals('fallback'));
    });

    test('required ask throws rather than looping when input is exhausted', () {
      ConsoleIo.stdinLineReader = () => null; // immediate end of input
      expect(() => Prompt.ask('Name', required: true), throwsA(isA<StateError>()));
    });
  });

  group('Uniform cancellation composition', () {
    test('Stream.cancelWith stops delivery once the token fires', () async {
      final token = CancellationToken();
      final controller = StreamController<int>();
      final received = <int>[];

      final done = controller.stream.cancelWith(token).forEach(received.add);

      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      token.cancel('enough');
      controller.add(2);
      await Future<void>.delayed(Duration.zero);

      await done;
      expect(received, equals([1]));
      await controller.close();
    });

    test('Stream.cancelWith can surface a CancellationException', () async {
      final token = CancellationToken();
      final controller = StreamController<int>();
      final stream = controller.stream.cancelWith(token, throwOnCancel: true);

      final future = stream.toList();
      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      token.cancel('halt');

      await expectLater(future, throwsA(isA<CancellationException>()));
      await controller.close();
    });

    test('Stream.cancelWith on an already-cancelled token yields nothing', () async {
      final token = CancellationToken()..cancel();
      final items = await Stream.fromIterable([1, 2, 3]).cancelWith(token).toList();
      expect(items, isEmpty);
    });

    test('Future.cancelWith rejects as soon as the token fires', () async {
      final token = CancellationToken();
      final slow = Future<int>.delayed(const Duration(seconds: 5), () => 1);
      final guarded = slow.cancelWith(token);
      token.cancel('stop');
      await expectLater(guarded, throwsA(isA<CancellationException>()));
    });

    test('Future.cancelWith passes the value through when not cancelled', () async {
      final token = CancellationToken();
      final value = await Future<int>.value(7).cancelWith(token);
      expect(value, equals(7));
    });
  });
}
