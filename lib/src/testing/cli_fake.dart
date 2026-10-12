part of '../cli/cli.dart';

/// Test seams for [Cli]: fake input lines and a captured stderr. Never needed by a script.
abstract final class CliFake {
  /// Answers prompts from [lines], in order; an empty answer once drained.
  static void lines(List<String> lines) => Cli._useLines(Stream.fromIterable(lines));

  /// Captures everything [Cli] writes (prints, prompts, bars, spinners) into
  /// a fresh buffer, answering it. With [live] the live region stays on
  /// screen: bars draw live until [Bar.close], and [screen] snapshots the
  /// screen; otherwise each bar prints one line when it ends (like a pipe).
  /// [level] forces the colour level ([ColorLevel.none] reads like
  /// `NO_COLOR`); [unicode] swaps `✓`/`✗`/`❯` and the bar glyphs for their
  /// ASCII words. [lines] feeds prompts, as in [lines].
  ///
  /// Pair every [capture] with [reset] (`addTearDown(CliFake.reset)`).
  static StringBuffer capture({
    bool live = false,
    ColorLevel level = ColorLevel.truecolor,
    bool unicode = true,
    List<String> lines = const [],
  }) {
    Cli._resetFake();
    final buf = StringBuffer();
    Cli._fakeSink = buf;
    Cli._fakeLive = live;
    Cli._fakeLevel = level;
    Cli._fakeUnicode = unicode;
    Cli._useLines(Stream.fromIterable(lines));
    return buf;
  }

  /// The live screen right now: finished lines first, then one line per open
  /// bar. Only meaningful after [capture] with `live: true`.
  static List<String> get screen => _LiveRegion.screen;

  /// Hands input and output back to the real stdio and clears the live region.
  static void reset() => Cli._resetFake();
}
