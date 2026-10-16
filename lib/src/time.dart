/// Time for people (exported by `utils`): unit literals (`3.seconds`),
/// `DateTime.format` for file names and logs, `Duration.human` for waits
/// and timeouts.
library;

/// Unit literals: `3.seconds`, `1.5.seconds`, `250.milliseconds`,
/// `11.minutes`. Fractions round to the microsecond.
extension DurationUtils on num {
  /// This many milliseconds.
  Duration get milliseconds => _us(Duration.microsecondsPerMillisecond);

  /// This many seconds.
  Duration get seconds => _us(Duration.microsecondsPerSecond);

  /// This many minutes.
  Duration get minutes => _us(Duration.microsecondsPerMinute);

  /// This many hours.
  Duration get hours => _us(Duration.microsecondsPerHour);

  /// This many days.
  Duration get days => _us(Duration.microsecondsPerDay);

  Duration _us(int per) => Duration(microseconds: this is int ? (this as int) * per : (this * per).round());
}

/// `DateTime.now().format('yyyy-MM-dd_HHmm')`.
extension TimeUtils on DateTime {
  /// [pattern] with `yyyy` `MM` `dd` `HH` `mm` `ss` `SSS` replaced by this
  /// time's zero-padded fields; every other character is kept as it is.
  String format(String pattern) {
    final out = StringBuffer();
    String pad(int v, int width) => '$v'.padLeft(width, '0');
    for (var i = 0; i < pattern.length;) {
      if (pattern.startsWith('yyyy', i)) {
        out.write(pad(year, 4));
        i += 4;
      } else if (pattern.startsWith('SSS', i)) {
        out.write(pad(millisecond, 3));
        i += 3;
      } else {
        final two = i + 2 <= pattern.length ? pattern.substring(i, i + 2) : '';
        final field = switch (two) {
          'MM' => month,
          'dd' => day,
          'HH' => hour,
          'mm' => minute,
          'ss' => second,
          _ => null,
        };
        if (field != null) {
          out.write(pad(field, 2));
          i += 2;
        } else {
          out.write(pattern[i++]);
        }
      }
    }
    return out.toString();
  }
}

/// `5.minutes.human()` → `'5 min'`.
extension SpanUtils on Duration {
  /// This span as a person says it, two units at most: `850 ms`, `4.2 s`,
  /// `11 min 5 s`, `2 h 3 min`, `3 d 4 h`.
  String human() {
    if (isNegative) return '-${(-this).human()}';
    final ms = inMilliseconds;
    if (ms < 1000) return '$ms ms';
    if (ms < 60000) {
      final s = (ms / 1000).toStringAsFixed(1);
      return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} s';
    }
    String two(int big, String a, int small, String b) => small == 0 ? '$big $a' : '$big $a $small $b';
    if (inHours < 1) return two(inMinutes, 'min', inSeconds % 60, 's');
    if (inDays < 1) return two(inHours, 'h', inMinutes % 60, 'min');
    return two(inDays, 'd', inHours % 24, 'h');
  }
}
