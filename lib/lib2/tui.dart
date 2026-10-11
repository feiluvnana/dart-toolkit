/// # TUI
///
/// Full-screen terminal apps: [Tui.run] takes a `draw`/`poll` loop over a
/// [Term] (`box`, `text`, `bar`, `list`, `split` …), hears [TuiEvent]s
/// (`Start`, `KeyPress`, `Paste`, `Pointer`, `Resize`, `Interrupt`, `Post`),
/// and restores the terminal on every way out. [FakeTerminal] is the test
/// seam: frames, keys and resizes without a terminal.
///
/// ```dart
/// await Tui.run((term) async {
///   while (true) {
///     term.draw((ui) {
///       ui.box(title: 'App');
///       ui.text('Press "q" to exit.');
///     });
///     if (await term.poll() case final ev? when ev.key == 'q') break;
///   }
/// });
/// ```
library;

export 'src/tui/buffer.dart';
export 'src/tui/canvas.dart';
export 'src/tui/events.dart';
export 'src/tui/layout.dart';
export 'src/tui/native.dart';
export 'src/tui/term.dart';
export 'src/tui/width.dart';
