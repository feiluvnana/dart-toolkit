part of 'process.dart';

const _shellKey = #dartToolkitShellScope;

/// The settings every command in a [Shell.scope] shares.
final class _Scope {
  final String? workdir;
  final Map<String, String?>? env;
  final Duration? timeout;
  final bool quiet;
  final Runner? runner;

  const _Scope({this.workdir, this.env, this.timeout, this.quiet = true, this.runner});

  static _Scope get current => Zone.current[_shellKey] as _Scope? ?? const _Scope();

  /// The working directory of [command] under this scope.
  String? workdirOf(Command command) => _within(workdir, command.workdir);

  /// The variables [command] adds to this scope's.
  Map<String, String?>? envOf(Command command) =>
      command.env == null ? env : (env == null ? command.env : {...env!, ...command.env!});
}

/// [inner] resolved against [outer] when it is relative.
String? _within(String? outer, String? inner) => switch ((outer, inner)) {
  (_, null) => outer,
  (null, final own?) => own,
  (final outer?, final own?) => _isAbsolute(own) ? own : '$outer${Platform.pathSeparator}$own',
};

bool _isAbsolute(String path) =>
    path.startsWith('/') ||
    (Platform.isWindows && (path.startsWith(r'\') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)));

/// Running programs: a command line ([run]), a shell script ([sh]), a program on this terminal
/// ([interact]), finding one ([which]), and the settings a block of them shares ([scope]). The
/// class form is [Command].
///
/// ```dart
/// final status = await Shell.run('git status --short').text;     // stdout, or a ShellException
/// if (await Shell.run('git diff --quiet').isOk) …                // a Future<bool>
/// await Shell.run('pg_dump db').save('db.sql');                  // stdout to a file, atomically
/// await Shell.interact('git commit');                            // your terminal
/// await Shell.sh(r'grep -c "$1" *.log | sort', args: [word]);    // shell syntax, explicitly
/// ```
///
/// {@category System}
abstract final class Shell {
  /// Runs [body] with these settings for every command it starts: [workdir] (a command's own
  /// relative one resolves against it), [env] (added to the enclosing scope's), [timeout] (each
  /// command's limit), [quiet] (`false` echoes output; the default is quiet), and [runner], the
  /// process seam: `Runner.fake(…)` in tests. What is not given stays the enclosing scope's.
  static Future<T> scope<T>(
    FutureOr<T> Function() body, {
    String? workdir,
    Map<String, String?>? env,
    Duration? timeout,
    bool? quiet,
    Runner? runner,
  }) async {
    _checkTimeout(timeout);
    final outer = _Scope.current;
    final scope = _Scope(
      workdir: _within(outer.workdir, workdir),
      env: env == null ? outer.env : {...?outer.env, ...env},
      timeout: timeout ?? outer.timeout,
      quiet: quiet ?? outer.quiet,
      runner: runner ?? outer.runner,
    );
    return await runZoned(() async => await body(), zoneValues: {_shellKey: scope});
  }

  /// Runs [line], a simple command line: split into words as a POSIX shell splits them (as
  /// `CommandLineToArgvW` does on Windows), then [args] as they are, and run with no shell. A
  /// line that is the path of a file is that one program, spaces and all
  /// (`Shell.run(r'C:\Program Files\ffmpeg.exe')`).
  ///
  /// **Never interpolate a scraped or typed-in value into [line]**: pass it in [args], which is
  /// never re-read (`Shell.run('git commit -m', args: [message])`). Shell syntax (`| & ; < >`, a
  /// backtick, `* ? [`, `{a,b}`, a leading `~` or `#`, `$VAR`, `$1`, `FOO=1 cmd`, `%VAR%` on
  /// Windows) is an [ArgumentError]: use [sh], `env:`, or a pipeline of [Command]s. An unclosed
  /// quote is a [FormatException].
  ///
  /// The rest is [Command.run]'s.
  static Run run(
    String line, {
    List<String> args = const [],
    String? workdir,
    Map<String, String?>? env,
    Duration? timeout,
    bool? quiet,
    String? text,
    List<int>? bytes,
    Stream<List<int>>? stream,
  }) => _parse(line, args, workdir, env).run(timeout: timeout, quiet: quiet, text: text, bytes: bytes, stream: stream);

  /// Runs [script] with a shell, so its syntax works: `/bin/sh -c` with [args] as `$1`, `$2`…,
  /// or `cmd.exe /c` on Windows, where [args] is an [ArgumentError] (`cmd` has no such slots)
  /// and `%NAME%` reads the command's environment. The rest is [Command.run]'s.
  static Run sh(
    String script, {
    List<String> args = const [],
    String? workdir,
    Map<String, String?>? env,
    Duration? timeout,
    bool? quiet,
    String? text,
    List<int>? bytes,
    Stream<List<int>>? stream,
  }) {
    if (script.trim().isEmpty) throw ArgumentError.value(script, 'script', 'Invalid script: empty');
    if (Platform.isWindows && args.isNotEmpty) {
      throw ArgumentError.value(args, 'args', 'Invalid args: cmd.exe has no \$1 for them; put the values in env:');
    }
    final command = Platform.isWindows
        ? Command._cmdScript(script, workdir: workdir, env: env)
        : Command('/bin/sh', ['-c', script, 'sh', ...args], workdir: workdir, env: env);
    return command.run(timeout: timeout, quiet: quiet, text: text, bytes: bytes, stream: stream);
  }

  /// Runs [line] (split as [run] splits it) on this terminal, as [Command.interact] does.
  static Task<void> interact(
    String line, {
    List<String> args = const [],
    String? workdir,
    Map<String, String?>? env,
    Duration? timeout,
  }) => _parse(line, args, workdir, env).interact(timeout: timeout);

  /// Where [program] is: the file on the `PATH` a command would run, as the enclosing scope's
  /// and [env]'s `PATH` (and `PATHEXT` on Windows) name it. A [MissingException]
  /// (`Missing ffmpeg in PATH`) when there is none; `(() => Shell.which('ffmpeg')).orNull` asks
  /// whether.
  static Future<Path> which(String program, {Map<String, String?>? env}) async {
    if (program.isEmpty) throw ArgumentError.value(program, 'program', 'Invalid program: empty');
    final scope = _Scope.current;
    final variables = _variables(env == null ? scope.env : {...?scope.env, ...env});
    return await _lookup(program, variables) ?? (throw MissingException(program, where: 'PATH'));
  }
}

/// [line] and [args] as the [Command] [Shell.run] runs.
Command _parse(String line, List<String> args, String? workdir, Map<String, String?>? env) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) throw ArgumentError.value(line, 'line', 'Invalid command line: empty');
  // A path with a space in it, naming a file, is one program: `which` gives such paths. Only a
  // line that starts as a path is looked at, so `git -C /repo status` costs no stat.
  final looksLikePath =
      (_isAbsolute(trimmed) || trimmed.startsWith('./') || trimmed.startsWith(r'.\')) &&
      trimmed.contains(RegExp(r'\s'));
  if (looksLikePath && FileSystemEntity.typeSync(trimmed) == FileSystemEntityType.file) {
    return Command(trimmed, args, workdir: workdir, env: env);
  }
  final words = ShellInternals.split(trimmed, windows: Platform.isWindows);
  return Command(words.first, [...words.skip(1), ...args], workdir: workdir, env: env);
}

void _checkTimeout(Duration? timeout) {
  if (timeout != null && timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'Invalid timeout, expected more than zero');
  }
}

/// Not API: the command-line splitter, for tests of both platforms' rules on either.
abstract final class ShellInternals {
  /// [line]'s words: as a POSIX shell reads a simple command, or as `CommandLineToArgvW` reads
  /// one when [windows].
  static List<String> split(String line, {required bool windows}) {
    final words = windows ? _splitWindows(line) : _splitPosix(line);
    if (words.isEmpty) throw ArgumentError.value(line, 'line', 'Invalid command line: empty');
    return words;
  }
}

/// [command] split as a POSIX shell reads a simple command, with no expansion.
///
/// An unclosed quote is a [FormatException]; unquoted shell syntax an [ArgumentError], since run
/// with no shell `a | wc -l` would hand `|` to `a` as a word.
List<String> _splitPosix(String command) {
  final args = <String>[];
  final current = StringBuffer();
  var quoted = false; // an empty quoted string is still a word
  var inSingle = false;
  var inDouble = false;

  const backslash = 0x5c, singleQuote = 0x27, doubleQuote = 0x22, dollar = 0x24, backtick = 0x60;
  bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

  for (var i = 0; i < command.length; i++) {
    final char = command.codeUnitAt(i);
    if (inSingle) {
      if (char == singleQuote) {
        inSingle = false;
      } else {
        current.writeCharCode(char);
      }
    } else if (inDouble) {
      if (char == doubleQuote) {
        inDouble = false;
      } else if (char == backslash && i + 1 < command.length) {
        final next = command.codeUnitAt(i + 1);
        if (next == 0x0a) {
          i++; // a line continuation
        } else if (next == backslash || next == doubleQuote || next == dollar || next == backtick) {
          current.writeCharCode(next);
          i++;
        } else {
          current.writeCharCode(char);
        }
      } else {
        current.writeCharCode(char);
      }
    } else if (char == backslash && i + 1 < command.length) {
      if (command.codeUnitAt(++i) != 0x0a) current.writeCharCode(command.codeUnitAt(i));
    } else if (char == singleQuote) {
      inSingle = quoted = true;
    } else if (char == doubleQuote) {
      inDouble = quoted = true;
    } else if (isSpace(char)) {
      if (current.isNotEmpty || quoted) args.add('$current');
      current.clear();
      quoted = false;
    } else if (char == 0x3d && args.isEmpty && !quoted && _isName('$current')) {
      throw ArgumentError.value(command, 'line', 'Invalid command line: `$current=` is a shell assignment; pass env:');
    } else if (_posixSyntax(command, i, current.isEmpty && !quoted) case final syntax?) {
      throw ArgumentError.value(command, 'line', 'Invalid command line: $syntax is shell syntax; ${_hint(syntax)}');
    } else {
      current.writeCharCode(char);
    }
  }
  if (inSingle || inDouble) {
    throw FormatException('Invalid command line: unclosed ${inSingle ? 'single' : 'double'} quote', command);
  }
  if (current.isNotEmpty || quoted) args.add('$current');
  return args;
}

String _hint(String syntax) => switch (syntax) {
  '`*`' || '`?`' || '`[`' => 'use Shell.sh, or list the files yourself',
  _ => 'use Shell.sh, or Command | Command',
};

/// The shell operator starting at [i] of [command], unquoted, or `null`.
String? _posixSyntax(String command, int i, bool atStartOfWord) {
  final char = command[i];
  if ('|&;<>`*?['.contains(char) || (atStartOfWord && (char == '~' || char == '#'))) return '`$char`';
  if (char == '{' && _braces.matchAsPrefix(command, i) != null) return '`{`';
  if (char == r'$' && i + 1 < command.length) {
    if (command[i + 1] == '(') return r'`$(`';
    if (command[i + 1] == '{') return r'`${`';
    if (r'0123456789@*#?$!-'.contains(command[i + 1])) return '`\$${command[i + 1]}`';
    final next = command.codeUnitAt(i + 1);
    if (_isIdentStart(next)) {
      var j = i + 1;
      while (j < command.length && _isIdentChar(command.codeUnitAt(j))) {
        j++;
      }
      return '`\$${command.substring(i + 1, j)}`';
    }
  }
  return null;
}

/// A brace expansion: `{a,b}` or `{1..3}`; a lone `{}` (`find -exec`) is a word.
final _braces = RegExp(r'\{[^\s{}]*(?:,|\.\.)[^\s{}]*\}');

bool _isName(String word) => word.isNotEmpty && _isIdentStart(word.codeUnitAt(0)) && word.codeUnits.every(_isIdentChar);

bool _isIdentStart(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f; // A-Z, a-z, _
bool _isIdentChar(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39); // A-Z, a-z, _, 0-9

/// [command] split as `CommandLineToArgvW` reads it: a backslash is itself unless it comes
/// before a quote (2n of them and a quote are n and a toggle; 2n+1 are n and a literal quote),
/// and `""` inside quotes is one quote. So `C:\tools\ffmpeg.exe` stays whole.
///
/// Unquoted `| & < >` and `%NAME%`, which only `cmd.exe` reads, are an [ArgumentError].
List<String> _splitWindows(String command) {
  final args = <String>[];
  final current = StringBuffer();
  var quoted = false, inQuotes = false;
  const backslash = 0x5c, quote = 0x22;
  for (var i = 0; i < command.length; i++) {
    final char = command.codeUnitAt(i);
    if (char == backslash) {
      var n = 0;
      while (i < command.length && command.codeUnitAt(i) == backslash) {
        n++;
        i++;
      }
      if (i < command.length && command.codeUnitAt(i) == quote) {
        for (var k = 0; k < n ~/ 2; k++) {
          current.writeCharCode(backslash);
        }
        if (n.isOdd) {
          current.writeCharCode(quote);
        } else {
          i--; // the quote toggles, below
        }
      } else {
        for (var k = 0; k < n; k++) {
          current.writeCharCode(backslash);
        }
        i--;
      }
      continue;
    }
    if (char == quote) {
      if (inQuotes && i + 1 < command.length && command.codeUnitAt(i + 1) == quote) {
        current.writeCharCode(quote);
        i++;
      } else {
        inQuotes = !inQuotes;
        quoted = true;
      }
    } else if (!inQuotes && (char == 0x20 || char == 0x09)) {
      if (current.isNotEmpty || quoted) args.add('$current');
      current.clear();
      quoted = false;
    } else if (!inQuotes && '|&<>'.contains(command[i])) {
      throw ArgumentError.value(
        command,
        'line',
        'Invalid command line: `${command[i]}` is shell syntax; ${_hint('|')}',
      );
    } else if (!inQuotes && char == 0x25 /* % */ && RegExp(r'%\w+%').matchAsPrefix(command, i) != null) {
      throw ArgumentError.value(command, 'line', 'Invalid command line: `%NAME%` is shell syntax; ${_hint('%')}');
    } else {
      current.writeCharCode(char);
    }
  }
  if (inQuotes) throw FormatException('Invalid command line: unclosed double quote', command);
  if (current.isNotEmpty || quoted) args.add('$current');
  return args;
}
