/// The error table's security signal: an operation that would escape its
/// sandbox (a zip-slip member, a symlink pointing outside the root, an
/// untrusted archive entry). Thrown before anything is written.
final class SecurityException implements Exception {
  /// What was refused, naming the offending entry or path.
  final String message;

  const SecurityException(this.message);

  @override
  String toString() => 'SecurityException: $message';
}

/// A reading found nothing: a key, a member, an entry. `Missing <what>`
/// `[in <where>]`. The only error a reading's `or:` answers for.
final class MissingException implements Exception {
  /// What was not there.
  final String what;

  /// Where it was looked for, when that says more than [what].
  final String? where;

  const MissingException(this.what, {this.where});

  /// ``Missing <what> [in <where>]``.
  String get message => where == null ? 'Missing $what' : 'Missing $what in $where';

  @override
  String toString() => message;
}
