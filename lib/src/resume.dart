/// The private handshake behind `Http.client(resume: true)`: `core`'s
/// `Reader.to` hands a pipeline that ends in a path to its source, which can
/// skip or resume the download itself. Not exported.
library;

import '../core.dart';

/// A source that can deliver itself to a file path (an unsent GET).
abstract interface class Resumable {
  /// Take over before the request is sent; false once it has started.
  bool claim();

  /// Deliver to [path] through [pipes] (all [PassThrough]): skip a complete
  /// file, resume a `.part`, rename into place.
  Future<void> resume(String path, List<Pipe> pipes);
}

/// A pipe whose output is its input (a progress bar, a hasher), so stored
/// bytes can be replayed through it on a skip or a resume.
abstract interface class PassThrough {}
