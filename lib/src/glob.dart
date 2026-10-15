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
      case '{':
        depth++;
        out.write('(?:');
      case '}' when depth > 0:
        depth--;
        out.write(')');
      case ',' when depth > 0:
        out.write('|');
      case '[':
        final end = pattern.indexOf(']', i + 2);
        if (end < 0) {
          out.write(r'\[');
        } else {
          var body = pattern.substring(i + 1, end);
          final negate = body.startsWith('!');
          if (negate) body = body.substring(1);
          out.write('[${negate ? '^' : ''}${body.replaceAll(r'\', r'\\').replaceAll('^', r'\^')}]');
          i = end;
        }
      default:
        out.write(RegExp.escape(c));
    }
  }
  out.write(r'$');
  return RegExp(out.toString());
}
