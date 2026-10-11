/// # HTML
///
/// A tolerant HTML parser and a CSS selector engine: `Html.parse` (or `Html.read` for
/// files, with an implied `html > head + body`), then `find`/`all` with type, `#id`,
/// `.class`, `[attr]`, combinators and pseudo-classes (`:first-child`, `:nth-child`,
/// `:not`, `:has`, `:contains`).
library;

export 'src/html/html.dart';
