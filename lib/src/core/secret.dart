part of '../base.dart';

/// Text that never prints: every `toString`, status, error and log shows `•••`. [reveal] is the
/// only way to the text, so a leak is visible in code review.
///
/// Every credential parameter in the package is a [Secret]: `credentials:`, `password:`,
/// `key:`, proxy logins.
///
/// ```dart
/// final pw = await Console.secret('Password');
/// await Path('x.zip').unarchive(into: 'out', password: pw);
/// final token = Env.get<Secret>('API_TOKEN');
/// ```
///
/// {@category Utilities}
final class Secret {
  final String _text;

  const Secret(this._text);

  /// The text itself.
  String get reveal => _text;

  /// Whether there is no text.
  bool get isEmpty => _text.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! Secret || other._text.length != _text.length) return false;
    // Constant time: how long the comparison takes says nothing about where they differ.
    var diff = 0;
    for (var i = 0; i < _text.length; i++) {
      diff |= _text.codeUnitAt(i) ^ other._text.codeUnitAt(i);
    }
    return diff == 0;
  }

  @override
  int get hashCode => _text.length.hashCode;

  @override
  String toString() => '•••';
}
