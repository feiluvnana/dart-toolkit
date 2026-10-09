part of '../../cli.dart';

// ---- the theme -------------------------------------------------------------------------------

/// How the console draws: a [Palette] of tokens, the most [rows] a batch shows, and builders that
/// say what each line *is* from a view of raw values: [task], [batch], [item], [log], [prompt].
/// `TuiTheme` has the same builder names over the same views, returning widgets.
///
/// A theme names only what it changes; the rest is the theme around it ([Console.scope]), then
/// the defaults. Each builder getter answers the default when unset, so a builder can wrap it:
///
/// ```dart
/// final theme = ConsoleTheme(log: (l) => '[${l.level.name}] ${const ConsoleTheme().log(l)}');
/// await Console.scope(() => deploy(), theme: theme);
/// ```
///
/// {@category CLI}
final class ConsoleTheme {
  final Palette? _palette;
  final int? _rows;
  final String Function(TaskView view)? _task;
  final String Function(BatchView view)? _batch;
  final String Function(ItemView<Object?> view)? _item;
  final String Function(LogView view)? _log;
  final String Function(PromptView view)? _prompt;

  const ConsoleTheme({
    Palette? palette,
    int? rows,
    String Function(TaskView view)? task,
    String Function(BatchView view)? batch,
    String Function(ItemView<Object?> view)? item,
    String Function(LogView view)? log,
    String Function(PromptView view)? prompt,
  }) : _palette = palette,
       _rows = rows,
       _task = task,
       _batch = batch,
       _item = item,
       _log = log,
       _prompt = prompt;

  /// The tokens: colours, marks, glyphs.
  Palette get palette => _palette ?? const Palette();

  /// The most item rows a batch draws under its header; the rest are `+N more`.
  int get rows => _rows ?? 8;

  /// One task's line, or a row of a batch: `⠋ ISO  ██████░░░░  60%  1.2/2.0 GB  3.1 MB/s  eta 4s`.
  String Function(TaskView view) get task => _task ?? _taskLine;

  /// A batch's header: `⠋ Images  ████░░░░  12/50  3.1 MB/s  eta 1m  2 failed`.
  String Function(BatchView view) get batch => _batch ?? _batchLine;

  /// A picker's row: `› ◉ label`.
  String Function(ItemView<Object?> view) get item => _item ?? _itemLine;

  /// A line that stays: a log verb's, a warning or a failure above live work, how work ends.
  String Function(LogView view) get log => _log ?? _logLine;

  /// A prompt's question, `Port (8080): `, and a picker's answer once given.
  String Function(PromptView view) get prompt => _prompt ?? _promptLine;

  ConsoleTheme _over(ConsoleTheme base) => ConsoleTheme(
    palette: switch ((_palette, base._palette)) {
      (final mine?, final theirs?) => TerminalBridge.over(mine, theirs),
      (final mine, final theirs) => mine ?? theirs,
    },
    rows: _rows ?? base._rows,
    task: _task ?? base._task,
    batch: _batch ?? base._batch,
    item: _item ?? base._item,
    log: _log ?? base._log,
    prompt: _prompt ?? base._prompt,
  );

  /// This theme with its palette as the terminal here draws it.
  ConsoleTheme _drawable(bool unicode) => ConsoleTheme(
    palette: TerminalBridge.drawable(palette, unicode: unicode),
    rows: _rows,
    task: _task,
    batch: _batch,
    item: _item,
    log: _log,
    prompt: _prompt,
  );

  /// [message] at [level], as [log] draws it.
  String _say(LogLevel level, String message, [Duration? elapsed]) =>
      log(LogView(level, message, elapsed: elapsed, palette: palette));
}

/// What a log line needs from where it is logged, read once per zone: a zone's values never change,
/// and every line would otherwise look each one up.
final class _Logging {
  final LogLevel level;
  final ConsoleTheme theme;
  final bool outColor, errColor;

  _Logging._()
    : level = Console.level,
      theme = Console.theme,
      outColor = IoBridge.takesColor(false),
      errColor = IoBridge.takesColor(true);

  static final _byZone = Expando<_Logging>('logging');

  static _Logging get here => _byZone[Zone.current] ??= _Logging._();
}

/// A prompt's question, for the theme's `prompt:` builder.
///
/// {@category CLI}
final class PromptView {
  final String question;

  /// What Enter answers (`8080`, `y/N`), or `null`.
  final String? hint;

  /// What was picked, as a picker writes its question back once answered; `null` while asking.
  final String? answer;
  final Palette palette;

  const PromptView(this.question, {this.hint, this.answer, this.palette = const Palette()});
}

// ---- the default builders --------------------------------------------------------------------

/// [head] (a label, kept), then a bar of [fraction] in what is left, then [tail]: the bar gives
/// way first, then the tail, so a narrow terminal still shows the name.
String _fit(int columns, String head, double? fraction, String tail, Palette p) {
  final tailWidth = tail.isEmpty ? 0 : Style.width(tail) + 2;
  final keep = max(columns * 2 ~/ 5, columns - tailWidth - (fraction == null ? 0 : 8));
  final h = Style.truncate(head, max(1, keep), ellipsis: p.ellipsis);
  final room = columns - Style.width(h) - tailWidth - 2;
  final bar = fraction == null || room < 4 ? '' : '  ${p.accent(p.bar.draw(fraction, min(20, room)))}';
  return Style.truncate('$h$bar${tail.isEmpty ? '' : '  $tail'}', columns, ellipsis: p.ellipsis);
}

String _joined(Iterable<String> parts) => parts.where((p) => p.isNotEmpty).join('  ');

/// The mark an ended item's line starts with.
String _markOf(Status<Object?, Object?> status, Palette p) => switch (status) {
  Done() => p.success(p.marks.ok),
  Failed() => p.danger(p.marks.error),
  Stopped() || Skipped() => p.warning(p.marks.warn),
  _ => p.accent(p.marks.info),
};

String _taskLine(TaskView t) {
  final p = t.palette;
  final status = t.status;
  if (status.isFinal) {
    final note = switch (status) {
      Done(fresh: false) => ' (already there)',
      Skipped(:final reason) || Stopped(:final reason) => ' ($reason)',
      Failed(:final error) => ': ${_oneLine('$error')}',
      _ => '',
    };
    final size = t.unit == Unit.bytes && t.received > 0 ? ' (${t.received.humanBytes})' : '';
    final line = '${t.isRow ? '  ' : ''}${_markOf(status, p)} ${t.label}$size$note';
    return t.isLive ? p.muted(line) : line;
  }
  final percent = t.percent == null ? '' : '${t.percent}%';
  final eta = t.eta == null ? '' : 'eta ${t.eta!.humanized}';
  final tail = _joined([
    percent,
    t.amounts,
    t.pace,
    eta,
    t.step ?? '',
    if (!t.isRow && t.fraction == null) '(${t.elapsed.humanized})',
  ]);
  final head = t.isRow ? '  ${t.label}' : '${p.accent(t.frame)} ${t.label}';
  return _fit(t.columns, head, t.fraction, p.muted(tail), p);
}

String _batchLine(BatchView b) {
  final p = b.palette;
  final failed = b.failed > 0 ? p.danger('${b.failed} failed') : '';
  final eta = b.eta == null ? '' : 'eta ${b.eta!.humanized}';
  if (!b.isLive) {
    return '${b.title}: ${b.count == null ? '${b.ended} done' : '${b.ended}/${b.count} (${b.percent}%)'}'
        '${b.failed > 0 ? ', ${b.failed} failed' : ''}';
  }
  final head = '${p.accent(b.frame)} ${b.title}';
  final latest = b.running == 0 ? b.latest ?? '' : '';
  if (b.count == null) {
    return _fit(
      b.columns,
      head,
      null,
      _joined([p.muted('${b.ended} done'), p.muted(b.pace), failed, p.muted(latest)]),
      p,
    );
  }
  final tail = _joined([
    '${b.ended}/${b.count}',
    if (b.total != null) b.amounts,
    b.pace,
    eta,
    if (b.failed == 0) '(${b.elapsed.humanized})',
  ]);
  return _fit(b.columns, head, b.fraction, _joined([p.muted(tail), failed, p.muted(latest)]), p);
}

String _itemLine(ItemView<Object?> i) {
  final p = i.palette;
  final pointer = i.isSelected ? p.accent(p.pointer) : ' ' * Style.width(p.pointer);
  final box = switch (i.isChecked) {
    true => '${p.accent(p.checked)} ',
    false => '${p.muted(p.unchecked)} ',
    null => '',
  };
  final label = [
    for (final (text, matched) in i.parts) matched ? (p.accent + const Style(bold: true))(text) : text,
  ].join();
  return '$pointer $box${i.isSelected ? p.accent(label) : label}';
}

/// `✓ Built (3.1s)`: the mark and the message in the level's colour, the time muted.
String _logLine(LogView l) {
  final time = l.elapsed == null ? '' : ' ${l.palette.muted('(${l.elapsed!.humanized})')}';
  return '${l.style('${l.mark} ${l.message}')}$time';
}

/// `Port (8080): `, and once a picker is answered `Env: prod`.
String _promptLine(PromptView v) {
  final p = v.palette;
  final hint = v.hint == null || v.hint!.isEmpty ? '' : p.muted(' (${v.hint})');
  return '${v.question}$hint: ${v.answer == null ? '' : p.accent(v.answer!)}';
}

/// [text] on one line: a failure is one line (a `FormatException` carries its source on a second).
String _oneLine(String text) => text.trim().replaceAll(_breaks, ' ');

final _breaks = RegExp(r'\s*\n\s*');

/// Control characters a line must not carry into the terminal, ESC aside.
final _control = RegExp(r'[\x00-\x1a\x1c-\x1f\x7f]');

// ---- what was said ---------------------------------------------------------------------------

/// Warnings and errors already on screen: a note is printed once, by the first display to hear
/// it, and `Cli.run` prints no second line for an error a display ended with.
final _said = Expando<bool>('said');

bool _markable(Object? o) => o != null && o is! num && o is! String && o is! bool && o is! Record;

/// Whether [o] has been said, marking it said.
bool _sayOnce(Object? o) {
  if (!_markable(o)) return true;
  if (_said[o!] == true) return false;
  _said[o] = true;
  return true;
}

bool _wasSaid(Object? o) => _markable(o) && _said[o!] == true;

// ---- the live region -------------------------------------------------------------------------

/// The bottom of the terminal, where live work is drawn: every display on screen, oldest first.
/// Everything durable (a log line, a prompt, a table) lands above it.
final class _Region {
  final List<_Display> _stack = [];

  /// The lines put on screen last frame, and the width they were drawn at.
  List<String> _drawn = const [];
  int _drawnAt = 0;
  int _suspended = 0;
  Timer? _timer;
  StreamSubscription<Object?>? _resize;
  void Function(void Function() write)? _outer;
  Future<T> Function<T>(Future<T> Function() action)? _outerSuspend;

  /// Whether live work can be drawn here: stderr is a terminal that takes escapes, and no `Tui`
  /// app owns the screen.
  static bool get possible {
    if (!Io.isStderrTerminal || TerminalBridge.app != null) return false;
    if (IoBridge.terminal != null) return true;
    try {
      return stderr.supportsAnsiEscapes;
    } catch (_) {
      return false; // no answer from this stderr: draw no live region
    }
  }

  /// The terminal's columns and rows.
  static (int, int) get _size {
    if (IoBridge.terminal case final t?) return (t.width, t.height);
    try {
      return (stderr.terminalColumns, stderr.terminalLines);
    } catch (_) {
      return (80, 24); // a terminal that reports no size: the defaults stand
    }
  }

  /// Writes [data] as it is, escapes and all, whatever the colour: cursor moves are not colour.
  static void _raw(String data) {
    if (IoBridge.terminal case final t?) return t.write(data.replaceAll('\n', '\r\n'));
    try {
      stderr.write(data);
    } catch (_) {} // stderr closed under us: nothing to draw on
  }

  void push(_Display display) {
    if (_stack.isEmpty) {
      _outer = IoBridge.above;
      _outerSuspend = IoBridge.suspend;
      IoBridge.above = Console._durable;
      IoBridge.suspend = suspend;
      _timer = Timer.periodic(display.theme.palette.interval, (_) => _tick());
      _watchSize();
    }
    _stack.add(display);
    paint();
  }

  void pop(_Display display) {
    if (!_stack.contains(display)) return;
    wipe();
    _stack.remove(display);
    if (_stack.isEmpty) {
      IoBridge.above = _outer;
      IoBridge.suspend = _outerSuspend;
      _timer?.cancel();
      _timer = null;
      _resize?.cancel();
      _resize = null;
    }
    paint();
  }

  void _watchSize() {
    if (IoBridge.terminal case final t?) {
      _resize = t.resized.listen((_) => paint());
      return;
    }
    if (Platform.isWindows) return;
    try {
      _resize = ProcessSignal.sigwinch.watch().listen((_) => paint());
    } catch (_) {} // a platform that cannot watch this signal: the next tick measures anyway
  }

  /// A tick: the rates sampled (so a stall decays) and the frame drawn.
  void _tick() {
    for (final display in _stack) {
      display.tally.sample();
    }
    paint();
  }

  /// Moves up to the first row of the last frame. A terminal narrowed since reflowed each line
  /// it drew into more rows, so they are counted again at its width now.
  void _up(StringBuffer out, int columns) {
    var rows = _drawn.length;
    if (columns != _drawnAt) {
      rows = 0;
      for (final line in _drawn) {
        rows += max(1, (Style.width(line) + columns - 1) ~/ columns);
      }
    }
    if (rows > 0) out.write('\x1b[${rows}A');
  }

  /// Draws every display, oldest first, leaving the cursor on the row below the last line;
  /// never taller than the terminal less one row, since what scrolls off cannot be drawn over.
  void paint() {
    if (_suspended > 0 || _stack.isEmpty) return;
    final (columns, rows) = _size;
    final width = max(1, columns - 1);
    final colour = IoBridge.takesColor(true);
    List<String> build() => [
      for (final display in _stack)
        for (final line in display.lines(width)) Style.truncate(line.replaceAll(_control, ' '), width),
    ];
    var lines = colour ? build() : TerminalBridge.plain(build);
    if (lines.length >= rows) lines = lines.sublist(0, max(1, rows - 1));
    final out = StringBuffer();
    _up(out, columns);
    for (final line in lines) {
      out.write('\r\x1b[K$line\n');
    }
    // What the last frame left below this one: fewer rows, or rows a narrower terminal wrapped.
    out.write('\x1b[J');
    _raw('$out');
    _drawn = lines;
    _drawnAt = columns;
  }

  /// Clears the region, leaving the cursor where its first row was.
  void wipe() {
    if (_drawn.isEmpty) return;
    final out = StringBuffer();
    _up(out, _size.$1);
    _raw('$out\r\x1b[J');
    _drawn = const [];
  }

  /// Runs [action] (a prompt, a child given the terminal) with the region cleared and not
  /// painted, then draws it again.
  Future<T> suspend<T>(Future<T> Function() action) async {
    wipe();
    _suspended++;
    try {
      return await action();
    } finally {
      _suspended--;
      paint();
    }
  }

  /// Wipes everything, as a signal or an exit leaves.
  void clear() {
    wipe();
    for (final display in [..._stack]) {
      pop(display);
    }
  }
}

// ---- a display -------------------------------------------------------------------------------

/// Work drawn while it runs: one task as one line, or a batch (or a bar) as a header with a row
/// per item running. It reads a [Tally]; on a terminal it lives in the region, without one each
/// item writes a line as it ends.
final class _Display {
  final String title;
  final Tally tally;
  final ConsoleTheme theme = Console.theme;
  final bool _live = _Region.possible;
  final bool _shown = Console._isEnabled(LogLevel.info);
  late final StreamSubscription<Status<Object?, Object?>> _heard;
  int _tenth = -1;
  bool _ended = false;

  _Display(this.title, this.tally) {
    _heard = tally.changes.listen(_hear);
    if (_live && _shown) Console._region.push(this);
  }

  List<String> lines(int width) {
    final p = theme.palette;
    if (tally.isTask) {
      final item = tally.items.firstOrNull;
      final view = item == null
          ? TaskView(label: title, status: const Running(null), elapsed: tally.elapsed, columns: width, palette: p)
          : TaskView.of(item, label: title, columns: width, palette: p);
      return [theme.task(view)];
    }
    final (:rows, :more) = tally.rows(theme.rows);
    return [
      theme.batch(BatchView.of(tally, title: title, more: more, columns: width, palette: p)),
      for (final row in rows) theme.task(TaskView.of(row, isRow: true, columns: width, palette: p)),
      if (more > 0) p.muted('  +$more more'),
    ];
  }

  void _hear(Status<Object?, Object?> status) {
    switch (status) {
      case Warned(:final warning) when _sayOnce(warning):
        Console._log(LogLevel.warn, '$status');
      // A task's failure is how it ends: said once, by the ending.
      case Failed(:final error) when !tally.isTask && _sayOnce(error):
        Console._log(LogLevel.error, '$status');
      case _:
    }
    if (_live || !_shown || tally.isTask || !status.isFinal || status is Failed) return;
    // No terminal: a line per item as it ends, or past a hundred items a line per tenth.
    final count = tally.count;
    final width = (Io.stderrColumns ?? 80) - 1;
    final p = theme.palette;
    if (count == null || count <= 100) {
      if (status is Stopped) return;
      final item = tally.latest!;
      Console._indicate(() => theme.task(TaskView.of(item, isRow: true, isLive: false, columns: width, palette: p)));
    } else {
      final tenth = tally.ended * 10 ~/ count;
      if (tenth == _tenth) return;
      _tenth = tenth;
      Console._indicate(
        () => theme.batch(BatchView.of(tally, title: title, isLive: false, columns: width, palette: p)),
      );
    }
  }

  /// Takes it off screen, ending with [message] at [level] (none when `null`), timed.
  void end(LogLevel? level, String? message) {
    if (_ended) return;
    _ended = true;
    _heard.cancel();
    Console._region.pop(this);
    if (level == null || message == null) return;
    if (level.index >= LogLevel.warn.index) {
      if (Zone.current[_runKey] case final _RunState run) run.failedWork = true;
    }
    Console._log(level, message, elapsed: level == LogLevel.ok ? tally.elapsed : null, indicator: true);
  }

  /// Ends it as the work it draws ended, given what awaiting the work threw.
  void finish(Object? error, {String? done}) => switch (error) {
    null => end(LogLevel.ok, done ?? title),
    _Exit() => end(null, null),
    BatchException(:final failures, :final count) => () {
      _sayOnce(error);
      end(LogLevel.warn, '$title: ${failures.length} of $count failed');
    }(),
    CancelledException() =>
      tally.isTask
          ? end(LogLevel.warn, '$title: cancelled')
          : end(
              LogLevel.warn,
              '$title: cancelled after ${tally.ended - tally.stopped} of ${tally.count ?? tally.ended}',
            ),
    _ => end(LogLevel.error, _sayOnce(error) ? '$title: ${_oneLine('$error')}' : '$title: failed'),
  };
}

/// Draws [tally] under [title] until [work] has ended, then ends the display as it ended and
/// answers what awaiting [work] answers.
Future<R> _drawn<R>(String title, Tally tally, Future<R> work, String? done) async {
  final display = _Display(title, tally);
  try {
    await tally.over;
    final value = await work;
    display.finish(null, done: done);
    return value;
  } catch (e) {
    display.finish(e);
    rethrow;
  }
}

/// Drawing a task while you await it.
///
/// {@category CLI}
extension TaskShow<T> on Task<T> {
  /// Draws this task until it ends, then answers what `await` answers: its value, or the throw.
  /// One line: a spinner, or a bar with sizes, rate and time left once it reports amounts. It
  /// ends `✓ title (3.1s)` ([done] in place of [title]), `✖ title: why`, or `⚠ title: cancelled`;
  /// everything it draws goes to stderr.
  ///
  /// ```dart
  /// final iso = await url.download(into: 'out').show('ISO');
  /// await Task.run('Building', (work) => build(work)).show('Building', done: 'Built');
  /// ```
  Future<T> show(String title, {String? done}) {
    final tally = Tally.task(this);
    // Whoever awaits the result handles a failure; until then the display holds it.
    settled.ignore();
    return _drawn(title, tally, this, done);
  }
}

/// Drawing any future while you await it: a spinner, for work that reports nothing.
///
/// {@category CLI}
extension FutureShow<T> on Future<T> {
  /// Draws a spinner named [title] until this completes, then answers what `await` answers, as
  /// [TaskShow.show] does. A [Task] and a [Batch] draw their own progress instead.
  ///
  /// ```dart
  /// final page = await tab.html.show('Reading the page');
  /// ```
  Future<T> show(String title, {String? done}) =>
      TaskInternals.start<T>(title, title, (_) => this).show(title, done: done);
}

/// Drawing a batch while you await it, or as it passes on down a pipeline.
///
/// {@category CLI}
extension BatchShow<I, T> on Batch<I, T> {
  /// Draws this batch until it ends, then answers what `await` answers: every value in input
  /// order, or the [BatchException]. A header in items (bytes alongside once every item is
  /// sized) and up to `theme.rows` rows of running items; each warning and failure is a line
  /// above it, once. It ends `✓ title (3.1s)`, `⚠ title: 2 of 50 failed` (then the throw) or
  /// `⚠ title: cancelled after 12 of 50`.
  ///
  /// ```dart
  /// final files = await urls.parallelize((u) => u.download(into: 'out')).show('Images');
  /// ```
  Future<List<T>> show(String title, {String? done}) {
    final tally = Tally.batch(this);
    settled.ignore();
    return _drawn(title, tally, this, done);
  }

  /// Draws this batch as [show] does and passes it on, for the middle of a pipeline: its ending
  /// line says how it went, its failures make a `Cli` run exit 1, and nothing is thrown here.
  ///
  /// ```dart
  /// final pages = urls.parallelize(fetch).progress('Fetching').values.parallelize(parse);
  /// ```
  Batch<I, T> progress(String title) {
    final tally = Tally.batch(this);
    settled.ignore();
    unawaited(_drawn(title, tally, this, null).then((_) {}, onError: (Object _) {})); // said by its ending line
    return this;
  }
}

/// A display fed by hand, for work that has no task: [tick] for each item done, or its real
/// statuses added to [tally]; [close] ends it. It draws a [Tally] as a batch's `show` does.
///
/// ```dart
/// final bar = Console.bar('Crawling', count: links.length);
/// for (final link in links) { await visit(link); bar.tick(label: link.path); }
/// await bar.close();
/// ```
///
/// {@category CLI}
final class Bar {
  /// What it has been told: `bar.tally.add(status)` for an item's progress, how it ended, a
  /// warning; hand it to `Board` to draw the same work in a `Tui` app.
  final Tally tally;
  late final _Display _display;
  int _ticks = 0;

  Bar._(String title, int? count) : tally = Tally(count: count) {
    _display = _Display(title, tally);
  }

  /// One item done, named [label].
  void tick({String? label}) {
    _ticks++;
    tally.add(Done(_Tick(_ticks), null, label: label ?? '$_ticks'));
  }

  /// Ends it with its summary: `✓ title (3.1s)`, or `⚠ title: 2 of 50 failed` and a
  /// [BatchException] holding the failures.
  Future<void> close() async {
    tally.close();
    if (tally.failures.isEmpty) return _display.finish(null);
    final error = BatchException<Object?, Object?>(tally.failures, tally.values, tally.count ?? tally.ended);
    _display.finish(error);
    throw error;
  }
}

/// A [Bar.tick]'s item: each one its own.
final class _Tick {
  final int n;

  const _Tick(this.n);

  @override
  String toString() => '$n';
}

// ---- the namespace ---------------------------------------------------------------------------

/// The terminal: log lines, rules, prompts, and work drawn while it runs.
///
/// `info`, `ok` and `line` write to stdout; `debug`, `warn`, `error` and everything drawn work
/// shows go to stderr, so `app --json | jq` gets only data. Live work sits at the bottom of the
/// terminal and every other line lands above it.
///
/// {@category CLI}
abstract final class Console {
  static final _region = _Region();
  static const _levelKey = #dartToolkitLogLevel;
  static const _themeKey = #dartToolkitConsoleTheme;

  /// The level of the enclosing [scope]: [LogLevel.info] by default.
  static LogLevel get level => Zone.current[_levelKey] as LogLevel? ?? LogLevel.info;

  /// The theme of the enclosing [scope], as this terminal draws it.
  static ConsoleTheme get theme {
    final given = Zone.current[_themeKey] as ConsoleTheme? ?? const ConsoleTheme();
    // Every line asks: the drawable form is made once per theme and terminal kind.
    final unicode = TerminalBridge.drawsUnicode;
    return (unicode ? _unicodeThemes : _asciiThemes)[given] ??= given._drawable(unicode);
  }

  static final _unicodeThemes = Expando<ConsoleTheme>('theme');
  static final _asciiThemes = Expando<ConsoleTheme>('theme');

  /// Runs [body] logging at [level] and drawing with [theme] (over the enclosing one); the scope
  /// holds until [body]'s result has finished.
  ///
  /// ```dart
  /// await Console.scope(() => sync(), level: LogLevel.warn);
  /// ```
  static Future<T> scope<T>(FutureOr<T> Function() body, {LogLevel? level, ConsoleTheme? theme}) async {
    final values = <Object?, Object?>{};
    if (level != null) values[_levelKey] = level;
    if (theme != null) {
      TerminalBridge.checked(theme.palette);
      if (theme.rows < 1) throw ArgumentError.value(theme.rows, 'rows', 'Invalid rows, expected at least 1');
      final outer = Zone.current[_themeKey] as ConsoleTheme?;
      values[_themeKey] = outer == null ? theme : theme._over(outer);
    }
    _bridge();
    return await runZoned(() async => await body(), zoneValues: values);
  }

  /// Lets `Table.show`, which cannot import this, draw with the theme's border.
  static void _bridge() => IoBridge.border ??= () => Console.theme.palette.border;

  static bool _isEnabled(LogLevel candidate) => level != LogLevel.silent && candidate.index >= level.index;

  // ---- writing ----

  /// Writes something that stays, above whatever is live; a `Tui` app on screen takes it above
  /// its own region.
  static void _durable(void Function() write) {
    if (_region._stack.isNotEmpty) {
      _region.wipe();
      write();
      _region.paint();
    } else if (IoBridge.above case final above?) {
      above(write);
    } else {
      write();
    }
  }

  /// [build]'s line at [level], when the level shows it: built unstyled for a sink that drops
  /// escapes. Warnings, errors, debug lines and an [indicator]'s go to stderr.
  static void _log(LogLevel level, String message, {Duration? elapsed, bool indicator = false}) {
    final here = _Logging.here;
    if (here.level == LogLevel.silent || level.index < here.level.index) return;
    final err = indicator || level.index >= LogLevel.warn.index || level == LogLevel.debug;
    final t = here.theme;
    _emit(() => t._say(level, message, elapsed), err: err, here: here);
  }

  /// An indicator's line on stderr, when indicators show.
  static void _indicate(String Function() line) {
    if (_isEnabled(LogLevel.info)) _emit(line, err: true);
  }

  static void _emit(String Function() build, {required bool err, _Logging? here}) {
    final at = here ?? _Logging.here;
    final text = (err ? at.errColor : at.outColor) ? build() : TerminalBridge.plain(build);
    // The sink is read when the line is written: a live region may take the write elsewhere.
    _durable(() => (err ? Io.stderr : Io.stdout).writeln(text));
    _tee(text);
  }

  /// The files [tee] appends to.
  static final List<RandomAccessFile> _tees = [];

  /// Appends every line from now on (logs, how drawn work ends, a line per item where no
  /// terminal draws it, `Interrupted`, an exit's message) to the file at [path] as well,
  /// unstyled, each after its ISO 8601 UTC time. Returns what stops it, closing the file.
  ///
  /// ```dart
  /// final untee = Console.tee('run.log');   // 2026-10-07T03:00:01.250Z ✓ 12 files synced
  /// ```
  static void Function() tee(String path) {
    final file = File(path).openSync(mode: FileMode.append);
    _tees.add(file);
    return () {
      if (_tees.remove(file)) file.closeSync();
    };
  }

  static void _tee(String line) {
    if (_tees.isEmpty) return;
    final stamped = '${Clock.current.now().toUtc().toIso8601String()} ${Style.plain(line)}\n';
    for (final file in _tees) {
      file.writeStringSync(stamped);
    }
  }

  /// Logs a diagnostic, shown under `-v`: `· message`, on stderr.
  static void debug(String message) => _log(LogLevel.debug, message);

  /// Logs information: `ℹ message`, on stdout.
  static void info(String message) => _log(LogLevel.info, message);

  /// Logs a success: `✓ message`, on stdout.
  static void ok(String message) => _log(LogLevel.ok, message);

  /// Logs a warning: `⚠ message`, on stderr.
  static void warn(String message) => _log(LogLevel.warn, message);

  /// Logs an error: `✖ message`, on stderr.
  static void error(String message) => _log(LogLevel.error, message);

  /// Writes [text] as it is, with no mark, on stdout; `Console.line()` is an empty line. A
  /// `print` inside `Cli.run` is one.
  static void line([String text = '']) {
    if (level == LogLevel.silent) return;
    _emit(() => text, err: false);
  }

  /// A divider across the terminal in the palette's border, with [title] in its middle.
  static void rule([String? title]) {
    if (level == LogLevel.silent) return;
    _emit(() {
      final p = theme.palette;
      final cols = (Io.columns ?? 80) - 1;
      final glyph = p.border.top.isEmpty ? ' ' : p.border.top;
      if (title == null || title.isEmpty) return glyph * cols;
      final room = cols - Style.width(title) - 2;
      if (room < 4) return '${glyph * 2} $title ${glyph * 2}';
      return p.accent('${glyph * (room ~/ 2)} $title ${glyph * (room - room ~/ 2)}');
    }, err: false);
  }

  /// A display fed by hand, of [count] items when that is known (without one and before any
  /// item, a spinner). It is drawn from now until [Bar.close].
  static Bar bar(String title, {int? count}) {
    if (count != null && count < 0) throw ArgumentError.value(count, 'count', 'Invalid count, expected at least 0');
    return Bar._(title, count);
  }

  /// Ends the program, at once: [message], when there is one, as an error line, then [code] (by
  /// default 1 with a message, else 0). Inside `Cli.run` it unwinds to it first, so the
  /// handler's cleanups run.
  ///
  /// ```dart
  /// final file = files.firstOrNull ?? Console.exit('Nothing to read');
  /// ```
  static Never exit(String? message, {int? code}) {
    final exitCode = code ?? (message == null ? 0 : 1);
    if (Zone.current[_runKey] is _RunState) throw _Exit(message, exitCode);
    _region.clear();
    if (message != null) _log(LogLevel.error, message);
    _terminate(exitCode);
  }

  // ---- prompts ----

  /// Asks [question] and reads one line, trimmed. Without [or] an answer is required; with it,
  /// Enter takes it. A [T] other than `String` is read by [parse], else as `'…'.to<T>()` reads
  /// text; what [parse] throws is shown and the question asked again. At the end of input it is
  /// [or], or a [MissingException].
  ///
  /// ```dart
  /// final name = await Console.ask('Name');
  /// final port = await Console.ask<int>('Port', or: 8080);
  /// final when = await Console.ask('When', parse: DateTime.parse);
  /// ```
  static Future<T> ask<T extends Object>(String question, {T? or, T Function(String answer)? parse}) {
    final read = parse ?? _reader<T>('ask');
    return _region.suspend(() async {
      while (true) {
        final answer = await _answer(question, hint: or == null ? null : _label(or));
        if (answer == null) return or ?? (throw MissingException('answer to "$question"', where: 'stdin'));
        if (answer.isEmpty) {
          if (or != null) return or;
          _reject('An answer is required.');
          continue;
        }
        try {
          return read(answer);
        } catch (e) {
          _reject(e is FormatException ? e.message : _oneLine('$e'));
        }
      }
    });
  }

  /// Asks a yes-or-no [question]. Enter takes [or] (shown `Y/n` or `y/N`); without it an
  /// answer is required, and at the end of input (a pipe, CI) it is a [MissingException]: a
  /// prompt nobody can answer is never a yes.
  static Future<bool> confirm(String question, {bool? or}) => _region.suspend(() async {
    final hint = switch (or) {
      true => 'Y/n',
      false => 'y/N',
      null => 'y/n',
    };
    while (true) {
      final answer = (await _answer(question, hint: hint))?.toLowerCase();
      if (answer == null) return or ?? (throw MissingException('answer to "$question"', where: 'stdin'));
      if (answer.isEmpty && or != null) return or;
      if (const {'y', 'yes'}.contains(answer)) return true;
      if (const {'n', 'no'}.contains(answer)) return false;
      _reject('Please answer y or n.');
    }
  });

  /// Asks for a secret with the typing hidden, and answers it as a [Secret]: it prints as `•••`
  /// wherever it goes. An answer is required.
  static Future<Secret> secret(String question) => _region.suspend(() async {
    final hide = Io.isInteractive;
    if (hide) {
      try {
        stdin.echoMode = false;
        IoBridge.restores.add(_restoreEcho);
      } catch (_) {} // not a terminal that can hide input: the prompt still reads
    }
    try {
      while (true) {
        final answer = await _answer(question, trim: false);
        if (hide) Io.stderr.writeln();
        if (answer == null) throw MissingException('answer to "$question"', where: 'stdin');
        if (answer.isNotEmpty) return Secret(answer);
        _reject('An answer is required.');
      }
    } finally {
      if (IoBridge.restores.remove(_restoreEcho)) _restoreEcho();
    }
  });

  static void _restoreEcho() {
    try {
      stdin.echoMode = true;
    } catch (_) {} // best-effort: stdin is no longer a terminal
  }

  /// Writes [question] to stderr as the theme's prompt draws it, and reads one line; `null` at the
  /// end of input.
  static Future<String?> _answer(String question, {String? hint, bool trim = true}) async {
    final t = theme;
    final ask = t.prompt(PromptView(question, hint: hint, palette: t.palette));
    Io.stderr.write(IoBridge.takesColor(true) ? ask : Style.plain(ask));
    final line = await Io.readLine();
    // No Enter echoed (the end of input, or input that is not a terminal): end the line here.
    if (line == null || !Io.isInteractive) Io.stderr.writeln();
    return trim ? line?.trim() : line;
  }

  /// A rejected answer, as an error line whatever the level: the question is asked again under it.
  static void _reject(String message) {
    final t = theme;
    _emit(() => t._say(LogLevel.error, message), err: true);
  }

  /// One of [choices]: a picker under the cursor on a terminal (arrows move, Enter picks, typing
  /// filters with [filter], Esc takes [or]), else the choices numbered and a number or a label
  /// read. Without [or] an answer is required. [label] names a choice (an enum by its `name`).
  ///
  /// ```dart
  /// final env = await Console.pick('Target', servers, label: (s) => s.name, filter: true);
  /// ```
  static Future<T> pick<T extends Object>(
    String question,
    List<T> choices, {
    T? or,
    String Function(T choice)? label,
    bool filter = false,
  }) async => choices[(await _choose(question, choices, false, or == null ? null : [or], label, filter)).single];

  /// Any of [choices], as [pick]: Space checks, Enter answers the checked (the cursor's when none
  /// is). Numbered, it reads numbers or labels separated by commas.
  static Future<List<T>> pickMany<T extends Object>(
    String question,
    List<T> choices, {
    List<T>? or,
    String Function(T choice)? label,
    bool filter = false,
  }) async => [for (final i in await _choose(question, choices, true, or, label, filter)) choices[i]];
}

/// [value] as an answer, a hint or a choice shows it.
const _label = TerminalBridge.label;

/// How [Console.ask] reads a [T] when no `parse:` is given; [what] names the call for the error.
T Function(String) _reader<T extends Object>(String what) {
  // Nothing says what `T` is (`Console.ask('Name')`): the answer is the text.
  if (T == String || T == Object) return (s) => s as T;
  if (!CoerceBridge.reads<T>()) {
    throw ArgumentError(
      'Cannot $what for a $T without parse: it reads String, numbers, bool, Duration, DateTime, Uri and Secret',
    );
  }
  return (s) => s.to<T>();
}
