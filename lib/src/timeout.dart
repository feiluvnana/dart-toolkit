/// A [TimeoutException] that prints its message once, for people (the
/// stock one prints `after 0:00:30.000000` before it). Shared by `http`
/// and `shell`.
library;

import 'dart:async';

final class Timeout extends TimeoutException {
  Timeout(super.message, super.duration);

  @override
  String toString() => 'TimeoutException: $message';
}
