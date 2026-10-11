import 'dart:typed_data';

/// Baseline readable byte source: everything that can produce bytes implements it.
abstract interface class Reader {
  /// Fills [buf] with the next bytes and answers how many were written. `0` means end.
  Future<int> read(Uint8List buf);
}

/// Baseline writable byte sink: files, sockets, subprocess stdin, hash writers.
///
/// The [write] contract is precise: a `String` is UTF-8 encoded, a `List<int>` /
/// `Uint8List` is written verbatim, and anything else is an [ArgumentError].
/// Sinks must not stringify unknown objects.
abstract interface class Writer {
  /// Writes [data] (a `String`, `List<int>` or `Uint8List`).
  Future<int> write(Object data);

  /// Flushes anything buffered.
  Future<void> flush();
}

/// Resource that can be closed.
abstract interface class Closer {
  Future<void> close();
}

/// Stream or file that supports seeking.
abstract interface class Seeker {
  /// Moves to [offset] and answers the new position.
  Future<int> seek(int offset);
}
