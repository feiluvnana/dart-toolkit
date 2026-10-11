// A live TUI monitor: background stats drain from a `Chan` into a board,
// redrawn at the poll pace. Quit with `q`.
//
//   dart run example/monitor/monitor.dart
library;

import 'dart:async';
import 'dart:math';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/tui.dart';

Future<void> main() async {
  final updates = Chan<(String, int)>(cap: 100);
  final stats = <String, int>{};
  final random = Random();

  // Background producer pushing metrics.
  unawaited(
    Task.run(() async {
      while (true) {
        await updates.send(('cpu', 20 + random.nextInt(70)));
        await updates.send(('mem', 40 + random.nextInt(50)));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }),
  );

  // TUI event and render loop (proposal 12:4.1).
  await Tui.run((term) async {
    while (true) {
      // Drain channel updates non-blocking.
      while (true) {
        final stat = updates.tryRecv();
        if (stat == null) break;
        stats[stat.$1] = stat.$2;
      }

      term.draw((ui) {
        ui.box(
          title: 'Live Monitor',
          build: (box) {
            box.board([BoardRow('CPU', stats['cpu'] ?? 0, 100), BoardRow('MEM', stats['mem'] ?? 0, 100)]);
          },
        );
      });

      final ev = await term.poll(timeout: const Duration(milliseconds: 100));
      if (ev?.key == 'q') break;
    }
  });
  await updates.close();
}
