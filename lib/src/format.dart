/// Shared progress text for `console` and the Tui status row: sizes, rates,
/// counts and bar glyphs, so a bar reads the same in both.
library;

/// A byte count as humans read it: `0 B`, `200.0 KB`, `12.1 MB`.
String fmtSize(num bytes) {
  if (bytes < 1024) return '${bytes.round()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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
