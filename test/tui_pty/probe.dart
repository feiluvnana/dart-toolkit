// Pty helper for test/tui_test.dart. Run under a real terminal (see
// tui_pty/drive.py); writes observations to the log file.
//
// Usage: probe.dart <log> <mode>
import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/tui.dart';

const _watched = [
  'a', 'q', 'shift+tab', 'up', 'ctrl+c', 'space', 'enter', 'insert', //
  'ctrl+up', 'f1', 'home', 'ctrl+delete', 'alt+x', 'delete', 'click',
];

Future<void> main(List<String> args) async {
  final log = File(args[0]);
  final mode = args.length > 1 ? args[1] : 'keys';
  final seen = <String>[];
  void quitOnEscape(App<int> app) {
    seen.add('escape');
    app.quit();
  }

  switch (mode) {
    case 'keys':
      await Tui.run<int>(
        0,
        (s, app) => Screen(
          (r) => r.write('keys'),
          keys: {for (final k in _watched) k: ('', () => seen.add(k)), 'escape': ('', () => quitOnEscape(app))},
        ),
      );
    case 'second':
      for (final word in ['one', 'two']) {
        await Tui.run<int>(0, (s, app) => Screen((r) => r.write(word), keys: {'show': ('', () => app.quit())}));
      }
      seen.add('second-ok');
    case 'cjk':
      await Tui.run<int>(
        0,
        (s, app) => Screen((r) {
          r.write('日 本 語abc');
          r.write('plain row two');
        }, keys: {'escape': ('', () => quitOnEscape(app))}),
      );
    case 'controls':
      await Tui.run<int>(
        0,
        (s, app) => Screen((r) {
          r.write('x\ty');
          r.write('a\x1bb\x01c');
          r.write('l1\nl2\nl3');
        }, keys: {'escape': ('', () => quitOnEscape(app))}),
      );
    case 'widgets':
      final query = TextField();
      final items = Selection(['alpha', 'beta', 'gamma', 'delta', 'epsilon']);
      var go = false;
      await Tui.run<int>(
        0,
        (s, app) => Screen((r) {
          final [hd, bd, ft] = r.splitRows([1, 0, 1]);
          hd.input(query);
          bd.list(items, (x) => x);
          ft.button('go', () => go = true);
        }, keys: {'escape': ('', () => quitOnEscape(app))}),
      );
      seen.addAll(['query=${query.text()}', 'sel=${items.index()}', 'go=$go']);
    case 'inline':
      final prompt = TextField();
      await Tui.run<int>(
        0,
        fullscreen: false,
        (s, app) => Screen(
          status: 'mode line',
          (r) => r.box('').input(prompt, hint: 'ask'),
          keys: {
            'enter': (
              'send',
              () {
                final text = prompt.submit();
                app.printAbove((r) => r.write('> $text'));
              },
            ),
            'escape': ('', () => quitOnEscape(app)),
          },
        ),
      );
    case 'late':
      // Work a handler started lands inside the 60 fps gap after a paint.
      var text = 'zero';
      await Tui.run<int>(
        0,
        (s, app) => Screen(
          (r) => r.write(text),
          keys: {
            'a': (
              '',
              () {
                text = 'one';
                Timer(const Duration(milliseconds: 4), () => text = 'two');
              },
            ),
            // Exit before any redraw: the screen shows what was painted.
          'q': ('', () => exit(0)),
          },
        ),
      );
    case 'sigint':
      // An external SIGINT becomes the ctrl+c binding.
      var saw = false;
      await Tui.run<int>(
        0,
        (s, app) => Screen(
          (r) => r.write(saw ? 'saw ctrl+c' : 'waiting'),
          keys: {
            'ctrl+c': (
              '',
              () {
                saw = true;
                Future<void>.delayed(const Duration(milliseconds: 300), app.quit);
              },
            ),
          },
        ),
      );
    case 'alive':
      // Idle but animated: a spinner, and a timer that lands later. The
      // driver ends it with SIGTERM.
      var text = 'waiting';
      await Tui.run<int>(
        0,
        (s, app) => Screen(
          (r) => r.spin('busy').write(text),
          keys: {
            'show': ('', () => Timer(const Duration(milliseconds: 300), () => text = 'timer fired')),
          },
        ),
      );
    case 'idle':
      // Nothing animates; a future's continuation changes the state.
      var text = 'waiting';
      await Tui.run<int>(
        0,
        (s, app) => Screen(
          (r) => r.write(text),
          keys: {
            'show': (
              '',
              () {
                // Not awaited, so no handler is pending; the change lands in
                // a microtask after the timer's own callback.
                unawaited(() async {
                  await Future<void>.delayed(const Duration(milliseconds: 300));
                  await Future<void>.value();
                  text = 'loaded';
                }());
              },
            ),
          },
        ),
      );
    case 'ascii':
      await Tui.run<int>(
        0,
        (s, app) => Screen((r) {
          final [a, b] = r.splitRows([3, 0]);
          a.box('t');
          b.progressBar(1, 2).write('x', color: Color.red);
        }, keys: {'escape': ('', () => quitOnEscape(app))}),
      );
  }
  await log.writeAsString('${seen.join('\n')}\n');
}
