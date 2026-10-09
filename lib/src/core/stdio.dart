part of '../core.dart';

const _ioKey = #dartToolkitIo;

/// What one [Io.scope] replaces; `null` keeps the enclosing one's.
final class _IoLayer {
  final Stream<List<int>>? stdin;
  final StringSink? stdout, stderr;
  final Terminal? terminal;
  final bool? color;
  final _IoLayer? parent;

  const _IoLayer(this.stdin, this.stdout, this.stderr, this.color, this.parent, [this.terminal]);

  Stream<List<int>>? get input => stdin ?? parent?.input;
  StringSink? get out => stdout ?? _screen ?? parent?.out;
  StringSink? get err => stderr ?? _screen ?? parent?.err;
  bool? get colored => color ?? parent?.colored;
  Terminal? get term => terminal ?? parent?.term;

  /// Whether stdout is a scope's terminal (`true`), a scope's sink (`false`), or the process's.
  bool? get outOnTerminal => stdout != null ? false : (terminal != null ? true : parent?.outOnTerminal);
  bool? get errOnTerminal => stderr != null ? false : (terminal != null ? true : parent?.errOnTerminal);

  StringSink? get _screen => switch (terminal) {
    final t? => _TerminalSink(t),
    null => null,
  };
}

/// The process's standard I/O: every console write and read goes through it, and [scope]
/// replaces any of it for a block (a test, a capture).
///
/// ```dart
/// await for (final line in Io.lines()) { … }      // one shared reader: break and read again
/// final out = StringBuffer();
/// await Io.scope(() => report(), stdout: out, color: false);
/// ```
///
/// {@category CLI}
abstract final class Io {
  static _IoLayer? get _layer => Zone.current[_ioKey] as _IoLayer?;

  /// Runs [body] with [stdin], [stdout], [stderr] and [color] in place of the process's (what
  /// is not given stays the enclosing scope's); the scope holds until [body]'s result has
  /// finished.
  ///
  /// [terminal] is the screen and keyboard instead of the process's: `Tui`, the pickers and the
  /// console's live region draw on it, and stdout and stderr not given here write onto it, as
  /// they would on a real one. Line prompts still read [stdin].
  static Future<T> scope<T>(
    FutureOr<T> Function() body, {
    Stream<List<int>>? stdin,
    StringSink? stdout,
    StringSink? stderr,
    Terminal? terminal,
    bool? color,
  }) async => await runZoned(
    () async => await body(),
    zoneValues: {_ioKey: _IoLayer(stdin, stdout, stderr, color, _layer, terminal)},
  );

  /// Standard output: the scope's sink, else the process's. Escapes are dropped where colour is
  /// off.
  static StringSink get stdout {
    // One zone lookup: every log line asks.
    final layer = _layer;
    final out = layer?.out;
    final colored = layer?.colored ?? (out == null && _ansiTerminal);
    if (out != null) return colored ? out : _Plain(out);
    return colored ? _stdout : _plainStdout;
  }

  /// Standard error, as [stdout]. Colour is decided for stderr on its own, so `app 2>log` writes
  /// a log with no escapes.
  static StringSink get stderr {
    final layer = _layer;
    final err = layer?.err;
    final colored = layer?.colored ?? (err == null && _ansiStderr);
    if (err != null) return colored ? err : _Plain(err);
    return colored ? _stderr : _plainStderr;
  }

  static bool get _outTakesColor => _layer?.colored ?? (_layer?.out == null && _ansiTerminal);
  static bool get _errTakesColor => _layer?.colored ?? (_layer?.err == null && _ansiStderr);

  static final StringSink _plainStdout = _Plain(_stdout);
  static final StringSink _plainStderr = _Plain(_stderr);

  static final IOSink _stdout = _quiet(io.stdout);
  static final IOSink _stderr = _quiet(io.stderr);

  /// A closed pipe (`| head`) is the reader leaving, not news.
  static IOSink _quiet(IOSink sink) => sink..done.catchError((_) {});

  static T? _try<T>(T Function() native) {
    try {
      return native();
    } catch (_) {
      return null; // no terminal, or a platform without the query: the answer is "unknown"
    }
  }

  /// Whether stdout is a terminal a person reads: a scope's `terminal:`, never a scope's sink.
  static bool get isTerminal => _layer?.outOnTerminal ?? _hasTerminal;

  /// Whether stderr is a terminal, as [isTerminal].
  static bool get isStderrTerminal => _layer?.errOnTerminal ?? _hasErrTerminal;

  /// Whether stdin is the process's own and a terminal: a person can answer a prompt.
  static bool get isInteractive => _layer?.input == null && _try(() => io.stdin.hasTerminal) == true;

  // Native calls, asked once: per call they were most of the cost of a progress tick.
  static final _hasTerminal = _try(() => io.stdout.hasTerminal) ?? false;
  static final _hasErrTerminal = _try(() => io.stderr.hasTerminal) ?? false;
  static final _ansiTerminal = _try(() => io.stdout.supportsAnsiEscapes && !Env.has('NO_COLOR')) ?? false;
  static final _ansiStderr = _try(() => io.stderr.supportsAnsiEscapes && !Env.has('NO_COLOR')) ?? false;

  /// stdout's width in cells when it is a terminal, else `null`.
  static int? get columns => switch (_layer?.outOnTerminal) {
    true => _layer!.term!.width,
    false => null,
    null => _hasTerminal ? _try(() => io.stdout.terminalColumns) : null,
  };

  /// stderr's width in cells when it is a terminal, else `null`.
  static int? get stderrColumns => switch (_layer?.errOnTerminal) {
    true => _layer!.term!.width,
    false => null,
    null => _hasErrTerminal ? _try(() => io.stderr.terminalColumns) : null,
  };

  /// Whether output carries colour: the scope's [scope] `color:`, else whether stdout is a
  /// terminal that takes escapes and `NO_COLOR` is unset.
  static bool get color => _outTakesColor;

  /// The next line of stdin, or `null` at its end. It reads from the one shared reader, so it
  /// mixes safely with [lines].
  static Future<String?> readLine() => _reader().next();

  /// stdin's lines, from the one shared reader: breaking out of the loop and reading again
  /// loses nothing.
  static Stream<String> lines() async* {
    final reader = _reader();
    for (String? line; (line = await reader.next()) != null;) {
      yield line!;
    }
  }

  /// The rest of stdin, its lines joined by `\n`.
  static Future<String> read() async => (await lines().toList()).join('\n');

  static _Lines _reader() {
    if (_layer?.input case final input?) return _scoped[input] ??= _Lines(input);
    // A person at a terminal: a line at a time, read on a helper isolate so nothing holds stdin
    // between prompts and a child given the terminal reads its own keys.
    if (_try(() => io.stdin.hasTerminal) == true) return _terminal;
    return _piped ??= _Lines(io.stdin);
  }

  static final _scoped = Expando<_Lines>('stdin');
  static _Lines? _piped;
  static final _terminal = _Lines.terminal();
}

enum Align { left, center, right }

/// Not API: terminal text, measured in cells and aware of ANSI escapes; `Style` (in `cli` and
/// `tui`) is its public face, and `collection` renders tables with it.
abstract final class TextBridge {
  /// [text] without ANSI escape sequences: styles, cursor moves, and hyperlinks (their text kept).
  static String stripAnsi(String text) => text.contains('\x1b') ? text.replaceAll(_ansiEscape, '') : text;

  /// The terminal columns [text] occupies: escapes zero, East Asian wide characters two.
  static int width(String text) {
    // Printable ASCII is one column each, and holds no escape: the common case skips both scans.
    var ascii = true;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit < 0x20 || unit > 0x7e) {
        ascii = false;
        break;
      }
    }
    if (ascii) return text.length;
    var w = 0, joined = false;
    for (final rune in stripAnsi(text).runes) {
      // What follows a zero-width joiner draws inside the glyph before it.
      if (!joined) w += _charVisualWidth(rune);
      joined = rune == 0x200d;
    }
    return w;
  }

  /// [text] cut to [width] columns, ending in `…` (one column) when cut. It cuts between
  /// graphemes, never inside an emoji sequence, and keeps every escape, so styles and links close
  /// as they would have.
  static String truncate(String text, int width) {
    if (width <= 0) return '';
    if (TextBridge.width(text) <= width) return text;
    final out = StringBuffer();
    var used = 0, cut = false;
    void visible(String part) {
      if (cut) return;
      final runes = part.runes.toList();
      for (var i = 0; i < runes.length;) {
        final start = i, w = _charVisualWidth(runes[i++]);
        // Marks, variation selectors and what a zero-width joiner joins ride with their glyph.
        while (i < runes.length && (_charVisualWidth(runes[i]) == 0 || runes[i - 1] == 0x200d)) {
          if (runes[i] < 0x20) break;
          i++;
        }
        if (used + w > width - 1) {
          out.write('…');
          cut = true;
          return;
        }
        out.write(String.fromCharCodes(runes, start, i));
        used += w;
      }
    }

    var at = 0;
    for (final escape in _ansiEscape.allMatches(text)) {
      visible(text.substring(at, escape.start));
      out.write(escape[0]);
      at = escape.end;
    }
    visible(text.substring(at));
    return '$out';
  }

  /// [text] filled with spaces to [width] columns, placed by [align]; text that is already as wide
  /// is returned as it is (cut it with [truncate]).
  static String pad(String text, int width, {Align align = Align.left}) {
    final gap = width - TextBridge.width(text);
    if (gap <= 0) return text;
    return switch (align) {
      Align.left => text + ' ' * gap,
      Align.right => ' ' * gap + text,
      Align.center => ' ' * (gap ~/ 2) + text + ' ' * (gap - gap ~/ 2),
    };
  }

  /// [text] in lines of at most [width] columns, broken at spaces and at its own newlines; a word
  /// wider than that has a line of its own.
  static List<String> wrap(String text, int width) {
    final lines = <String>[];
    for (final paragraph in text.split('\n')) {
      final line = StringBuffer();
      var used = 0;
      for (final word in paragraph.split(' ')) {
        final w = TextBridge.width(word);
        if (used > 0 && used + 1 + w > width) {
          lines.add('$line');
          line.clear();
          used = 0;
        }
        if (used > 0) {
          line.write(' ');
          used++;
        }
        line.write(word);
        used += w;
      }
      lines.add('$line'.trimRight());
    }
    return lines;
  }
}

/// How a line sits in its width: [Io.pad]'s, a `tui` label's, a table column's.
///
/// {@category CLI}

/// The helper isolate behind [Io.readLine]: one blocking read per request, its line (or a
/// one-field record holding what failed) sent to the request's port. Top level, so the spawn
/// copies nothing else.
/// One reader of a stdin: lines are taken from it as they are asked for, so any number of
/// loops and prompts share it.
final class _Lines {
  final Stream<List<int>>? _source;
  StreamSubscription<String>? _subscription;
  final _ready = Queue<String>();
  final _waiting = Queue<Completer<String?>>();
  bool _ended = false;
  Future<SendPort>? _isolate;

  _Lines(Stream<List<int>> source) : _source = source;

  /// The terminal's stdin, read a line at a time on a helper isolate.
  _Lines.terminal() : _source = null;

  Future<String?> next() {
    final source = _source;
    if (source == null) return _readTerminal();
    if (_ready.isNotEmpty) return Future.value(_ready.removeFirst());
    if (_ended) return Future.value();
    final line = Completer<String?>();
    _waiting.add(line);
    final subscription = _subscription ??= source
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_line, onError: _error, onDone: _done);
    if (subscription.isPaused) subscription.resume();
    return line.future;
  }

  void _line(String line) {
    if (_waiting.isNotEmpty) return _waiting.removeFirst().complete(line);
    _ready.add(line);
    _subscription?.pause();
  }

  void _error(Object error, StackTrace stackTrace) {
    if (_waiting.isNotEmpty) _waiting.removeFirst().completeError(error, stackTrace);
  }

  void _done() {
    _ended = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    }
  }

  Future<String?> _readTerminal() async {
    final reader = await (_isolate ??= _startReader());
    final line = Completer<String?>();
    final reply = RawReceivePort();
    reply.handler = (Object? message) {
      reply.close();
      switch (message) {
        case (final String error,):
          line.completeError(StdinException(error));
        case final String? text:
          line.complete(text);
      }
    };
    reader.send(reply.sendPort);
    return line.future;
  }

  static Future<SendPort> _startReader() async {
    final ready = RawReceivePort();
    final inbox = Completer<SendPort>();
    ready.handler = (Object? port) {
      ready.close();
      inbox.complete(port as SendPort);
    };
    await Isolate.spawn(_readLines, ready.sendPort, debugName: 'Io.readLine');
    return inbox.future;
  }
}

void _readLines(SendPort ready) {
  final inbox = RawReceivePort();
  inbox.handler = (Object? message) {
    final reply = message as SendPort;
    try {
      reply.send(stdin.readLineSync(encoding: const Utf8Codec(allowMalformed: true)));
    } catch (e) {
      reply.send(('$e',));
    }
  };
  ready.send(inbox.sendPort);
}

/// Not API: what `cli` and `tui` need from [Io].
final class IoBridge {
  IoBridge._();

  /// Draws a write above a live region; `cli` installs it while one is on screen.
  static void Function(void Function() write)? above;

  /// What [write] printed to stdout and stderr, colour kept as stderr would have it.
  static (String out, String err) capture(void Function() write) {
    final keep = Io._errTakesColor;
    final (o, e) = (StringBuffer(), StringBuffer());
    runZoned(write, zoneValues: {_ioKey: _IoLayer(null, o, e, keep, Io._layer)});
    return ('$o', '$e');
  }

  static Future<T> Function<T>(Future<T> Function() action)? suspend;

  static Border Function()? border;

  static final Set<void Function()> restores = {};

  static final Set<Future<void> Function()> stops = {};

  /// The colour a scope asked for, or `null` when none did.
  static bool? get color => Io._layer?.colored;

  /// The terminal an [Io.scope] set, or `null` for the process's own.
  static Terminal? get terminal => Io._layer?.term;

  /// Whether stderr ([err]) or stdout carries colour.
  static bool takesColor(bool err) => err ? Io._errTakesColor : Io._outTakesColor;

  static int runeWidth(int rune) => _charVisualWidth(rune);
}

final class _Plain implements StringSink {
  final StringSink _sink;

  _Plain(this._sink);

  @override
  void write(Object? object) => _sink.write(TextBridge.stripAnsi('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _sink.writeln(TextBridge.stripAnsi('$object'));
}

// ---- text measurement: here so that `cli` and `collection` share it

int _charVisualWidth(int rune) {
  if (rune < 0x20 || (rune >= 0x7f && rune < 0xa0)) return 0;
  if (rune < 0x7f) return 1;
  // Combining and zero-width.
  if (rune >= 0x0300 && rune <= 0x036f) return 0;
  if (rune >= 0x200b && rune <= 0x200f) return 0;
  if (rune == 0x200d) return 0;
  if (rune >= 0xfe00 && rune <= 0xfe0f) return 0;
  if (rune >= 0x1f3fb && rune <= 0x1f3ff) return 0;

  // East Asian Wide/Fullwidth and emoji; of the dingbats only ☕ ⚡ ✅ ❌ are wide.
  if (rune == 0x2615 ||
      rune == 0x26a1 ||
      rune == 0x2705 ||
      rune == 0x274c ||
      (rune >= 0x1100 && rune <= 0x115f) ||
      rune == 0x2329 ||
      rune == 0x232a ||
      (rune >= 0x2e80 && rune <= 0x303e) ||
      (rune >= 0x3040 && rune <= 0xa4cf) ||
      (rune >= 0xac00 && rune <= 0xd7a3) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0xfe10 && rune <= 0xfe19) ||
      (rune >= 0xfe30 && rune <= 0xfe6f) ||
      (rune >= 0xff00 && rune <= 0xff60) ||
      (rune >= 0xffe0 && rune <= 0xffe6) ||
      (rune >= 0x1f300 && rune <= 0x1faff) ||
      (rune >= 0x20000 && rune <= 0x2fffd) ||
      (rune >= 0x30000 && rune <= 0x3fffd)) {
    return 2;
  }
  return 1;
}

/// A CSI sequence (colours, cursor moves), or an OSC one (a hyperlink, a title) ended by BEL or ST.
final _ansiEscape = RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\))');
