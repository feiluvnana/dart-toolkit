/// Immediate-mode terminal apps. In-house on `dart:io`
/// (ANSI output, raw stdin, `SIGWINCH`).
///
/// ```dart
/// await Tui.run((screen) async {
///   var sel = 0, filter = '';
///   while (!screen.pressed('escape')) {
///     await screen.frame((r) {
///       final [head, body] = r.rows([3, 0]);
///       filter = head.box('Filter').input(filter);
///       sel = body.box('Items').list(items.where((i) => i.contains(filter)).toList(), sel);
///     });
///   }
/// });
/// ```
///
/// Public surface is exactly: [Tui], [Screen], [Region].
/// - `Tui.run()` runs an app on the alternate screen.
/// - [Screen] supports `frame` `pressed` `typed` `width` `height`.
/// - [Region] supports `width` `height` `write` `box` `rows` `cols`
///   `button` `list` `input`.
///
/// The app keeps its state in its own variables and redraws everything in
/// `frame`; work it starts without awaiting (a download, a search) changes
/// that state, and the next frame shows it. Widgets take the app's state and
/// return the new state (`sel = r.list(items, sel)`), and react to keys only
/// while drawn.
library;

export 'src/tui.dart' show Tui, Screen, Region, ScreenFuture;
