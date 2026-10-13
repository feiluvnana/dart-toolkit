// Pty helper for test/tui_test.dart. Run under a real terminal (see
// tui_pty/drive.py); writes observations to the log file.
//
// Usage: probe.dart <log> <mode> [frames]
import 'dart:io';
import 'package:dart_toolkit/tui.dart';

const _watched = [
  'a', 'q', 'escape', 'shift+tab', 'up', 'ctrl+c', 'space', 'enter',
  'insert', 'wheelup', 'wheeldown', 'ctrl+up', 'f1', 'home', 'ctrl+delete',
  'alt+x', 'delete',
];

Future<void> main(List<String> args) async {
  final log = File(args[0]);
  final mode = args.length > 1 ? args[1] : 'keys';
  final frames = args.length > 2 ? int.parse(args[2]) : 300;
  switch (mode) {
    case 'second':
      await Tui.run((s) async {
        await s.frame((r) => r.write('one'));
      });
      await Tui.run((s) async {
        await s.frame((r) => r.write('two'));
      });
      await log.writeAsString('second-ok\n');
      return;
    case 'cjk':
      await _run(log, frames, (r) {
        r.write('日 本 語abc');
        r.write('plain row two');
      });
      return;
    case 'controls':
      await _run(log, frames, (r) {
        r.write('x\ty');
        r.write('a\x1bb\x01c');
        r.write('l1\nl2\nl3');
      });
      await log.writeAsString('controls-done\n', mode: FileMode.append);
      return;
    case 'widgets':
      await _widgets(log, frames);
      return;
    default:
      await _run(log, frames, (r) => r.write('frame'));
  }
}

Future<void> _run(
  File log,
  int frames,
  void Function(Region r) draw,
) async {
  final seen = <String>[];
  await Tui.run((screen) async {
    for (var f = 0; f < frames; f++) {
      await screen.frame(draw);
      for (final k in _watched) {
        if (screen.pressed(k)) seen.add('$f:$k');
      }
      final t = screen.typed();
      if (t.isNotEmpty) seen.add('$f:typed=$t');
      if (screen.pressed('escape')) break;
    }
  });
  await log.writeAsString('${seen.join('\n')}\n');
}

Future<void> _widgets(File log, int frames) async {
  var query = '';
  var sel = 0;
  var go = false;
  const items = ['alpha', 'beta', 'gamma', 'delta', 'epsilon'];
  await Tui.run((screen) async {
    for (var f = 0; f < frames; f++) {
      await screen.frame((r) {
        final [hd, bd, ft] = r.rows([1, 0, 1]);
        query = hd.input(query);
        sel = bd.list(items, sel);
        if (ft.button('go')) go = true;
      });
      if (screen.pressed('escape')) break;
    }
  });
  await log.writeAsString('query=$query\nsel=$sel\ngo=$go\n');
}
