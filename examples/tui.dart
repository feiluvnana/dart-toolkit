/// tui: state-driven terminal apps; `screen` describes, keys change state. `q` quits.
///
/// `dart run examples/tui.dart`
library;

import 'package:dart_toolkit/tui.dart';

Future<void> main() async {
  final items = Pick<String>(['apples', 'bread', 'cheese']);
  final clicks = Scroll();
  final lines = <String>[];
  await Tui.run<int>(
    0,
    (n, app) => Screen(
      title: 'tui example',
      status: '$n picks',
      (r) {
        final [list, log] = r.cols([24, 0]);
        list.box('shopping').list(items, (s) => s);
        final inner = log.box('log').scroll(clicks);
        for (final l in lines) {
          inner.write('$l\n');
        }
      },
      keys: {
        'enter': (
          'pick',
          () {
            lines.add('picked ${items.selected()}');
            app.go(n + 1);
          },
        ),
        'q': ('quit', app.quit),
      },
    ),
  );
}
