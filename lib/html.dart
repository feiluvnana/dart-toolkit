/// # HTML
///
/// A tolerant HTML parser and a CSS selector engine: `Html.parse`, then
/// `find`/`all` with type, `#id`, `.class`, `[attr]`, combinators and
/// pseudo-classes (`:first-child`, `:nth-child`, `:not`, `:has`,
/// `:contains`). Documents are immutable: `drop(css)` copies without the
/// match, `save` writes the markup back.
library;

export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';
export 'src/html/html.dart';
