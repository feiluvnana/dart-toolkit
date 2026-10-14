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
/// Public surface is exactly: [Tui], [App], [Screen], [Binding],
/// [Pick], [Field], [Scroll], [Region], [Color], [Style],
/// plus the [RegionWidgets], [RegionMarkdown] and [RegionDiff] extensions
/// (method carriers from the `src/tui/` split: importing this library
/// applies them to [Region] automatically, never reference them by name).
/// - `Tui.run()` owns the loop and redraws on events; `screen` describes
///   the screen for a state and never blocks.
/// - [App] supports `state` `go` `status` `quit` (notifications and the
///   clipboard are `Console.notify`/`copy`, which route here while it runs).
/// - Widget state lives in [Pick], [Field] and [Scroll]
///   objects held by the app's state, so focus, selection and scroll survive
///   `go` and back.
/// - While `run` is active, `Console.spin`/`bar` draw in the
///   status row and `Console.ask`/`confirm`/`choose` open a popup
///   and `Console.log` goes to the status row.
library;

export 'src/tui.dart'
    show
        Tui,
        App,
        Screen,
        Binding,
        Pick,
        Field,
        Scroll,
        Region,
        RegionWidgets,
        RegionMarkdown,
        RegionDiff,
        Style;
export 'src/terminal.dart' show Color;
