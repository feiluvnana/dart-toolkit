// The terminal seam: what `Io.scope(terminal:)` takes, so `Tui`, the pickers and the console's
// live region all run on a `FakeTerminal` in a test.

part of '../core.dart';

/// The screen and keyboard an app draws on and reads keys from: the process's terminal, or a
/// `FakeTerminal` (in `testing.dart`) under `Io.scope(terminal:)`.
///
/// [open] puts it in raw mode and starts [input]; [close] undoes both and must be synchronous,
/// because a signal handler calls it on the way out; it can be opened again after. Escape
/// sequences go through [write].
///
/// ```dart
/// final term = FakeTerminal(width: 40, height: 10);
/// await Io.scope(() => urls.parallelize(fetch).show('Pages'), terminal: term);
/// print(term.screen);
/// ```
///
/// {@category CLI}
abstract interface class Terminal {
  int get width;
  int get height;

  /// Colours it can show: 1 << 24, 256, 16, or 0 (attributes only).
  int get colors;

  /// Whether it draws Unicode; where it does not, both UIs draw in ASCII.
  bool get unicode;

  /// Bytes typed, pasted or reported (mouse), between [open] and [close].
  Stream<List<int>> get input;

  /// Fires when [width] or [height] changed.
  Stream<void> get resized;

  Future<void> open();

  void close();

  /// Stops the process as ^Z does (SIGTSTP) and completes once it runs again (SIGCONT). It is
  /// called closed, and opened again after.
  Future<void> suspend();

  void write(String data);
}

/// What a scope's [Terminal] is to `Io.stdout` and `Io.stderr`: its screen, a line feed returning
/// the carriage as a terminal's output translation does.
final class _TerminalSink implements StringSink {
  final Terminal _terminal;

  _TerminalSink(this._terminal);

  @override
  void write(Object? object) => _terminal.write('$object'.replaceAll('\n', '\r\n'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');
}
