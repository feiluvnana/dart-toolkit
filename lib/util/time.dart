/// # Time & Delays (`util.time.*`)
///
/// Delays, timestamps, duration formatting — and the readers back the other
/// way, [TimeAccessor.parse] and [TimeAccessor.span], which are what a `--since`
/// option or a date column in a CSV needs. Delays are always [Duration]; the
/// [DurationInt] extension keeps call sites short (`250.ms`, `2.h`).
library;

import 'dart:async';

// ============================================================================
// TIME & DELAYS (util.time.*)
// ============================================================================

/// Entry point for time helpers, reachable as `util.time`.
///
/// ```dart
/// final clock = util.time.clock();
/// await util.time.wait(250.ms);
/// print(util.time.format(clock.elapsed)); // '00:00'
/// ```
class TimeAccessor {
  /// Creates the accessor. Prefer the shared `util.time` instance.
  const TimeAccessor();

  /// Waits for [duration] without blocking the isolate.
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);

  /// A started [Stopwatch], for measuring elapsed work.
  Stopwatch clock() => Stopwatch()..start();

  /// Formats [duration] as `mm:ss`, or `hh:mm:ss` past an hour.
  ///
  /// A negative duration formats its magnitude behind a `-`, so
  /// `format(-5.s)` is `'-00:05'`. Through 4.0.0 the sign reached the
  /// remainders instead and the result was `'00:-5'` — a script that
  /// subtracted two timestamps in the order it happened to have them printed
  /// something that was not a time at all.
  String format(Duration duration) {
    final sign = duration.isNegative ? '-' : '';
    final total = duration.abs();
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = total.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$sign${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$sign$minutes:$seconds';
  }

  /// A filename-safe timestamp, `yyyyMMdd_HHmmss`.
  ///
  /// Uses [date], or the current local time.
  String stamp([DateTime? date]) {
    final d = date ?? DateTime.now();
    String pad(int value, [int width = 2]) =>
        value.toString().padLeft(width, '0');
    return '${pad(d.year, 4)}${pad(d.month)}${pad(d.day)}'
        '_${pad(d.hour)}${pad(d.minute)}${pad(d.second)}';
  }

  /// An ISO-8601 UTC timestamp for [date], or now.
  String iso([DateTime? date]) =>
      (date ?? DateTime.now()).toUtc().toIso8601String();

  /// A coarse human description of how long ago [past] was.
  ///
  /// Compares against [relativeTo], or now. Future instants report
  /// `'in the future'`.
  String ago(DateTime past, [DateTime? relativeTo]) {
    final diff = (relativeTo ?? DateTime.now()).difference(past);
    if (diff.isNegative) return 'in the future';
    return switch (diff) {
      Duration(inSeconds: final s) when s < 5 => 'just now',
      Duration(inSeconds: final s) when s < 60 => '${s}s ago',
      Duration(inMinutes: final m) when m < 60 => '${m}m ago',
      Duration(inHours: final h) when h < 24 => '${h}h ago',
      Duration(inDays: final d) when d < 30 => '${d}d ago',
      Duration(inDays: final d) when d < 365 => '${d ~/ 30}mo ago',
      Duration(inDays: final d) => '${d ~/ 365}y ago',
    };
  }

  /// Milliseconds since the Unix epoch for [date], or now.
  int epoch([DateTime? date]) =>
      (date ?? DateTime.now()).millisecondsSinceEpoch;

  // --- Reading, the other direction ---

  static final _isoDate = RegExp(r'^\d{4}-(\d{2})-(\d{2})');
  static final _bareDigits = RegExp(r'^\d+$');
  static final _stamp = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(?:[_T]?(\d{2})(\d{2})(\d{2}))?$',
  );
  static final _slashed = RegExp(
    r'^(\d{1,4})[/.](\d{1,2})[/.](\d{1,4})'
    r'(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
  );
  static final _named = RegExp(
    r'^(?:(\d{1,2})\s+([A-Za-z]{3,})|([A-Za-z]{3,})\s+(\d{1,2}))'
    r',?\s+(\d{4})$',
  );
  static const _months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

  /// The [DateTime] [text] names, or `null` when it names none.
  ///
  /// ISO-8601 is tried first, so anything [iso] or `DateTime.toString` wrote
  /// round-trips. Then the loose forms a spreadsheet column or a command line
  /// actually carries:
  ///
  /// | Text | Read as |
  /// | :--- | :--- |
  /// | `2024-03-09T10:15:00Z`, `2024-03-09 10:15` | ISO, as `DateTime.parse` |
  /// | `20240309_101500`, `20240309` | what [stamp] writes |
  /// | `2024/03/09` | year first, because the first group is four digits |
  /// | `09/03/2024`, `09.03.2024` | **day** first — see below |
  /// | `9 Mar 2024`, `Mar 9, 2024` | English month names, long or short |
  ///
  /// A slashed or dotted date with a two-digit first group is read **day
  /// first**: `09/03/2024` is the ninth of March. Month-first is ambiguous
  /// with it and only one of the two can win, so the reader picks the
  /// international order and says so rather than guessing per value.
  ///
  /// Nullable rather than throwing, so a bad cell is a `null` to handle rather
  /// than a `try` to write:
  ///
  /// ```dart
  /// // setup: final row = const {'date': '2026-01-01'};
  /// final since = util.time.parse(row['date'] ?? '') ?? DateTime(2000);
  /// ```
  DateTime? parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    // `DateTime.parse` reads a run of digits as ISO 8601 basic format, so a
    // Unix timestamp came back as a date: '1700000000' was year 170000 with a
    // zero month and day, rolled back to 169999-11-30. Eight digits is the
    // longest a bare date can be (`yyyyMMdd`); anything longer is not one.
    if (_bareDigits.hasMatch(trimmed) && trimmed.length != 8) return null;

    final iso = DateTime.tryParse(trimmed);
    // `DateTime.parse` rolls an out-of-range field forward, so '2024-13-01'
    // silently becomes January 2025. A date that came back describing a
    // different month or day than the text did was never a real one.
    if (iso != null) {
      if (_isoDate.firstMatch(trimmed) case final m?) {
        final month = int.parse(m.group(1)!);
        final day = int.parse(m.group(2)!);
        final local = iso.isUtc ? iso.toLocal() : iso;
        if ((iso.month != month || iso.day != day) &&
            (local.month != month || local.day != day)) {
          return null;
        }
      }
      return iso;
    }

    if (_stamp.firstMatch(trimmed) case final m?) {
      return _build(
        m.group(1)!,
        m.group(2)!,
        m.group(3)!,
        m.group(4),
        m.group(5),
        m.group(6),
      );
    }

    if (_slashed.firstMatch(trimmed) case final m?) {
      final first = m.group(1)!;
      final third = m.group(3)!;
      // Four digits can only be the year, and that settles the order without
      // a guess. Otherwise the day leads, which is stated in the doc above.
      final (year, day) = first.length == 4 ? (first, third) : (third, first);
      return _build(year, m.group(2)!, day, m.group(4), m.group(5), m.group(6));
    }

    if (_named.firstMatch(trimmed) case final m?) {
      final day = m.group(1) ?? m.group(4)!;
      final name = (m.group(2) ?? m.group(3)!).toLowerCase();
      final month = _months.indexWhere(name.startsWith);
      if (month == -1) return null;
      return _build(m.group(5)!, '${month + 1}', day, null, null, null);
    }

    return null;
  }

  static DateTime? _build(
    String year,
    String month,
    String day,
    String? hour,
    String? minute,
    String? second,
  ) {
    final y = int.tryParse(year);
    final mo = int.tryParse(month);
    final d = int.tryParse(day);
    if (y == null || mo == null || d == null) return null;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final built = DateTime(
      y,
      mo,
      d,
      int.tryParse(hour ?? '') ?? 0,
      int.tryParse(minute ?? '') ?? 0,
      int.tryParse(second ?? '') ?? 0,
    );
    // DateTime rolls a 31st of February forward into March rather than
    // refusing it, so a date that came back different was never a real one.
    return built.month == mo && built.day == d ? built : null;
  }

  static final _units = RegExp(r'(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)?');

  /// The [Duration] [text] names, or `null` when it names none.
  ///
  /// The units a timeout is written in — `ms`, `s`, `m`, `h`, `d`, `w` — and
  /// as many of them at once as you like: `'1h30m'`, `'2d 12h'`, `'250ms'`.
  /// Decimals are allowed (`'1.5h'`), and a bare number means seconds, so
  /// `--timeout 30` works.
  ///
  /// ```dart
  /// // setup: final row = const {'retry_after': '30s'};
  /// final wait = util.time.span(row['retry_after'] ?? '') ?? 30.s;
  /// ```
  Duration? span(String text) {
    final trimmed = text.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    final matches = _units.allMatches(trimmed);
    if (matches.isEmpty) return null;
    // Anything the unit pattern did not claim means this was not a duration —
    // `'tomorrow'` and `'5 apples'` should read as null, not as five seconds.
    var covered = 0;
    var micros = 0.0;
    for (final match in matches) {
      covered += match.group(0)!.replaceAll(' ', '').length;
      final value = double.tryParse(match.group(1)!);
      if (value == null) return null;
      micros +=
          value *
          switch (match.group(2)) {
            'ms' => 1000,
            null || 's' => 1000 * 1000,
            'm' => 60 * 1000 * 1000,
            'h' => 60 * 60 * 1000 * 1000,
            'd' => 24 * 60 * 60 * 1000 * 1000,
            _ => 7 * 24 * 60 * 60 * 1000 * 1000,
          };
    }
    if (covered != trimmed.replaceAll(' ', '').length) return null;
    return Duration(microseconds: micros.round());
  }

  /// [date] truncated to midnight, keeping its UTC or local flag.
  ///
  /// The grouping primitive: a daily rollup is one call, where `dart:core` has
  /// no one-liner for it.
  ///
  /// ```dart
  /// rows.collect(.group.by((r) => util.time.day(r.seen)));
  /// ```
  DateTime day(DateTime date) => date.isUtc
      ? DateTime.utc(date.year, date.month, date.day)
      : DateTime(date.year, date.month, date.day);
}
