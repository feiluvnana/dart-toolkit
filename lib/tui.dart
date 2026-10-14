/// State-driven terminal apps. In-house on `dart:io`
/// (ANSI output, raw stdin, `SIGWINCH`).
///
/// ```dart
/// sealed class Page {}
/// final class Search extends Page {
///   final query = TextField();
///   final hits = Selection<Hit>();
/// }
/// await Tui.run<Page>(Search(), (page, app) => switch (page) {
///   Search s => Screen(title: 'demo', (r) {
///       final [body, foot] = r.splitRows([0, 3]);
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
/// [Selection], [TextField], [ScrollPosition], [Region], [Color], [Style],
/// plus the [RegionWidgets], [RegionMarkdown] and [RegionDiff] extensions
/// (method carriers from the `src/tui/` split: importing this library
/// applies them to [Region] automatically, never reference them by name).
/// - `Tui.run()` owns the loop and redraws on events; `screen` describes
///   the screen for a state and never blocks.
/// - [App] supports `state` `goTo` `showStatus` `printAbove` `notify`
///   `copyToClipboard` `quit`.
/// - Widget state lives in [Selection], [TextField] and [ScrollPosition]
///   objects held by the app's state, so focus, selection and scroll survive
///   `goTo` and back.
/// - While `run` is active, `Console.withSpinner`/`progressBar` draw in the
///   status row and `Console.ask`/`confirm`/`choose` open a popup.
library;

export 'src/tui.dart'
    show
        Tui,
        App,
        Screen,
        Binding,
        Selection,
        TextField,
        ScrollPosition,
        Region,
        RegionWidgets,
        RegionMarkdown,
        RegionDiff,
        Color,
        Style;
