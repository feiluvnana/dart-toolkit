/// The private handshake behind `Http.client(resume: true)`: `core`'s
/// `Reader >` hands a pipeline that ends in a path to its source, which can
/// skip or resume the download itself. Not exported.
library;

import '../core.dart';
import 'names.dart' show safeName;

/// A source that can deliver itself to a file path (an unsent GET).
abstract interface class Resumable {
  /// Take over before the request is sent; false once it has started.
  bool claim();

  /// Deliver to [to] (a writer with a path, or a [Folder]) through [pipes]
  /// (all [PassThrough]): skip a complete file, resume a `.part`, rename
  /// into place.
  Future<void> resume(Writer to, List<Pipe> pipes);
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

/// A writer that is a folder (fs `Dir`): `Reader >` stores the bytes in
/// its [file] named by the reader's `origin().name()`, resumable or not.
abstract interface class Folder implements Writer {
  /// The file called [name] inside this folder.
  Writer file(String name);
}

/// [folder]'s file for a reader from [origin]: its name, made one safe
/// segment when it is not one already (a separator, `..`).
Writer into(Folder folder, Origin origin) {
  final name = origin.name();
  if (name == null || name.isEmpty) {
    throw ContentException('this reader has no name to store it under in a folder: write to dir.file(name) instead');
  }
  final plain = !name.contains(_separator) && name != '.' && name != '..';
  final safe = plain ? name : safeName(name);
  return folder.file(safe.isEmpty ? '_' : safe);
}

final _separator = RegExp(r'[\\/\x00]');
