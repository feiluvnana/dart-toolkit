/// # Chrome / DevTools
///
/// A lazy `Chrome()` (or `Chrome(port:)` to attach) and driven `Page`s through
/// the native CDP engine: `open`, `navigate`, `title`, `eval`, `click`,
/// `type`, `wait`, `screenshot`, `pdf`, `page.html()`.
library;

export 'src/chrome/chrome.dart';
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';
