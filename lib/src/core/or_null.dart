part of '../core.dart';

/// The door for an absence that a reading's own `or:` does not cover: `null`, or a default for an
/// expression of several steps.
///
/// Every reading in the package is total — `T` in, `T` out, or a [MissingException] naming what was
/// absent. A reading that answers for one named thing takes a default itself
/// (`a.attr('title', or: '')`, `Env.get('PORT', or: 8080)`); this wraps any other in a thunk so the
/// caller can answer for the absence, and so no member carries a `…OrNull` twin.
///
/// ```dart
/// final src = (() => song.html.$('a[href*=".mp3"]').link).orNull; // Uri?
/// final cover = (() => card.$('img').link).or(placeholder);      // Uri
/// ```
///
/// A thunk, not the value, because a getter evaluates eagerly: `els.link.orNull` would throw
/// before `orNull` runs. The thunk defers it.
///
/// [orNull] is for an expected absence and returns `T?`. [or] is for a default that differs and
/// returns that default's own type — `or('')` is a `String`, `or(0)` an `int` — so nothing needs a
/// type argument at the call site. Its default is required and **non-null**: a default that does
/// not fit the reading does not compile, and `or(null)` does not compile either, so the absence
/// door is [orNull] and there is no spelling that silently answers `null` for a value that was
/// there.
///
/// Only a [MissingException] — the package's one signal that a value was absent — or a
/// [PathNotFoundException] — a file that is not there — becomes the fallback:
/// `await (() => 'config.json'.path.readText()).or('{}')` is never a racy `exists()` check. A [FormatException] from a malformed document or an unreadable value, an
/// [ArgumentError] from a bad type argument and an [UnsupportedError] from a missing native
/// library all travel on, so a broken document is never silently skipped — and a bug in the
/// reader's own code is not read as an absence either.
///
/// {@category Utilities}
extension Or<T> on T Function() {
  /// This reading's value, or `null` when it throws a [MissingException] — for an expected absence.
  T? get orNull {
    try {
      return this();
    } on MissingException {
      return null;
    } on PathNotFoundException {
      return null;
    }
  }

  /// This reading's value, or [fallback] when it throws a [MissingException] — for a default that
  /// differs. [fallback] is required, and must be a [T]: it is the answer's own type, so
  /// `(() => a.attr('title')).or('')` is a `String` and a default that does not fit does not
  /// compile.
  ///
  /// A value that is present is returned as it is, whatever its type: the fallback is for an
  /// absence, never for a value that does not fit. An untyped reading (`(() => Env.get('PORT'))
  /// .or(8080)`) therefore answers the `String` it read, and `final int port = …` fails to
  /// compile rather than running on the default.
  T or(T fallback) {
    try {
      return this();
    } on MissingException {
      return fallback;
    } on PathNotFoundException {
      return fallback;
    }
  }
}

/// The same two doors for an async reading, whose absence arrives in the [Future] rather than at
/// the call, so only an awaited door can see it.
///
/// ```dart
/// final text = await (() => page.text(sel)).orNull;
/// final title = await (() => page.attr(sel, 'title')).or('');
/// ```
///
/// {@category Utilities}
extension AwaitOr<T> on Future<T> Function() {
  /// This reading's value, or `null` when the [Future] throws a [MissingException].
  Future<T?> get orNull async {
    try {
      return await this();
    } on MissingException {
      return null;
    } on PathNotFoundException {
      return null;
    }
  }

  /// This reading's value, or [fallback] when the [Future] throws a [MissingException]. [fallback] may
  /// be a [FutureOr], so a plain value reads as one.
  Future<T> or(FutureOr<T> fallback) async {
    try {
      return await this();
    } on MissingException {
      return await fallback;
    } on PathNotFoundException {
      return await fallback;
    }
  }
}
