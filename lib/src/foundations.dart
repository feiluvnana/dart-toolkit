/// Not API: what a topic built on core's foundations re-exports, in place of `core.dart`.
library;

import 'core/errors.dart';

export 'core/errors.dart';

/// The door for an expected absence: `null`, or a default for an expression of
/// several steps. Only a [MissingException] becomes the fallback.
extension Or<T> on T Function() {
  /// This reading's value, or `null` when it throws a [MissingException].
  T? get orNull {
    try {
      return this();
    } on MissingException {
      return null;
    }
  }

  /// This reading's value, or [fallback] when it throws a [MissingException].
  T or(T fallback) {
    try {
      return this();
    } on MissingException {
      return fallback;
    }
  }
}
