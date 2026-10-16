/// Helpers beside the core, one separate import (no module re-exports it):
/// unit literals, human sizes and times, pacing, cookie jars and hashes.
///
/// ```dart
/// final http = Http.client(rate: Rate(4, 1.seconds), cookies: await Fs.file('.session').cookies(or: Cookies()));
/// print('${bytes.size()} in ${took.human()} at ${DateTime.now().format('HH:mm')}');
/// await (http.get(isoUrl) | HashUtils.sha256(expect: sum) > Fs.file('disc.iso')); // a mismatch never lands
/// final h = HashUtils.sha256(); await (Fs.file('disc.iso') > h); print(h.hex());  // a file's digest
/// final id = HashUtils.md5().add(url).hex();
/// final sig = HashUtils.sha256(key: utf8.encode(secret)).add(body).hex();       // HMAC
/// ```
///
/// Public surface is exactly: [DurationUtils], [SizeUtils], [TimeUtils],
/// [SpanUtils], [Rate], [Cookies], [ReaderCookies], [ReaderFutureCookies],
/// [HashUtils], [Hasher].
/// - [DurationUtils]: `3.seconds`, `11.minutes`: unit literals for every timeout.
/// - [SizeUtils]: `bytes.size()` (`12.1 MB`).
/// - [TimeUtils]: `now.format('yyyy-MM-dd')`; [SpanUtils]: `wait.human()` (`11 min 5 s`).
/// - [Rate]: paces the work that shares it (`wait`; `perHost:` paces each host apart).
/// - [Cookies]: a jar shared by `chrome` and `http`: `parse` `encode` `[]` `set`;
///   `reader.cookies(or:)` reads a `cookies.txt` session from any reader.
/// - [HashUtils]: `md5` `sha1` `sha256` `sha512` make a [Hasher]; on md5 and
///   sha256 `key:` makes it an HMAC and `expect:` checks the digest.
/// - [Hasher]: `add` (text) `addBytes` `hex` `bytes`. As a [Writer] it
///   digests a stream; as a [Pipe] it forwards unchanged and digests, so
///   `reader | hasher > file` stores and checksums in one pass.
/// Everything else is private.
///
/// {@canonicalFor cookies.Cookies}
/// {@canonicalFor format.SizeUtils}
/// {@canonicalFor hash.HashUtils}
/// {@canonicalFor hash.Hasher}
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
export 'src/hash.dart' show HashUtils, Hasher;
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
