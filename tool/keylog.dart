// Diagnostic probe: prints the raw stdin bytes each keypress produces, so
// key-routing bugs can be diagnosed without guessing what a terminal sends.
// Run from a real terminal (not piped):
//
//   dart run tool/keylog.dart
//
// Press keys (arrows, esc, enter, letters); `q` or Ctrl+C quits. Paste the
// header lines plus the hex lines for the misbehaving key into the report.
import 'dart:io';

void main() {
  stdout.writeln('stdin.hasTerminal=${stdin.hasTerminal}');
  stdout.writeln('stderr.hasTerminal=${stderr.hasTerminal}');
  try {
    stdin.echoMode = false;
    stdout.writeln('set echoMode=false: ok');
  } catch (e) {
    stdout.writeln('set echoMode=false FAILED: $e');
  }
  try {
    stdin.lineMode = false;
    stdout.writeln('set lineMode=false: ok');
  } catch (e) {
    stdout.writeln('set lineMode=false FAILED: $e');
  }
  try {
    stdout.writeln(
        'readback: echoMode=${stdin.echoMode} lineMode=${stdin.lineMode}');
  } catch (e) {
    stdout.writeln('readback FAILED: $e');
  }
  if (!stdin.hasTerminal) {
    stderr.writeln('keylog needs a terminal (stdin is piped).');
    exit(2);
  }
  stdout.writeln('keylog: press keys, q quits. One hex line per stdin read.');
  stdin.listen((List<int> bytes) {
    final String hex =
        bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final String ascii = bytes
        .map((int b) =>
            b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : '.')
        .join();
    stdout.writeln('$hex   |$ascii|');
    if (bytes.length == 1 && bytes[0] == 0x71) {
      exit(0);
    }
  });
}
