/// State-driven terminal apps (REPORT §15, Step 1a scaffold).
///
/// Temporary surface while the new API is built: [Tui], [App], [Screen],
/// [Bind], [Pick], [Field], [Scroll], [Region], [Color], [Style]. This merges
/// into `tui.dart` (replacing the immediate-mode engine) at migration; until
/// then `tui.dart` keeps serving `rawfree` and the old tests.
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
library;

export 'src/tui_state.dart'
    show
        Tui,
        App,
        Screen,
        Bind,
        Pick,
        Field,
        Scroll,
        Region,
        Color,
        Style,
        TestSession,
        testSession;
