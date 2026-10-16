/// What one archive may make the in-memory decoders (7z, RAR) do, whatever
/// its headers claim: a 3 KB file must not ask for gigabytes or a minute of
/// key rounds. Fixed limits, no option.
library;

import '../core.dart';

final class Budget {
  /// Bytes all members decode to together. Past it the archive goes to
  /// 7-Zip, which streams to disk (the message starts with `unsupported`,
  /// as for a method the Dart decoders lack).
  static const output = 1 << 30;

  /// Members in one archive.
  static const entries = 1 << 22;

  /// Key-derivation rounds (7z SHA-256, RAR5 PBKDF2) over the archive.
  static const rounds = 1 << 26;

  var _output = 0, _rounds = 0;

  /// [bytes] more of declared output for [what].
  void take(int bytes, String what) {
    _output += bytes;
    if (bytes < 0 || _output > output) {
      throw ContentException('unsupported in memory: $what decodes past ${output >> 30} GiB');
    }
  }

  /// [n] members.
  void count(int n, String what) {
    if (n < 0 || n > entries) throw ContentException('corrupt archive: $what claims $n members');
  }

  /// One key derivation of [n] rounds for [what].
  void kdf(int n, String what) {
    _rounds += n;
    if (_rounds > rounds) throw ContentException('corrupt archive: $what asks for more than 2^26 key rounds');
  }
}
