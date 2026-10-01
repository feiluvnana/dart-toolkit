part of '../../tui.dart';

/// The screen and keyboard an app runs on: the process's terminal, or a [FakeTerminal] in a test.
///
/// [open] puts it in raw mode and starts [input]; [close] undoes both and must be synchronous,
/// because a signal handler calls it on the way out. Escape sequences go through [write].
///
/// {@category CLI}
abstract interface class Terminal {
  int get width;
  int get height;

  /// Colours it can show: 1 << 24, 256, 16, or 0 (attributes only).
  int get colors;

  /// Bytes typed, pasted or reported (mouse), between [open] and [close].
  Stream<List<int>> get input;

  /// Fires when [width] or [height] changed.
  Stream<void> get resized;

  Future<void> open();

  void close();

  void write(String data);
}

/// The process's terminal, through `/dev/tty`: input still works when stdin is a pipe, and
/// nothing reaches stdout, so `app | next` and `app > out` carry only what the app prints.
final class _Tty implements Terminal {
  final RandomAccessFile _out;
  String? _saved;
  Isolate? _reader;
  ReceivePort? _port;
  StreamController<List<int>> _input = StreamController.broadcast();
  final StreamController<void> _resized = StreamController.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  (int, int)? _size;

  _Tty._(this._out);

  /// The controlling terminal, or `null` when there is none (or on Windows).
  static _Tty? connect() {
    if (Platform.isWindows) return null;
    try {
      return _Tty._(File('/dev/tty').openSync(mode: FileMode.writeOnly));
    } catch (_) {
      return null;
    }
  }

  static String _stty(List<String> args) {
    final r = Process.runSync('stty', [Platform.isMacOS ? '-f' : '-F', '/dev/tty', ...args]);
    if (r.exitCode != 0) throw StateError('stty ${args.join(' ')}: ${r.stderr}'.trim());
    return '${r.stdout}'.trim();
  }

  /// Colours, from the environment: `NO_COLOR` or `Io.color = false` leaves attributes only.
  static int _depth() {
    if (Io.colorOverride == false || (Io.colorOverride == null && Env.has('NO_COLOR'))) return 0;
    final ct = Env.getOrNull('COLORTERM') ?? '';
    if (ct.contains('truecolor') || ct.contains('24bit')) return 1 << 24;
    final term = Env.getOrNull('TERM') ?? '';
    if (term == 'dumb') return 0;
    return term.contains('256') ? 256 : 16;
  }

  (int, int) get _dims => _size ??= () {
    for (final s in [stdout, stderr]) {
      try {
        if (s.hasTerminal) return (s.terminalColumns, s.terminalLines);
      } catch (_) {}
    }
    try {
      final rc = _stty(['size']).split(' ').map(int.parse).toList();
      return (rc[1], rc[0]);
    } catch (_) {
      return (80, 24);
    }
  }();

  @override
  int get width => _dims.$1;

  @override
  int get height => _dims.$2;

  @override
  int get colors => _depth();

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Stream<void> get resized => _resized.stream;

  @override
  Future<void> open() async {
    _saved = _stty(['-g']);
    // -isig: ^C and ^Z arrive as keys; min 0 time 1: a read returns within 100 ms, so the reader
    // isolate can be killed and the process can end.
    _stty(['-icanon', '-echo', '-isig', '-ixon', '-iexten', 'min', '0', 'time', '1']);
    if (_input.isClosed) _input = StreamController.broadcast();
    final port = _port = ReceivePort();
    port.listen((bytes) => _input.add(bytes as List<int>));
    _reader = await Isolate.spawn(_readTty, port.sendPort);
    void interrupt(ProcessSignal _) => _Engine._active?._interrupt();
    _subs.addAll([
      ProcessSignal.sigwinch.watch().listen((_) {
        _size = null;
        _resized.add(null);
      }),
      ProcessSignal.sigint.watch().listen(interrupt),
      ProcessSignal.sigterm.watch().listen(interrupt),
    ]);
  }

  @override
  void close() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _reader?.kill(priority: Isolate.immediate);
    _port?.close();
    _reader = null;
    _port = null;
    if (_saved case final saved?) {
      _saved = null;
      try {
        _stty([saved]);
      } catch (_) {}
    }
  }

  @override
  void write(String data) {
    try {
      _out.writeFromSync(utf8.encode(data));
    } catch (_) {}
  }
}

/// The reader isolate: blocks on the terminal, never on this isolate's event loop.
void _readTty(SendPort out) {
  final tty = File('/dev/tty').openSync();
  while (true) {
    final bytes = tty.readSync(4096);
    if (bytes.isNotEmpty) out.send(bytes);
  }
}

/// A terminal in memory for tests: [type] or [press] keys, [resize] it, and read the [screen]
/// it shows — a small VT emulator keeps it, alternate screen and all.
///
/// ```dart
/// final term = Tui.terminal = FakeTerminal(width: 40, height: 10);
/// final done = Tui.run(0, view: (n) => Label('$n'), update: (n, e) => e == Key.up ? n + 1 : Tui.quit());
/// await pump(); term.press(Key.up); await pump();
/// expect(term.screen, '1');
/// ```
///
/// {@category CLI}
final class FakeTerminal implements Terminal {
  @override
  int width, height;

  @override
  final int colors;

  /// Every [write], in order: what a frame cost, byte for byte.
  final List<String> writes = [];

  bool isOpen = false, isAltScreen = false, isCursorVisible = true, isMouse = false, isPaste = false;

  final StreamController<List<int>> _input = StreamController.broadcast();
  final StreamController<void> _resized = StreamController.broadcast();
  late List<List<String>> _main = _grid(), _alt = _grid();
  int _cx = 0, _cy = 0;

  List<List<String>> get _g => isAltScreen ? _alt : _main;

  FakeTerminal({this.width = 80, this.height = 24, this.colors = 256});

  List<List<String>> _grid() => [for (var y = 0; y < height; y++) List.filled(width, ' ')];

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Stream<void> get resized => _resized.stream;

  @override
  Future<void> open() async => isOpen = true;

  @override
  void close() => isOpen = false;

  /// Sends [text] as typed: `'hi'`, or raw sequences like `'\x1b[A'`.
  void type(String text) => _input.add(utf8.encode(text));

  /// Sends raw [bytes]: a sequence cut mid-character, or malformed input.
  void send(List<int> bytes) => _input.add(bytes);

  /// Sends [key] as a terminal encodes it.
  void press(Key key) => type(_encode(key));

  /// Clicks or scrolls at [x], [y] (SGR encoding).
  void mouse(int x, int y, [MouseKind kind = MouseKind.press]) {
    final b = switch (kind) {
      MouseKind.wheelUp => 64,
      MouseKind.wheelDown => 65,
      MouseKind.drag => 32,
      _ => 0,
    };
    type('\x1b[<$b;${x + 1};${y + 1}${kind == MouseKind.release ? 'm' : 'M'}');
  }

  void resize(int width, int height) {
    List<List<String>> fit(List<List<String>> g) => [
      for (var y = 0; y < height; y++)
        [for (var x = 0; x < width; x++) y < g.length && x < g[y].length ? g[y][x] : ' '],
    ];
    this.width = width;
    this.height = height;
    _main = fit(_main);
    _alt = fit(_alt);
    _resized.add(null);
  }

  /// What the screen shows, rows joined by newlines, trailing blanks and blank rows dropped.
  String get screen {
    final rows = [for (final r in isAltScreen ? _alt : _main) r.join().trimRight()];
    while (rows.isNotEmpty && rows.last.isEmpty) {
      rows.removeLast();
    }
    return rows.join('\n');
  }

  @override
  void write(String data) {
    writes.add(data);
    final runes = data.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      final r = runes[i];
      if (r == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5b) {
        var j = i + 2;
        while (j < runes.length && (runes[j] < 0x40 || runes[j] > 0x7e)) {
          j++;
        }
        if (j >= runes.length) break;
        _csi(String.fromCharCodes(runes, i + 2, j), runes[j]);
        i = j;
      } else if (r == 0x0d) {
        _cx = 0;
      } else if (r == 0x0a) {
        if (++_cy >= height) {
          _g
            ..removeAt(0)
            ..add(List.filled(width, ' '));
          _cy = height - 1;
        }
      } else if (r >= 0x20) {
        final w = _cellWidth(r);
        if (w == 0) continue;
        if (_cx + w <= width && _cy < height) {
          _g[_cy][_cx] = String.fromCharCode(r);
          if (w == 2) _g[_cy][_cx + 1] = '';
        }
        _cx = (_cx + w).clamp(0, width);
      }
    }
  }

  void _csi(String params, int fin) {
    if (params.startsWith('?')) {
      final on = fin == 0x68;
      for (final p in params.substring(1).split(';')) {
        switch (p) {
          case '1049':
            if (on) _alt = _grid();
            isAltScreen = on;
          case '25':
            isCursorVisible = on;
          case '2004':
            isPaste = on;
          case '1000' || '1002' || '1006':
            isMouse = on;
        }
      }
      return;
    }
    final ps = params.split(';').map((p) => int.tryParse(p)).toList();
    int n([int i = 0, int or = 1]) => i < ps.length && ps[i] != null ? ps[i]! : or;
    final g = _g;
    void clear(int y, int from, int to) {
      for (var x = from; x < to && x < width; x++) {
        g[y][x] = ' ';
      }
    }

    switch (String.fromCharCode(fin)) {
      case 'A':
        _cy = (_cy - n()).clamp(0, height - 1);
      case 'B':
        _cy = (_cy + n()).clamp(0, height - 1);
      case 'C':
        _cx = (_cx + n()).clamp(0, width - 1);
      case 'D':
        _cx = (_cx - n()).clamp(0, width - 1);
      case 'H' || 'f':
        _cy = (n(0) - 1).clamp(0, height - 1);
        _cx = (n(1) - 1).clamp(0, width - 1);
      case 'J':
        final mode = n(0, 0);
        for (var y = 0; y < height; y++) {
          if (mode == 2 || y > _cy) clear(y, 0, width);
        }
        if (mode != 2) clear(_cy, _cx, width);
      case 'K':
        final mode = n(0, 0);
        clear(_cy, mode == 2 ? 0 : _cx, width);
    }
  }

  static String _encode(Key k) {
    const csi = {
      'up': 'A',
      'down': 'B',
      'right': 'C',
      'left': 'D',
      'home': 'H',
      'end': 'F',
      'f1': 'P',
      'f2': 'Q',
      'f3': 'R',
      'f4': 'S',
    };
    const tilde = {
      'insert': 2,
      'delete': 3,
      'pageUp': 5,
      'pageDown': 6,
      'f5': 15,
      'f6': 17,
      'f7': 18,
      'f8': 19,
      'f9': 20,
      'f10': 21,
      'f11': 23,
      'f12': 24,
    };
    final mod = 1 + (k.shift ? 1 : 0) + (k.alt ? 2 : 0) + (k.ctrl ? 4 : 0);
    if (k == Key.backTab) return '\x1b[Z';
    if (csi[k.name] case final c?) return mod == 1 ? '\x1b[$c' : '\x1b[1;$mod$c';
    if (tilde[k.name] case final t?) return mod == 1 ? '\x1b[$t~' : '\x1b[$t;$mod~';
    final alt = k.alt ? '\x1b' : '';
    return alt +
        switch (k.name) {
          'enter' => '\r',
          'tab' => '\t',
          'backspace' => '\x7f',
          'esc' => '\x1b',
          final c when k.ctrl && c.length == 1 => String.fromCharCode(c.codeUnitAt(0) & 0x1f),
          final c => c,
        };
  }
}
