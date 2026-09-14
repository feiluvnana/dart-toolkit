/// # Shared Extensions
///
/// Small extensions that let the strongly-typed APIs in this library stay
/// concise at the call site. Every public signature takes a real type — a
/// [Uri], a [Duration], a `String` path — and these extensions make producing
/// one a few characters rather than a full constructor call.
library;

import '../format/format.dart';
import '../net/net.dart';
import '../src/json.dart';
import '../src/markup.dart';

/// Turns a URL string into a [Uri].
///
/// Every networking entry point in this library takes a [Uri], matching
/// `package:http`. This keeps call sites short:
///
/// ```dart
/// final res = await Http.get('https://example.com'.url);
/// ```
///
/// The same family as `.path`, `.bytes`, `.date` and `.duration`: *this
/// string, read as something*.
extension UrlString on String {
  /// This string read as a [Uri].
  ///
  /// Strict, the way `Uri.parse` is strict — a relative `'/health'` stays a
  /// relative URI. A *crawl seed* is the lenient conversion, and it is done
  /// for you: `crawl(['<h1>fixture</h1>'])` reads markup as a `data:` URI
  /// without anything here having to guess.
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
/// await delay(250.ms);
/// final timeout = 5.seconds;
/// final overnight = 8.hours;
/// ```
extension DurationInt on int {
  /// This many milliseconds.
  Duration get ms => Duration(milliseconds: this);

  /// This many milliseconds.
  Duration get milliseconds => Duration(milliseconds: this);

  /// This many seconds.
  Duration get s => Duration(seconds: this);

  /// This many seconds.
  Duration get seconds => Duration(seconds: this);

  /// This many minutes.
  Duration get m => Duration(minutes: this);

  /// This many minutes.
  Duration get minutes => Duration(minutes: this);

  /// This many hours.
  Duration get h => Duration(hours: this);

  /// This many hours.
  Duration get hours => Duration(hours: this);

  /// This many days.
  Duration get d => Duration(days: this);

  /// This many days.
  Duration get days => Duration(days: this);
}

/// Quick document parsing extensions on [String].
extension StringParseExtensions on String {
  /// Parses this string as a JSON document cursor.
  Json parseJson() => const JsonFormat().parse(this);

  /// Parses this string as an HTML markup cursor.
  Markup parseHtml() => const HtmlFormat().parse(this);
}

/// Direct document and selector extensions on [Response].
extension ReplyDocumentExtensions on Response {
  /// Parsed HTML markup cursor.
  Markup get html => parse(const HtmlFormat());

  /// jQuery-style selector shorthand over the parsed HTML document.
  Markup $(String selector) => html.$(selector);

  /// Returns all matching elements in the parsed HTML document as a list of [Markup] cursors.
  List<Markup> $$(String selector) => html.$$(selector);

  /// XPath selector shorthand over the parsed HTML document.
  Markup $xpath(String path) => html.$xpath(path);

  /// Reads one typed [field] out of the parsed HTML document.
  ///
  /// ```dart
  /// res.pick(.text('h1'));       // String?
  /// res.pick(.number('.price')); // num?
  /// ```
  ///
  /// The same shorthand relationship `$` has to `html.$`: a reply is read far
  /// more often than it is converted.
  T pick<T>(Field<T> field) => html.pick(field);
}
