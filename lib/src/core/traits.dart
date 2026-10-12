import 'dart:typed_data';

/// Something that ends. A [Reader]'s `close` may throw: a process reports a failed exit there.
abstract interface class Closer {
  Future<void> close();
}

/// Reads bytes into [buf]; `0` means the end.
abstract interface class Reader implements Closer {
  Future<int> read(Uint8List buf);
}

/// Writes [data] in order; [flush] pushes what is buffered. [close] completes the target
/// (a file is renamed into place on close).
abstract interface class Writer implements Closer {
  Future<int> write(Uint8List data);
  Future<void> flush();
}

/// Moves the read position to [offset].
abstract interface class Seeker {
  Future<int> seek(int offset);
}

/// Anything a reading or `pipe` can read: a file, a response, a process's stdout, a page.
/// [from] starts the bytes at an offset (a resumed transfer).
abstract interface class Source {
  Future<Reader> reader({int from = 0});

  /// The body's length when the source knows it (a response's
  /// `content-length`), else null. A sizing hint for streaming sinks, never a
  /// status source.
  int? get lengthHint;
}

/// Anything `pipe` can write: a file, a process's stdin. With `resume`, the writer appends
/// to what [size] reports instead of replacing it.
abstract interface class Target {
  Future<Writer> writer({bool resume = false});
  Future<int> size();
}
