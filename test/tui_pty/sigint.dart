// Pty helper: proves an external SIGINT becomes pressed('ctrl+c') and the
// terminal is restored. Driven by sigint_drive.py (it sends the signal).
import 'package:dart_toolkit/tui.dart';

Future<void> main() async {
  await Tui.run((s) async {
    for (var f = 0; f < 10000; f++) {
      await s.frame((r) => r.write('tick $f'));
      if (s.pressed('ctrl+c')) {
        await s.frame((r) => r.write('saw ctrl+c'));
        return;
      }
    }
  });
}
