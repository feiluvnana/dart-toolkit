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

int _columnsOr(int? fixed) {
  if (fixed != null && fixed > 0) return fixed;
  return Io.columns ?? 80;
}

String _bar(int current, int total, String message) {
  const barLength = 20;
  final percent = total > 0 ? ((current / total) * 100).clamp(0, 100).toInt() : 0;
  final filled = total > 0 ? ((current / total) * barLength).clamp(0, barLength).toInt() : 0;
  final bar = '=' * filled + '-' * (barLength - filled);
  final prefix = message.isNotEmpty ? '$message: ' : '';
  return '  $prefix[$bar] $percent% ($current/$total)';
}

bool _interactive() => Io.isTerminal && Io.color;

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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
    // cut one in half and leave the terminal wearing the colour.
    final room = max(10, _columnsOr(null) - Io.width(frame) - Io.width(time) - 6);
    return ['${frame.cyan} ${Io.truncate(_text, room)} (${time.dim})'];
  }

  void _start() {
    _watch.start();
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
  void succeed([String? message]) => _finish('✓', message ?? _text, (s) => s.green, err: false);

  /// Ends it with `✖ message`, on stderr.
  void fail([String? message]) => _finish('✖', message ?? _text, (s) => s.red, err: true);

  /// Ends it with `⚠ message`, on stderr.
  void warn([String? message]) => _finish('⚠', message ?? _text, (s) => s.yellow, err: true);

  /// Ends it with `ℹ message`, on stdout.
  void info([String? message]) => _finish('ℹ', message ?? _text, (s) => s.cyan, err: false);

  /// Ends it with no final line at all.
  void stop() => _finish(null, null, null, err: false);

  void _finish(String? mark, String? message, String Function(String)? paint, {required bool err}) {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
    Console._pop(this);
    if (mark == null || message == null || paint == null) return;
    (err ? Io.err : Io.out).writeln(paint('  $mark $message (${_watch.elapsed.humanized.dim})'));
  }

  static Future<T> run<T>(
    String message,
    FutureOr<T> Function() action, {
    String? done,
    String? failed,
    SpinnerStyle style = SpinnerStyle.braille,
  }) async {
    final spinner = Spinner._(message, style).._start();
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

// ---- a bar for one measurable thing ----------------------------------------------------

/// A single-line progress bar over [total] steps.
///
/// Created by [Console.progress]. Redraws are coalesced, so a caller may tick per chunk;
/// without a terminal a line is written when a new tenth is reached, not per tick.
///
/// {@category Terminal}
final class ProgressBar extends _Live {
  /// Steps in the run.
  final int total;

  /// The label drawn before the bar.
  final String message;

  /// A fixed width, or `null` to follow the terminal.
  final int? columns;

  int _current = 0;
  bool _isDone = false;
  int _lastDecile = -1;
  String? _label;

  ProgressBar._(this.total, {this.message = '', this.columns});

  /// Steps counted so far.
  int get current => _current;

  /// Whether [done] has been called.
  bool get isDone => _isDone;

  @override
  bool get _running => !_isDone;

  @override
  List<String> _lines() => [formatLine(_label).dim];

  /// Formats the single-line progress text for current progress and [label],
  /// truncated to fit within terminal bounds.
  String formatLine([String? label]) {
    final base = _bar(_current, total, message);
    final maxCols = max(20, _columnsOr(columns) - 1);

    var line = base;
    if (label != null && label.isNotEmpty) {
      final availableForSuffix = maxCols - Io.width(base);
      // " ($label)" requires 3 columns for " (" and ")"
      if (availableForSuffix > 5) line = '$base (${Io.truncate(label, availableForSuffix - 3)})';
    }
    return Io.truncate(line, maxCols);
  }

  /// Advances the progress by [count] and optionally displays [label].
  void tick([int count = 1, String? label]) {
    if (_isDone) return;
    _current += count;
    if (label != null) _label = label;
    if (_interactive()) {
      if (_rows == 0) Console._push(this);
      _render();
    } else {
      final decile = total > 0 ? (_current * 10 ~/ total).clamp(0, 10) : 0;
      if (decile != _lastDecile) {
        _lastDecile = decile;
        Io.out.writeln(formatLine(label));
      }
    }
  }

  /// Marks progress as done with an optional final [message].
  void done([String? message]) {
    if (_isDone) return;
    _frames.flush();
    _isDone = true;
    Console._pop(this);
    if (message != null && message.isNotEmpty) Io.out.writeln('  ✓ $message'.green);
  }
}

class _ProgressSlot {
  String? taskId;
  String label = '';
  double? ratio;
  int? received;
  int? total;
  String? status;
  bool isDone = false;
  DateTime lastUpdated = DateTime.now();

  void update(TaskProgress task) {
    taskId = task.taskId;
    label = task.label;
    ratio = task.ratio;
    received = task.received;
    total = task.total;
    status = task.status;
    isDone = task.isDone;
    lastUpdated = DateTime.now();
  }
}

/// A multi-line board of concurrent tasks: a header bar and one row per worker.
///
/// Created by [Console.tasks] and driven by [report]; it renders whatever a
/// [BatchProgress] carries, so any producer that speaks that interface — a batch download,
/// a crawl — can be shown without either side knowing about the other.
///
/// {@category Terminal}
final class TaskBoard extends _Live {
  /// Steps in the batch. A stream-sourced batch revises it upward as work is discovered.
  int total;

  /// How many task rows are drawn.
  final int slots;

  /// The label drawn before the header bar.
  final String message;

  /// A fixed width, or `null` to follow the terminal.
  final int? columns;

  int _current = 0;
  bool _isDone = false;
  final List<_ProgressSlot> _slotList;
  final Map<String, int> _slotByTask = {};

  TaskBoard._(this.total, {this.slots = 4, this.message = '', this.columns})
    : _slotList = List.generate(slots > 0 ? slots : 1, (_) => _ProgressSlot());

  /// Steps finished so far.
  int get current => _current;

  /// Whether [done] has been called.
  bool get isDone => _isDone;

  @override
  bool get _running => !_isDone;

  @override
  List<String> _lines() => formatLines();

  /// Formats the board's lines: the header bar, then one line per slot.
  List<String> formatLines() {
    final maxCols = max(20, _columnsOr(columns) - 1);
    return [
      Io.truncate(_bar(_current, total, message), maxCols).dim,
      for (var i = 0; i < _slotList.length; i++)
        _formatSlotLine(_slotList[i], i == _slotList.length - 1 ? '  └─ ' : '  ├─ ', maxCols).dim,
    ];
  }

  String _formatSlotLine(_ProgressSlot slot, String prefix, int maxCols) {
    if (slot.taskId == null && slot.label.isEmpty) return '$prefix(idle)';

    const subBarLen = 10;
    final ratio = slot.ratio;
    final String barStr;
    final String percentStr;

    if (ratio != null) {
      final percent = (ratio * 100).clamp(0, 100).toInt();
      final filled = (ratio * subBarLen).clamp(0, subBarLen).toInt();
      final barChars = '=' * max(0, filled - 1) + (filled > 0 ? '>' : '') + '-' * (subBarLen - filled);
      barStr = '[$barChars]';
      percentStr = '$percent%'.padLeft(4);
    } else {
      barStr = '[----------]';
      percentStr = ' --%';
    }

    var sizeStr = '';
    if (slot.received != null && slot.total != null && slot.total! > 0) {
      sizeStr = '(${_formatBytes(slot.received!)}/${_formatBytes(slot.total!)}) ';
    } else if (slot.received != null && slot.received! > 0) {
      sizeStr = '(${_formatBytes(slot.received!)}) ';
    }

    final statusSuffix = slot.status != null && slot.status!.isNotEmpty ? ' [${slot.status}]' : '';
    return Io.truncate('$prefix$barStr $percentStr $sizeStr${slot.label}$statusSuffix', maxCols);
  }

  /// Without a terminal there is no cursor to move, so emit one durable line per
  /// completed task instead of a redrawn frame.
  void _renderCompletion(_ProgressSlot slot) {
    if (_isDone || Io.isTerminal) return;
    final status = slot.status ?? 'done';
    final size = slot.total != null && slot.total! > 0 ? ' (${_formatBytes(slot.total!)})' : '';
    Io.out.writeln('  [$_current/$total] ${slot.label}$size [$status]');
  }

  int _slotFor(String taskId) {
    final existing = _slotByTask[taskId];
    if (existing != null) return existing;

    var found = _slotList.indexWhere((s) => s.taskId == null || s.isDone);
    if (found == -1) {
      found = 0;
      for (var i = 1; i < _slotList.length; i++) {
        if (_slotList[i].lastUpdated.isBefore(_slotList[found].lastUpdated)) found = i;
      }
    }
    final oldTask = _slotList[found].taskId;
    if (oldTask != null) _slotByTask.remove(oldTask);
    _slotByTask[taskId] = found;
    return found;
  }

  /// Renders one [BatchProgress] update: the overall count, a revised [total], and
  /// the current task's slot.
  void report(BatchProgress batch) {
    if (_isDone) return;
    final discovered = batch.total;
    if (discovered != null && discovered > total) total = discovered;
    _current = batch.completed;

    final task = batch.current;
    final slot = _slotList[_slotFor(task.taskId)]..update(task);
    if (task.isDone) {
      _slotByTask.remove(task.taskId);
      _renderCompletion(slot);
    }
    if (_interactive() && _rows == 0) Console._push(this);
    _render();
  }

  /// Marks the board as done with an optional final [message].
  void done([String? message]) {
    if (_isDone) return;
    _frames.flush();
    _isDone = true;
    Console._pop(this);
    if (message != null && message.isNotEmpty) Io.out.writeln('  ✓ $message'.green);
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

  Stages(this.total);

  /// Prints the next stage banner: `[n/total] message`.
  void call(String message) {
    _current++;
    if (!Console.isEnabled(LogLevel.info)) return;
    Console._durable(() => Io.out.writeln('[$_current/$total] $message'.cyan.bold));
  }
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

  static _Live? get _top => _stack.isEmpty ? null : _stack.last;

  static void _push(_Live live) {
    if (_stack.contains(live)) return;
    _top?._wipe();
    _stack.add(live);
    live._paint();
  }

  static void _pop(_Live live) {
    final index = _stack.indexOf(live);
    if (index == -1) return;
    final wasTop = index == _stack.length - 1;
    if (wasTop) live._wipe();
    _stack.removeAt(index);
    if (wasTop) _top?._paint();
  }

  /// Writes something that stays on screen, above whatever is live.
  ///
  /// Every verb on this class goes through here. A renderer holding the bottom rows is
  /// cleared, [write] lands where it stood, and the renderer is drawn again below it.
  static void _durable(void Function() write) {
    final live = _top;
    if (live == null) {
      write();
      return;
    }
    live._wipe();
    write();
    live._paint();
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
  static Stages stages(int total) => Stages(total);

  /// Logs a verbose diagnostic message: `  · message`.
  static void debug(String message) {
    if (!isEnabled(LogLevel.debug)) return;
    _durable(() => Io.out.writeln('  · $message'.dim));
  }

  /// Logs a success message: `  ✓ message`. Filtered at [LogLevel.info], like [info].
  static void ok(String message) {
    if (!isEnabled(LogLevel.info)) return;
    _durable(() => Io.out.writeln('  ✓ $message'.green));
  }

  /// Logs an informational message: `  ℹ message`.
  static void info(String message) {
    if (!isEnabled(LogLevel.info)) return;
    _durable(() => Io.out.writeln('  ℹ $message'.cyan));
  }

  /// Logs a warning message to standard error: `  ⚠ message`.
  static void warn(String message) {
    if (!isEnabled(LogLevel.warn)) return;
    _durable(() => Io.err.writeln('  ⚠ $message'.yellow));
  }

  /// Logs an error message to standard error: `  ✖ message`.
  static void error(String message) {
    if (!isEnabled(LogLevel.error)) return;
    _durable(() => Io.err.writeln('  ✖ $message'.red));
  }

  // ---- prompts ----

  /// Reads one line, returning `null` at end of input.
  static String? _read() => Io.readLine(encoding: utf8)?.trim();

  /// Prompts for text input, returning [or] on an empty answer.
  ///
  /// [validate] returns an error message to re-prompt, or `null` to accept.
  /// At end of input the default is used, or a [StateError] is thrown when a
  /// [required] value has none.
  ///
  /// ```dart
  /// final port = Console.ask('Port', or: '8080',
  ///     validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
  /// ```
  static String ask(String message, {String? or, bool required = false, String? Function(String value)? validate}) {
    assert(!(required && or != null), 'A required prompt cannot also have a default.');
    final live = _top?.._wipe();
    try {
      while (true) {
        final defaultHint = or != null ? ' ($or)'.dim : '';
        Io.out.write('$message$defaultHint: ');
        final input = _read();

        if (input == null) {
          if (or != null) return or;
          if (!required) return '';
          throw StateError('No input available for required prompt: $message');
        }

        final value = input.isEmpty ? (or ?? '') : input;

        if (value.isEmpty && required) {
          Io.out.writeln('  Value cannot be empty.'.red);
          continue;
        }

        final error = validate?.call(value);
        if (error != null) {
          Io.out.writeln('  $error'.red);
          continue;
        }

        return value;
      }
    } finally {
      live?._paint();
    }
  }

  /// Prompts for a yes/no confirmation, returning [or] on an empty answer.
  static bool confirm(String message, {bool or = true}) {
    final live = _top?.._wipe();
    try {
      final hint = or ? '[Y/n]'.dim : '[y/N]'.dim;
      Io.out.write('$message $hint: ');
      final input = _read()?.toLowerCase();

      if (input == null || input.isEmpty) return or;
      return input == 'y' || input == 'yes' || input == 'true' || input == '1';
    } finally {
      live?._paint();
    }
  }

  /// Prompts for sensitive input, hiding typed characters.
  static String secret(String message) {
    final live = _top?.._wipe();
    Io.out.write('$message: ');
    var isEchoModeAvailable = false;
    try {
      if (Io.input == null && stdin.hasTerminal) {
        stdin.echoMode = false;
        isEchoModeAvailable = true;
      }
    } catch (_) {}

    try {
      final input = _read() ?? '';
      Io.out.writeln();
      return input;
    } finally {
      if (isEchoModeAvailable) {
        try {
          stdin.echoMode = true;
        } catch (_) {}
      }
      live?._paint();
    }
  }

  /// Prompts for one of [choices], of any element type.
  ///
  /// [display] renders each choice, which keeps records and domain objects usable:
  /// `Console.select('Target', servers, display: (s) => s.name)`.
  static T select<T>(String message, List<T> choices, {T? or, String Function(T choice)? display}) {
    if (choices.isEmpty) {
      throw ArgumentError('Choices cannot be empty');
    }

    String label(T choice) => display?.call(choice) ?? '$choice';

    final defaultIndex = or != null ? choices.indexOf(or) : -1;
    final live = _top?.._wipe();

    try {
      Io.out.writeln('$message:');
      for (var i = 0; i < choices.length; i++) {
        final marker = i == defaultIndex ? ' (default)'.dim : '';
        Io.out.writeln('  ${i + 1}) ${label(choices[i])}$marker');
      }

      while (true) {
        final defaultHint = defaultIndex >= 0 ? ' [${defaultIndex + 1}]' : '';
        Io.out.write('Select [1-${choices.length}]$defaultHint: ');
        final input = _read();

        if (input == null) {
          if (defaultIndex >= 0) return choices[defaultIndex];
          throw StateError('No input available for required prompt: $message');
        }

        if (input.isEmpty && defaultIndex >= 0) return choices[defaultIndex];

        final index = int.tryParse(input);
        if (index != null && index >= 1 && index <= choices.length) {
          return choices[index - 1];
        }

        final match = choices.where((c) => label(c) == input);
        if (match.isNotEmpty) return match.first;

        Io.out.writeln('  Invalid choice, please enter a number from 1 to ${choices.length}.'.red);
      }
    } finally {
      live?._paint();
    }
  }

  // ---- the screen ----

  /// Clears the terminal screen.
  static void clear() {
    if (!_interactive()) return;
    _stack.clear();
    Io.out.write('\x1B[2J\x1B[0;0H');
  }

  /// Renders a horizontal divider rule across the terminal with an optional centered [title].
  static void rule([String? title]) => _durable(() {
    final cols = Io.columns ?? 80;

    if (title == null || title.isEmpty) {
      Io.out.writeln('─' * cols);
      return;
    }

    final titleLen = Io.width(title) + 2;
    if (titleLen >= cols) {
      Io.out.writeln('── $title ──');
      return;
    }

    final sideLen = (cols - titleLen) ~/ 2;
    Io.out.writeln('${'─' * sideLen} $title ${'─' * (cols - titleLen - sideLen)}'.cyan);
  });

  // ---- indicators ----

  /// A single-line progress bar over [total] steps.
  static ProgressBar progress(int total, {String message = '', int? columns}) =>
      ProgressBar._(total, message: message, columns: columns);

  /// A board of [slots] concurrent task rows under one header bar.
  ///
  /// Omit [total] when the work is still being discovered; [TaskBoard.report] revises it
  /// upward as it arrives.
  static TaskBoard tasks({int total = 0, int slots = 4, String message = '', int? columns}) =>
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
  }) => Spinner.run(message, action, done: done, failed: failed, style: style);
}

/// Rendering a batch as it runs.
///
/// {@category Terminal}
extension StreamBatchProgressExtensions<T extends BatchProgress> on Stream<T> {
  /// Draws this batch in a [TaskBoard] until it ends, then prints [done].
  ///
  /// Returns the last event, or `null` for an empty batch.
  ///
  /// ```dart
  /// final last = await pairs.download(concurrency: 4).show(slots: 4, message: 'Downloading');
  /// ```
  Future<T?> show({int slots = 4, String message = '', String? done, int? columns}) async {
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
