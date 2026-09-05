import 'dart:io';

// ============================================================================
// CLI ARGUMENT PARSER (cli.* / Cli)
// ============================================================================

/// Top-level CLI argument accessor singleton.
///
/// Provides access to the currently parsed command-line arguments:
/// ```dart
/// cli.parse(args);
/// final force = cli.has('force', 'f');
/// final concurrency = cli.get('concurrency', 4);
/// final targets = cli.list();
/// ```
final CliAccessor cli = CliAccessor();

/// CLI argument accessor and state holder.
class CliAccessor {
  Cli _instance = Cli();

  /// Parses and binds command-line arguments into the active session.
  ///
  /// ```dart
  /// void main(List<String> rawArgs) {
  ///   cli.parse(rawArgs);
  /// }
  /// ```
  void parse(List<String> args) {
    _instance = Cli(args);
  }

  /// Checks whether a boolean flag or its alias was passed.
  ///
  /// Matches `--name`, `-alias`, or `--no-name`.
  /// ```dart
  /// final verbose = cli.has('verbose', 'v');
  /// final force = cli.has('force', 'f');
  /// ```
  bool has(String name, [String? alias]) => _instance.has(name, alias);

  /// Extracts a typed option value with an optional fallback default.
  ///
  /// Supports `--key=value`, `--key value`, and `-k value`.
  /// Type is automatically inferred from [fallback] or specified generic [T]:
  /// ```dart
  /// final port = cli.get('port', 8080);            // inferred as int
  /// final ratio = cli.get('ratio', 0.5);           // inferred as double
  /// final env = cli.get('env', 'production');      // inferred as String
  /// final token = cli.get<String?>('token');       // nullable String
  /// ```
  T get<T>(String name, [T? fallback, String? alias]) =>
      _instance.get<T>(name, fallback, alias);

  /// Returns the unmodifiable list of positional non-option arguments.
  ///
  /// ```bash
  /// dart run my_script.dart --concurrency=4 build deploy
  /// ```
  /// ```dart
  /// final targets = cli.list(); // ['build', 'deploy']
  /// ```
  List<String> list() => _instance.list();

  /// Returns the raw unmodified argument strings passed to the CLI.
  List<String> get raw => _instance.raw;
}

/// Standalone CLI argument parser instance.
class Cli {
  /// The raw list of argument strings.
  final List<String> raw;
  final Map<String, String> _options = {};
  final Set<String> _flags = {};
  final List<String> _rest = [];

  /// Creates a parser instance for [args], defaulting to [Platform.executableArguments].
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

  /// Checks if flag [name] or [alias] is present.
  bool has(String name, [String? alias]) {
    final cleanName = name.replaceFirst(RegExp(r'^-+'), '');
    final cleanAlias = alias?.replaceFirst(RegExp(r'^-+'), '');
    return _flags.contains(cleanName) ||
        (cleanAlias != null && _flags.contains(cleanAlias));
  }

  /// Retrieves an option value converted to type [T].
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

  /// Returns unmodifiable list of positional non-option arguments.
  List<String> list() => List.unmodifiable(_rest);
}
