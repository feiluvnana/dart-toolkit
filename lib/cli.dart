/// Argument parsing by declare-by-reading. In-house, about 150 lines.
///
/// ```dart
/// final args = Cli.parse(argv);
/// final verbose = args.flag('verbose', short: 'v', help: 'Print every request.');
/// final out = args.option('out', short: 'o', help: 'Output folder.') ?? 'out';
/// switch (args.rest()) {
///   case ['get', final url]: await fetch(url, out);
///   case ['list']: await list(out);
/// }
/// ```
///
/// Public surface is exactly: [Cli], [Args].
/// - `Cli.parse()` parses argv.
/// - [Args] supports `flag` `option` `multi` `rest` `usage`.
/// Everything else is private.
library;

/// Entry point: parse argv.
abstract final class Cli {
  /// Parse [args]. Never throws; errors surface when the tokens are read
  /// (`rest()` for unknown flags, the option call for a missing value).
  static Args parse(List<String> args) => Args._(List.of(args));
}

/// Declared-by-reading arguments.
final class Args {
  Args._(List<String> raw) : _tokens = raw;

  final List<String> _tokens;
  final List<_Decl> _decls = [];
  final Map<String, Object?> _cache = {};
  final Set<String> _consumedValue = {};
  final Map<int, Set<String>> _claimedShorts = {};
  bool _restCalled = false;
  int _dashDash = -1;

  /// A `--name`/`-s` flag. True when present. Grouped shorts (`-vq`) work.
  bool flag(String name, {String? short, String? help}) {
    _checkDeclare(name);
    if (_cache.containsKey(name)) return _cache[name] as bool;
    _decls.add(_Decl.flag(name, short: short, help: help));
    var found = false;
    for (var i = 0; i < _tokens.length; i++) {
      if (_isDashDash(i)) break;
      if (_isValueToken(i)) continue;
      final t = _tokens[i];
      if (t == '--$name') {
        found = true;
      } else if (short != null && _isShortToken(t) && t.substring(1).contains(short)) {
        (_claimedShorts[i] ??= {}).add(short);
        found = true;
      }
    }
    _cache[name] = found;
    return found;
  }

  /// A `--name value`/`--name=value`/`-s value` option. Last value wins, or
  /// null. The next token is always the value, even when it starts with `-`.
  String? option(String name, {String? short, String? help}) {
    _checkDeclare(name);
    if (_cache.containsKey(name)) return _cache[name] as String?;
    _decls.add(_Decl.option(name, short: short, help: help));
    String? value;
    for (var i = 0; i < _tokens.length; i++) {
      if (_isDashDash(i)) break;
      if (_isValueToken(i)) continue;
      final t = _tokens[i];
      if (t == '--$name') {
        value = _takeValue(i, t);
      } else if (t.startsWith('--$name=')) {
        value = t.substring('--$name='.length);
      } else if (short != null && t == '-$short') {
        value = _takeValue(i, t);
      }
    }
    _cache[name] = value;
    return value;
  }

  /// A repeatable option: every value, in order.
  List<String> multi(String name, {String? short, String? help}) {
    _checkDeclare(name);
    if (_cache.containsKey(name)) {
      return List.of(_cache[name] as List<String>);
    }
    _decls.add(_Decl.multi(name, short: short, help: help));
    final values = <String>[];
    for (var i = 0; i < _tokens.length; i++) {
      if (_isDashDash(i)) break;
      if (_isValueToken(i)) continue;
      final t = _tokens[i];
      if (t == '--$name') {
        values.add(_takeValue(i, t));
      } else if (t.startsWith('--$name=')) {
        values.add(t.substring('--$name='.length));
      } else if (short != null && t == '-$short') {
        values.add(_takeValue(i, t));
      }
    }
    _cache[name] = values;
    return List.of(values);
  }

  /// Ends the declarations; returns the positional arguments.
  /// A leftover `-x`/`--x` is a [FormatException] naming the token.
  List<String> rest() {
    _restCalled = true;
    final out = <String>[];
    for (var i = 0; i < _tokens.length; i++) {
      if (_tokens[i] == '--' && _dashDashDone(i)) {
        continue;
      }
      if (_isValueToken(i)) continue;
      if (_isOptionToken(i)) continue;
      final t = _tokens[i];
      if (_afterDashDash(i)) {
        out.add(t);
        continue;
      }
      if (t.startsWith('--') && t.length > 2) {
        throw FormatException('unknown option: $t');
      }
      if (_isShortToken(t)) {
        final claimed = _claimedShorts[i] ?? const <String>{};
        final chars = t.substring(1);
        final unclaimed = [
          for (var k = 0; k < chars.length; k++)
            if (!claimed.contains(chars[k])) chars[k],
        ];
        if (unclaimed.isNotEmpty) {
          throw FormatException('unknown option: $t');
        }
        continue;
      }
      out.add(t);
    }
    return out;
  }

  /// The declarations in call order, one aligned line each.
  String usage() {
    final lefts = <String>[];
    for (final d in _decls) {
      final names = <String>[
        if (d.short != null) '-${d.short}',
        '--${d.name}',
      ].join(', ');
      lefts.add(d.kind == _Kind.flag ? names : '$names <value>');
    }
    var width = 0;
    for (final l in lefts) {
      if (l.length > width) width = l.length;
    }
    final lines = <String>[];
    for (var i = 0; i < _decls.length; i++) {
      final help = _decls[i].help ?? '';
      lines.add(
        help.isEmpty
            ? lefts[i]
            : '${lefts[i].padRight(width)}   $help',
      );
    }
    return lines.join('\n');
  }

  void _checkDeclare(String name) {
    if (_restCalled) {
      throw StateError('cannot declare "$name" after rest()');
    }
  }

  bool _isDashDash(int i) {
    if (_dashDash == -1) {
      _dashDash = _tokens.indexOf('--');
    }
    return _dashDash != -1 && i == _dashDash;
  }

  bool _dashDashDone(int i) => _isDashDash(i);

  bool _afterDashDash(int i) =>
      _dashDash != -1 && i > _dashDash;

  String _takeValue(int i, String token) {
    if (i + 1 >= _tokens.length || _afterDashDash(i + 1)) {
      throw FormatException('$token needs a value');
    }
    _consumedValue.add('${i + 1}');
    return _tokens[i + 1];
  }

  bool _isValueToken(int i) => _consumedValue.contains('$i');

  bool _isOptionToken(int i) {
    final t = _tokens[i];
    if (_afterDashDash(i)) return false;
    for (final d in _decls) {
      if (t == '--${d.name}') return true;
      if (t.startsWith('--${d.name}=')) return true;
      if (d.short != null && t == '-${d.short}' && d.kind != _Kind.flag) {
        return true;
      }
    }
    // A --name token for an undeclared name is left for rest() to reject.
    return false;
  }

  static bool _isShortToken(String t) =>
      t.startsWith('-') &&
      !t.startsWith('--') &&
      t.length > 1 &&
      t != '-';
}

enum _Kind { flag, option, multi }

final class _Decl {
  _Decl.flag(this.name, {this.short, this.help}) : kind = _Kind.flag;
  _Decl.option(this.name, {this.short, this.help}) : kind = _Kind.option;
  _Decl.multi(this.name, {this.short, this.help}) : kind = _Kind.multi;

  final _Kind kind;
  final String name;
  final String? short;
  final String? help;
}
