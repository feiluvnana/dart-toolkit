/// tui + shell: run a command and stream its output live into a scrolling pane. `q` quits.
///
/// `dart run examples/combo_tui_shell.dart`
library;

import 'dart:convert' show LineSplitter, utf8;

import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/tui.dart';

final class Run {
  final scroll = Scroll();
  final lines = <String>[];
  var started = false, done = false;
}

const _script = 'for i in 1 2 3 4 5; do echo "step \$i"; sleep 0.4; done';

Future<void> main() => Tui.run<Run>(
  Run(),
  (run, app) => Screen(title: 'tui + shell', status: run.done ? 'finished' : 'running…', (r) {
    final out = r.box(_script).scroll(run.scroll);
    for (final l in run.lines) {
      out.write('$l\n');
    }
  }, keys: {'show': ('', () => _start(run)), 'q': ('quit', app.quit)}),
);

void _start(Run run) {
  if (run.started) return;
  run.started = true;
  (Reader.of([]) | Shell.filter(['sh', '-c', _script]))
      .stream()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(run.lines.add, onDone: () => run.done = true);
}
