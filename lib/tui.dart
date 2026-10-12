/// # TUI
///
/// Full-screen terminal apps: [Tui.run] takes a `draw`/`poll` loop over a
/// [Term] (`box`, `text`, `bar`, `list`, `split`, `button`, `field`, `tabs`,
/// `table`, `popup`, `markdown`, `picture` …), hears [TuiEvent]s (`Start`,
/// `KeyPress`, `Paste`, `Pointer`, `Resize`, `Interrupt`, `Post`), and
/// restores the terminal on every way out. Tests drive the same loop on a
/// `FakeTerminal` (import `testing.dart`).
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

export 'src/tui/buffer.dart' show BarGlyphs, CellStyle, SpinGlyphs, TuiColor;
export 'src/tui/canvas.dart' show Canvas, FieldState;
export 'src/tui/events.dart'
    show Blur, Focus, Interrupt, Paste, Pointer, PointerKind, Post, Resize, Resume, Start, Suspend, TuiEvent, KeyPress;
export 'src/tui/term.dart' show Term, Tui;
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';
