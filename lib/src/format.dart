/// Shared progress text for `console` and the Tui status row: sizes, rates,
/// counts and bar glyphs, so a bar reads the same in both; and the rate
/// meter behind `Speed`, `Console.bar` and the status row.
library;

import 'dart:collection';

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

/// Bytes or items per second over the last 5 seconds: the meter behind
/// `Speed`, `Console.bar` and the Tui status row. Counts in 100 ms buckets,
/// so memory stays at 50 samples whatever the traffic.
final class Meter {
  Meter([int Function()? clock]) : _clock = clock ?? _monotonic;

  static const _window = 5000, _bucket = 100;
  static final _watch = Stopwatch()..start();
  static int _monotonic() => _watch.elapsedMilliseconds;

  final int Function() _clock;
  final _samples = ListQueue<(int, int)>(); // (bucket start ms, count)
  int? _first;

  /// Everything counted so far.
  int counted = 0;

  /// Count [n] now; zero or negative is ignored (a counter that went back).
  void add(int n) {
    if (n <= 0) return;
    final now = _clock();
    _first ??= now;
    counted += n;
    final last = _samples.isEmpty ? null : _samples.last;
    if (last != null && now - last.$1 < _bucket) {
      _samples
        ..removeLast()
        ..add((last.$1, last.$2 + n));
    } else {
      _samples.add((now, n));
    }
    _trim(now);
  }

  /// Per second over the last 5 s, or over the time since the first count
  /// when shorter (at least 1 s, so a first burst is not a spike); 0 after
  /// 5 s with nothing counted.
  double rate() {
    final first = _first;
    if (first == null) return 0;
    final now = _clock();
    _trim(now);
    if (_samples.isEmpty) return 0;
    var sum = 0;
    for (final (_, n) in _samples) {
      sum += n;
    }
    final span = (now - first).clamp(1000, _window);
    return sum * 1000 / span;
  }

  void _trim(int now) {
    while (_samples.isNotEmpty && now - _samples.first.$1 >= _window) {
      _samples.removeFirst();
    }
  }
}
