import 'dart:io';

// ============================================================================
// CLI ARGUMENT PARSER (cli.* / Cli)
// ============================================================================

/// Top-level CLI argument accessor singleton.
final CliAccessor cli = CliAccessor();

/// CLI argument accessor and state holder.
class CliAccessor {
  Cli _instance = Cli();

  /// Parse or re-bind command line arguments into active namespace session (1-word).
  void parse(List<String> args) {
    _instance = Cli(args);
  }

  /// Check if a flag exists, e.g. `--force` or `-f` (1-word).
  bool has(String name, [String? alias]) => _instance.has(name, alias);

  /// Parse option value to target type (int, double, bool, String) (1-word).
  T get<T>(String name, [T? fallback, String? alias]) =>
      _instance.get<T>(name, fallback, alias);

  /// Return positional non-option arguments list (1-word).
  List<String> list() => _instance.list();

  /// Return all raw arguments.
  List<String> get raw => _instance.raw;
}

/// Standalone CLI argument parser instance.
class Cli {
  final List<String> raw;
  final Map<String, String> _options = {};
  final Set<String> _flags = {};
  final List<String> _rest = [];

  Cli([List<String>? args]) : raw = args ?? Platform.executableArguments {
    _parse();
  }

  void _parse() {
    for (var i = 0; i < raw.length; i++) {
      final arg = raw[i];
      if (arg.startsWith('--')) {
        final stripped = arg.substring(2);
        final eq = stripped.indexOf('=');
        if (eq != -1) {
          final k = stripped.substring(0, eq);
          final v = stripped.substring(eq + 1);
          _options[k] = v;
          _flags.add(k);
        } else {
          if (i + 1 < raw.length && !raw[i + 1].startsWith('-')) {
            _options[stripped] = raw[i + 1];
            _flags.add(stripped);
            i++;
          } else {
            _flags.add(stripped);
          }
        }
      } else if (arg.startsWith('-') && arg.length > 1) {
        final stripped = arg.substring(1);
        final eq = stripped.indexOf('=');
        if (eq != -1) {
          final k = stripped.substring(0, eq);
          final v = stripped.substring(eq + 1);
          _options[k] = v;
          _flags.add(k);
        } else {
          if (i + 1 < raw.length && !raw[i + 1].startsWith('-')) {
            _options[stripped] = raw[i + 1];
            _flags.add(stripped);
            i++;
          } else {
            _flags.add(stripped);
          }
        }
      } else {
        _rest.add(arg);
      }
    }
  }

  bool has(String name, [String? alias]) {
    final cleanName = name.replaceFirst(RegExp(r'^-+'), '');
    final cleanAlias = alias?.replaceFirst(RegExp(r'^-+'), '');
    return _flags.contains(cleanName) ||
        (cleanAlias != null && _flags.contains(cleanAlias));
  }

  T get<T>(String name, [T? fallback, String? alias]) {
    final cleanName = name.replaceFirst(RegExp(r'^-+'), '');
    final cleanAlias = alias?.replaceFirst(RegExp(r'^-+'), '');

    final val = _options[cleanName] ??
        (cleanAlias != null ? _options[cleanAlias] : null);
    if (val == null) return fallback as T;

    if (fallback is int || T == int) {
      return (int.tryParse(val) ?? fallback) as T;
    }
    if (fallback is double || T == double) {
      return (double.tryParse(val) ?? fallback) as T;
    }
    if (fallback is bool || T == bool) {
      return (val == 'true' || val == '1') as T;
    }
    return val as T;
  }

  List<String> list() => List.unmodifiable(_rest);
}
