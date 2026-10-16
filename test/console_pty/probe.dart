// Pty/subprocess helper for test/console_test.dart.
//
// Usage: probe.dart <log> <mode>
// Modes: bar | choose | ask | secret
//   bar:    a 100-item bar with a long label under the pty, then close.
//   choose: interactive choose of [red, green, blue]; writes the pick.
//   stack:  a bar and two spinners live at once.
//   orphan-exit|crash|cancel: start the tty reader, print its pid, then
//           exit(3), crash, or cancel and report whether it is alive.
//   leak:   ticks a bar and returns without closing it; must still exit.
//   over:   ticks past the total and by a negative count; close prints the count.
//   keep:   a kept bar, a `keep: false` one, and a `keep: false` one that fails.
//   evil:   choose over a label with ESC and a newline (piped).
//   ask:    reads one line (piped stdin); writes the answer.
//   ask2:   reads two lines; writes both.
//   secret: reads one secret line; writes the answer.
//   eof:    every prompt on an empty stdin; writes what each gave back.
//   empty:  prompts answered by empty lines (stdin is \n per prompt).
//   park:   a spinner runs while ask waits (pty); writes the answer.
//   asktimeout: ask(timeout:) with nobody answering; writes what it gave.
//   dumb:   notify and copy, then `done` (TERM=dumb: no escapes may print).
import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/src/terminal.dart' as term;

Future<void> main(List<String> args) async {
  final log = File(args[0]);
  final mode = args[1];
  switch (mode) {
    case 'bar':
      final bar = Console.bar('a very long label that must be cut somewhere along the way', total: 100);
      for (var i = 0; i < 5; i++) {
        bar.tick(20);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await bar.close();
    case 'keep':
      Console.bar('kept', total: 2).tick(2);
      Console.bar('gone', total: 2, keep: false).tick(2);
      try {
        await (Reader.of([1, 2, 3]) & Console.bar('broken', keep: false) > _Failing());
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
      stdout.writeln('done');
    case 'short':
      final bar = Console.bar('Pages', total: 40);
      bar.tick(12);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await bar.close();
    case 'spin':
      await (Future<void>.delayed(const Duration(milliseconds: 400)) & Console.bar('working'));
      stdout.writeln('spun');
    case 'stack':
      final bar = Console.bar('files', total: 4);
      final spins = Future.wait([
        Future<void>.delayed(const Duration(milliseconds: 500)) & Console.bar('alpha'),
        Future<void>.delayed(const Duration(milliseconds: 250)) & Console.bar('beta'),
      ]);
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        bar.tick();
      }
      await spins;
      stdout.writeln('stacked');
    case 'orphan-exit' || 'orphan-crash' || 'orphan-cancel':
      // Listen to the terminal (starts the `cat /dev/tty` child), report the
      // reader's pid, then leave without cancelling.
      final sub = term.sharedStdin().listen((_) {});
      String? cat;
      for (var i = 0; i < 100 && cat == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        Future<List<String>> kids(String of) async =>
            (await Process.run('pgrep', ['-P', of])).stdout.toString().split('\n').where((k) => k.isNotEmpty).toList();
        // Children and grandchildren; the reader is the cat holding /dev/tty.
        final near = await kids('$pid');
        for (final k in [...near, for (final c in near) ...await kids(c)]) {
          final args = (await Process.run('ps', ['-o', 'args=', '-p', k])).stdout.toString();
          if (args.contains('/dev/tty')) cat = k;
        }
      }
      stdout.writeln('cat=$cat');
      // A detached checker looks after we are gone (the pty stays open).
      await Process.start('/bin/sh', [
        '-c',
        'sleep 0.6; if ps -p $cat >/dev/null; then echo alive; else echo gone; fi > "\$0"',
        log.path,
      ], mode: ProcessStartMode.detached);
      if (mode == 'orphan-exit') exit(3);
      if (mode == 'orphan-cancel') {
        await sub.cancel();
        stdout.writeln('cancelled');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final alive = (await Process.run('ps', ['-p', '$cat'])).exitCode == 0;
        stdout.writeln('alive=$alive');
        exit(0);
      }
      throw StateError('crash');
    case 'leak':
      Console.bar('', total: 10).tick(3);
      stdout.writeln('ready-leak');
    case 'total':
      final bar = Console.bar('T');
      bar.update(2, 4);
      Console.log('logged above');
      await bar.close();
    case 'over':
      final bar = Console.bar('', total: 3);
      bar.tick(5).tick(-2);
      await bar.close();
    case 'evil':
      await Console.choose('Pick', ['a\x1b[31mb\nc'], (s) => s);
    case 'choose':
      final pick = await Console.choose('Pick', ['red', 'green', 'blue'], (s) => s, or: 'red');
      await log.writeAsString('pick=$pick\n');
    case 'ask':
      final answer = await Console.ask('Name?');
      await log.writeAsString('answer=$answer\n');
    case 'ask2':
      final a = await Console.ask('A?');
      final b = await Console.ask('B?');
      await log.writeAsString('answer=$a|$b\n');
    case 'eof':
      final a = await Console.ask('A?');
      final b = await Console.ask('B?', or: 'dflt');
      final c = await Console.confirm('C?', or: true);
      final d = await Console.confirm('D?');
      final e = await Console.choose('E', ['x', 'y'], (s) => s);
      final f = await Console.choose('F', ['x', 'y'], (s) => s, or: 'y');
      await log.writeAsString('eof=$a|$b|$c|$d|$e|$f\n');
    case 'empty':
      final a = await Console.ask('A?', or: 'dflt');
      final b = await Console.ask('B?');
      final c = await Console.confirm('C?', or: true);
      await log.writeAsString('empty=$a|$b|$c\n');
    case 'park':
      final work = Future<void>.delayed(const Duration(seconds: 3)) & Console.bar('working');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final answer = await Console.ask('Name?');
      await log.writeAsString('answer=$answer\n');
      await work;
    case 'asktimeout':
      final answer = await Console.ask('Name?', or: 'anon', timeout: const Duration(milliseconds: 300));
      await log.writeAsString('answer=$answer\n');
    case 'secret':
      final answer = await Console.ask('Password?', secret: true);
      await log.writeAsString('secret=$answer\n');
    case 'dumb':
      Console.notify('finished');
      Console.copy('clip');
      stderr.writeln('done');
  }
}

/// A writer that fails after the first chunk, so a piped bar aborts.
final class _Failing with Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    await for (final _ in input) {
      throw const FileSystemException('disk full');
    }
  }
}
