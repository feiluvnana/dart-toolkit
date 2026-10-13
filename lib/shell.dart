/// Run programs, or use one as a filter. Thin facade over `dart:io`.
///
/// ```dart
/// final head = (await Shell.run(['git', 'rev-parse', 'HEAD']).text()).trim();
/// if (await Shell.run(['git', 'diff', '--quiet']).exitCode() != 0) print('dirty');
/// await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
/// ```
///
/// Public surface is exactly: [Shell], [Output].
/// - `Shell.run()` runs a program, `Shell.filter()` makes a process a [Pipe].
/// - [Output] supports `exitCode` `errorText` (plus [Reader] over stdout).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'core.dart';
export 'core.dart';

/// Entry point: run a program or make one a filter.
abstract final class Shell {
  /// Run [command] directly (no shell), with stdin closed. Waits for the exit
  /// and returns an [Output]. A program that can't start throws
  /// [io.ProcessException]. A non-zero exit is an [Output], never a throw.
  static Future<Output> run(
    List<String> command, {
    String? workingDir,
    Map<String, String>? env,
  }) async {
    _checkCommand(command);
    io.ProcessResult r;
    try {
      r = await io.Process.run(
        command[0],
        command.sublist(1),
        workingDirectory: workingDir,
        environment:
            env == null ? null : {...io.Platform.environment, ...env},
        stdoutEncoding: null,
        stderrEncoding: null,
      );
    } on io.ProcessException catch (e) {
      throw io.ProcessException(
        command[0],
        command.sublist(1),
        'cannot start ${command[0]}: ${e.message}',
      );
    }
    return Output._(
      r.exitCode,
      _resultBytes(r.stdout),
      _resultText(r.stderr),
    );
  }

  /// A process as a [Pipe]: the stream goes to its stdin, stdout comes out.
  /// stderr is collected; a non-zero exit fails the run with a
  /// [io.ProcessException] carrying the code and stderr.
  static Pipe filter(
    List<String> command, {
    String? workingDir,
    Map<String, String>? env,
  }) {
    _checkCommand(command);
    return _Filter(command, workingDir: workingDir, env: env);
  }

  static void _checkCommand(List<String> command) {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
  }

  static List<int> _resultBytes(Object? out) {
    if (out is List<int>) return out;
    if (out is String) return utf8.encode(out);
    return const [];
  }

  static String _resultText(Object? out) {
    if (out is String) return out;
    if (out is List<int>) return utf8.decode(out, allowMalformed: true);
    return '';
  }
}

/// A finished program: a [Reader] of stdout.
final class Output with Reader {
  Output._(this._exitCode, this._out, this._err);

  final int _exitCode;
  final List<int> _out;
  final String _err;

  /// The exit code. Never throws.
  int exitCode() => _exitCode;

  /// Stderr, decoded as UTF-8.
  String errorText() => _err;

  @override
  Stream<List<int>> stream() => Stream.value(_out);

  @override
  Future<String> text() async =>
      utf8.decode(_out, allowMalformed: true);
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension OutputFuture on Future<Output> {
  Future<int> exitCode() async => (await this).exitCode();
  Future<String> errorText() async => (await this).errorText();
}

final class _Filter implements Pipe {
  _Filter(this._command, {this._workingDir, this._env});

  final List<String> _command;
  final String? _workingDir;
  final Map<String, String>? _env;

  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    io.Process proc;
    try {
      proc = await io.Process.start(
        _command[0],
        _command.sublist(1),
        workingDirectory: _workingDir,
        environment:
            _env == null ? null : {...io.Platform.environment, ..._env},
      );
    } on io.ProcessException catch (e) {
      throw io.ProcessException(
        _command[0],
        _command.sublist(1),
        'cannot start ${_command[0]}: ${e.message}',
      );
    }
    // A downstream cancel tears this generator down without an error, so
    // track normal completion and kill in the finally: without this the
    // child outlives a failed run.
    var ok = false;
    final stderrBuf = BytesBuilder(copy: false);
    final stderrSub = proc.stderr.listen(stderrBuf.add);
    Object? inputError;
    StackTrace? inputStack;
    final stdinDone = () async {
      try {
        await proc.stdin.addStream(input);
        await proc.stdin.close();
      } catch (e, st) {
        inputError = e;
        inputStack = st;
        try {
          await proc.stdin.close();
        } catch (_) {}
        proc.kill();
      }
    }();
    try {
      await for (final chunk in proc.stdout) {
        yield chunk;
      }
      ok = true;
    } catch (_) {
      proc.kill();
      rethrow;
    } finally {
      if (!ok) proc.kill();
      try {
        await proc.stdin.close();
      } catch (_) {}
      try {
        await stdinDone;
      } catch (_) {}
      await stderrSub.cancel();
    }
    if (inputError != null) {
      // The upstream failed: don't mask it behind the exit code.
      await Future<void>.error(inputError!, inputStack);
    }
    final code = await proc.exitCode;
    if (code != 0) {
      throw io.ProcessException(
        _command[0],
        _command.sublist(1),
        'exit $code: ${utf8.decode(stderrBuf.takeBytes(), allowMalformed: true)}',
        code,
      );
    }
  }
}
