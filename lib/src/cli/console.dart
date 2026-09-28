part of '../../cli.dart';

/// Coalesces redraws so a producer that reports per chunk does not issue a write
/// per chunk. Shared by every [_Live] renderer; they must not disagree about how often
/// the terminal is touched. Always draws the *latest* state.
class _FrameGate {
  static const _interval = Duration(milliseconds: 33);
  DateTime? _last;
  Timer? _timer;
  void Function()? _pending;

  void request(void Function() render) {
    final now = DateTime.now();
    if (_last == null || now.difference(_last!) >= _interval) {
      _timer?.cancel();
      _timer = null;
      _pending = null;
      render();
      _last = now;
    } else {
      _pending = render;
      _timer ??= Timer(_interval, flush);
    }
  }

  /// Draws a deferred frame now, so `done()` never leaves the last state unrendered.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final render = _pending;
    _pending = null;
    if (render != null) {
      render();
      _last = DateTime.now();
    }
  }
}

int _columnsOr(int? fixed) => fixed != null && fixed > 0 ? fixed : Io.columns ?? 80;

String _bar(int current, int total, String message) {
  const barLength = 20;
  final percent = total > 0 ? ((current / total) * 100).clamp(0, 100).toInt() : 0;
  final filled = total > 0 ? ((current / total) * barLength).clamp(0, barLength).toInt() : 0;
  final bar = '=' * filled + '-' * (barLength - filled);
  final prefix = message.isNotEmpty ? '$message: ' : '';
  return '  $prefix[$bar] $percent% ($current/$total)';
}

bool _interactive() => Io.isTerminal && Io.color;

/// Whether an indicator is shown at all: `-q` asks for warnings and errors only, and a
/// spinner, a bar or a board is neither.
bool _shown() => Console.isEnabled(LogLevel.info);

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  var value = bytes / 1024;
  for (final unit in const ['KB', 'MB']) {
    if (value < 1024) return '${value.toStringAsFixed(1)} $unit';
    value /= 1024;
  }
  return '${value.toStringAsFixed(1)} GB';
}

// ---- the live region -------------------------------------------------------------------

/// A renderer that owns the bottom rows of the terminal and can redraw them in place.
///
/// The one reason [Console] can mix a spinner with a log line. Only the innermost live
/// renderer is on screen; anything durable — a log line, a rule, a prompt — [_wipe]s it,
/// writes where it stood, and [_paint]s it again underneath. Without this the two write to
/// the same row and garble each other, which is what they used to do.
abstract class _Live {
  /// Rows this renderer put on screen last frame.
  int _rows = 0;

  final _frames = _FrameGate();

  /// The lines this renderer wants on screen right now.
  List<String> _lines();

  /// Whether it still wants to be drawn at all; a finished one never repaints.
  bool get _running;

  /// Redraws through the frame gate, and only while this is the renderer on screen.
  void _render() {
    if (!_running || !identical(Console._top, this)) return;
    _frames.request(_paint);
  }

  /// The cursor ends on the row below the last line, so every renderer agrees about
  /// where it left the terminal and [_wipe] is the same three moves for all of them.
  void _paint() {
    if (!_interactive() || !_running) return;
    final lines = _lines();
    final buffer = StringBuffer();
    if (_rows > 0) buffer.write('\x1b[${_rows}A');
    for (final line in lines) {
      buffer.write('\r\x1b[K$line\n');
    }
    // Rows the last frame used and this one does not: a board whose slot count shrank.
    for (var i = lines.length; i < _rows; i++) {
      buffer.write('\r\x1b[K\n');
    }
    if (_rows > lines.length) buffer.write('\x1b[${_rows - lines.length}A');
    Io.out.write(buffer.toString());
    _rows = lines.length;
  }

  /// Clears the rows and leaves the cursor where the first one was.
  void _wipe() {
    _frames.flush();
    if (!_interactive() || _rows == 0) return;
    final buffer = StringBuffer('\x1b[${_rows}A');
    for (var i = 0; i < _rows; i++) {
      buffer.write('\r\x1b[K\n');
    }
    buffer.write('\x1b[${_rows}A');
    Io.out.write(buffer.toString());
    _rows = 0;
  }
}

// ---- spinners --------------------------------------------------------------------------

/// The frames an indeterminate [Spinner] cycles through, and how fast.
///
/// The named ones cover what a terminal usually wants; the constructor takes any frames,
/// so a program with its own is not stuck choosing from this list:
///
/// ```dart
/// const pulse = SpinnerStyle(['·', 'o', 'O', 'o'], interval: Duration(milliseconds: 120));
/// Console.spinner('Waiting', style: pulse);
/// ```
///
/// {@category Terminal}
final class SpinnerStyle {
  /// The frames, drawn in order and wrapped around.
  final List<String> frames;

  /// How long each frame stays on screen.
  final Duration interval;

  const SpinnerStyle(this.frames, {this.interval = const Duration(milliseconds: 80)});

  /// The rotating braille dot, the default: eight dots in one cell, so it turns in place
  /// without changing width.
  static const braille = SpinnerStyle(['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']);

  /// A single braille dot orbiting the cell — quieter than [braille].
  static const dot = SpinnerStyle(['⠁', '⠂', '⠄', '⡀', '⢀', '⠠', '⠐', '⠈']);

  /// ASCII, for a terminal or a font that will not draw braille.
  static const line = SpinnerStyle([r'-', r'\', r'|', r'/'], interval: Duration(milliseconds: 100));

  /// A growing and shrinking ellipsis, for waiting on something slow.
  static const ellipsis = SpinnerStyle(['   ', '.  ', '.. ', '...'], interval: Duration(milliseconds: 300));

  /// A bar that rises and falls.
  static const bar = SpinnerStyle(['▁', '▃', '▄', '▅', '▆', '▇', '▆', '▅', '▄', '▃']);

  /// A circling arc.
  static const arc = SpinnerStyle(['◜', '◠', '◝', '◞', '◡', '◟'], interval: Duration(milliseconds: 100));
}

/// An indeterminate spinner, for work with no measurable size.
///
/// [Console.spin] wraps an action and is the shorter way in when the work is one call.
/// This is the handle for when it is not: the message changes as the work moves on, and
/// the program decides how it ends.
///
/// ```dart
/// final spinner = Console.spinner('Connecting');
/// spinner.text = 'Fetching the index';
/// Console.info('found 12 files');        // scrolls above; the spinner keeps spinning
/// spinner.succeed('12 files indexed');
/// ```
///
/// Without a terminal it writes one line when it starts and one when it ends, so a log
/// captured from CI reads the same without the animation.
///
/// {@category Terminal}
final class Spinner extends _Live {
  /// The frames being drawn.
  final SpinnerStyle style;

  final Stopwatch _watch = Stopwatch();
  String _text;
  Timer? _timer;
  int _frame = 0;
  bool _stopped = false;

  Spinner._(this._text, this.style);

  /// The message beside the frame. Assigning redraws it without restarting the animation.
  String get text => _text;

  set text(String value) {
    if (_text == value) return;
    _text = value;
    _render();
  }

  /// How long this spinner has been running.
  Duration get elapsed => _watch.elapsed;

  /// Whether it is still spinning.
  bool get isSpinning => !_stopped;

  @override
  bool get _running => !_stopped;

  @override
  List<String> _lines() {
    final frame = style.frames[_frame % style.frames.length];
    final time = _watch.elapsed.humanized;
    // The text is cut, never the styled line: truncating a string with escapes in it can
    // cut one in half and leave the terminal wearing the colour. A line wider than the
    // terminal wraps, and the next frame then climbs one row too few; so on a narrow one
    // the time goes first, then the text.
    final width = _columnsOr(null) - 1;
    final room = width - Io.width(frame) - Io.width(time) - 4;
    if (room >= 1) return ['${frame.cyan} ${Io.truncate(_text, room)} (${time.dim})'];
    return ['${frame.cyan} ${Io.truncate(_text, max(0, width - Io.width(frame) - 1))}'];
  }

  void _start() {
    _watch.start();
    if (!_shown()) return;
    if (_interactive()) {
      Console._push(this);
      _timer = Timer.periodic(style.interval, (_) {
        if (_stopped) return;
        _frame++;
        _render();
      });
    } else {
      Io.out.writeln('  ${style.frames.first} $_text...');
    }
  }

  /// Ends it with `✓ message`, on stdout.
  void succeed([String? message]) => _finish('✓', message ?? _text, (s) => s.green, LogLevel.info);

  /// Ends it with `✖ message`, on stderr.
  void fail([String? message]) => _finish('✖', message ?? _text, (s) => s.red, LogLevel.error);

  /// Ends it with `⚠ message`, on stderr.
  void warn([String? message]) => _finish('⚠', message ?? _text, (s) => s.yellow, LogLevel.warn);

  /// Ends it with `ℹ message`, on stdout.
  void info([String? message]) => _finish('ℹ', message ?? _text, (s) => s.cyan, LogLevel.info);

  /// Ends it with no final line at all.
  void stop() => _finish(null, null, null, LogLevel.info);

  /// The final line is a log line at [severity]: `-q` keeps a failure and drops a success.
  void _finish(String? mark, String? message, String Function(String)? paint, LogLevel severity) {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
    Console._pop(this);
    if (mark == null || message == null || paint == null) return;
    Console._log(severity, paint('  $mark $message (${_watch.elapsed.humanized.dim})'));
  }
}

// ---- a bar and a board -----------------------------------------------------------------

/// What a [ProgressBar] and a [TaskBoard] share: a count toward a total, a label, a width,
/// and one way to end.
abstract class _Meter extends _Live {
  /// The label drawn before the bar.
  final String message;

  /// A fixed width, or `null` to follow the terminal.
  final int? columns;

  int _current = 0;
  bool _isDone = false;

  _Meter(this.message, this.columns);

  /// Steps counted so far.
  int get current => _current;

  /// Whether [done] has been called.
  bool get isDone => _isDone;

  @override
  bool get _running => !_isDone;

  /// The widest a line may be: one short of the terminal, so it never wraps.
  int get _width => max(1, _columnsOr(columns) - 1);

  /// Shows this as the live renderer, if it is not already.
  void _show() {
    if (!_shown()) return;
    if (_interactive() && _rows == 0) Console._push(this);
    _render();
  }

  /// Ends it, with `✓ message` when there is one.
  void done([String? message]) {
    if (_isDone) return;
    _frames.flush();
    _isDone = true;
    Console._pop(this);
    if (message != null && message.isNotEmpty) Console._log(LogLevel.info, '  ✓ $message'.green);
  }
}

/// A single-line progress bar over [total] steps.
///
/// Created by [Console.progress]. Redraws are coalesced, so a caller may tick per chunk;
/// without a terminal a line is written when a new tenth is reached, not per tick.
///
/// {@category Terminal}
final class ProgressBar extends _Meter {
  /// Steps in the run.
  final int total;

  int _lastDecile = -1;
  String? _label;

  ProgressBar._(this.total, {String message = '', int? columns}) : super(message, columns);

  @override
  List<String> _lines() => [_line(_label).dim];

  /// The bar and [label], cut to fit the terminal.
  String _line([String? label]) {
    final base = _bar(_current, total, message);
    // " ($label)" takes three columns of its own.
    final room = _width - Io.width(base);
    final line = label != null && label.isNotEmpty && room > 5 ? '$base (${Io.truncate(label, room - 3)})' : base;
    return Io.truncate(line, _width);
  }

  /// Advances the progress by [count] and optionally displays [label].
  void tick([int count = 1, String? label]) {
    if (_isDone) return;
    _current += count;
    if (label != null) _label = label;
    if (_interactive() || !_shown()) return _show();
    final decile = total > 0 ? (_current * 10 ~/ total).clamp(0, 10) : 0;
    if (decile == _lastDecile) return;
    _lastDecile = decile;
    Io.out.writeln(_line(label));
  }
}

/// One row of a [TaskBoard]: the last update its task sent, and when.
final class _Slot {
  TaskProgress? task;
  DateTime seen = DateTime.now();
}

/// A multi-line board of concurrent tasks: a header bar and one row per worker.
///
/// Created by [Console.tasks] and driven by [report]; it renders whatever a
/// [BatchProgress] carries, so any producer that speaks that interface — a batch download,
/// a crawl — can be shown without either side knowing about the other.
///
/// {@category Terminal}
final class TaskBoard extends _Meter {
  /// Steps in the batch. A stream-sourced batch revises it upward as work is discovered.
  int total;

  /// How many task rows are drawn, or `null` to grow a row for each task running at once —
  /// as many as the batch's concurrency, found out rather than repeated — up to [_most].
  final int? slots;

  final List<_Slot> _slots;
  final Map<String, _Slot> _slotByTask = {};

  /// The most rows a board grows to by itself; past that, the task updated longest ago
  /// gives up its row.
  static const _most = 8;

  TaskBoard._(this.total, {this.slots, String message = '', int? columns})
    : _slots = List.generate(max(1, slots ?? 1), (_) => _Slot()),
      super(message, columns);

  /// The header bar, then one line per slot.
  @override
  List<String> _lines() => [
    Io.truncate(_bar(_current, total, message), _width).dim,
    for (final (i, slot) in _slots.indexed) _row(slot.task, i == _slots.length - 1 ? '  └─ ' : '  ├─ ').dim,
  ];

  String _row(TaskProgress? task, String prefix) {
    if (task == null) return '$prefix(idle)';
    final (bar, percent) = switch (task.ratio) {
      final ratio? => switch ((ratio * 10).clamp(0, 10).toInt()) {
        final filled => (
          '${'=' * max(0, filled - 1)}${filled > 0 ? '>' : ''}${'-' * (10 - filled)}',
          '${(ratio * 100).clamp(0, 100).toInt()}%'.padLeft(4),
        ),
      },
      null => ('----------', ' --%'),
    };
    final size = switch ((task.received, task.total)) {
      (final got?, final all?) when all > 0 => '(${_formatBytes(got)}/${_formatBytes(all)}) ',
      (final got?, _) when got > 0 => '(${_formatBytes(got)}) ',
      _ => '',
    };
    final status = switch (task.status) {
      final s? when s.isNotEmpty => ' [$s]',
      _ => '',
    };
    return Io.truncate('$prefix[$bar] $percent $size${task.label}$status', _width);
  }

  /// The slot [taskId] is drawn in: its own, a free one, a new one while the board may
  /// grow, or the one updated longest ago.
  _Slot _slotFor(String taskId) => _slotByTask[taskId] ??= () {
    final free = _slots.where((s) => s.task == null || s.task!.isDone).firstOrNull;
    if (free == null && slots == null && _slots.length < _most) {
      final grown = _Slot();
      _slots.add(grown);
      return grown;
    }
    final slot = free ?? _slots.reduce((a, b) => b.seen.isBefore(a.seen) ? b : a);
    _slotByTask.remove(slot.task?.taskId);
    return slot;
  }();

  /// Renders one [BatchProgress] update: the overall count, a revised [total], and
  /// the current task's slot.
  void report(BatchProgress batch) {
    if (_isDone) return;
    if (batch.total case final discovered? when discovered > total) total = discovered;
    _current = batch.completed;

    final task = batch.current;
    _slotFor(task.taskId)
      ..task = task
      ..seen = DateTime.now();
    if (task.isDone) {
      _slotByTask.remove(task.taskId);
      // Without a terminal there is no cursor to move: one durable line per finished task.
      if (!_interactive() && _shown()) {
        final size = switch (task.total) {
          final all? when all > 0 => ' (${_formatBytes(all)})',
          _ => '',
        };
        Io.out.writeln('  [$_current/$total] ${task.label}$size [${task.status ?? 'done'}]');
      }
    }
    _show();
  }
}

// ---- logging ---------------------------------------------------------------------------

/// Severity levels for [Console]'s log verbs, ordered from most to least verbose.
///
/// {@category CLI}
enum LogLevel {
  /// Everything, including [Console.debug].
  debug,

  /// Informational messages and above (the default).
  info,

  /// Warnings and errors only.
  warn,

  /// Errors only.
  error,

  /// Suppresses all output.
  silent,
}

/// A self-numbering sequence of stage banners. Created by [Console.stages].
///
/// {@category CLI}
class Stages {
  /// How many stages the run has.
  final int total;
  int _current = 0;

  Stages._(this.total);

  /// Prints the next stage banner: `[n/total] message`.
  void call(String message) => Console._log(LogLevel.info, '[${++_current}/$total] $message'.cyan.bold);
}

// ---- the namespace ---------------------------------------------------------------------

/// The terminal: logging, rules, spinners, progress, boards and prompts.
///
/// One namespace for everything that reaches a terminal, and one live region underneath it,
/// so the parts compose: a log line written while a spinner is running scrolls above it
/// rather than landing on top of it, and a prompt asked mid-download does the same.
///
/// At end of input — piped stdin, CI — a prompt falls back to its default rather than
/// looping forever, or throws [StateError] when it has none.
///
/// {@category Terminal}
class Console {
  // ---- the live region ----

  /// The renderers on screen, innermost last; only that one is drawn.
  static final List<_Live> _stack = [];

  static _Live? get _top => _stack.lastOrNull;

  static void _push(_Live live) {
    if (_stack.contains(live)) return;
    _top?._wipe();
    _stack.add(live);
    IoBridge.above = _durable;
    live._paint();
  }

  static void _pop(_Live live) {
    final index = _stack.indexOf(live);
    if (index == -1) return;
    final wasTop = index == _stack.length - 1;
    if (wasTop) live._wipe();
    _stack.removeAt(index);
    if (_stack.isEmpty) IoBridge.above = null;
    if (wasTop) _top?._paint();
  }

  /// Writes something that stays on screen, above whatever is live.
  ///
  /// Every verb on this class goes through here. A renderer holding the bottom rows is
  /// cleared, [write] lands where it stood, and the renderer is drawn again below it.
  static void _durable(void Function() write) {
    final live = _top?.._wipe();
    write();
    live?._paint();
  }

  /// Writes [message] durably, above any spinner or progress bar on screen.
  ///
  /// The unlevelled escape hatch: everything [Io.out.writeln] does, without landing on top
  /// of a live renderer. Prefer a log verb when the line has a severity.
  static void writeln([String message = '']) => _durable(() => Io.out.writeln(message));

  // ---- logging ----

  static const _levelKey = #dartToolkitLogLevel;
  static LogLevel _processLevel = LogLevel.info;

  /// The minimum severity that is emitted. Defaults to [LogLevel.info].
  ///
  /// Reads the level [silenced] set for the work in progress, if any, and otherwise the
  /// process-wide one that assigning to this sets.
  static LogLevel get level => Zone.current[_levelKey] as LogLevel? ?? _processLevel;

  static set level(LogLevel value) => _processLevel = value;

  /// Whether [level] currently permits [candidate] to be written.
  static bool isEnabled(LogLevel candidate) => candidate.index >= level.index && level != LogLevel.silent;

  /// Runs [action], sync or async, with logging suppressed.
  ///
  /// The suppression belongs to [action] and what it awaits — not to the process — so a
  /// task running beside it still reports. `Http.scope` scopes its client the same way.
  static Future<T> silenced<T>(FutureOr<T> Function() action) =>
      runZoned(() async => action(), zoneValues: {_levelKey: LogLevel.silent});

  /// A counter over [total] stages, printing `[n/total] message` on each call.
  ///
  /// ```dart
  /// final stage = Console.stages(3);
  /// stage('Scraping metadata');   // [1/3] Scraping metadata
  /// ```
  static Stages stages(int total) => Stages._(total);

  /// Writes [line] at [severity], warnings and errors on stderr.
  static void _log(LogLevel severity, String line) {
    if (!isEnabled(severity)) return;
    _durable(() => (severity.index >= LogLevel.warn.index ? Io.err : Io.out).writeln(line));
  }

  // Each verb takes any object and writes its `toString()`: an exception, a failure or a
  // count is logged as it is, without a `'$e'` at every call site.

  /// Logs a verbose diagnostic message: `  · message`.
  static void debug(Object? message) => _log(LogLevel.debug, '  · $message'.dim);

  /// Logs a success message: `  ✓ message`. Filtered at [LogLevel.info], like [info].
  static void ok(Object? message) => _log(LogLevel.info, '  ✓ $message'.green);

  /// Logs an informational message: `  ℹ message`.
  static void info(Object? message) => _log(LogLevel.info, '  ℹ $message'.cyan);

  /// Logs a warning message to standard error: `  ⚠ message`.
  static void warn(Object? message) => _log(LogLevel.warn, '  ⚠ $message'.yellow);

  /// Logs an error message to standard error: `  ✖ message`.
  static void error(Object? message) => _log(LogLevel.error, '  ✖ $message'.red);

  // ---- prompts ----
  //
  // Every prompt is async. One that blocked this isolate in `readLineSync` also blocked
  // `Cli.run`'s signal handler, so ^C was swallowed and the prompt came back empty; the read
  // now blocks a helper isolate instead (see [Io.readLine]) and ^C ends the program.

  /// Runs [body] with the live region cleared, and draws it again afterwards.
  static Future<T> _prompt<T>(Future<T> Function() body) async {
    final live = _top?.._wipe();
    try {
      return await body();
    } finally {
      live?._paint();
    }
  }

  /// Writes [question] and reads one trimmed line, or `null` at end of input.
  ///
  /// A prompt talks to the person, not to the pipe: every word of it goes to stderr, so
  /// `app > out.txt` captures the answer's result and none of the questions.
  static Future<String?> _answer(String question) async {
    Io.err.write(question);
    return (await Io.readLine())?.trim();
  }

  /// Says what was wrong with an answer, where the question was asked.
  static void _reject(String message) => Io.err.writeln('  $message'.red);

  /// Whether [secret] has echo off right now, so the way out can turn it back on.
  static bool _echoOff = false;

  /// Puts the terminal back as a prompt found it: what a signal does before it leaves.
  static void _restoreTerminal() {
    if (!_echoOff) return;
    _echoOff = false;
    try {
      stdin.echoMode = true;
    } catch (_) {}
  }

  /// Prompts for text input, returning [or] on an empty answer.
  ///
  /// [validate] returns an error message to re-prompt, or `null` to accept.
  /// At end of input the default is used, or a [StateError] is thrown when a
  /// [required] value has none.
  ///
  /// ```dart
  /// final port = await Console.ask('Port', or: '8080',
  ///     validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
  /// ```
  static Future<String> ask(
    String message, {
    String? or,
    bool required = false,
    String? Function(String value)? validate,
  }) => _prompt(() async {
    assert(!(required && or != null), 'A required prompt cannot also have a default.');
    while (true) {
      final input = await _answer('$message${or != null ? ' ($or)'.dim : ''}: ');
      if (input == null) {
        if (required) throw StateError('No input available for required prompt: $message');
        return or ?? '';
      }
      final value = input.isEmpty ? (or ?? '') : input;
      final error = value.isEmpty && required ? 'Value cannot be empty.' : validate?.call(value);
      if (error == null) return value;
      _reject(error);
    }
  });

  /// Prompts for a yes/no confirmation, returning [or] on an empty answer.
  ///
  /// Anything but a yes or a no asks again: a typo of `yes` is not a no.
  static Future<bool> confirm(String message, {bool or = true}) => _prompt(() async {
    while (true) {
      final input = (await _answer('$message ${(or ? '[Y/n]' : '[y/N]').dim}: '))?.toLowerCase();
      if (input == null || input.isEmpty) return or;
      if (const {'y', 'yes', 'true', '1'}.contains(input)) return true;
      if (const {'n', 'no', 'false', '0'}.contains(input)) return false;
      _reject('Please answer y or n.');
    }
  });

  /// Prompts for sensitive input, hiding typed characters.
  static Future<String> secret(String message) => _prompt(() async {
    try {
      if (Io.input == null && stdin.hasTerminal) {
        stdin.echoMode = false;
        _echoOff = true;
      }
    } catch (_) {}
    try {
      final input = await _answer('$message: ') ?? '';
      Io.err.writeln();
      return input;
    } finally {
      _restoreTerminal();
    }
  });

  /// Prompts for one of [choices], of any element type.
  ///
  /// [display] renders each choice, which keeps records and domain objects usable:
  /// `await Console.select('Target', servers, display: (s) => s.name)`.
  ///
  /// Throws [ArgumentError] at once when [or] is not one of [choices], as `Opt.or` does: a
  /// default the prompt cannot offer is a bug in the call, not in the answer.
  static Future<T> select<T>(String message, List<T> choices, {T? or, String Function(T choice)? display}) {
    if (choices.isEmpty) throw ArgumentError('Choices cannot be empty');
    String label(T choice) => display?.call(choice) ?? '$choice';
    final fallback = or != null ? choices.indexOf(or) : -1;
    if (or != null && fallback < 0) {
      throw ArgumentError.value(or, 'or', 'Not one of ${choices.map(label).join(', ')}');
    }
    return _prompt(() async {
      Io.err.writeln('$message:');
      for (final (i, choice) in choices.indexed) {
        Io.err.writeln('  ${i + 1}) ${label(choice)}${i == fallback ? ' (default)'.dim : ''}');
      }
      while (true) {
        final input = await _answer('Select [1-${choices.length}]${fallback >= 0 ? ' [${fallback + 1}]' : ''}: ');
        if ((input == null || input.isEmpty) && fallback >= 0) return choices[fallback];
        if (input == null) throw StateError('No input available for required prompt: $message');
        if (int.tryParse(input) case final n? when n >= 1 && n <= choices.length) return choices[n - 1];
        if (choices.where((c) => label(c) == input).firstOrNull case final match?) return match;
        _reject('Invalid choice, please enter a number from 1 to ${choices.length}.');
      }
    });
  }

  // ---- the screen ----

  /// Clears the terminal screen.
  static void clear() {
    if (!_interactive()) return;
    _stack.clear();
    IoBridge.above = null;
    Io.out.write('\x1B[2J\x1B[0;0H');
  }

  /// Renders a horizontal divider rule across the terminal with an optional centered [title].
  static void rule([String? title]) => _durable(() {
    final cols = Io.columns ?? 80;
    if (title == null || title.isEmpty) return Io.out.writeln('─' * cols);
    final titleLen = Io.width(title) + 2;
    if (titleLen >= cols) return Io.out.writeln('── $title ──');
    final side = (cols - titleLen) ~/ 2;
    Io.out.writeln('${'─' * side} $title ${'─' * (cols - titleLen - side)}'.cyan);
  });

  // ---- indicators ----

  /// A single-line progress bar over [total] steps.
  static ProgressBar progress(int total, {String message = '', int? columns}) =>
      ProgressBar._(total, message: message, columns: columns);

  /// A board of task rows under one header bar: [slots] of them, or by default one for
  /// each task that runs at once.
  ///
  /// Omit [total] when the work is still being discovered; [TaskBoard.report] revises it
  /// upward as it arrives.
  static TaskBoard tasks({int total = 0, int? slots, String message = '', int? columns}) =>
      TaskBoard._(total, slots: slots, message: message, columns: columns);

  /// An indeterminate spinner, started and left running until the caller ends it.
  ///
  /// ```dart
  /// final spinner = Console.spinner('Connecting');
  /// spinner.text = 'Fetching the index';
  /// spinner.succeed('12 files indexed');
  /// ```
  ///
  /// Use [spin] instead when the work is a single call: it ends the spinner for you.
  static Spinner spinner(String message, {SpinnerStyle style = SpinnerStyle.braille}) =>
      Spinner._(message, style).._start();

  /// Runs [action] behind an indeterminate spinner; [done] and [failed] replace [message]
  /// on the final line. Whatever [action] returns comes back; whatever it throws is rethrown
  /// after the failure line.
  static Future<T> spin<T>(
    String message,
    FutureOr<T> Function() action, {
    String? done,
    String? failed,
    SpinnerStyle style = SpinnerStyle.braille,
  }) async {
    final spinner = Console.spinner(message, style: style);
    try {
      final result = await action();
      spinner.succeed(done);
      return result;
    } catch (e) {
      spinner.fail(failed ?? '$message failed: $e');
      rethrow;
    }
  }
}

/// Rendering a batch as it runs.
///
/// {@category Terminal}
extension StreamBatchProgressExtensions<T extends BatchProgress> on Stream<T> {
  /// Draws this batch in a [TaskBoard] until it ends, then prints [done].
  ///
  /// The board has a row for each task running at once, so it matches the batch's
  /// concurrency without being told it; [slots] fixes the count instead.
  ///
  /// Returns the last event, or `null` for an empty batch.
  ///
  /// ```dart
  /// final last = await pairs.download(concurrency: 4).show(message: 'Downloading');
  /// ```
  Future<T?> show({int? slots, String message = '', String? done, int? columns}) async {
    final board = Console.tasks(slots: slots, message: message, columns: columns);
    T? last;
    var failed = true;
    try {
      await for (final p in this) {
        board.report(last = p);
      }
      failed = false;
    } finally {
      board.done(failed ? null : done);
    }
    return last;
  }
}
