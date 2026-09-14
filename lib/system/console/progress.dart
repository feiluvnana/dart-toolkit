/// # Progress Bars (`Progress`)
///
/// A single-line bar with a rate and an ETA, repainted in place. It owns a
/// cursor position and a clock, so it is one of the two things in
/// the console with state rather than a single render.
///
/// Split out of `writer.dart` in 6.0.0. Nothing about the API moved.
library;

import '../../util/size.dart';
import '../../util/time.dart';
import 'ansi.dart';
import 'terminal.dart';
import 'writer.dart';

// ============================================================================
// PROGRESS BARS (Progress)
// ============================================================================

/// What a [Progress] bar is counting.
enum ProgressUnit {
  /// Plain item counts.
  count,

  /// Byte totals, rendered with [formatBytes].
  bytes,
}

/// A single-line progress bar with rate and ETA.
///
/// Renders only to a terminal, so piped output stays clean.
///
/// ```dart
/// final bar = Progress(total: files.length, message: 'Downloading');
/// for (final f in files) { await Path(f.path).readText(); bar.tick(); }
/// bar.done('Finished');
/// ```
class Progress {
  /// Where the bar is drawn. Defaults to stdout.
  final ConsoleWriter writer;

  /// The target count, updatable through [update].
  int total;

  /// Width of the bar itself, in characters.
  final int width;

  /// Whether [total] counts items or bytes.
  final ProgressUnit unit;

  /// Character filling completed space.
  final String fill;

  /// Character filling remaining space.
  final String empty;

  final Stopwatch _clock = Stopwatch();
  int _current = 0;
  String _message;
  DateTime? _painted;

  /// Creates a bar counting up to [total].
  ///
  /// The glyph defaults are the shared ones, so a bar built either
  /// way looks the same.
  Progress({
    required this.total,
    this.width = 25,
    this.unit = ProgressUnit.count,
    this.fill = '█',
    this.empty = '░',
    String message = '',
    ConsoleWriter? writer,
  }) : _message = message,
       writer = writer ?? sharedConsoleWriter {
    _clock.start();
  }

  /// The current count.
  int get current => _current;

  /// Sets the count to [current], optionally changing [total] or [message].
  ///
  /// Repaints at most every 80ms, and always on completion.
  void update(int current, {int? total, String? message}) {
    if (total != null) this.total = total;
    if (message != null) _message = message;
    _current = current;

    final now = DateTime.now();
    final due =
        _painted == null ||
        now.difference(_painted!).inMilliseconds > 80 ||
        _current >= this.total;
    if (!due) return;
    _painted = now;
    render();
  }

  /// Advances the count by [delta].
  void tick([int delta = 1, String? message]) =>
      update(_current + delta, message: message);

  /// Repaints the bar in place.
  void render() {
    if (!writer.tty) return;
    final fraction = total > 0 ? (_current / total).clamp(0.0, 1.0) : 0.0;
    final filled = (width * fraction).round();
    final metrics = unit == ProgressUnit.bytes
        ? '${_current.formatBytes()} / ${total.formatBytes()}'
        : '$_current / $total';

    final parts = [
      if (_message.isNotEmpty) _message.brightCyan(),
      '[${fill * filled}${empty * (width - filled).clamp(0, width)}]'.bold(),
      '${(fraction * 100).toStringAsFixed(1)}%'.padLeft(6).green(),
      '($metrics)'.dim(),
      ..._rate(),
    ];

    Terminal(writer).line();
    writer.write('\r${parts.join(' ')}');
  }

  /// Rate and ETA, once there is enough elapsed time to be meaningful.
  List<String> _rate() {
    final elapsed = _clock.elapsed;
    if (elapsed.inMilliseconds <= 300 || _current <= 0) return const [];
    final perSecond = _current / (elapsed.inMilliseconds / 1000);
    final rate = unit == ProgressUnit.bytes
        ? '${perSecond.round().formatBytes()}/s'
        : '${perSecond.toStringAsFixed(1)} items/s';
    if (total <= _current || perSecond <= 0) return [rate.dim()];
    final remaining = Duration(
      seconds: ((total - _current) / perSecond).round(),
    );
    return [rate.dim(), 'ETA ${remaining.format()}'.dim()];
  }

  /// Fills the bar, prints [message] and moves to the next line.
  ///
  /// Off a terminal nothing was drawn, so nothing is closed off either — a
  /// bare newline would be the one mark a redirected run still carried.
  void done([String? message]) {
    _clock.stop();
    update(total, message: message);
    if (writer.tty) writer.writeln();
  }

  /// Abandons the bar and reports [message] as a failure.
  void fail([String? message]) {
    _clock.stop();
    if (writer.tty) writer.writeln();
    if (message != null) writer.errorln('${'✖'.brightRed()} $message');
  }
}
