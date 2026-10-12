/// # CLI & Terminal
///
/// ANSI-coloured output, async non-blocking prompts (`ask`, `confirm`, `choose`) and
/// progress feedback (`bar` — each its own live-region line, so several tick side by
/// side — and `spin`). Bar glyphs ([BarGlyphs], incl. the ASCII set) are shared
/// with `tui`.
library;

export 'src/cli/cli.dart' show AnsiText, Bar, Cli;
export 'src/tui/buffer.dart' show BarGlyphs, SpinGlyphs;
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';
