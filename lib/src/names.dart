/// One portable-file-name rule set, shared by `fs` (`Fs.sanitize`) and the
/// network file names in `src/origin.dart`, plus [redact] for messages
/// (light enough for `json` to import).
library;

import 'dart:convert';

/// [name] as one segment safe to create on Linux, macOS and Windows:
/// separators and reserved characters (`<>:"|?*`, controls) become `_`,
/// trailing dots and spaces go, a reserved device name (`CON`, `NUL`, …)
/// or a leading `.`/`-` (a dotfile, an option) gets a `_` prefix, and the
/// result is at most 255 UTF-8 bytes. Empty when nothing usable is left.
String safeName(String name) {
  var s = name.replaceAll(_unsafe, '_').trim().replaceAll(_trailing, '');
  if (s.isEmpty) return '';
  if (isReserved(s) || s.startsWith('.') || s.startsWith('-')) s = '_$s';
  if (utf8.encode(s).length > 255) {
    final out = StringBuffer();
    var bytes = 0;
    for (final r in s.runes) {
      final n = r < 0x80
          ? 1
          : r < 0x800
          ? 2
          : r < 0x10000
          ? 3
          : 4;
      if (bytes + n > 255) break;
      bytes += n;
      out.writeCharCode(r);
    }
    s = out.toString().replaceAll(_trailing, '');
  }
  return s;
}

/// The last path segment of `a/b\\c`, made portable by [safeName]. Empty
/// when nothing usable is left (callers fall back to `download`/`upload`).
/// Used for header filenames and upload staging alike.
String stripPath(String name) => safeName(name.split(_separator).last);

final _separator = RegExp(r'[\\/]');

final _unsafe = RegExp(r'[\\/<>:"|?*\x00-\x1f\x7f]');
final _trailing = RegExp(r'[. ]+$');

/// A Windows device name, with or without an extension: `CON`, `PRN`,
/// `AUX`, `NUL`, `COM0`–`COM9`, `LPT0`–`LPT9` (superscript ¹²³ too),
/// `CONIN$`, `CONOUT$`; spaces before the extension do not help
/// (`nul .txt`).
bool isReserved(String name) => _reserved.hasMatch(name);

final _reserved = RegExp(
  r'^(con|prn|aux|nul|com[0-9\u00b9\u00b2\u00b3]|lpt[0-9\u00b9\u00b2\u00b3]|conin\$|conout\$) *(\..*)?$',
  caseSensitive: false,
);

/// [url] fit for an error message or log: no `user:password@`, the values
/// of credential parameters in the query and the fragment
/// (`#access_token=`) shown as `***`, and so are path tokens: a Telegram
/// `bot<id>:<token>` segment and what follows a `webhooks` segment or
/// Slack's `hooks.slack.com/services`. Only exact secret names count
/// (`token`, `access_token`, `key`, `api_key`, `code`, `auth`, `password`,
/// `secret`, `sig`, `signature`, `session`, … and AWS/GCS signing
/// parameters), so `shortcode`, `keyword` and `author` stay readable. Not
/// a URL to request.
String redact(Object url) {
  final uri = url is Uri ? url : Uri.tryParse('$url');
  if (uri == null) return '$url';
  var out = uri.userInfo.isEmpty ? uri : uri.replace(userInfo: '');
  final segments = <String>[];
  var cut = false;
  for (final s in uri.pathSegments) {
    if (_botToken.hasMatch(s)) {
      segments.add('bot***');
      cut = true;
      continue;
    }
    segments.add(s);
    if (s == 'webhooks' || s == 'services' && uri.host == 'hooks.slack.com') {
      if (segments.length < uri.pathSegments.length) segments.add('***');
      cut = true;
      break;
    }
  }
  if (cut) out = out.replace(pathSegments: segments);
  if (uri.hasQuery) {
    final masked = _maskPairs(uri.query);
    if (masked != null) out = out.replace(query: masked);
  }
  // Uri.replace keeps the fragment; masking it means building the string.
  final text = out.toString();
  if (!uri.hasFragment) return text;
  final masked = _maskPairs(uri.fragment);
  return masked == null ? text : '${text.substring(0, text.lastIndexOf('#'))}#$masked';
}

/// `a=1&token=x` with the secret values as `***`; null when none is.
String? _maskPairs(String pairs) {
  var hit = false;
  final masked = pairs
      .split('&')
      .map((pair) {
        final eq = pair.indexOf('=');
        if (eq < 0 || !_secretParams.contains(pair.substring(0, eq).toLowerCase().replaceAll('-', '_'))) {
          return pair;
        }
        hit = true;
        return '${pair.substring(0, eq)}=***';
      })
      .join('&');
  return hit ? masked : null;
}

/// A Telegram bot API token segment: `bot123456:AAE…`.
final _botToken = RegExp(r'^bot\d+:[\w-]+$');

/// Query parameter names whose values are credentials (lowercase, `-` as
/// `_`).
const _secretParams = {
  'token', 'access_token', 'refresh_token', 'id_token', 'auth_token', 'bearer', //
  'key', 'api_key', 'apikey', 'access_key', 'private_key', 'client_secret', 'secret', //
  'code', 'auth', 'authorization', 'password', 'passwd', 'pwd', 'pass', //
  'sig', 'signature', 'session', 'sessionid', 'session_id', 'sid', 'jwt', 'otp', //
  'credential', 'credentials', 'x_amz_signature', 'x_amz_credential', 'x_amz_security_token', //
  'x_goog_signature', 'x_goog_credential',
};
