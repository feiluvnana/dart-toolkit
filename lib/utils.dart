/// Helpers beside the core, one separate import (no module re-exports it):
/// unit literals, human sizes and times, pacing and cookie jars.
///
/// ```dart
/// final http = Http.client(rate: Rate(4, 1.seconds), cookies: await Fs.file('.session').cookies(or: Cookies()));
/// print('${bytes.size()} in ${took.human()} at ${DateTime.now().format('HH:mm')}');
/// ```
///
/// Public surface is exactly: [DurationUtils], [SizeUtils], [TimeUtils],
/// [SpanUtils], [Rate], [Cookies], [ReaderCookies], [ReaderFutureCookies].
/// - [DurationUtils]: `3.seconds`, `11.minutes`: unit literals for every timeout.
/// - [SizeUtils]: `bytes.size()` (`12.1 MB`).
/// - [TimeUtils]: `now.format('yyyy-MM-dd')`; [SpanUtils]: `wait.human()` (`11 min 5 s`).
/// - [Rate]: paces the work that shares it (`wait`; `perHost:` paces each host apart).
/// - [Cookies]: a jar shared by `chrome` and `http`: `parse` `encode` `[]` `set`;
///   `reader.cookies(or:)` reads a `cookies.txt` session from any reader.
/// Everything else is private.
///
/// {@canonicalFor cookies.Cookies}
/// {@canonicalFor format.SizeUtils}
/// {@canonicalFor rate.Rate}
/// {@canonicalFor time.DurationUtils}
/// {@canonicalFor time.SpanUtils}
/// {@canonicalFor time.TimeUtils}
library;

import 'dart:io' show PathNotFoundException;

import 'core.dart';
import 'src/cookies.dart';

export 'src/cookies.dart' show Cookies;
export 'src/format.dart' show SizeUtils;
export 'src/rate.dart' show Rate;
export 'src/time.dart' show DurationUtils, SpanUtils, TimeUtils;

/// `reader.cookies()`: a Netscape `cookies.txt` session from any [Reader].
extension ReaderCookies on Reader {
  /// The session in this reader (see [Cookies.parse]); [or] when the source
  /// does not exist (a first run, before any login).
  ///
  /// ```dart
  /// final jar = await Fs.file('.ins.session').cookies(or: Cookies());
  /// ```
  Future<Cookies> cookies({Cookies? or}) async {
    try {
      return Cookies.parse(await text());
    } on PathNotFoundException {
      if (or != null) return or;
      rethrow;
    }
  }
}

/// The Future mirror (rule 4).
extension ReaderFutureCookies on Future<Reader> {
  Future<Cookies> cookies({Cookies? or}) async => (await this).cookies(or: or);
}
