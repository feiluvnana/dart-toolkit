part of '../message.dart';

/// A media type, checked when made: `type/subtype` with optional `; name=value` parameters, or a
/// `type/` prefix, which is what a download's `accept:` matches. It is a [String], so it goes
/// wherever a content type does.
///
/// ```dart
/// final page = 'text/html; charset=utf-8'.mime;
/// page.charset;                                   // utf-8
/// 'image/'.mime.matches('image/png');             // true
/// ```
///
/// {@category Networking}
extension type const Mime._(String _text) implements String {
  /// [text] as a media type; anything but `type/subtype`, `type/` or `*/*`, with optional
  /// parameters, is a [FormatException].
  Mime(String text) : _text = text {
    final cut = text.indexOf(';');
    final essence = (cut == -1 ? text : text.substring(0, cut)).trim();
    if (!_mimeEssence.hasMatch(essence)) {
      throw FormatException('Invalid media type: "$text", expected type/subtype or type/', text);
    }
    if (cut != -1) {
      for (final param in text.substring(cut + 1).split(';')) {
        if (param.trim().isEmpty) continue;
        if (!_mimeParam.hasMatch(param.trim())) {
          throw FormatException('Invalid media type: "$text", parameter "${param.trim()}" is not name=value', text);
        }
      }
    }
  }

  String get _essence => (_text.contains(';') ? _text.substring(0, _text.indexOf(';')) : _text).trim().toLowerCase();

  /// The top-level type, lowercase: `text` for `text/html`.
  String get type => _essence.substring(0, _essence.indexOf('/'));

  /// The subtype, lowercase: `html` for `text/html`, `''` for a `type/` prefix.
  String get subtype => _essence.substring(_essence.indexOf('/') + 1);

  /// The `charset` parameter, unquoted, or `null`.
  String? get charset {
    for (final param in _text.split(';').skip(1)) {
      final eq = param.indexOf('=');
      if (eq == -1 || param.substring(0, eq).trim().toLowerCase() != 'charset') continue;
      final value = param.substring(eq + 1).trim();
      return value.length >= 2 && value.startsWith('"') && value.endsWith('"')
          ? value.substring(1, value.length - 1)
          : value;
    }
    return null;
  }

  /// Whether [contentType] (a header's value, parameters and all) is of this type: the same
  /// type and subtype ignoring case, any subtype for a `type/` prefix or `type/*`, anything for
  /// `*/*`. An unreadable [contentType] matches nothing.
  bool matches(String contentType) {
    final other = contentType.split(';').first.trim().toLowerCase();
    final slash = other.indexOf('/');
    if (slash <= 0) return false;
    if (type == '*') return true;
    if (other.substring(0, slash) != type) return false;
    return subtype.isEmpty || subtype == '*' || other.substring(slash + 1) == subtype;
  }
}

/// RFC 9110's token characters, for a type, a subtype and a parameter name.
const _mimeToken = r"[!#$%&'*+.^_`|~0-9A-Za-z-]+";
final _mimeEssence = RegExp('^$_mimeToken/(?:$_mimeToken)?\$');
final _mimeParam = RegExp('^$_mimeToken\\s*=\\s*(?:$_mimeToken|"(?:[^"\\\\]|\\\\.)*")\$');

/// Text read as a [Mime].
///
/// {@category Networking}
extension StringMime on String {
  /// This text checked as a media type: `'image/'.mime`. Anything else is a [FormatException].
  Mime get mime => Mime(this);
}
