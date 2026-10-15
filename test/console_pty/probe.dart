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
//   evil:   choose over a label with ESC and a newline (piped).
//   ask:    reads one line (piped stdin); writes the answer.
//   ask2:   reads two lines; writes both.
//   secret: reads one secret line; writes the answer.
//   eof:    every prompt on an empty stdin; writes what each gave back.
//   empty:  prompts answered by empty lines (stdin is \n per prompt).
import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/src/terminal.dart' as term;

Future<void> main(List<String> args) async {
  final log = File(args[0]);
  final mode = args[1];
  if (Platform.environment['PROBE_ACCENT'] != null) Console.accent = Color.orange;
  switch (mode) {
    case 'bar':
      final bar = Console.bar(100, label: 'a very long label that must be cut somewhere along the way');
      for (var i = 0; i < 5; i++) {
        bar.tick(20);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await bar.close();
    case 'short':
      final bar = Console.bar(40, label: 'Pages');
      bar.tick(12);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await bar.close();
    case 'spin':
      await Console.spin('working', Future<void>.delayed(const Duration(milliseconds: 400)));
      stdout.writeln('spun');
    case 'stack':
      final bar = Console.bar(4, label: 'files');
      final spins = Future.wait([
        Console.spin('alpha', Future<void>.delayed(const Duration(milliseconds: 500))),
        Console.spin('beta', Future<void>.delayed(const Duration(milliseconds: 250))),
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
      Console.bar(10).tick(3);
      stdout.writeln('ready-leak');
    case 'total':
      final bar = Console.bar(null, label: 'T');
      bar.tick(2).setTotal(4);
      Console.log('logged above');
      await bar.close();
    case 'over':
      final bar = Console.bar(3);
      bar.tick(5).tick(-2);
      await bar.close();
    case 'evil':
      await Console.choose('Pick', ['a\x1b[31mb\nc']);
    case 'choose':
      final pick = await Console.choose('Pick', ['red', 'green', 'blue'], or: 'red');
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
      final e = await Console.choose('E', ['x', 'y']);
      final f = await Console.choose('F', ['x', 'y'], or: 'y');
      await log.writeAsString('eof=$a|$b|$c|$d|$e|$f\n');
    case 'empty':
      final a = await Console.ask('A?', or: 'dflt');
      final b = await Console.ask('B?');
      final c = await Console.confirm('C?', or: true);
      await log.writeAsString('empty=$a|$b|$c\n');
    case 'secret':
      final answer = await Console.ask('Password?', secret: true);
      await log.writeAsString('secret=$answer\n');
  }
}
