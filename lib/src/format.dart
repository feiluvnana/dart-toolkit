/// Shared progress text for `console` and the Tui status row: sizes, rates,
/// counts and bar glyphs, so a bar reads the same in both; and the rate
/// window behind `Meter`, `Console.bar` and the status row.
library;

import 'dart:math' as math;

/// A byte count as humans read it: `0 B`, `200.0 KB`, `12.1 MB`.
String fmtSize(num bytes) {
  if (bytes < 1024) return '${bytes.round()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Byte counts as humans read them: `bytes.size()` → `12.1 MB`.
extension Sizes on num {
  /// `0 B`, `200.0 KB`, `12.1 MB`, `1.5 GB`.
  String size() => fmtSize(this);
}

/// A byte rate: `512 B/s`, `1.2 MB/s`.
String fmtRate(double bytesPerSec) {
  if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
  if (bytesPerSec < 1024 * 1024) return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
  return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

/// An item rate without its unit: one decimal below 100.
String fmtCount(double perSec) => perSec < 100 ? perSec.toStringAsFixed(1) : perSec.toStringAsFixed(0);

/// What a progress count measures: bytes (a flow), items (jobs, entries)
/// or time in microseconds (an encode).
enum Unit { bytes, items, time }

/// [n] in [unit]: `12.1 MB`, `12`, `1:12`.
String fmtAmount(int n, Unit unit) => switch (unit) {
  Unit.bytes => fmtSize(n),
  Unit.items => '$n',
  Unit.time => fmtClock(n),
};

/// [n] of [total] in [unit]: `12.1/40.0 MB` reads as `12.1 MB/40.0 MB`.
String fmtCounts(int n, int? total, Unit unit) =>
    total == null || total <= 0 ? fmtAmount(n, unit) : '${fmtAmount(n, unit)}/${fmtAmount(total, unit)}';

/// A rate in [unit] per second: `1.2 MB/s`, `3.1/s`, `3.4×` (media time
/// per wall-clock second).
String fmtPace(double perSec, Unit unit) => switch (unit) {
  Unit.bytes => fmtRate(perSec),
  Unit.items => '${fmtCount(perSec)}/s',
  Unit.time => '${(perSec / 1e6).toStringAsFixed(1)}×',
};

/// Microseconds as a clock: `0:07`, `4:30`, `1:02:09`.
String fmtClock(int us) {
  final s = us ~/ 1000000;
  final h = s ~/ 3600, m = s ~/ 60 % 60, sec = '${s % 60}'.padLeft(2, '0');
  return h > 0 ? '$h:${'$m'.padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// Bar cells for [done] of [total] over [width] cells: `━━━╸────`, or
/// `###>----` in ASCII. An unknown total draws an empty bar.
String barGlyphs(int done, int? total, int width, {required bool ascii}) {
  if (width <= 0) return '';
  final frac = total == null || total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
  final cells = frac * width;
  final full = cells.floor();
  final half = cells - full >= 0.5 && full < width;
  final (on, mid, off) = ascii ? ('#', '>', '-') : ('━', '╸', '─');
  return '${on * full}${half ? mid : ''}${off * (width - full - (half ? 1 : 0))}';
}

/// Spinner frames, ASCII where the locale is not UTF-8.
List<String> spinFrames({required bool ascii}) => ascii ? _asciiFrames : _brailleFrames;

const _asciiFrames = ['-', '\\', '|', '/'];
const _brailleFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/// Bytes, items or media time per second, as it is now: the rate behind
/// `Meter`, `Console.bar` and the Tui status row.
///
/// Counts go into 100 ms steps; each finished step's rate feeds an
/// exponential moving average with a 1 s time constant, so the speed
/// follows a change within about a second instead of averaging the last
/// few, without jumping with every chunk. The first steps are
/// bias-corrected (the average starts at zero), and 5 s with nothing
/// counted reads 0. O(1) time and memory per count.
final class Window {
  Window([int Function()? clock]) : _clock = clock ?? _monotonic;

  static const _step = 100, _idle = 5000;

  /// Weight of one step: `1 - e^(-step/τ)` with τ = 1 s.
  static final _alpha = 1 - math.exp(-_step / 1000);

  static final _watch = Stopwatch()..start();
  static int _monotonic() => _watch.elapsedMilliseconds;

  final int Function() _clock;
  int? _start; // the open step's start, ms
  var _open = 0; // counted in the open step
  var _avg = 0.0; // per second
  var _weight = 0.0; // 1 - (1 - α)^steps: the bias correction
  var _last = 0; // ms of the last count

  /// Everything counted so far.
  int counted = 0;

  /// Count [n] now; zero or negative is ignored (a counter that went back).
  void add(int n) {
    if (n <= 0) return;
    final now = _clock();
    _roll(now);
    _start ??= now - now % _step;
    _open += n;
    _last = now;
    counted += n;
  }

  /// Per second now (see the class doc); 0 before the first count and
  /// after 5 s with nothing counted.
  double rate() {
    final now = _clock();
    if (_start == null || now - _last >= _idle) return 0;
    _roll(now);
    // Only the open step so far: its rate over the time it has run.
    if (_weight == 0) return _open * 1000 / math.max(now - _start!, _step);
    return _avg / _weight;
  }

  /// Close every step that ended by [now]: the first with what it counted,
  /// the empty ones after it as zeros.
  void _roll(int now) {
    final start = _start;
    if (start == null || now < start + _step) return;
    final steps = (now - start) ~/ _step;
    final keep = 1 - _alpha;
    _avg = _avg * keep + _alpha * _open * 1000 / _step;
    _weight = _weight * keep + _alpha;
    if (steps > 1) {
      final decay = math.pow(keep, steps - 1).toDouble();
      _avg *= decay;
      _weight = 1 - (1 - _weight) * decay;
    }
    _start = start + steps * _step;
    _open = 0;
  }
}
