part of 'process.dart';

/// A command on its way: a [Task] of its [ShellResult], and the readings that say what you want
/// of it. Awaiting it is strict: a non-zero exit is a [ShellException].
///
/// | Reading | Gives |
/// |---|---|
/// | `await run` | the [ShellResult]; a [ShellException] on a non-zero exit |
/// | [settled] / [isOk] / [exitCode] | the outcome, never throwing for an exit code (126 and 127 still do) |
/// | [text] / [lines] / [bytes] | stdout, or throws |
/// | [output] / [errors] | stdout / stderr lines, live |
/// | [save] | stdout written to a file, atomically |
///
/// stdout is kept for the result until [output] or [save] takes it; whichever comes, it gets
/// everything from the first byte, so when a reading is chained never changes what it reads.
/// stderr keeps its last 64 KiB for errors. A cancel stops the command and everything it
/// started: SIGTERM, then SIGKILL half a second later (`taskkill /T /F` on Windows). Its
/// [Running] step is the last line it printed, so `show` (in `cli`) draws it as a spinner.
///
/// ```dart
/// final branch = await Shell.run('git rev-parse --abbrev-ref HEAD').text;
/// if (!await Shell.run('git diff --quiet').isOk) print('uncommitted changes');
/// await for (final line in Shell.run('tail -f app.log').output) { … }
/// ```
///
/// {@category System}
abstract interface class Run implements Task<ShellResult> {
  /// The command it runs.
  @override
  Command get item;

  /// Whether it exited 0; a non-zero exit is `false`, not a throw. A program that cannot run
  /// (126) or is not there (127) still throws: a typo is not a "no".
  Future<bool> get isOk;

  /// Its exit code, as [isOk] reads it.
  Future<int> get exitCode;

  /// Its stdout, trimmed; throws as awaiting it does.
  Future<String> get text;

  /// The non-empty lines of its stdout, right-trimmed; throws as awaiting it does.
  Future<List<String>> get lines;

  /// Its stdout as printed, for an encoding other than UTF-8; throws as awaiting it does.
  Future<Uint8List> get bytes;

  /// Its stdout a line at a time, live: what it printed so far first, then each line as it
  /// comes. A pause holds the command (its pipe fills), a cancel stops it, and a failure is the
  /// stream's error after the lines before it. It takes stdout: [text] and the result's
  /// `stdout` are then a [StateError], and so is a second taker.
  Stream<String> get output;

  /// Its stderr a line at a time, live, the kept tail first.
  Stream<String> get errors;

  /// Its stdout written to [to] as it comes, atomically: [to] changes only once the command has
  /// exited 0, so a failure keeps the old file. It takes stdout, as [output] does. A cancel of
  /// the save stops the command.
  Task<Path> save(String to);
}

/// The most of stderr a run keeps.
const _stderrKept = 64 << 10;

/// How often a run's step (its last line) is reported, at most.
const _stepGap = Duration(milliseconds: 100);

final class _Run implements Run {
  @override
  final Command item;
  final _Stdout _out;
  final _Stderr _err;
  late final Task<ShellResult> _task;

  _Run(this.item, _Scope scope, {Duration? timeout, bool? quiet, Object? input})
    : _out = _Stdout(echo: !(quiet ?? scope.quiet)),
      _err = _Stderr(echo: !(quiet ?? scope.quiet)) {
    _checkTimeout(timeout);
    final limit = timeout ?? scope.timeout;
    _task = TaskInternals.start(item, '$item', (work) async {
      final steps = _Steps(work);
      _out.steps = _err.steps = steps;
      try {
        return switch (scope.runner?._answer) {
          final answer? => await _fake(item, answer, limit, _out, _err),
          null => await _spawn(item, scope, limit, input, _out, _err),
        };
      } finally {
        _out.end();
        _err.end();
      }
    });
  }

  @override
  String get label => _task.label;

  @override
  Status<Object?, ShellResult> get status => _task.status;

  @override
  Stream<Status<Object?, ShellResult>> get statuses => _task.statuses;

  @override
  Future<Status<Object?, ShellResult>> get settled => _task.settled;

  @override
  void cancel([String reason = 'cancelled']) => _task.cancel(reason);

  @override
  Future<bool> get isOk => exitCode.then((code) => code == 0);

  @override
  Future<int> get exitCode => _task.then(
    (result) => result.exitCode,
    onError: (Object e, StackTrace st) =>
        e is ShellException && !_cannotRun(e) ? e.result.exitCode : Error.throwWithStackTrace(e, st),
  );

  @override
  Future<String> get text => _kept('text').then((result) => result.text);

  @override
  Future<List<String>> get lines => _kept('lines').then((result) => result.lines);

  @override
  Future<Uint8List> get bytes => _kept('bytes').then((result) => result.bytes);

  Future<ShellResult> _kept(String reading) {
    if (_out.takenBy case final taker?) {
      throw StateError('Cannot read the $reading of $item: $taker took its stdout');
    }
    return _task;
  }

  @override
  Stream<String> get output {
    final lines = _out.takeLines(() => _task.cancel('the output was cancelled'));
    // The stream says how it ended: a failure is its error, so the run's is handled there.
    _task.then(
      (_) => lines.close(),
      onError: (Object e, StackTrace st) {
        if (!lines.isClosed && !(e is CancelledException && _out.cancelledByReader)) lines.addError(e, st);
        lines.close();
      },
    );
    return lines.stream;
  }

  @override
  Stream<String> get errors => _err.listen();

  @override
  Task<Path> save(String to) {
    if (to.isEmpty) throw ArgumentError.value(to, 'to', 'Invalid path: empty');
    final bytes = _out.takeBytes();
    // The save answers for the run's outcome (it rethrows it once the output is in), so a run
    // that fails while the output is still being written is no unhandled error.
    _task.ignore();
    return TaskInternals.start(Path(to), to, (work) async {
      final unlink = Cancel.token?.onCancel(() => _task.cancel('the save was cancelled'));
      final steps = _task.statuses.listen((status) {
        if (status case Running(:final step?)) work.step(step);
      });
      try {
        await FileBridge.writeStream(to, _committed(bytes, _task));
        return Path(to);
      } catch (_) {
        // Nothing reads its output now: the command stops rather than wait on a full pipe, and
        // its pipe is let go so this program can end.
        _task.cancel('the save failed');
        _out.drop();
        rethrow;
      } finally {
        unlink?.call();
        await steps.cancel();
      }
    });
  }

  @override
  Stream<ShellResult> asStream() => _task.asStream();

  @override
  Future<ShellResult> catchError(Function onError, {bool Function(Object error)? test}) =>
      _task.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(ShellResult value) onValue, {Function? onError}) =>
      _task.then(onValue, onError: onError);

  /// Gives up after [timeLimit] as [Future.timeout] does, and stops the command then, so nothing
  /// is left running: `run(timeout:)` is the way to give a command a limit.
  @override
  Future<ShellResult> timeout(Duration timeLimit, {FutureOr<ShellResult> Function()? onTimeout}) =>
      TaskInternals.timeout(_task, timeLimit, onTimeout, cancel: _task.cancel, subject: '$item');

  @override
  Future<ShellResult> whenComplete(FutureOr<void> Function() action) => _task.whenComplete(action);

  @override
  String toString() => 'Run($item, ${_task.status})';
}

/// [source], then a wait for [run]: its failure ends the stream, so an atomic write of it
/// keeps the old file.
Stream<List<int>> _committed(Stream<List<int>> source, Future<ShellResult> run) async* {
  yield* source;
  await run;
}

/// A run's [Running] step: the last line it printed, at most every [_stepGap].
final class _Steps {
  final Work _work;
  Duration? _last;

  _Steps(this._work);

  /// Whether a step is due, so the caller can skip finding the line.
  bool get due {
    final last = _last;
    return last == null || Clock.current.elapsed - last >= _stepGap;
  }

  void step(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _last = Clock.current.elapsed;
    _work.step(trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed);
  }
}

/// Where a run's stdout goes: kept for the result until [output] or [save] takes it, echoed
/// when the run is not quiet.
final class _Stdout {
  final _Echo? _echo;
  BytesBuilder? _kept = BytesBuilder(copy: false);
  _Steps? steps;

  /// What took stdout: `'output'` or `'save'`, or `null` while it is kept.
  String? takenBy;

  /// Whether the reader of [takeLines] cancelled: the run stopping then is no news to it.
  bool cancelledByReader = false;

  StreamController<String>? _lines;
  StreamController<List<int>>? _bytes;
  Sink<List<int>>? _decoder;
  StreamSubscription<List<int>>? _source;
  bool _ended = false, _dropped = false;

  _Stdout({required bool echo}) : _echo = echo ? _Echo(err: false) : null;

  /// The lines of stdout, from the first; [stop] when the reader cancels.
  StreamController<String> takeLines(void Function() stop) {
    _take('output');
    final lines = _lines = StreamController<String>(
      onPause: () => _source?.pause(),
      onResume: () => _source?.resume(),
      onCancel: () {
        if (_ended) return;
        cancelledByReader = true;
        stop();
      },
    );
    _decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(const LineSplitter().startChunkedConversion(_Each(lines.add)));
    _replay();
    return lines;
  }

  /// The bytes of stdout, from the first.
  Stream<List<int>> takeBytes() {
    _take('save');
    final bytes = _bytes = StreamController<List<int>>(
      onPause: () => _source?.pause(),
      onResume: () => _source?.resume(),
    );
    _replay();
    return bytes.stream;
  }

  void _take(String by) {
    if (takenBy case final taker?) throw StateError('Cannot read the $by of this run: $taker took its stdout');
    takenBy = by;
  }

  /// Hands what was kept to the taker, and ends it if the run has.
  void _replay() {
    final kept = _kept?.takeBytes();
    _kept = null;
    if (kept != null && kept.isNotEmpty) _route(kept);
    if (_ended) _closeTaker();
  }

  /// Reads [stdout]: a pipe of a child.
  void attach(Stream<List<int>> stdout) {
    if (_dropped) return stdout.listen(null).cancel().ignore();
    final source = _source = stdout.listen(
      add,
      onError: (Object _) {}, // a broken pipe: the exit says the rest
      onDone: _drained.complete,
    );
    if ((_lines?.isPaused ?? false) || (_bytes?.isPaused ?? false)) source.pause();
  }

  final _drained = Completer<void>();

  /// Completes when the source has ended.
  Future<void> get drained => _drained.future;

  void add(List<int> chunk) {
    _echo?.add(chunk);
    if (steps case final steps? when steps.due) {
      if (_lastLine(chunk) case final line?) steps.step(line);
    }
    if (_kept case final kept?) {
      kept.add(chunk);
    } else {
      _route(chunk);
    }
  }

  void _route(List<int> chunk) {
    if (_decoder case final decoder?) decoder.add(chunk);
    if (_bytes case final bytes? when !bytes.isClosed) bytes.add(chunk);
  }

  /// The taker failed: stdout is read no more, and its pipe is let go (now, or when attached).
  void drop() {
    _dropped = true;
    _source?.cancel().ignore();
    if (!_drained.isCompleted) _drained.complete();
    if (_bytes case final bytes? when !bytes.isClosed) bytes.close();
  }

  /// The run has ended: the taker ends too.
  void end() {
    if (_ended) return;
    _ended = true;
    _echo?.close();
    _closeTaker();
  }

  void _closeTaker() {
    _decoder?.close();
    _decoder = null;
    if (_bytes case final bytes? when !bytes.isClosed) bytes.close();
  }

  /// What the result holds: the bytes kept, or `null` when a taker took them. They are joined
  /// once and kept joined, so the result and a late taker share one copy.
  Uint8List? get result {
    final kept = _kept;
    if (kept == null) return null;
    final bytes = kept.takeBytes();
    kept.add(bytes);
    return bytes;
  }
}

/// The last whole line in [chunk], decoded, or `null`: only the end of it is looked at.
String? _lastLine(List<int> chunk) {
  var end = chunk.length;
  while (end > 0 && (chunk[end - 1] == 0x0a || chunk[end - 1] == 0x0d)) {
    end--;
  }
  if (end == 0) return null;
  var start = end;
  while (start > 0 && end - start < 240 && chunk[start - 1] != 0x0a && chunk[start - 1] != 0x0d) {
    start--;
  }
  return const Utf8Decoder(allowMalformed: true).convert(chunk, start, end);
}

/// Where a run's stderr goes: its last [_stderrKept] bytes kept, its lines to each [listen]er,
/// echoed when the run is not quiet.
final class _Stderr {
  final _Echo? _echo;
  final _tail = BytesBuilder(copy: false);
  bool _cut = false;
  final _listeners = <StreamController<String>>[];
  _Steps? steps;
  bool _ended = false;
  final _sources = <Future<void>>[];

  _Stderr({required bool echo}) : _echo = echo ? _Echo(err: true) : null;

  /// Reads [stderr], a pipe of one stage: decoded and split on its own, so a line two reads cut
  /// arrives whole.
  void attach(Stream<List<int>> stderr) {
    final lines = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(const LineSplitter().startChunkedConversion(_Each(_line)));
    final done = Completer<void>();
    stderr.listen(
      (chunk) {
        _keep(chunk);
        _echo?.add(chunk);
        lines.add(chunk);
      },
      onError: (Object _) {}, // a broken pipe: the exit says the rest
      onDone: () {
        lines.close();
        done.complete();
      },
    );
    _sources.add(done.future);
  }

  /// [text], all a fake said on stderr.
  void addAll(String text) {
    if (text.isEmpty) return;
    final bytes = utf8.encode(text);
    _keep(bytes);
    _echo?.add(bytes);
    const LineSplitter().convert(text).forEach(_line);
  }

  Future<void> get drained => Future.wait(_sources);

  void _keep(List<int> chunk) {
    _tail.add(chunk);
    if (_tail.length > 2 * _stderrKept) {
      final all = _tail.takeBytes();
      _tail.add(Uint8List.sublistView(all, all.length - _stderrKept));
      _cut = true;
    }
  }

  void _line(String line) {
    if (steps case final steps? when steps.due) steps.step(line);
    for (final listener in _listeners) {
      listener.add(line);
    }
  }

  /// The lines from now on, the whole lines kept so far first.
  Stream<String> listen() {
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () {
        final kept = const LineSplitter().convert(text);
        // A line still being printed arrives whole when it ends.
        final whole = text.isEmpty || text.endsWith('\n') ? kept : kept.take(kept.length - 1);
        whole.forEach(controller.add);
        _ended ? controller.close() : _listeners.add(controller);
      },
      onCancel: () => _listeners.remove(controller),
    );
    return controller.stream;
  }

  /// The kept tail, decoded.
  String get text {
    final bytes = _tail.toBytes();
    final kept = _tail.length > _stderrKept ? Uint8List.sublistView(bytes, bytes.length - _stderrKept) : bytes;
    final decoded = const Utf8Decoder(allowMalformed: true).convert(kept);
    return _cut || kept.length < bytes.length ? '…$decoded' : decoded;
  }

  void end() {
    if (_ended) return;
    _ended = true;
    _echo?.close();
    for (final listener in _listeners) {
      listener.close();
    }
    _listeners.clear();
  }
}

/// Why a run was stopped before it ended: its limit ran out.
final class _Expired {
  final Duration limit;
  const _Expired(this.limit);
}

/// What stops a run before it ends: the enclosing cancel, or its [limit] ([_Expired]). Its
/// [processes] die as a tree then; [why] completes with the reason.
final class _Stop {
  final List<Process> processes;
  final _why = Completer<Object>();
  Future<void> stopped = Future.value();
  void Function()? _unlisten;
  Timer? _timer;

  _Stop(this.processes, Duration? limit) {
    final token = Cancel.token;
    _unlisten = token?.onCancel(() => halt(CancelledException.of(token)));
    if (limit != null) _timer = Timer(limit, () => halt(_Expired(limit)));
  }

  Future<Object> get why => _why.future;

  bool get isStopped => _why.isCompleted;

  void halt(Object why) {
    if (_why.isCompleted) return;
    _why.complete(why);
    stopped = _stopTree(processes);
  }

  /// The run is over: neither its cancel nor its limit can stop it now.
  void end() {
    _timer?.cancel();
    _unlisten?.call();
  }
}

/// The exit code a shell gives: a child killed by signal n is 128 + n.
int _shellCode(int code) => code < 0 ? 128 - code : code;

/// A [PathNotFoundException] when [place], the working directory of [command], is not there.
Future<void> _checkWorkdir(String? place, Command command) async {
  if (place != null && await FileSystemEntity.type(place) == FileSystemEntityType.notFound) {
    throw PathNotFoundException(
      place,
      const OSError('No such file or directory', 2),
      'Cannot run $command: no working directory',
    );
  }
}

/// [stage] started, or the [ShellException] a shell gives (126, 127) when it cannot be.
Future<Process> _launch(Command command, Command stage, String? place, _Scope scope, ProcessStartMode mode) async {
  try {
    return await _start(stage, place, _childEnv(scope.envOf(stage)), mode);
  } on ProcessException catch (e) {
    final code = _codeOf(e) ?? (throw e);
    throw ShellException(ShellResult._(command, code, Uint8List(0), '${e.message}: ${e.executable}\n'));
  }
}

/// The run's limit ran out ([_Expired]) or it was cancelled: the exception it ends with.
Object _stopped(Object why, ShellResult Function() printed) => switch (why) {
  _Expired(:final limit) => ShellTimeoutException(printed(), limit),
  final other => other, // a cancel, or the input stream's own failure
};

/// Runs [command] (each stage of it) as children of this process.
Future<ShellResult> _spawn(
  Command command,
  _Scope scope,
  Duration? limit,
  Object? input,
  _Stdout out,
  _Stderr err,
) async {
  final stages = command.stages;
  final places = [for (final stage in stages) scope.workdirOf(stage)];
  for (final place in {...places}) {
    await _checkWorkdir(place, command);
  }
  Cancel.check();

  final processes = <Process>[];
  final stop = _Stop(processes, limit);
  try {
    for (final (i, stage) in stages.indexed) {
      try {
        processes.add(await _launch(command, stage, places[i], scope, ProcessStartMode.normal));
      } catch (_) {
        await _stopTree(processes);
        rethrow;
      }
      // Stopped while it started: it goes the way the ones before it went.
      if (stop.isStopped) stop.stopped = stop.stopped.then((_) => _stopTree([processes.last]));
    }

    // Readers first: a child that echoes a large input fills its stdout pipe and stops reading
    // stdin, so feeding before draining would hold both sides.
    for (var i = 0; i < processes.length - 1; i++) {
      processes[i].stdout.pipe(processes[i + 1].stdin).catchError((Object _) {}); // the exit says the rest
    }
    out.attach(processes.last.stdout);
    for (final p in processes) {
      err.attach(p.stderr);
    }
    final fed = _feed(processes.first, input, stop.halt);

    final ended = <int>[];
    final exits = Future.wait([
      for (final (i, p) in processes.indexed) p.exitCode.then((code) => (ended..add(i), code).$2),
    ]);
    // The output is waited for under the same limit and cancel as the exits: a background child
    // left holding stdout open (`sleep 60 &`) would otherwise hold the run with it.
    final settled = await Future.any<Object>([
      exits.then((codes) async => (await Future.wait([out.drained, err.drained, fed]), codes).$2),
      stop.why,
    ]);

    if (settled is! List<int>) {
      await stop.stopped;
      throw _stopped(
        settled,
        () => ShellResult._(command, 124, out.result ?? Uint8List(0), err.text, taken: out.takenBy != null),
      );
    }

    final said = err.text;
    bool brokenPipe(int i, int code) =>
        i + 1 < settled.length &&
        (code == 141 || (ended.indexOf(i + 1) < ended.indexOf(i) && said.contains('Broken pipe')));
    final codes = [for (final (i, code) in settled.indexed) brokenPipe(i, _shellCode(code)) ? 0 : _shellCode(code)];
    final code = codes.lastWhere((c) => c != 0, orElse: () => 0);
    final result = ShellResult._(command, code, out.result, said, taken: out.takenBy != null);
    if (code != 0) throw ShellException(result);
    return result;
  } finally {
    stop.end();
  }
}

/// [command] answered by a fake runner, stage by stage, its output read as a child's would be.
Future<ShellResult> _fake(
  Command command,
  FutureOr<ShellResult> Function(Command command) answer,
  Duration? limit,
  _Stdout out,
  _Stderr err,
) async {
  final stop = _Stop(const [], limit);
  try {
    var code = 0;
    late ShellResult last;
    for (final stage in command.stages) {
      final answered = await Future.any<Object>([Future.sync(() => answer(stage)), stop.why]);
      if (answered is! ShellResult) {
        throw _stopped(answered, () => ShellResult._(command, 124, Uint8List(0), err.text));
      }
      err.addAll(answered.stderr);
      if (answered.exitCode != 0) code = answered.exitCode;
      last = answered;
    }
    out.add(last.bytes);
    final result = ShellResult._(command, code, out.result, err.text, taken: out.takenBy != null);
    if (code != 0) throw ShellException(result);
    return result;
  } finally {
    stop.end();
  }
}

/// [input] written to [process]'s stdin, which is then closed; an error in an input stream stops
/// the command through [halt], and is what the run throws.
Future<void> _feed(Process process, Object? input, void Function(Object why) halt) async {
  try {
    switch (input) {
      case String():
        process.stdin.add(utf8.encode(input));
      case List<int>():
        process.stdin.add(input);
      case Stream<List<int>>():
        await _pump(input, process, halt);
    }
    await process.stdin.close();
  } catch (_) {} // the child may have exited and closed its stdin: its exit says the rest
}

/// [source] into [process]'s stdin a chunk at a time, each written before the next is read. The
/// source is let go when the child exits, so a stream that never ends does not outlive the run.
Future<void> _pump(Stream<List<int>> source, Process process, void Function(Object why) halt) {
  final pumped = Completer<void>();
  late final StreamSubscription<List<int>> reading;
  void end() {
    if (pumped.isCompleted) return;
    pumped.complete();
    reading.cancel().ignore();
  }

  reading = source.listen(
    (chunk) {
      try {
        process.stdin.add(chunk);
        reading.pause(process.stdin.flush().catchError((Object _) => end())); // a closed pipe: the exit says the rest
      } on StateError catch (_) {
        end(); // its stdin is closed: the exit says the rest
      }
    },
    onError: (Object e) {
      halt(e);
      end();
    },
    onDone: end,
    cancelOnError: true,
  );
  process.exitCode.then((_) => end());
  return pumped.future;
}

/// [command] run on this terminal: no capture, and ^C is the child's.
Task<void> _interact(Command command, _Scope scope, Duration? timeout) {
  _checkTimeout(timeout);
  final limit = timeout ?? scope.timeout;
  return TaskInternals.start(command, '$command', (work) async {
    if (scope.runner?._answer case final answer?) {
      final result = await answer(command);
      Io.stdout.write(result.stdout);
      Io.stderr.write(result.stderr);
      if (result.exitCode != 0) {
        throw ShellException(ShellResult._(command, result.exitCode, Uint8List(0), result.stderr));
      }
      return;
    }
    final place = scope.workdirOf(command);
    await _checkWorkdir(place, command);
    Future<void> body() async {
      // The terminal sends ^C to the child too: here it only must not end this process.
      final interrupts = ProcessSignal.sigint.watch().listen((_) {});
      ProcessBridge.interactive++;
      try {
        final child = await _launch(command, command, place, scope, ProcessStartMode.inheritStdio);
        final stop = _Stop([child], limit);
        try {
          switch (await Future.any<Object>([child.exitCode, stop.why])) {
            case final int code when code != 0:
              throw ShellException(ShellResult._(command, _shellCode(code), Uint8List(0), ''));
            case int():
              return;
            case final why:
              await stop.stopped;
              throw _stopped(why, () => ShellResult._(command, 124, Uint8List(0), ''));
          }
        } finally {
          stop.end();
        }
      } finally {
        ProcessBridge.interactive--;
        await interrupts.cancel();
      }
    }

    await (IoBridge.suspend?.call(body) ?? body());
  });
}

/// A [Sink] that hands each piece to a callback.
final class _Each implements Sink<String> {
  final void Function(String piece) _add;

  _Each(this._add);

  @override
  void add(String piece) => _add(piece);

  @override
  void close() {}
}

/// A child's output on its way to the terminal, decoded as one stream. While a spinner or a
/// board is drawn it goes a line at a time above it, through [IoBridge.above], instead of onto
/// its row.
final class _Echo {
  final bool err;
  final _partial = StringBuffer();
  late final Sink<List<int>> _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_Each(_write));

  _Echo({required this.err});

  StringSink get _sink => err ? Io.stderr : Io.stdout;

  void add(List<int> chunk) => _decoder.add(chunk);

  void _write(String chunk) {
    final above = IoBridge.above;
    if (above == null) {
      _sink.write(_partial.isEmpty ? chunk : '$_partial$chunk');
      _partial.clear();
      return;
    }
    // The newline is looked for in the chunk, so a long line held back is copied once, not per chunk.
    final end = chunk.lastIndexOf('\n') + 1;
    if (end == 0) {
      _partial.write(chunk);
      return;
    }
    final text = '$_partial${chunk.substring(0, end)}';
    _partial
      ..clear()
      ..write(chunk.substring(end));
    above(() => _sink.write(text));
  }

  void close() {
    _decoder.close();
    if (_partial.isEmpty) return;
    final rest = '$_partial';
    _partial.clear();
    if (IoBridge.above case final above?) {
      above(() => _sink.writeln(rest));
    } else {
      _sink.write(rest);
    }
  }
}
