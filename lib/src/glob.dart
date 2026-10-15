/// Glob patterns as a [RegExp], for `fs` (`Dir.list(match:)`) and `chrome`
/// (`page.responses(pattern)`).
///
/// `*` matches any run without a `/` (any run at all when [paths] is false),
/// `**` any run including `/` (`**/` also matches nothing), `?` one
/// character, `{a,b}` either alternative, `[abc]`/`[!abc]` a class; `\`
/// escapes the next character.
library;

/// The whole-string [RegExp] for [pattern].
RegExp glob(String pattern, {bool paths = true}) {
  final out = StringBuffer('^');
  var depth = 0;
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    switch (c) {
      case '\\' when i + 1 < pattern.length:
        out.write(RegExp.escape(pattern[++i]));
      case '*':
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          i++;
          if (i + 1 < pattern.length && pattern[i + 1] == '/') {
            i++;
            out.write('(?:.*/)?');
          } else {
            out.write('.*');
          }
        } else {
          out.write(paths ? '[^/]*' : '.*');
        }
      case '?':
        out.write(paths ? '[^/]' : '.');
      case '{' when _closes(pattern, i):
        depth++;
        out.write('(?:');
      case '}' when depth > 0:
        depth--;
        out.write(')');
      case ',' when depth > 0:
        out.write('|');
      case '[':
        // `[!…]` negates; a `]` right after `[` or `[!` is a member.
        final negate = i + 1 < pattern.length && pattern[i + 1] == '!';
        final start = negate ? i + 2 : i + 1;
        final end = pattern.indexOf(']', start + 1);
        if (end < 0) {
          out.write(r'\[');
        } else {
          final body = pattern
              .substring(start, end)
              .replaceAll(r'\', r'\\')
              .replaceAll('^', r'\^')
              .replaceAll(']', r'\]')
              .replaceAll('[', r'\[');
          // A class never matches the folder separator in a path glob.
          out.write(negate ? '[^${paths ? '/' : ''}$body]' : '${paths ? '(?!/)' : ''}[$body]');
          i = end;
        }
      default:
        out.write(RegExp.escape(c));
    }
  }
  out.write(r'$');
  return RegExp(out.toString());
}

/// Whether the `{` at [at] has a matching `}`; an unmatched one is literal.
bool _closes(String pattern, int at) {
  var depth = 0;
  for (var i = at; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '\\') {
      i++;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      return true;
    }
  }
  return false;
}
