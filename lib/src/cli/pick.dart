part of '../../cli.dart';

/// The picked indexes of [choices], in list order: a picker on a terminal, else numbered input.
Future<List<int>> _choose<T extends Object>(
  String question,
  List<T> choices,
  bool many,
  List<T>? or,
  String Function(T choice)? label,
  bool filter,
) {
  if (choices.isEmpty) throw ArgumentError.value(choices, 'choices', 'Invalid choices: none');
  final fallback = or == null ? null : [for (final o in or) choices.indexOf(o)];
  final choice = Choice<T>(
    choices,
    label: label,
    filter: filter,
    multi: many,
    index: max(0, fallback?.firstOrNull ?? 0),
  );
  if (fallback != null && fallback.contains(-1)) {
    throw ArgumentError.value(
      or,
      'or',
      'Invalid or: not one of ${[for (var i = 0; i < choices.length; i++) choice.label(i)].join(', ')}',
    );
  }
  if (many) {
    for (final i in fallback ?? const <int>[]) {
      choice.toggle(i);
    }
  }
  return Console._region.suspend(() async {
    if (_keyboard() case final term?) return _Picker<T>(question, choice, fallback, term).run();
    return _numbered(question, choice, many, fallback);
  });
}

/// The terminal a picker reads keys from: the scope's, else the process's own when a person is
/// at it (stdin and stderr both a terminal); `null` means numbered input.
Terminal? _keyboard() {
  if (IoBridge.terminal case final term?) return term;
  if (Platform.isWindows || !Io.isInteractive || !Io.isStderrTerminal) return null;
  return TerminalBridge.connect();
}

/// A picker without a terminal: the choices numbered, and a line of numbers or labels read.
Future<List<int>> _numbered(String question, Choice<Object?> choice, bool many, List<int>? fallback) async {
  final t = Console.theme;
  final p = t.palette;
  final count = choice.items.length;
  final labels = [for (var i = 0; i < count; i++) choice.label(i)];
  final lines = [
    '$question:',
    for (final (i, label) in labels.indexed)
      '  ${i + 1}) $label${fallback?.contains(i) ?? false ? p.muted(' (default)') : ''}',
  ];
  for (final line in lines) {
    Io.stderr.writeln(IoBridge.takesColor(true) ? line : Style.plain(line));
  }
  while (true) {
    final answer = await Console._answer(
      'Select 1-$count${many ? ', comma-separated' : ''}',
      hint: fallback?.map((i) => i + 1).join(','),
    );
    if ((answer == null || answer.isEmpty) && fallback != null) return fallback;
    if (answer == null) throw MissingException('answer to "$question"', where: 'stdin');
    final picked = <int>{};
    for (final word in many ? answer.split(',').map((w) => w.trim()) : [answer]) {
      final n = int.tryParse(word);
      final i = n != null && n >= 1 && n <= count ? n - 1 : labels.indexOf(word);
      if (i < 0) {
        picked.clear();
        break;
      }
      picked.add(i);
    }
    if (picked.isNotEmpty) return picked.toList()..sort();
    Console._reject('Please enter ${many ? 'numbers' : 'a number'} from 1 to $count.');
  }
}

/// A picker drawn under the cursor on the [Choice] model: arrows move, Space checks, typing
/// filters, Enter picks. It erases itself on every way out and leaves the answer as one line.
final class _Picker<T extends Object> {
  final String question;
  final Choice<T> choice;
  final List<int>? or;
  final Terminal term;
  final ConsoleTheme theme = Console.theme;
  late final _keys = TerminalBridge(_events);
  final _done = Completer<List<int>>();
  StreamSubscription<List<int>>? _sub;
  void Function()? _unlinkCancel;
  int _offset = 0, _drawn = 0;
  bool _restored = false;

  _Picker(this.question, this.choice, this.or, this.term);

  /// Writes to the terminal as it is: escapes and all, whatever the colour.
  void _write(String data) => TerminalBridge.isTty(term) ? _Region._raw(data) : term.write(data);

  Future<List<int>> run() async {
    await term.open();
    IoBridge.restores.add(_restore);
    TerminalBridge.interrupted = _interrupt;
    try {
      final token = Cancel.token;
      _unlinkCancel = token?.onCancel(() => _finish(error: CancelledException('${token.reason ?? 'cancelled'}')));
      _sub = term.input.listen(_keys.add);
      _write('\x1b[?25l');
      _draw();
      final picked = await _done.future;
      _restore();
      final answer = [for (final i in picked) choice.label(i)].join(', ');
      final p = theme.palette;
      final line = theme.prompt(PromptView(question, answer: answer, palette: p));
      _write('${IoBridge.takesColor(true) ? line : Style.plain(line)}\n');
      return picked;
    } finally {
      _restore();
    }
  }

  void _interrupt() {
    _restore();
    _finish(error: const CancelledException('Interrupted'));
  }

  void _finish({List<int>? picked, Object? error}) {
    if (_done.isCompleted) return;
    error == null ? _done.complete(picked) : _done.completeError(error);
  }

  void _events(List<TuiEvent<Never>> events) {
    for (final e in events) {
      if (_done.isCompleted) return;
      _handle(e);
    }
    if (!_done.isCompleted) _draw();
  }

  void _handle(TuiEvent<Never> e) {
    switch (e) {
      case const KeyPress('c', ctrl: true):
        TerminalBridge.ctrlC(term, _interrupt);
      // A filter that matches nothing has nothing to pick.
      case KeyPress.enter when choice.multi && choice.checked.isNotEmpty:
        _finish(picked: choice.checked.toList()..sort());
      case KeyPress.enter when choice.index >= 0:
        _finish(picked: [choice.index]);
      case KeyPress.esc when or != null:
        _finish(picked: or);
      case _:
        choice.handle(e);
    }
  }

  /// Item rows on screen: ten at most, and the terminal less the question and a spare row.
  int get _rows => min(10, max(1, term.height - 2));

  void _draw() {
    final width = max(1, term.width - 1);
    final rows = _rows;
    final shown = choice.shown;
    TerminalBridge.layout(choice).page = rows;
    final pos = max(0, shown.indexOf(choice.index));
    if (pos < _offset) _offset = pos;
    if (pos >= _offset + rows) _offset = pos - rows + 1;
    _offset = _offset.clamp(0, max(0, shown.length - rows));
    final p = theme.palette;
    List<String> build() => [
      '${theme.prompt(PromptView(question, palette: p))}${choice.query}',
      if (shown.isEmpty) '  ${p.muted('No matches')}',
      for (final i in shown.skip(_offset).take(rows))
        theme.item(
          ItemView<Object?>(
            index: i,
            value: choice.items[i],
            label: choice.label(i),
            isSelected: i == choice.index,
            isChecked: choice.multi ? choice.checked.contains(i) : null,
            matches: choice.matchesOf(i),
            palette: p,
          ),
        ),
    ];
    final lines = IoBridge.takesColor(true) ? build() : TerminalBridge.plain(build);
    final out = StringBuffer('\r');
    if (_drawn > 1) out.write('\x1b[${_drawn - 1}A');
    out.write('\x1b[J');
    out.write(
      [for (final l in lines) Style.truncate(l.replaceAll(_control, ' '), width, ellipsis: p.ellipsis)].join('\r\n'),
    );
    _write('$out');
    _drawn = lines.length;
  }

  /// Erases the picker and puts the terminal back: once, synchronously, on every way out.
  void _restore() {
    if (_restored) return;
    _restored = true;
    IoBridge.restores.remove(_restore);
    if (TerminalBridge.interrupted == _interrupt) TerminalBridge.interrupted = null;
    _keys.cancel();
    _sub?.cancel();
    _unlinkCancel?.call();
    try {
      _write('\r${_drawn > 1 ? '\x1b[${_drawn - 1}A' : ''}\x1b[J\x1b[?25h');
    } finally {
      term.close();
    }
  }
}
