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
/// [Pick], [Field], [Scroll], [Region], [Color], [Style], [Pixels], [Meter],
/// plus the [RegionWidgets] and [RegionMarkdown] extensions
/// (applied to [Region] on import).
/// - `Tui.run()` owns the loop and redraws on events; `screen` describes
///   the screen for a state and never blocks. `work:` is the job the screen
///   watches: started once shown, cancelled by quitting, run with Console
///   when there is no terminal.
/// - [App] supports `go` `status` `quit` (notifications and the clipboard
///   are `Console.notify` and utils' `ConsoleUtils.copy`, which route here
///   while it runs).
/// - Widget state lives in [Pick], [Field] and [Scroll]
///   objects held by the app's state, so focus, selection and scroll survive
///   `go` and back.
/// - `Region.bar` draws a [Meter] (core's, re-exported here): attach it
///   with `&` to the work it should count.
/// - While `run` is active, `Console.bar` and `Console.log` draw in the
///   status row, or in `Region.bars()`/`log()` when the screen draws them;
///   `Console.ask`/`confirm`/`choose`/`pick` open a popup.
///
/// {@canonicalFor terminal.Color}
/// {@canonicalFor pixels.Pixels}
library;

export 'src/tui.dart'
    show Tui, App, Screen, Binding, Pick, Field, Scroll, Region, RegionWidgets, RegionMarkdown, Style;
export 'src/terminal.dart' show Color;
export 'src/pixels.dart' show Pixels;
export 'src/progress.dart' show Meter;
