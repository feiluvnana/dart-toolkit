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

/// How a line sits in its width: `Style.pad`'s, a `tui` label's, a table column's.
///
/// {@category CLI}
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
  /// wider than that has a line of its own. A paragraph's indent starts each of its lines.
  static List<String> wrap(String text, int width) {
    final lines = <String>[];
    for (final paragraph in text.split('\n')) {
      final words = paragraph.trimLeft();
      final lead = paragraph.length - words.length;
      final indent = lead < width ? paragraph.substring(0, lead) : '';
      final line = StringBuffer(indent);
      var used = 0;
      for (final word in words.split(' ')) {
        final w = TextBridge.width(word);
        if (used > 0 && indent.length + used + 1 + w > width) {
          lines.add('$line');
          line
            ..clear()
            ..write(indent);
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

  /// A CSI sequence (its parameters and final byte captured), an OSC one (a hyperlink, a title)
  /// ended by BEL or ST, a character-set designation (`ESC ( B`), or a two-byte escape (`ESC 7`).
  static RegExp get escape => _ansiEscape;
}

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

/// The helper isolate behind [Io.readLine]: one blocking read per request, its line (or a
/// one-field record holding what failed) sent to the request's port. Top level, so the spawn
/// copies nothing else.
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

/// The columns [rune] takes: none for a control, a mark, a joiner or a format character; two
/// for an East Asian wide or full-width one (emoji included); else one.
int _charVisualWidth(int rune) {
  if (rune < 0x20 || (rune >= 0x7f && rune < 0xa0)) return 0;
  if (rune < 0x300) return 1;
  // The last range starting at or before [rune].
  var lo = 0, hi = _widths.length ~/ 2 - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (_widths[mid * 2] <= rune) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  final end = _widths[lo * 2 + 1];
  return rune <= end >> 1 ? (end & 1) * 2 : 1;
}

/// The code points that are not one column, as `start, end << 1 | wide` pairs in order: zero
/// columns (Mn, Me, Cf, Hangul medial and final jamo, emoji skin tones), or two (East Asian Width
/// W or F, and the unassigned CJK planes). From Unicode 16.0's data.
// dart format off
const _widths = <int>[
  0x300, 0x6de, 0x483, 0x912, 0x591, 0xb7a, 0x5bf, 0xb7e, 0x5c1, 0xb84, 0x5c4, 0xb8a, 0x5c7, 0xb8e, 0x600, 0xc0a,
  0x610, 0xc34, 0x61c, 0xc38, 0x64b, 0xcbe, 0x670, 0xce0, 0x6d6, 0xdba, 0x6df, 0xdc8, 0x6e7, 0xdd0, 0x6ea, 0xdda,
  0x70f, 0xe1e, 0x711, 0xe22, 0x730, 0xe94, 0x7a6, 0xf60, 0x7eb, 0xfe6, 0x7fd, 0xffa, 0x816, 0x1032, 0x81b, 0x1046,
  0x825, 0x104e, 0x829, 0x105a, 0x859, 0x10b6, 0x890, 0x1122, 0x897, 0x113e, 0x8ca, 0x1204, 0x93a, 0x1274, 0x93c,
  0x1278, 0x941, 0x1290, 0x94d, 0x129a, 0x951, 0x12ae, 0x962, 0x12c6, 0x981, 0x1302, 0x9bc, 0x1378, 0x9c1, 0x1388,
  0x9cd, 0x139a, 0x9e2, 0x13c6, 0x9fe, 0x13fc, 0xa01, 0x1404, 0xa3c, 0x1478, 0xa41, 0x1484, 0xa47, 0x1490, 0xa4b,
  0x149a, 0xa51, 0x14a2, 0xa70, 0x14e2, 0xa75, 0x14ea, 0xa81, 0x1504, 0xabc, 0x1578, 0xac1, 0x158a, 0xac7, 0x1590,
  0xacd, 0x159a, 0xae2, 0x15c6, 0xafa, 0x15fe, 0xb01, 0x1602, 0xb3c, 0x1678, 0xb3f, 0x167e, 0xb41, 0x1688, 0xb4d,
  0x169a, 0xb55, 0x16ac, 0xb62, 0x16c6, 0xb82, 0x1704, 0xbc0, 0x1780, 0xbcd, 0x179a, 0xc00, 0x1800, 0xc04, 0x1808,
  0xc3c, 0x1878, 0xc3e, 0x1880, 0xc46, 0x1890, 0xc4a, 0x189a, 0xc55, 0x18ac, 0xc62, 0x18c6, 0xc81, 0x1902, 0xcbc,
  0x1978, 0xcbf, 0x197e, 0xcc6, 0x198c, 0xccc, 0x199a, 0xce2, 0x19c6, 0xd00, 0x1a02, 0xd3b, 0x1a78, 0xd41, 0x1a88,
  0xd4d, 0x1a9a, 0xd62, 0x1ac6, 0xd81, 0x1b02, 0xdca, 0x1b94, 0xdd2, 0x1ba8, 0xdd6, 0x1bac, 0xe31, 0x1c62, 0xe34,
  0x1c74, 0xe47, 0x1c9c, 0xeb1, 0x1d62, 0xeb4, 0x1d78, 0xec8, 0x1d9c, 0xf18, 0x1e32, 0xf35, 0x1e6a, 0xf37, 0x1e6e,
  0xf39, 0x1e72, 0xf71, 0x1efc, 0xf80, 0x1f08, 0xf86, 0x1f0e, 0xf8d, 0x1f2e, 0xf99, 0x1f78, 0xfc6, 0x1f8c, 0x102d,
  0x2060, 0x1032, 0x206e, 0x1039, 0x2074, 0x103d, 0x207c, 0x1058, 0x20b2, 0x105e, 0x20c0, 0x1071, 0x20e8, 0x1082,
  0x2104, 0x1085, 0x210c, 0x108d, 0x211a, 0x109d, 0x213a, 0x1100, 0x22bf, 0x1160, 0x23fe, 0x135d, 0x26be, 0x1712,
  0x2e28, 0x1732, 0x2e66, 0x1752, 0x2ea6, 0x1772, 0x2ee6, 0x17b4, 0x2f6a, 0x17b7, 0x2f7a, 0x17c6, 0x2f8c, 0x17c9,
  0x2fa6, 0x17dd, 0x2fba, 0x180b, 0x301e, 0x1885, 0x310c, 0x18a9, 0x3152, 0x1920, 0x3244, 0x1927, 0x3250, 0x1932,
  0x3264, 0x1939, 0x3276, 0x1a17, 0x3430, 0x1a1b, 0x3436, 0x1a56, 0x34ac, 0x1a58, 0x34bc, 0x1a60, 0x34c0, 0x1a62,
  0x34c4, 0x1a65, 0x34d8, 0x1a73, 0x34f8, 0x1a7f, 0x34fe, 0x1ab0, 0x359c, 0x1b00, 0x3606, 0x1b34, 0x3668, 0x1b36,
  0x3674, 0x1b3c, 0x3678, 0x1b42, 0x3684, 0x1b6b, 0x36e6, 0x1b80, 0x3702, 0x1ba2, 0x374a, 0x1ba8, 0x3752, 0x1bab,
  0x375a, 0x1be6, 0x37cc, 0x1be8, 0x37d2, 0x1bed, 0x37da, 0x1bef, 0x37e2, 0x1c2c, 0x3866, 0x1c36, 0x386e, 0x1cd0,
  0x39a4, 0x1cd4, 0x39c0, 0x1ce2, 0x39d0, 0x1ced, 0x39da, 0x1cf4, 0x39e8, 0x1cf8, 0x39f2, 0x1dc0, 0x3bfe, 0x200b,
  0x401e, 0x202a, 0x405c, 0x2060, 0x40c8, 0x2066, 0x40de, 0x20d0, 0x41e0, 0x231a, 0x4637, 0x2329, 0x4655, 0x23e9,
  0x47d9, 0x23f0, 0x47e1, 0x23f3, 0x47e7, 0x25fd, 0x4bfd, 0x2614, 0x4c2b, 0x2630, 0x4c6f, 0x2648, 0x4ca7, 0x267f,
  0x4cff, 0x268a, 0x4d1f, 0x2693, 0x4d27, 0x26a1, 0x4d43, 0x26aa, 0x4d57, 0x26bd, 0x4d7d, 0x26c4, 0x4d8b, 0x26ce,
  0x4d9d, 0x26d4, 0x4da9, 0x26ea, 0x4dd5, 0x26f2, 0x4de7, 0x26f5, 0x4deb, 0x26fa, 0x4df5, 0x26fd, 0x4dfb, 0x2705,
  0x4e0b, 0x270a, 0x4e17, 0x2728, 0x4e51, 0x274c, 0x4e99, 0x274e, 0x4e9d, 0x2753, 0x4eab, 0x2757, 0x4eaf, 0x2795,
  0x4f2f, 0x27b0, 0x4f61, 0x27bf, 0x4f7f, 0x2b1b, 0x5639, 0x2b50, 0x56a1, 0x2b55, 0x56ab, 0x2cef, 0x59e2, 0x2d7f,
  0x5afe, 0x2de0, 0x5bfe, 0x2e80, 0x5d33, 0x2e9b, 0x5de7, 0x2f00, 0x5fab, 0x2ff0, 0x6053, 0x302a, 0x605a, 0x302e,
  0x607d, 0x3041, 0x612d, 0x3099, 0x6134, 0x309b, 0x61ff, 0x3105, 0x625f, 0x3131, 0x631d, 0x3190, 0x63cb, 0x31ef,
  0x643d, 0x3220, 0x648f, 0x3250, 0x14919, 0xa490, 0x1498d, 0xa66f, 0x14ce4, 0xa674, 0x14cfa, 0xa69e, 0x14d3e,
  0xa6f0, 0x14de2, 0xa802, 0x15004, 0xa806, 0x1500c, 0xa80b, 0x15016, 0xa825, 0x1504c, 0xa82c, 0x15058, 0xa8c4,
  0x1518a, 0xa8e0, 0x151e2, 0xa8ff, 0x151fe, 0xa926, 0x1525a, 0xa947, 0x152a2, 0xa960, 0x152f9, 0xa980, 0x15304,
  0xa9b3, 0x15366, 0xa9b6, 0x15372, 0xa9bc, 0x1537a, 0xa9e5, 0x153ca, 0xaa29, 0x1545c, 0xaa31, 0x15464, 0xaa35,
  0x1546c, 0xaa43, 0x15486, 0xaa4c, 0x15498, 0xaa7c, 0x154f8, 0xaab0, 0x15560, 0xaab2, 0x15568, 0xaab7, 0x15570,
  0xaabe, 0x1557e, 0xaac1, 0x15582, 0xaaec, 0x155da, 0xaaf6, 0x155ec, 0xabe5, 0x157ca, 0xabe8, 0x157d0, 0xabed,
  0x157da, 0xac00, 0x1af47, 0xd7b0, 0x1affe, 0xf900, 0x1f5ff, 0xfb1e, 0x1f63c, 0xfe00, 0x1fc1e, 0xfe10, 0x1fc33,
  0xfe20, 0x1fc5e, 0xfe30, 0x1fca5, 0xfe54, 0x1fccd, 0xfe68, 0x1fcd7, 0xfeff, 0x1fdfe, 0xff01, 0x1fec1, 0xffe0,
  0x1ffcd, 0xfff9, 0x1fff6, 0x101fd, 0x203fa, 0x102e0, 0x205c0, 0x10376, 0x206f4, 0x10a01, 0x21406, 0x10a05, 0x2140c,
  0x10a0c, 0x2141e, 0x10a38, 0x21474, 0x10a3f, 0x2147e, 0x10ae5, 0x215cc, 0x10d24, 0x21a4e, 0x10d69, 0x21ada,
  0x10eab, 0x21d58, 0x10efc, 0x21dfe, 0x10f46, 0x21ea0, 0x10f82, 0x21f0a, 0x11001, 0x22002, 0x11038, 0x2208c,
  0x11070, 0x220e0, 0x11073, 0x220e8, 0x1107f, 0x22102, 0x110b3, 0x2216c, 0x110b9, 0x22174, 0x110bd, 0x2217a,
  0x110c2, 0x22184, 0x110cd, 0x2219a, 0x11100, 0x22204, 0x11127, 0x22256, 0x1112d, 0x22268, 0x11173, 0x222e6,
  0x11180, 0x22302, 0x111b6, 0x2237c, 0x111c9, 0x22398, 0x111cf, 0x2239e, 0x1122f, 0x22462, 0x11234, 0x22468,
  0x11236, 0x2246e, 0x1123e, 0x2247c, 0x11241, 0x22482, 0x112df, 0x225be, 0x112e3, 0x225d4, 0x11300, 0x22602,
  0x1133b, 0x22678, 0x11340, 0x22680, 0x11366, 0x226d8, 0x11370, 0x226e8, 0x113bb, 0x22780, 0x113ce, 0x2279c,
  0x113d0, 0x227a0, 0x113d2, 0x227a4, 0x113e1, 0x227c4, 0x11438, 0x2287e, 0x11442, 0x22888, 0x11446, 0x2288c,
  0x1145e, 0x228bc, 0x114b3, 0x22970, 0x114ba, 0x22974, 0x114bf, 0x22980, 0x114c2, 0x22986, 0x115b2, 0x22b6a,
  0x115bc, 0x22b7a, 0x115bf, 0x22b80, 0x115dc, 0x22bba, 0x11633, 0x22c74, 0x1163d, 0x22c7a, 0x1163f, 0x22c80,
  0x116ab, 0x22d56, 0x116ad, 0x22d5a, 0x116b0, 0x22d6a, 0x116b7, 0x22d6e, 0x1171d, 0x22e3a, 0x1171f, 0x22e3e,
  0x11722, 0x22e4a, 0x11727, 0x22e56, 0x1182f, 0x2306e, 0x11839, 0x23074, 0x1193b, 0x23278, 0x1193e, 0x2327c,
  0x11943, 0x23286, 0x119d4, 0x233ae, 0x119da, 0x233b6, 0x119e0, 0x233c0, 0x11a01, 0x23414, 0x11a33, 0x23470,
  0x11a3b, 0x2347c, 0x11a47, 0x2348e, 0x11a51, 0x234ac, 0x11a59, 0x234b6, 0x11a8a, 0x2352c, 0x11a98, 0x23532,
  0x11c30, 0x2386c, 0x11c38, 0x2387a, 0x11c3f, 0x2387e, 0x11c92, 0x2394e, 0x11caa, 0x23960, 0x11cb2, 0x23966,
  0x11cb5, 0x2396c, 0x11d31, 0x23a6c, 0x11d3a, 0x23a74, 0x11d3c, 0x23a7a, 0x11d3f, 0x23a8a, 0x11d47, 0x23a8e,
  0x11d90, 0x23b22, 0x11d95, 0x23b2a, 0x11d97, 0x23b2e, 0x11ef3, 0x23de8, 0x11f00, 0x23e02, 0x11f36, 0x23e74,
  0x11f40, 0x23e80, 0x11f42, 0x23e84, 0x11f5a, 0x23eb4, 0x13430, 0x26880, 0x13447, 0x268aa, 0x1611e, 0x2c252,
  0x1612d, 0x2c25e, 0x16af0, 0x2d5e8, 0x16b30, 0x2d66c, 0x16f4f, 0x2de9e, 0x16f8f, 0x2df24, 0x16fe0, 0x2dfc7,
  0x16fe4, 0x2dfc8, 0x16ff0, 0x2dfe3, 0x17000, 0x30fef, 0x18800, 0x319ab, 0x18cff, 0x31a11, 0x1aff0, 0x35fe7,
  0x1aff5, 0x35ff7, 0x1affd, 0x35ffd, 0x1b000, 0x36245, 0x1b132, 0x36265, 0x1b150, 0x362a5, 0x1b155, 0x362ab,
  0x1b164, 0x362cf, 0x1b170, 0x365f7, 0x1bc9d, 0x3793c, 0x1bca0, 0x37946, 0x1cf00, 0x39e5a, 0x1cf30, 0x39e8c,
  0x1d167, 0x3a2d2, 0x1d173, 0x3a304, 0x1d185, 0x3a316, 0x1d1aa, 0x3a35a, 0x1d242, 0x3a488, 0x1d300, 0x3a6ad,
  0x1d360, 0x3a6ed, 0x1da00, 0x3b46c, 0x1da3b, 0x3b4d8, 0x1da75, 0x3b4ea, 0x1da84, 0x3b508, 0x1da9b, 0x3b53e,
  0x1daa1, 0x3b55e, 0x1e000, 0x3c00c, 0x1e008, 0x3c030, 0x1e01b, 0x3c042, 0x1e023, 0x3c048, 0x1e026, 0x3c054,
  0x1e08f, 0x3c11e, 0x1e130, 0x3c26c, 0x1e2ae, 0x3c55c, 0x1e2ec, 0x3c5de, 0x1e4ec, 0x3c9de, 0x1e5ee, 0x3cbde,
  0x1e8d0, 0x3d1ac, 0x1e944, 0x3d294, 0x1f004, 0x3e009, 0x1f0cf, 0x3e19f, 0x1f18e, 0x3e31d, 0x1f191, 0x3e335,
  0x1f200, 0x3e405, 0x1f210, 0x3e477, 0x1f240, 0x3e491, 0x1f250, 0x3e4a3, 0x1f260, 0x3e4cb, 0x1f300, 0x3e641,
  0x1f32d, 0x3e66b, 0x1f337, 0x3e6f9, 0x1f37e, 0x3e727, 0x1f3a0, 0x3e795, 0x1f3cf, 0x3e7a7, 0x1f3e0, 0x3e7e1,
  0x1f3f4, 0x3e7e9, 0x1f3f8, 0x3e7f5, 0x1f3fb, 0x3e7fe, 0x1f400, 0x3e87d, 0x1f440, 0x3e881, 0x1f442, 0x3e9f9,
  0x1f4ff, 0x3ea7b, 0x1f54b, 0x3ea9d, 0x1f550, 0x3eacf, 0x1f57a, 0x3eaf5, 0x1f595, 0x3eb2d, 0x1f5a4, 0x3eb49,
  0x1f5fb, 0x3ec9f, 0x1f680, 0x3ed8b, 0x1f6cc, 0x3ed99, 0x1f6d0, 0x3eda5, 0x1f6d5, 0x3edaf, 0x1f6dc, 0x3edbf,
  0x1f6eb, 0x3edd9, 0x1f6f4, 0x3edf9, 0x1f7e0, 0x3efd7, 0x1f7f0, 0x3efe1, 0x1f90c, 0x3f275, 0x1f93c, 0x3f28b,
  0x1f947, 0x3f3ff, 0x1fa70, 0x3f4f9, 0x1fa80, 0x3f513, 0x1fa8f, 0x3f58d, 0x1face, 0x3f5b9, 0x1fadf, 0x3f5d3,
  0x1faf0, 0x3f5f1, 0x20000, 0x5fffb, 0x30000, 0x7fffb, 0xe0001, 0x1c0002, 0xe0020, 0x1c00fe, 0xe0100, 0x1c03de,
];
// dart format on

/// What [TextBridge.escape] matches.
final _ansiEscape = RegExp(r'\x1B(?:\[([0-?]*)[ -/]*([@-~])|\][^\x07\x1B]*(?:\x07|\x1B\\)|[()*+][0-~]|[78=>DEHMc])');
