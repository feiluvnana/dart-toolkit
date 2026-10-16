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

/// Pass-through pipes that want the full length once the download knows it
/// (a bar created without a total shows `done/total` from then on): the
/// pipe registers a callback here instead of growing a public method.
final sizers = Expando<void Function(int bytes)>();

/// Pass-through pipes that count speed register here how many bytes the
/// next stream replays from disk (a resumed download's `.part`, a skipped
/// complete file), so the rate leaves them out. The resume path calls it
/// right before it starts the pipes.
final replays = Expando<void Function(int bytes)>();
