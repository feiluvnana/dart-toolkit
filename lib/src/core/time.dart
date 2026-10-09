part of '../base.dart';

final _random = Random();

/// A [TimeoutException] that says its subject and limit once, `https://x timed out after 1m`, where
/// Dart's own puts `TimeoutException after 0:01:00.000000:` before any message. Not API: the
/// libraries that time things out throw it; callers catch [TimeoutException].
final class TimeoutBridge extends TimeoutException {
  TimeoutBridge(String subject, Duration limit) : super('$subject timed out after ${limit.humanized}', limit);

  @override
  String toString() => 'TimeoutException: $message';
}

/// Formatting on [DateTime].
///
/// {@category Utilities}
extension DateTimeExtensions on DateTime {
  /// This time written by [pattern], with the tokens `to<DateTime>(format:)` reads: `yyyy`, `yy`,
  /// `MM`, `dd`, `HH`, `mm`, `ss`, each zero-padded, and the English month as `MMM` (`Oct`) or
  /// `MMMM` (`October`); anything else is copied as it is.
  ///
  /// ```dart
  /// stamp.format('yyyy-MM-dd HH:mm');    // 2026-10-08 14:05
  /// '08/10/2026'.to<DateTime>(format: 'dd/MM/yyyy').format('yyyyMMdd');
  /// ```
  String format(String pattern) {
    final out = StringBuffer();
    String two(int n) => n < 10 ? '0$n' : '$n';
    for (var i = 0; i < pattern.length;) {
      final rest = pattern.length - i;
      final c = pattern.codeUnitAt(i);
      final pair = rest >= 2 && pattern.codeUnitAt(i + 1) == c;
      if (c == 0x4d /* M */ && rest >= 3 && pattern.startsWith('MMM', i)) {
        final name = CoerceBridge._monthNames[month - 1];
        final full = rest >= 4 && pattern.codeUnitAt(i + 3) == 0x4d;
        out.write(name[0].toUpperCase() + (full ? name.substring(1) : name.substring(1, 3)));
        i += full ? 4 : 3;
        continue;
      }
      if (c == 0x79 /* y */ && pair) {
        if (rest >= 4 && pattern.startsWith('yy', i + 2)) {
          out.write('$year'.padLeft(4, '0'));
          i += 4;
        } else {
          out.write(two(year % 100));
          i += 2;
        }
        continue;
      }
      final value = !pair
          ? null
          : switch (c) {
              0x4d => month, // M
              0x64 => day, // d
              0x48 => hour, // H
              0x6d => minute, // m
              0x73 => second, // s
              _ => null,
            };
      if (value == null) {
        out.writeCharCode(c);
        i++;
      } else {
        out.write(two(value));
        i += 2;
      }
    }
    return '$out';
  }
}

/// Formatting, jitter and cancellable waits on [Duration].
///
/// {@category Utilities}
extension DurationExtensions on Duration {
  /// A human-readable form, rounded to what it shows: `125ms`, `1.9s` under ten seconds, `45s`,
  /// `2m 15s`, `1h 5m 2s`, and days with hours past a day: `2d 2h`. It reads back as a
  /// [Duration] through `to<Duration>()`.
  String get humanized {
    if (isNegative) return '-${(-this).humanized}';
    final ms = (inMicroseconds / 1000).round();
    if (ms < 1000) return '${ms}ms';
    final tenths = (inMicroseconds / 100000).round();
    if (tenths < 100) return tenths % 10 == 0 ? '${tenths ~/ 10}s' : '${tenths / 10}s';
    final total = (inMicroseconds / 1000000).round();
    if (total >= 86400) {
      final hours = (inMicroseconds / 3600000000).round();
      return ['${hours ~/ 24}d', if (hours % 24 > 0) '${hours % 24}h'].join(' ');
    }
    final hours = total ~/ 3600, minutes = total ~/ 60 % 60, seconds = total % 60;
    return [
      if (hours > 0) '${hours}h',
      if (minutes > 0) '${minutes}m',
      if (seconds > 0 || (hours == 0 && minutes == 0)) '${seconds}s',
    ].join(' ');
  }

  /// This duration scaled by a random factor in `[1 - factor, 1 + factor]`.
  Duration jittered([double factor = 0.25]) {
    final variance = (_random.nextDouble() * 2 - 1) * factor.clamp(0.0, 1.0);
    return Duration(microseconds: max(0, (inMicroseconds * (1 + variance)).round()));
  }

  /// Waits this long, or throws [CancelledException] as soon as the enclosing [Cancel.scope] is
  /// cancelled.
  Future<void> delay() {
    final token = Cancel.token;
    if (token == null) return Future<void>.delayed(this);
    if (token.isCancelled) return Future.error(CancelledException.of(token));
    final done = Completer<void>();
    final timer = Timer(this, done.complete);
    final unregister = token.onCancel(() {
      timer.cancel();
      if (!done.isCompleted) done.completeError(CancelledException.of(token));
    });
    return done.future.whenComplete(unregister);
  }
}
