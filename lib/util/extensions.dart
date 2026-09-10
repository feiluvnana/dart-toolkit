/// # Shared Extensions
///
/// Small extensions that let the strongly-typed APIs in this library stay
/// concise at the call site. Every public signature takes a real type — a
/// [Uri], a [Duration], a `String` path — and these extensions make producing
/// one a few characters rather than a full constructor call.
library;

/// Turns a URL string into a [Uri].
///
/// Every networking entry point in this library takes a [Uri], matching
/// `package:http`. This keeps call sites short:
///
/// ```dart
/// final res = await net.get('https://example.com'.url);
/// ```
extension UrlString on String {
  /// Parses this string as a [Uri].
  ///
  /// Throws [FormatException] if the string is not a valid URI.
  Uri get url => Uri.parse(this);
}

/// Builds a [Duration] from a plain number.
///
/// Delays and timeouts are always typed as [Duration]; these getters keep
/// them readable:
///
/// ```dart
/// await util.time.wait(250.ms);
/// net.crawl('https://example.com').delay(2.s);
/// final overnight = 8.h;
/// ```
extension DurationInt on int {
  /// This many milliseconds.
  Duration get ms => Duration(milliseconds: this);

  /// This many seconds.
  Duration get s => Duration(seconds: this);

  /// This many minutes.
  Duration get m => Duration(minutes: this);

  /// This many hours.
  Duration get h => Duration(hours: this);

  /// This many days.
  Duration get d => Duration(days: this);
}
