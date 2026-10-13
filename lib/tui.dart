/// State-driven terminal apps. In-house on `dart:io`
/// (ANSI output, raw stdin, `SIGWINCH`).
///
/// ```dart
/// sealed class Page {}
/// final class Search extends Page {
///   final query = Field();
///   final hits = Pick<Hit>();
/// }
/// await Tui.run<Page>(Search(), (page, app) => switch (page) {
///   Search s => Screen(title: 'demo', (r) {
///       final [body, foot] = r.rows([0, 3]);
///       body.list(s.hits, (h) => h.title, empty: 'type, press enter');
///       foot.box('search').input(s.query);
///     }, keys: {
///       'enter': ('search', () => _search(s)),
///       'escape': ('quit', () => app.quit()),
///     }),
/// });
/// ```
///
/// Public surface is exactly: [Tui], [App], [Screen], [Bind], [Pick],
/// [Field], [Scroll], [Region], [Color], [Style].
/// - `Tui.run()` owns the loop and redraws on events; `screen` describes
///   the screen for a state and never blocks.
/// - [App] supports `state` `go` `say` `print` `notify` `copy` `quit`.
/// - Widget state lives in [Pick], [Field] and [Scroll] objects held by the
///   app's state, so focus, selection and scroll survive `go` and back.
/// - While `run` is active, `Console.spin`/`bar` draw in the status row and
///   `Console.ask`/`confirm`/`choose` open a popup.
library;

export 'src/tui.dart'
    show Tui, App, Screen, Bind, Pick, Field, Scroll, Region, Color, Style;
