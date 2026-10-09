part of '../core.dart';

/// What [CoerceBridge.coerce] reads a value as.
enum _Kind { any, string, boolean, duration, date, secret, uri, integer, real, number, none }

/// Shared coercion logic for Env, Row, and JsonDocument.
abstract final class CoerceBridge {
  static final _durationRegex = RegExp(r'([+-]?\d+(?:\.\d+)?)\s*(ms|us|µs|s|m|h|d)', caseSensitive: false);
  static final _isoDate = RegExp(
    r'^(\d{4})-(\d\d)-(\d\d)(?:[Tt ](\d\d)(?::?(\d\d)(?::?(\d\d)(?:\.(\d+))?)?)?)?([Zz]|[+-]\d\d:?\d\d)?$',
  );
  static final _thousands = RegExp(r'^[+-]?\d{1,3}(,\d{3})+(\.\d+)?$');
  static final _thousandsDot = RegExp(r'^[+-]?\d{1,3}(\.\d{3})+(,\d+)?$');

  /// Coerces [value] to [T], or returns `null` if it cannot be coerced.
  static T? coerce<T>(Object? value, {String? format, String decimal = '.'}) {
    if (value == null) return null;
    if (value is T) return value as T;
    // Which reading [T] asks for is worked out once per type: rows read it per cell.
    switch (_kinds[T] ??= _kindOf<T>()) {
      case _Kind.any:
        return value as T;
      case _Kind.string:
        return (value is DateTime ? value.toIso8601String() : '$value') as T;
      case _Kind.boolean:
        return _toBool(value) as T?;
      case _Kind.duration:
        return _toDuration(value) as T?;
      case _Kind.date:
        return _toDateTime(value, format: format) as T?;
      case _Kind.secret:
        return value is String ? Secret(value) as T : null;
      case _Kind.uri:
        return value is String && value.trim().isNotEmpty ? Uri.tryParse(value.trim()) as T? : null;
      case _Kind.integer || _Kind.real || _Kind.number:
        final n = _toNum(value, decimal: decimal);
        if (n == null || !n.isFinite) return null;
        return switch (_kinds[T]) {
          _Kind.integer => _integral(n) as T?,
          _Kind.real => n.toDouble() as T,
          _ => n as T,
        };
      case _Kind.none:
        return null;
    }
  }

  static final _kinds = <Type, _Kind>{};

  static _Kind _kindOf<T>() {
    if (_same<T, Object>() || _same<T, dynamic>()) return _Kind.any;
    if (_same<T, String>()) return _Kind.string;
    if (_same<T, bool>()) return _Kind.boolean;
    if (_same<T, Duration>()) return _Kind.duration;
    if (_same<T, DateTime>()) return _Kind.date;
    if (_same<T, Secret>()) return _Kind.secret;
    if (_same<T, Uri>()) return _Kind.uri;
    if (_same<T, int>()) return _Kind.integer;
    if (_same<T, double>()) return _Kind.real;
    if (_same<T, num>()) return _Kind.number;
    return _Kind.none;
  }

  /// Whether [coerce] reads text as [T] at all (`Path` is a `String` here).
  static bool reads<T>() => switch (_kinds[T] ??= _kindOf<T>()) {
    _Kind.any || _Kind.none => false,
    _ => true,
  };

  /// [s] as a key whose plain order is natural order, as `compareNatural` orders them: for `Table`.
  static String naturalKey(String s) => _naturalKey(s);

  static Type _typeOf<X>() => X;
  static bool _same<A, B>() => A == B || A == _typeOf<B?>();

  static bool? _toBool(Object? value) {
    if (value is bool) return value;
    if (value is num) {
      if (value == 1) return true;
      if (value == 0) return false;
      return null;
    }
    if (value is String) {
      return switch (value.trim().toLowerCase()) {
        'true' || '1' || 'yes' || 'y' || 'on' => true,
        'false' || '0' || 'no' || 'n' || 'off' => false,
        _ => null,
      };
    }
    return null;
  }

  static Duration? _toDuration(Object? value) {
    if (value is Duration) return value;
    // A bare number is seconds, as `sleep 90` and `timeout = 90` mean; `90ms` says otherwise.
    if (value is num) return value.isFinite ? Duration(microseconds: (value * 1000000).round()) : null;
    if (value is String) {
      final s = value.trim();
      if (s.isEmpty) return null;
      if (num.tryParse(s) case final n?) return _toDuration(n);
      if (_clock(s) ?? _isoDuration(s) case final d?) return d;

      // Verify the entire non-whitespace string is covered by the matches.
      var totalMicroseconds = 0.0;
      var lastEnd = 0;
      final isNegative = s.startsWith('-');
      var working = s;
      if (isNegative || working.startsWith('+')) working = working.substring(1).trim();

      final nonSignMatches = _durationRegex.allMatches(working).toList();
      if (nonSignMatches.isEmpty) return null;

      for (final m in nonSignMatches) {
        final prefix = working.substring(lastEnd, m.start).trim();
        if (prefix.isNotEmpty) return null;
        lastEnd = m.end;

        final amount = double.tryParse(m.group(1)!);
        if (amount == null) return null;
        final unit = m.group(2)!.toLowerCase();

        final factor = switch (unit) {
          'us' || 'µs' => 1.0,
          'ms' => 1000.0,
          's' => 1000000.0,
          'm' => 60 * 1000000.0,
          'h' => 3600 * 1000000.0,
          'd' => 86400 * 1000000.0,
          _ => 0.0,
        };
        totalMicroseconds += amount * factor;
      }
      final trailing = working.substring(lastEnd).trim();
      if (trailing.isNotEmpty) return null;

      final total = (isNegative ? -totalMicroseconds : totalMicroseconds).round();
      return Duration(microseconds: total);
    }
    return null;
  }

  /// A clock reading, as players and track lists print a length: `3:45` (minutes and seconds),
  /// `1:02:03`, `-0:30`, `4:13.5`.
  static final _clockPattern = RegExp(r'^([+-])?(\d+):([0-5]\d)(?::([0-5]\d))?(\.\d+)?$');

  static Duration? _clock(String s) {
    final m = _clockPattern.firstMatch(s);
    if (m == null) return null;
    final (hours, minutes, seconds) = m[4] == null
        ? (0, int.parse(m[2]!), int.parse(m[3]!))
        : (int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!));
    final micros = ((hours * 3600 + minutes * 60 + seconds + double.parse('0${m[5] ?? ''}')) * 1000000).round();
    return Duration(microseconds: m[1] == '-' ? -micros : micros);
  }

  /// ISO 8601 durations as feeds and APIs write them: `PT4M13S`, `P1DT2H`, `P2W`; years and
  /// months, which have no fixed length, are not read.
  static final _isoDurationPattern = RegExp(
    r'^([+-])?P(?:(\d+(?:[.,]\d+)?)W)?(?:(\d+(?:[.,]\d+)?)D)?(?:T(?:(\d+(?:[.,]\d+)?)H)?(?:(\d+(?:[.,]\d+)?)M)?(?:(\d+(?:[.,]\d+)?)S)?)?$',
    caseSensitive: false,
  );

  static Duration? _isoDuration(String s) {
    final m = _isoDurationPattern.firstMatch(s);
    // `P` and `PT` alone say nothing.
    if (m == null || [2, 3, 4, 5, 6].every((g) => m[g] == null)) return null;
    double part(int g) => m[g] == null ? 0 : double.parse(m[g]!.replaceAll(',', '.'));
    final seconds = part(2) * 604800 + part(3) * 86400 + part(4) * 3600 + part(5) * 60 + part(6);
    final micros = (seconds * 1000000).round();
    return Duration(microseconds: m[1] == '-' ? -micros : micros);
  }

  static DateTime? _toDateTime(Object? value, {String? format}) {
    if (value is DateTime) return value;
    // An epoch: seconds from 1973, else milliseconds.
    if (value is num) {
      if (!value.isFinite) return null;
      final n = value.round();
      if (n < 100000000) return null;
      return DateTime.fromMillisecondsSinceEpoch(n < 100000000000 ? n * 1000 : n, isUtc: true);
    }
    if (value is String) {
      final s = value.trim();
      if (s.isEmpty) return null;

      if (format != null) {
        return _parseFormattedDate(s, format);
      }

      // Digits alone are an epoch, as the same number in JSON is: seconds, or milliseconds.
      if (num.tryParse(s) case final n?) return _toDateTime(n);

      // Check ISO format.
      final m = _isoDate.firstMatch(s);
      if (m != null) {
        final year = int.parse(m[1]!);
        final month = int.parse(m[2]!);
        final day = int.parse(m[3]!);
        if (month >= 1 && month <= 12 && day >= 1 && day <= DateTime.utc(year, month + 1, 0).day) {
          final hour = m[4] != null ? int.parse(m[4]!) : 0;
          final minute = m[5] != null ? int.parse(m[5]!) : 0;
          final second = m[6] != null ? int.parse(m[6]!) : 0;
          if (hour <= 23 && minute <= 59 && second <= 59) {
            // Text without a zone is UTC, as `format:` and RFC dates without one are.
            final micros = int.parse((m[7] ?? '').padRight(6, '0').substring(0, 6));
            final at = DateTime.utc(year, month, day, hour, minute, second, 0, micros);
            final zone = m[8] ?? 'Z';
            if (zone == 'Z' || zone == 'z') return at;
            final digits = zone.replaceAll(':', '');
            final offset = int.parse(digits.substring(1, 3)) * 60 + int.parse(digits.substring(3));
            return at.subtract(Duration(minutes: zone.startsWith('-') ? -offset : offset));
          }
        }
        return null;
      }

      if (_rfc(s) case final rfc?) return rfc;

      // Common fallback formats: dd/MM/yyyy or yyyy/MM/dd
      if (s.contains('/')) {
        return _parseFormattedDate(s, 'dd/MM/yyyy') ?? _parseFormattedDate(s, 'yyyy/MM/dd');
      }
    }
    return null;
  }

  /// The tokens `format:` reads, longest first, each with what it matches.
  static const _dateTokens = [
    ('yyyy', r'(\d{4})'),
    ('yy', r'(\d{2})'),
    ('MMMM', r'(\p{L}+)'),
    ('MMM', r'(\p{L}{3})'),
    ('MM', r'(\d{1,2})'),
    ('dd', r'(\d{1,2})'),
    ('HH', r'(\d{1,2})'),
    ('mm', r'(\d{1,2})'),
    ('ss', r'(\d{1,2})'),
  ];

  /// Each format's pattern and the tokens of its groups, built once per format.
  static final _formats = <String, (RegExp, List<String>)>{};

  static DateTime? _parseFormattedDate(String s, String format) {
    final (regex, tokens) = _formats[format] ??= _formatPattern(format);
    if (tokens.isEmpty) return null;
    final match = regex.firstMatch(s);
    if (match == null) return null;
    var year = 1970, month = 1, day = 1, hour = 0, minute = 0, second = 0;
    for (var i = 0; i < tokens.length; i++) {
      final text = match.group(i + 1)!;
      if (tokens[i] case 'MMMM' || 'MMM') {
        final m = _month(text);
        if (m == null) return null;
        month = m;
        continue;
      }
      final value = int.parse(text);
      switch (tokens[i]) {
        case 'yyyy':
          year = value;
        case 'yy':
          year = 2000 + value;
        case 'MM':
          month = value;
        case 'dd':
          day = value;
        case 'HH':
          hour = value;
        case 'mm':
          minute = value;
        case 'ss':
          second = value;
      }
    }
    if (month < 1 || month > 12 || day < 1 || day > DateTime.utc(year, month + 1, 0).day) return null;
    if (hour > 23 || minute > 59 || second > 59) return null;
    return DateTime.utc(year, month, day, hour, minute, second);
  }

  /// [format] as a pattern: each token a group at its width (so `yyyyMMdd` splits where it was
  /// written), the rest literal.
  static (RegExp, List<String>) _formatPattern(String format) {
    final pattern = StringBuffer('^'), tokens = <String>[];
    outer:
    for (var i = 0; i < format.length;) {
      for (final (token, group) in _dateTokens) {
        if (format.startsWith(token, i)) {
          pattern.write(group);
          tokens.add(token);
          i += token.length;
          continue outer;
        }
      }
      pattern.write(RegExp.escape(format[i++]));
    }
    pattern.write(r'$');
    return (RegExp('$pattern', unicode: true, caseSensitive: false), tokens);
  }

  static const _monthNames = [
    'january', 'february', 'march', 'april', 'may', 'june', //
    'july', 'august', 'september', 'october', 'november', 'december',
  ];

  /// The month [name] names, in English, whole or by its first three letters (`Sept` too).
  static int? _month(String name) {
    final lower = name.toLowerCase();
    if (lower.length < 3) return null;
    for (var i = 0; i < 12; i++) {
      final full = _monthNames[i];
      if (lower == full || lower == full.substring(0, 3) || (lower.length > 3 && full.startsWith(lower))) return i + 1;
    }
    return null;
  }

  /// RFC 1123 / 822 / 850 (`Sun, 06 Nov 1994 08:49:37 GMT`, `Wed, 02 Oct 02 13:00:00 +0200`,
  /// `Sunday, 06-Nov-94 08:49:37 GMT`) and asctime (`Sun Nov  6 08:49:37 1994`), as headers and
  /// feeds write them.
  static final _rfcDate = RegExp(
    r'^(?:[a-z]{3,9},?\s+)?(\d{1,2})[\s-]([a-z]{3,9})\.?[\s-](\d{2}|\d{4})\s+(\d{1,2}):(\d\d)(?::(\d\d))?\s*(gmt|ut|utc|z|[+-]\d\d:?\d\d|[a-z]{3})?$',
    caseSensitive: false,
  );
  static final _asctime = RegExp(
    r'^[a-z]{3}\s+([a-z]{3})\s+(\d{1,2})\s+(\d{1,2}):(\d\d):(\d\d)\s+(\d{4})$',
    caseSensitive: false,
  );

  /// Hours east of UTC for the zones RFC 822 names.
  static const _zones = {
    'gmt': 0, 'ut': 0, 'utc': 0, 'z': 0, 'est': -5, 'edt': -4, 'cst': -6, 'cdt': -5, //
    'mst': -7, 'mdt': -6, 'pst': -8, 'pdt': -7,
  };

  static DateTime? _rfc(String s) {
    if (_asctime.firstMatch(s) case final m?) {
      return _utc(
        int.parse(m[6]!),
        _month(m[1]!),
        int.parse(m[2]!),
        int.parse(m[3]!),
        int.parse(m[4]!),
        int.parse(m[5]!),
        0,
      );
    }
    final m = _rfcDate.firstMatch(s);
    if (m == null) return null;
    var year = int.parse(m[3]!);
    if (m[3]!.length == 2) year += year < 50 ? 2000 : 1900;
    final zone = (m[7] ?? 'gmt').toLowerCase();
    final int? offset; // minutes east of UTC
    if (zone.startsWith('+') || zone.startsWith('-')) {
      final digits = zone.substring(1).replaceAll(':', '');
      final minutes = int.parse(digits.substring(0, 2)) * 60 + int.parse(digits.substring(2));
      offset = zone.startsWith('-') ? -minutes : minutes;
    } else {
      offset = _zones[zone] == null ? null : _zones[zone]! * 60;
    }
    if (offset == null) return null;
    return _utc(
      year,
      _month(m[2]!),
      int.parse(m[1]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6] ?? '0'),
      offset,
    );
  }

  /// The UTC time of a wall-clock reading [offset] minutes east of UTC, or `null` out of range.
  static DateTime? _utc(int year, int? month, int day, int hour, int minute, int second, int offset) {
    if (month == null || day < 1 || day > DateTime.utc(year, month + 1, 0).day) return null;
    if (hour > 23 || minute > 59 || second > 60) return null;
    return DateTime.utc(year, month, day, hour, minute, second).subtract(Duration(minutes: offset));
  }

  static num? _toNum(Object? value, {String decimal = '.'}) {
    if (value is num) return value;
    if (value is String) {
      var text = value.trim();
      if (text.isEmpty) return null;

      // A grouping pattern needs its separator: most cells skip the regex.
      if (decimal == ',') {
        if (text.contains('.') && _thousandsDot.hasMatch(text)) text = text.replaceAll('.', '');
        text = text.replaceAll(',', '.');
      } else if (text.contains(',') && _thousands.hasMatch(text)) {
        text = text.replaceAll(',', '');
      }

      if (_isHexPrefix(text)) return null;
      return num.tryParse(text) ?? _bytes(value.trim(), decimal);
    }
    return null;
  }

  /// A size as pages print it, in binary units as `humanBytes` writes them: `1.5 GB`, `512 B`,
  /// `20MiB`.
  static final _byteSize = RegExp(r'^(.*?\d)\s*([kmgtp]i?)?b$', caseSensitive: false);

  static int? _bytes(String text, String decimal) {
    final m = _byteSize.firstMatch(text);
    if (m == null) return null;
    final n = _toNum(m[1], decimal: decimal);
    if (n == null) return null;
    final power = switch (m[2]?[0].toLowerCase()) {
      null => 0,
      'k' => 1,
      'm' => 2,
      'g' => 3,
      't' => 4,
      _ => 5,
    };
    return (n * pow(1024, power)).round();
  }

  static bool _isHexPrefix(String s) {
    final i = s.startsWith('+') || s.startsWith('-') ? 1 : 0;
    return s.length >= i + 2 && s.codeUnitAt(i) == 0x30 && (s.codeUnitAt(i + 1) | 0x20) == 0x78;
  }

  static int? _integral(num n) => switch (n) {
    final int i => i,
    final double d when d >= -9223372036854775808.0 && d < 9223372036854775808.0 && d == d.truncateToDouble() =>
      d.toInt(),
    _ => null,
  };
}
