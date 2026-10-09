/// The keys and the raw terminal `tui` and `pick` share: the events an app hears, the
/// terminal in raw mode (`/dev/tty`, the Windows console), the key decoder, and the `Choice`
/// list model. `cli` does not compile it.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' hide Pointer;
import 'dart:ffi' as ffi show Pointer;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'core.dart';
import 'terminal.dart';

/// What an app hears, each one noun for what arrived: a moment ([Start], [Resize], [Focus],
/// [Blur], [Suspend], [Resume], [Interrupt]), an input ([KeyPress], [Paste], [Pointer]), or its
/// own message ([Post]). Sealed, so a `switch` over it is exhaustive.
///
/// {@category CLI}
sealed class TuiEvent<M> {
  const TuiEvent();
}

/// Once, when the terminal is ready and before the first frame: where an app starts its work
/// (`Tui.post`, `Tui.listen`, `Tui.focus`).
///
/// {@category CLI}
final class Start extends TuiEvent<Never> {
  const Start();

  @override
  bool operator ==(Object other) => other is Start;

  @override
  int get hashCode => (Start).hashCode;

  @override
  String toString() => 'Start';
}

/// The terminal is now [width] × [height]; the next frame is drawn at that size.
///
/// {@category CLI}
final class Resize extends TuiEvent<Never> {
  final int width, height;

  const Resize(this.width, this.height);

  @override
  bool operator ==(Object other) => other is Resize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'Resize($width×$height)';
}

/// The terminal window gained the focus; [Blur] when it lost it. Not a control's focus.
///
/// {@category CLI}
final class Focus extends TuiEvent<Never> {
  const Focus();

  @override
  bool operator ==(Object other) => other is Focus;

  @override
  int get hashCode => (Focus).hashCode;

  @override
  String toString() => 'Focus';
}

/// The terminal window lost the focus.
///
/// {@category CLI}
final class Blur extends TuiEvent<Never> {
  const Blur();

  @override
  bool operator ==(Object other) => other is Blur;

  @override
  int get hashCode => (Blur).hashCode;

  @override
  String toString() => 'Blur';
}

/// ^Z: the terminal is put back and the process stops once `update` has seen it. POSIX only.
///
/// {@category CLI}
final class Suspend extends TuiEvent<Never> {
  const Suspend();

  @override
  bool operator ==(Object other) => other is Suspend;

  @override
  int get hashCode => (Suspend).hashCode;

  @override
  String toString() => 'Suspend';
}

/// The process runs again after a [Suspend]: the screen is redrawn whole.
///
/// {@category CLI}
final class Resume extends TuiEvent<Never> {
  const Resume();

  @override
  bool operator ==(Object other) => other is Resume;

  @override
  int get hashCode => (Resume).hashCode;

  @override
  String toString() => 'Resume';
}

/// ^C. An `update` that answers a state not `identical` to the one it got keeps the app open;
/// answering the same state (`_ => state`) ends it as a SIGINT would. A second ^C within two
/// seconds always ends it, and a SIGINT from outside never reaches `update`.
///
/// {@category CLI}
final class Interrupt extends TuiEvent<Never> {
  const Interrupt();

  @override
  bool operator ==(Object other) => other is Interrupt;

  @override
  int get hashCode => (Interrupt).hashCode;

  @override
  String toString() => 'Interrupt';
}

/// An app's own message: from `Tui.post`, `Tui.listen`, a `Button`, a `Clickable` or a popup's
/// dismiss.
///
/// {@category CLI}
final class Post<M> extends TuiEvent<M> {
  final M message;

  const Post(this.message);

  @override
  bool operator ==(Object other) => other is Post<M> && other.message == message;

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() => 'Post($message)';
}

/// A key: a printable one is its text (`KeyPress('q')`, `KeyPress('Q', shift: true)`, a
/// keypad's digit), the others have names (`KeyPress.enter`, `const KeyPress('f5')`), and Ctrl
/// and Alt combine with either (`const KeyPress('c', ctrl: true)`). A key reads the same
/// whether or not the terminal speaks the kitty keyboard protocol: Ctrl+letter is lowercase, and
/// Ctrl+H, I, M and [ are Backspace, Tab, Enter and Esc.
///
/// {@category CLI}
final class KeyPress extends TuiEvent<Never> {
  /// The text typed (one character, with what joins it), or a name: `up`, `enter`, `f5`.
  final String name;
  final bool ctrl, alt, shift;

  const KeyPress(this.name, {this.ctrl = false, this.alt = false, this.shift = false});

  static const up = KeyPress('up');
  static const down = KeyPress('down');
  static const left = KeyPress('left');
  static const right = KeyPress('right');
  static const home = KeyPress('home');
  static const end = KeyPress('end');
  static const pageUp = KeyPress('pageUp');
  static const pageDown = KeyPress('pageDown');
  static const insert = KeyPress('insert');
  static const delete = KeyPress('delete');
  static const enter = KeyPress('enter');
  static const tab = KeyPress('tab');
  static const backTab = KeyPress('tab', shift: true);
  static const backspace = KeyPress('backspace');
  static const esc = KeyPress('esc');

  /// What it types into a text input: [name] for a printable key without Ctrl or Alt, else
  /// `null`.
  String? get text => ctrl || alt || _isNamed(name) ? null : name;

  /// A name is two or more ASCII letters and digits, which no single typed character is.
  static bool _isNamed(String name) {
    if (name.length < 2) return false;
    for (var i = 0; i < name.length; i++) {
      final c = name.codeUnitAt(i) | 0x20;
      if (!((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39))) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is KeyPress && other.name == name && other.ctrl == ctrl && other.alt == alt && other.shift == shift;

  @override
  int get hashCode => Object.hash(name, ctrl, alt, shift);

  @override
  String toString() => '${ctrl ? 'ctrl+' : ''}${alt ? 'alt+' : ''}${shift ? 'shift+' : ''}$name';
}

/// Text pasted in one piece (bracketed paste), newlines and all.
///
/// {@category CLI}
final class Paste extends TuiEvent<Never> {
  final String text;

  const Paste(this.text);

  @override
  bool operator ==(Object other) => other is Paste && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'Paste(${text.length} chars)';
}

/// What a [Pointer] event did.
///
/// {@category CLI}
enum PointerKind { press, release, drag, move, wheelUp, wheelDown }

/// A click, drag, move or wheel turn at column [x], row [y] (0-based, of the app's rows).
///
/// Only with `pointer: true` on `Tui.run`.
///
/// {@category CLI}
final class Pointer extends TuiEvent<Never> {
  final int x, y;
  final PointerKind kind;

  /// 0 left, 1 middle, 2 right.
  final int button;
  final bool ctrl, alt, shift;

  const Pointer(this.x, this.y, this.kind, {this.button = 0, this.ctrl = false, this.alt = false, this.shift = false});

  @override
  bool operator ==(Object other) =>
      other is Pointer &&
      other.x == x &&
      other.y == y &&
      other.kind == kind &&
      other.button == button &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(x, y, kind, button, ctrl, alt, shift);

  @override
  String toString() => 'Pointer(${kind.name} $x,$y)';
}

/// What takes the focus: keys reach it before an app's `update`, Tab moves between the ones on
/// screen, a click gives it. `Field`, `Scroll`, `Log` and [Choice] are; a custom widget mixes it
/// in and calls `canvas.focus(this)` when it paints.
///
/// ```dart
/// final class Dial extends Widget with Focusable {
///   int value = 0;
///   @override
///   bool handle(TuiEvent<Object?> event) => switch (event) {
///     KeyPress.up => (value++, true).$2,
///     _ => false,
///   };
///   @override
///   void paint(Canvas canvas) => canvas.text(0, 0, '$value', canvas.focus(this) ? canvas.palette.accent : null);
/// }
/// ```
///
/// {@category CLI}
mixin Focusable {
  /// Handles a key or a paste; `true` when it used it, so `update` does not see it.
  bool handle(TuiEvent<Object?> event) => false;

  /// A click or a wheel turn at [x], [y] inside it.
  void pointer(Pointer event, int x, int y) {}
}

/// Not API: the key reader `tui` and `pick` share.
///
/// An instance turns a terminal's bytes into events: [add] each chunk, [cancel] at the end; a
/// lone ESC is the Esc key once nothing follows it for 30 ms.
final class KeysBridge {
  final void Function(List<TuiEvent<Never>> events) _onEvents;
  final _Decoder _decoder;
  Timer? _esc;

  /// [position] hears a cursor position report (1-based row and column), [kitty] the answer
  /// that the kitty keyboard protocol is spoken; neither is an event.
  KeysBridge(this._onEvents, {void Function(int row, int column)? position, void Function()? kitty})
    : _decoder = _Decoder(position, kitty);

  void add(List<int> bytes) {
    _esc?.cancel();
    _onEvents(_decoder.add(bytes));
    if (_decoder.isWaiting) _esc = Timer(const Duration(milliseconds: 30), () => _onEvents(_decoder.flush()));
  }

  void cancel() => _esc?.cancel();

  /// What a signal caught while the terminal is open runs: the reader that is in charge of it.
  static void Function()? interrupted;

  /// The scope's terminal (`Io.scope(terminal:)`), else the controlling one, or `null` when
  /// there is none.
  static Terminal? connect() => IoBridge.terminal ?? (Platform.isWindows ? _WinConsole.connect() : _Tty.connect());

  /// Whether [t] is the process's terminal, where ^C can be raised as the SIGINT it would be.
  static bool isTty(Terminal t) => t is _Tty || t is _WinConsole;

  /// ^C, which raw mode reads as a byte: on the process's own terminal it is raised as the SIGINT
  /// it would have been (a `Cli` then leaves through its cleanups with 130, and the terminal's
  /// watch ends the reader); elsewhere [interrupt] runs.
  static void ctrlC(Terminal term, void Function() interrupt) {
    if (isTty(term) && !Platform.isWindows && Process.killPid(pid, ProcessSignal.sigint)) return;
    interrupt();
  }

  /// Whether a picker's filter [query] (lowercased) finds [label] (lowercased): a substring, else
  /// a subsequence. Without building the ranges: it runs on every item at every key.
  static bool matches(String label, String query) => _find(label, query, null);

  /// Where [choice] was drawn: what a widget keeps between frames.
  static ChoiceLayout layout(Choice<Object?> choice) => choice._layout;

  /// Where [choice]'s cursor is among the items it shows, or -1.
  static int position(Choice<Object?> choice) {
    choice._settle();
    return choice._position(choice.index);
  }

  /// The widest of [choice]'s labels, in columns: measured once per list.
  static int widest(Choice<Object?> choice) {
    final items = choice._items;
    if (!identical(choice._widestOf, items) || choice._widestCount != items.length) {
      var best = 0;
      for (var i = 0; i < items.length; i++) {
        final w = Style.width(choice.label(i));
        if (w > best) best = w;
      }
      choice
        .._widest = best
        .._widestOf = items
        .._widestCount = items.length;
    }
    return choice._widest;
  }
}

/// The process's terminal, through `/dev/tty`: input still works when stdin is a pipe, and
/// nothing reaches stdout, so `app | next` and `app > out` carry only what the app prints.
final class _Tty implements Terminal {
  RandomAccessFile? _out;
  String? _saved;

  /// The keys, read by a `cat` of the terminal: a read in this process cannot be stopped once
  /// the modes are restored, and would hold the exit until Enter; a child is killed mid-read.
  Process? _reader;
  int _readerPid = -1;
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

  (int, int) get _dims => _size ??=
      _terminalSize() ??
      () {
        try {
          final rc = _stty(['size']).split(' ').map(int.parse).toList();
          return (rc[1], rc[0]);
        } catch (_) {
          return (80, 24);
        }
      }();

  /// The size stdout or stderr reports, when either is the terminal: no process to ask.
  static (int, int)? _terminalSize() {
    for (final s in [stdout, stderr]) {
      try {
        if (s.hasTerminal) return (s.terminalColumns, s.terminalLines);
      } catch (_) {} // no size from this terminal: the defaults stand
    }
    return null;
  }

  @override
  int get width => _dims.$1;

  @override
  int get height => _dims.$2;

  @override
  int get colors => TerminalBridge.depth();

  @override
  bool get unicode => TerminalBridge.unicode;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Stream<void> get resized => _resized.stream;

  /// One process from open to close: it prints the saved modes, sets raw mode, prints the
  /// reader's pid, then reads the keys — a `cat` it kills when our end of its stdin closes, so
  /// the reader dies with this process even after `kill -9` and never reads the shell's input.
  /// `-isig`: ^C and ^Z arrive as keys; `min 1 time 0`: each key is read as it comes, and cat
  /// would take a read of nothing for the end of input.
  static const _session = r'''
stty -g < /dev/tty >&2 || exit 1
stty -icanon -echo -isig -ixon -iexten min 1 time 0 < /dev/tty || exit 1
cat /dev/tty & echo $! >&2
cat >/dev/null
kill $!
''';

  @override
  Future<void> open() async {
    if (_input.isClosed) _input = StreamController.broadcast();
    _out ??= File('/dev/tty').openSync(mode: FileMode.writeOnly);
    final reader = _reader = await Process.start('/bin/sh', ['-c', _session]);
    final lines = <String>[];
    final ready = Completer<void>();
    reader.stdout.listen(_input.add);
    reader.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (lines.length < 2) lines.add(line);
      if (lines.length == 2 && !ready.isCompleted) ready.complete();
    }, onDone: () => ready.isCompleted ? null : ready.complete());
    await ready.future;
    if (lines.length < 2 || int.tryParse(lines[1]) == null) {
      _reader = null;
      throw StateError('stty cannot set up /dev/tty: ${lines.join(' ')}'.trim());
    }
    _saved = lines[0];
    _readerPid = int.parse(lines[1]);
    void interrupt(ProcessSignal _) => KeysBridge.interrupted?.call();
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
    // Before the modes are restored, so it never reads a line meant for what runs next.
    if (_readerPid > 0) Process.killPid(_readerPid, ProcessSignal.sigkill);
    _reader?.stdin.close().ignore();
    _reader = null;
    _readerPid = -1;
    if (_saved case final saved?) {
      _saved = null;
      try {
        _stty([saved]);
      } catch (_) {} // best-effort: the tty may be gone already
    }
    try {
      _out?.closeSync();
    } catch (_) {} // best-effort: the tty may be gone already
    _out = null;
  }

  @override
  Future<void> suspend() async {
    Process.killPid(pid, ProcessSignal.sigtstp);
    // Stopped here until SIGCONT; the beat after covers a stop that lands a moment late.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  @override
  void write(String data) {
    try {
      _out?.writeFromSync(utf8.encode(data));
    } catch (_) {} // best-effort: the tty may be gone already
  }
}

/// The Windows console, using SetConsoleMode and raw VT sequences.
final class _WinConsole implements Terminal {
  static final _k32 = DynamicLibrary.open('kernel32.dll');
  static final _getStdHandle = _k32.lookupFunction<ffi.Pointer<Void> Function(Int32), ffi.Pointer<Void> Function(int)>(
    'GetStdHandle',
  );
  static final _getConsoleMode = _k32
      .lookupFunction<
        Int32 Function(ffi.Pointer<Void>, ffi.Pointer<Uint32>),
        int Function(ffi.Pointer<Void>, ffi.Pointer<Uint32>)
      >('GetConsoleMode');
  static final _setConsoleMode = _k32
      .lookupFunction<Int32 Function(ffi.Pointer<Void>, Uint32), int Function(ffi.Pointer<Void>, int)>(
        'SetConsoleMode',
      );
  static final _localAlloc = _k32
      .lookupFunction<ffi.Pointer<Void> Function(Uint32, IntPtr), ffi.Pointer<Void> Function(int, int)>('LocalAlloc');
  static final _localFree = _k32
      .lookupFunction<ffi.Pointer<Void> Function(ffi.Pointer<Void>), ffi.Pointer<Void> Function(ffi.Pointer<Void>)>(
        'LocalFree',
      );

  int _savedInMode = 0;
  int _savedErrMode = 0;
  bool _isOpen = false;
  Isolate? _readerIsolate;
  ReceivePort? _receivePort;
  StreamController<List<int>> _input = StreamController.broadcast();
  final StreamController<void> _resized = StreamController.broadcast();
  Timer? _resizeTimer;
  (int, int)? _lastDims;

  _WinConsole._();

  static _WinConsole? connect() {
    if (!Platform.isWindows) return null;
    final hIn = _getStdHandle(-10);
    final hErr = _getStdHandle(-12);
    if (hIn.address == 0 || hErr.address == 0) return null;
    final mode = _localAlloc(0x0040, 4).cast<Uint32>();
    try {
      if (_getConsoleMode(hIn, mode) == 0) return null;
      if (_getConsoleMode(hErr, mode) == 0) return null;
      return _WinConsole._();
    } catch (_) {
      // not a console
      return null;
    } finally {
      _localFree(mode.cast());
    }
  }

  (int, int) get _dims {
    final size = _Tty._terminalSize();
    if (size != null) return size;
    return (80, 24);
  }

  @override
  int get width => _dims.$1;

  @override
  int get height => _dims.$2;

  @override
  int get colors => TerminalBridge.depth();

  @override
  bool get unicode => TerminalBridge.unicode;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Stream<void> get resized => _resized.stream;

  @override
  Future<void> open() async {
    if (_isOpen) return;
    if (_input.isClosed) _input = StreamController.broadcast();
    final hIn = _getStdHandle(-10);
    final hErr = _getStdHandle(-12);
    final modeIn = _localAlloc(0x0040, 4).cast<Uint32>();
    final modeErr = _localAlloc(0x0040, 4).cast<Uint32>();
    try {
      if (_getConsoleMode(hIn, modeIn) != 0) {
        _savedInMode = modeIn.value;
        // ENABLE_VIRTUAL_TERMINAL_INPUT (0x0200) | ENABLE_WINDOW_INPUT (0x0008)
        // Disable ENABLE_PROCESSED_INPUT (0x0001) | ENABLE_LINE_INPUT (0x0002) | ENABLE_ECHO_INPUT (0x0004)
        final rawIn = (_savedInMode | 0x0200 | 0x0008) & ~(0x0001 | 0x0002 | 0x0004);
        _setConsoleMode(hIn, rawIn);
      }
      if (_getConsoleMode(hErr, modeErr) != 0) {
        _savedErrMode = modeErr.value;
        // ENABLE_PROCESSED_OUTPUT (0x0001) | ENABLE_WRAP_AT_EOL_OUTPUT (0x0002) | ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004)
        final rawErr = _savedErrMode | 0x0001 | 0x0002 | 0x0004;
        _setConsoleMode(hErr, rawErr);
      }
    } finally {
      _localFree(modeIn.cast());
      _localFree(modeErr.cast());
    }
    _isOpen = true;

    final port = _receivePort = ReceivePort();
    _readerIsolate = await Isolate.spawn(_readConsoleStdin, port.sendPort, debugName: 'WinConsole.reader');
    port.listen((message) {
      if (message is! List<int>) return;
      // ^C is the interrupt where something is in charge of it, and then not a key as well.
      final interrupt = KeysBridge.interrupted;
      final keys = interrupt != null && message.contains(3)
          ? [
              for (final b in message)
                if (b != 3) b,
            ]
          : message;
      if (!identical(keys, message)) interrupt!();
      if (keys.isNotEmpty && !_input.isClosed) _input.add(keys);
    });

    _lastDims = _dims;
    _resizeTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final current = _dims;
      if (current != _lastDims) {
        _lastDims = current;
        if (!_resized.isClosed) _resized.add(null);
      }
    });
  }

  @override
  void close() {
    _resizeTimer?.cancel();
    _resizeTimer = null;
    if (_readerIsolate != null) {
      _readerIsolate!.kill(priority: Isolate.immediate);
      _readerIsolate = null;
    }
    _receivePort?.close();
    _receivePort = null;
    if (_isOpen) {
      _isOpen = false;
      final hIn = _getStdHandle(-10);
      final hErr = _getStdHandle(-12);
      if (_savedInMode != 0) {
        _setConsoleMode(hIn, _savedInMode);
        _savedInMode = 0;
      }
      if (_savedErrMode != 0) {
        _setConsoleMode(hErr, _savedErrMode);
        _savedErrMode = 0;
      }
    }
  }

  /// The Windows console has no ^Z stop: an app never asks.
  @override
  Future<void> suspend() async {}

  @override
  void write(String data) {
    try {
      stderr.write(data);
    } catch (_) {} // best-effort console write
  }
}

void _readConsoleStdin(SendPort send) {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final getStdHandle = k32.lookupFunction<ffi.Pointer<Void> Function(Int32), ffi.Pointer<Void> Function(int)>(
    'GetStdHandle',
  );
  final readFile = k32
      .lookupFunction<
        Int32 Function(ffi.Pointer<Void>, ffi.Pointer<Uint8>, Uint32, ffi.Pointer<Uint32>, ffi.Pointer<Void>),
        int Function(ffi.Pointer<Void>, ffi.Pointer<Uint8>, int, ffi.Pointer<Uint32>, ffi.Pointer<Void>)
      >('ReadFile');
  final localAlloc = k32
      .lookupFunction<ffi.Pointer<Void> Function(Uint32, IntPtr), ffi.Pointer<Void> Function(int, int)>('LocalAlloc');
  final localFree = k32
      .lookupFunction<ffi.Pointer<Void> Function(ffi.Pointer<Void>), ffi.Pointer<Void> Function(ffi.Pointer<Void>)>(
        'LocalFree',
      );

  final hIn = getStdHandle(-10);
  final buf = localAlloc(0x0040, 1024).cast<Uint8>();
  final read = localAlloc(0x0040, 4).cast<Uint32>();
  try {
    while (true) {
      if (readFile(hIn, buf, 1024, read, nullptr) == 0) break;
      final count = read.value;
      if (count > 0) {
        send.send(Uint8List.fromList(buf.asTypedList(count)));
      }
    }
  } finally {
    localFree(buf.cast());
    localFree(read.cast());
  }
}

/// Bytes in, events out. Holds a partial sequence until the next chunk, or until [flush] — the
/// ESC timeout — says a lone ESC was the key.
final class _Decoder {
  final void Function(int row, int column)? _position;
  final void Function()? _kitty;
  final List<int> _pending = [];
  final List<int> _paste = [];
  bool _inPaste = false;

  _Decoder([this._position, this._kitty]);

  /// Whether a lone ESC (or a sequence it starts, cut off) waits on more bytes.
  bool get isWaiting => _pending.isNotEmpty && _pending.first == 0x1b && !_inPaste;

  List<TuiEvent<Never>> add(List<int> bytes) {
    _pending.addAll(bytes);
    final out = <TuiEvent<Never>>[];
    var i = 0;
    while (i < _pending.length) {
      final n = _inPaste ? _pasteStep(i, out) : _step(i, out);
      if (n == 0) break;
      i += n;
    }
    _pending.removeRange(0, i);
    return out;
  }

  /// What waits, read as typed: a lone ESC is Esc, a cut-off sequence is its bytes. Only an ESC
  /// times out: a character cut mid-way, or the end of a paste, waits for the rest.
  List<TuiEvent<Never>> flush() {
    if (_pending.isEmpty || _inPaste || _pending.first != 0x1b) return const [];
    final bytes = List.of(_pending);
    _pending.clear();
    if (bytes.length == 1) return const [KeyPress.esc];
    final rest = _Decoder().add(bytes.sublist(1));
    return [if (rest.isEmpty) KeyPress.esc, for (final e in rest) _alt(e)];
  }

  static TuiEvent<Never> _alt(TuiEvent<Never> e) => switch (e) {
    KeyPress(:final name, :final ctrl, :final shift) => KeyPress(name, ctrl: ctrl, alt: true, shift: shift),
    _ => e,
  };

  /// A printable key: its text, with Shift when that made it a capital.
  static KeyPress _text(String text, {bool alt = false}) => KeyPress(text, alt: alt, shift: text.toLowerCase() != text);

  int _pasteStep(int i, List<TuiEvent<Never>> out) {
    const end = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]; // ESC [ 2 0 1 ~
    final b = _pending[i];
    if (b == 0x1b) {
      for (var k = 0; k < end.length; k++) {
        if (i + k >= _pending.length) return 0;
        if (_pending[i + k] != end[k]) {
          _paste.add(b);
          return 1;
        }
      }
      _inPaste = false;
      out.add(Paste(utf8.decode(_paste, allowMalformed: true).replaceAll('\r\n', '\n').replaceAll('\r', '\n')));
      _paste.clear();
      return end.length;
    }
    _paste.add(b);
    return 1;
  }

  /// Decodes one event at [i]; returns the bytes it used, or 0 when it needs more.
  int _step(int i, List<TuiEvent<Never>> out) {
    final b = _pending[i];
    if (b == 0x1b) return _escape(i, out);
    if (b < 0x80) {
      out.add(_byte(b));
      return 1;
    }
    final len = b >= 0xf0 ? 4 : (b >= 0xe0 ? 3 : (b >= 0xc0 ? 2 : 1));
    // A byte that does not continue the character ends it, malformed; the end of a read waits.
    var n = 1;
    while (n < len && i + n < _pending.length && _pending[i + n] & 0xc0 == 0x80) {
      n++;
    }
    if (n < len && i + n == _pending.length) return 0;
    final text = utf8.decode(_pending.sublist(i, i + n), allowMalformed: true);
    // A combining mark or joiner belongs to the character before it.
    final last = out.lastOrNull;
    if (last is KeyPress && !last.ctrl && !KeyPress._isNamed(last.name) && IoBridge.runeWidth(text.runes.first) == 0) {
      out
        ..removeLast()
        ..add(KeyPress(last.name + text, alt: last.alt, shift: last.shift));
    } else {
      out.add(_text(text));
    }
    return n;
  }

  static TuiEvent<Never> _byte(int b) => switch (b) {
    0x0d || 0x0a => KeyPress.enter,
    0x09 => KeyPress.tab,
    0x7f || 0x08 => KeyPress.backspace,
    0x00 => const KeyPress(' ', ctrl: true),
    < 0x1b => KeyPress(String.fromCharCode(b + 0x60), ctrl: true),
    < 0x20 => KeyPress(String.fromCharCode(b + 0x40), ctrl: true),
    _ => _text(String.fromCharCode(b)),
  };

  /// The keys an SS3 (`ESC O x`) or CSI (`ESC [ … x`) sequence names by its final byte.
  static const _finals = {
    0x41: 'up', 0x42: 'down', 0x43: 'right', 0x44: 'left', 0x48: 'home', 0x46: 'end', //
    0x50: 'f1', 0x51: 'f2', 0x52: 'f3', 0x53: 'f4',
  };

  /// The keypad in application mode (`ESC O x`): Enter, its operators and its digits.
  static const _keypad = {
    0x4d: 'enter', 0x58: '=', 0x6a: '*', 0x6b: '+', 0x6c: ',', 0x6d: '-', 0x6e: '.', 0x6f: '/', //
    0x70: '0', 0x71: '1', 0x72: '2', 0x73: '3', 0x74: '4', 0x75: '5', 0x76: '6', 0x77: '7', 0x78: '8', 0x79: '9',
  };

  int _escape(int i, List<TuiEvent<Never>> out) {
    if (i + 1 >= _pending.length) return 0;
    final next = _pending[i + 1];
    if (next == 0x5b) return _csi(i, out);
    if (next == 0x4f) {
      // SS3: ESC O x
      if (i + 2 >= _pending.length) return 0;
      final last = _pending[i + 2];
      if (_finals[last] ?? _keypad[last] case final name?) out.add(KeyPress(name));
      return 3;
    }
    if (next == 0x1b) {
      out.add(KeyPress.esc);
      return 1;
    }
    // ESC then a key: Alt+key.
    final inner = <TuiEvent<Never>>[];
    final used = _step(i + 1, inner);
    if (used == 0) return 0;
    out.addAll(inner.map(_alt));
    return 1 + used;
  }

  int _csi(int i, List<TuiEvent<Never>> out) {
    var j = i + 2;
    if (j < _pending.length && _pending[j] == 0x3c) return _pointer(i, out);
    while (j < _pending.length && (_pending[j] < 0x40 || _pending[j] > 0x7e)) {
      j++;
    }
    if (j >= _pending.length) return 0;
    final raw = String.fromCharCodes(_pending.sublist(i + 2, j));
    final params = raw.split(';');
    final last = _pending[j];
    final used = j - i + 1;
    // Answers to queries: the kitty protocol's `?flags u`, a cursor position `row;col R`.
    if (raw.startsWith('?') && last == 0x75) {
      _kitty?.call();
      return used;
    }
    if (last == 0x52 && params.length == 2 && _position != null && (int.tryParse(params[0]) ?? 0) > 1) {
      _position(int.parse(params[0]), int.tryParse(params[1]) ?? 1);
      return used;
    }
    // Focus reports (`?1004h`): ESC [ I and ESC [ O.
    if (raw.isEmpty && (last == 0x49 || last == 0x4f)) {
      out.add(last == 0x49 ? const Focus() : const Blur());
      return used;
    }
    if (last == 0x75) {
      _kittyKey(params, out);
      return used;
    }
    final first = int.tryParse(params[0]) ?? 1;
    final mod = params.length > 1 ? (int.tryParse(params[1]) ?? 1) - 1 : 0;
    final (shift, alt, ctrl) = (mod & 1 != 0, mod & 2 != 0, mod & 4 != 0);
    final name = switch (last) {
      0x5a => 'tab', // ESC [ Z: Shift+Tab
      0x7e => switch (first) {
        1 || 7 => 'home',
        2 => 'insert',
        3 => 'delete',
        4 || 8 => 'end',
        5 => 'pageUp',
        6 => 'pageDown',
        11 || 12 || 13 || 14 || 15 => 'f${first - 10}',
        17 || 18 || 19 || 20 || 21 => 'f${first - 11}',
        23 || 24 => 'f${first - 12}',
        _ => null,
      },
      _ => _finals[last],
    };
    if (last == 0x7e && first == 200) {
      _inPaste = true;
      return used;
    }
    if (name != null) out.add(KeyPress(name, ctrl: ctrl, alt: alt, shift: shift || last == 0x5a));
    return used;
  }

  /// The kitty protocol's keypad codes, from KP_0 (57399) to KP_DELETE (57426), as the keys a
  /// legacy terminal sends for them.
  static const _kittyKeypad = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '/', '*', '-', '+', 'enter', '=', ',', //
    'left', 'right', 'up', 'down', 'pageUp', 'pageDown', 'home', 'end', 'insert', 'delete',
  ];

  /// A key in the kitty keyboard protocol, `ESC [ code ; mods u`, as a legacy terminal would send
  /// it: Ctrl+letter lowercase, Ctrl+H/I/M/[ as Backspace/Tab/Enter/Esc, the keypad as its keys.
  /// Private-use codes it has no legacy key for, and codes past Unicode, are dropped.
  void _kittyKey(List<String> params, List<TuiEvent<Never>> out) {
    final code = int.tryParse(params[0].split(':').first) ?? 0;
    final mod = params.length > 1 ? (int.tryParse(params[1].split(':').first) ?? 1) - 1 : 0;
    final (shift, alt, ctrl) = (mod & 1 != 0, mod & 2 != 0, mod & 4 != 0);
    if (code >= 57399 && code < 57399 + _kittyKeypad.length) {
      final key = _kittyKeypad[code - 57399];
      return out.add(KeyPress(key, ctrl: ctrl, alt: alt, shift: shift && KeyPress._isNamed(key)));
    }
    final named = switch (code) {
      13 => 'enter',
      9 => 'tab',
      127 || 8 => 'backspace',
      27 => 'esc',
      _ => null,
    };
    if (named != null) return out.add(KeyPress(named, ctrl: ctrl, alt: alt, shift: shift));
    // Below a space, past Unicode, a surrogate, or a private-use key it has no legacy one for.
    if (code < 0x20 || code > 0x10ffff || (code >= 0xd800 && code < 0xf900)) return;
    if (ctrl) {
      // What a legacy terminal cannot tell apart from Backspace, Tab, Enter and Esc.
      final legacy = switch (code | 0x20) {
        0x68 => 'backspace',
        0x69 => 'tab',
        0x6a || 0x6d => 'enter',
        _ => code == 0x5b ? 'esc' : null,
      };
      if (legacy != null) return out.add(KeyPress(legacy, alt: alt));
      return out.add(KeyPress(String.fromCharCode(code).toLowerCase(), ctrl: true, alt: alt));
    }
    final char = String.fromCharCode(code);
    out.add(_text(shift ? char.toUpperCase() : char, alt: alt));
  }

  /// SGR pointer reports: ESC [ < b ; x ; y (M | m).
  int _pointer(int i, List<TuiEvent<Never>> out) {
    var j = i + 3;
    while (j < _pending.length && _pending[j] != 0x4d && _pending[j] != 0x6d) {
      j++;
    }
    if (j >= _pending.length) return 0;
    final p = String.fromCharCodes(_pending.sublist(i + 3, j)).split(';').map(int.tryParse).toList();
    if (p.length == 3 && p.every((v) => v != null)) {
      final (b, x, y) = (p[0]!, p[1]! - 1, p[2]! - 1);
      final kind = b & 64 != 0
          ? (b & 1 == 0 ? PointerKind.wheelUp : PointerKind.wheelDown)
          : b & 32 != 0 && b & 3 == 3
          ? PointerKind.move
          : b & 32 != 0
          ? PointerKind.drag
          : _pending[j] == 0x6d
          ? PointerKind.release
          : PointerKind.press;
      out.add(Pointer(x, y, kind, button: b & 3, shift: b & 4 != 0, alt: b & 8 != 0, ctrl: b & 16 != 0));
    }
    return j - i + 1;
  }
}

// ---- the list model --------------------------------------------------------------------------

/// What a widget keeps of where a [Choice] was drawn, between frames. Not API.
final class ChoiceLayout {
  int offset = 0, page = 1;
  bool horizontal = false;

  /// Where each tab was drawn, and which shown item each row is: for clicks.
  List<(int, int)> tabs = const [];
  List<int> rows = const [];
}

/// A list of [items] to pick from, and where the picking stands: the cursor, the filter, the
/// checked items. `list.pick` and a `Menu`, `Grid` or `Tabs` all run on it.
///
/// Hold one per list; a widget is rebuilt each frame around it. With [filter], typed text
/// narrows the list; with [multi], Space checks the cursor's item. [label] names an item (by
/// default its `toString()`, an enum's `name`).
///
/// ```dart
/// final pick = Choice(files, label: (f) => f.name, filter: true);
/// … Menu(pick) …
/// KeyPress.enter when pick.value != null => Tui.quit(pick.value),
/// ```
///
/// {@category CLI}
final class Choice<T> with Focusable {
  final String Function(T item)? _label;
  final bool filter, multi;
  final Set<int> _checked;
  final _layout = ChoiceLayout();
  List<T> _items;
  String _query = '';

  /// The cursor's item, as an index into the full list; `-1` when the filter matches nothing.
  int index;

  /// The labels lowercased once a filter needs them, and the query [_shown] was filtered by.
  List<String>? _lowered;
  String? _filtered;
  List<int> _shown = const [];

  /// The widest label, and the list and length it was measured on.
  int _widest = 0, _widestCount = -1;
  List<T>? _widestOf;

  Choice(
    List<T> items, {
    String Function(T item)? label,
    this.filter = false,
    this.multi = false,
    this.index = 0,
    Iterable<int> checked = const [],
  }) : _items = items,
       _label = label,
       _checked = {...checked} {
    if (!multi && _checked.isNotEmpty) throw ArgumentError.value(checked, 'checked', 'Invalid checked: not multi');
    if (_checked.any((i) => i < 0 || i >= items.length)) {
      throw ArgumentError.value(checked, 'checked', 'Invalid checked: not an index of items');
    }
  }

  /// The list to pick from. Assigning another shows it, filtered as [query] says.
  List<T> get items => _items;

  set items(List<T> next) {
    _items = next;
    _lowered = _filtered = null;
    _checked.removeWhere((i) => i >= next.length);
  }

  /// Item [i]'s text.
  String label(int i) => _label?.call(_items[i]) ?? TerminalBridge.label(_items[i]);

  /// What has been typed into the filter.
  String get query => _query;

  set query(String value) {
    if (!filter) throw StateError('Cannot filter a Choice made without filter: true');
    _query = value;
  }

  /// The checked items' indexes.
  Set<int> get checked => UnmodifiableSetView(_checked);

  /// The cursor's item, or `null` when the filter matches nothing.
  T? get value => index >= 0 && index < _items.length ? _items[index] : null;

  /// The checked items, in list order.
  List<T> get picked => [for (final i in _checked.toList()..sort()) _items[i]];

  /// The items the filter leaves, as indexes into the full list.
  List<int> get shown {
    _settle();
    return _shown;
  }

  /// Where the filter matches item [i]'s label, as `[start, end)` ranges.
  List<(int, int)> matchesOf(int i) =>
      _query.isEmpty ? const [] : _match(label(i).toLowerCase(), _query.toLowerCase()) ?? const [];

  /// Checks or unchecks item [i] (by default the cursor's).
  void toggle([int? i]) {
    if (!multi) throw StateError('Cannot check an item of a Choice made without multi: true');
    final at = i ?? index;
    if (at < 0 || at >= _items.length) return;
    if (!_checked.remove(at)) _checked.add(at);
  }

  /// Moves the cursor [by] items among those shown.
  void move(int by) {
    _settle();
    if (_shown.isEmpty) return;
    index = _shown[(_position(index) + by).clamp(0, _shown.length - 1)];
  }

  /// Where [i] is in [_shown] (sorted, so a binary search), or -1.
  int _position(int i) {
    var (lo, hi) = (0, _shown.length - 1);
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final at = _shown[mid];
      if (at == i) return mid;
      if (at < i) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

  /// Settles the cursor and the filter on [items]: the labels are read once per list and
  /// filtered once per query.
  void _settle() {
    final q = _query.toLowerCase();
    final count = _items.length;
    if (q != _filtered || _shown.length > count) {
      final lowered = q.isEmpty ? null : _lowered ??= [for (var i = 0; i < count; i++) label(i).toLowerCase()];
      _shown = lowered == null
          ? List.generate(count, (i) => i)
          : [
              for (var i = 0; i < count; i++)
                if (KeysBridge.matches(lowered[i], q)) i,
            ];
      _filtered = q;
    }
    if (_shown.isEmpty) {
      index = -1;
    } else if (_position(index) < 0) {
      index = _shown.firstWhere((i) => i >= index, orElse: () => _shown.last);
    }
  }

  @override
  bool handle(TuiEvent<Object?> event) {
    final horizontal = _layout.horizontal;
    final (back, forward) = horizontal ? (KeyPress.left, KeyPress.right) : (KeyPress.up, KeyPress.down);
    switch (event) {
      case _ when event == back:
        move(-1);
      case _ when event == forward:
        move(1);
      case KeyPress.home when !horizontal:
        move(-_items.length);
      case KeyPress.end when !horizontal:
        move(_items.length);
      case KeyPress.pageUp when !horizontal:
        move(-_layout.page);
      case KeyPress.pageDown when !horizontal:
        move(_layout.page);
      case KeyPress(text: ' ') when multi && index >= 0:
        toggle();
      case KeyPress(:final text?) when filter:
        _query += text;
      case Paste(:final text) when filter:
        _query += text.replaceAll('\n', ' ');
      case KeyPress.backspace when filter && _query.isNotEmpty:
        _query = String.fromCharCodes(_query.runes.toList()..removeLast());
      default:
        return false;
    }
    _settle();
    return true;
  }

  @override
  void pointer(Pointer event, int x, int y) {
    switch (event.kind) {
      case PointerKind.wheelUp:
        move(-1);
      case PointerKind.wheelDown:
        move(1);
      case PointerKind.press when _layout.horizontal:
        for (final (i, (s, e)) in _layout.tabs.indexed) {
          if (x >= s && x < e) index = i;
        }
      case PointerKind.press:
        // The rows drawn last may outlive a filter that now matches nothing.
        final rows = _layout.rows;
        if (y < rows.length && rows[y] < _shown.length) index = _shown[rows[y]];
      default:
    }
  }
}

/// The filter's match in [label]: a substring, else a subsequence, as ranges; `null` for none.
List<(int, int)>? _match(String label, String query) {
  final ranges = <(int, int)>[];
  return _find(label, query, ranges) ? ranges : null;
}

/// Whether [query] is in [label], as a substring or else a subsequence, adding the matched
/// ranges to [ranges] when given.
bool _find(String label, String query, List<(int, int)>? ranges) {
  if (query.isEmpty) return true;
  final at = label.indexOf(query);
  if (at >= 0) {
    ranges?.add((at, at + query.length));
    return true;
  }
  final start = ranges?.length;
  var q = 0;
  for (var i = 0; i < label.length && q < query.length; i++) {
    if (label.codeUnitAt(i) != query.codeUnitAt(q)) continue;
    q++;
    if (ranges == null) continue;
    if (ranges.length > start! && ranges.last.$2 == i) {
      ranges.last = (ranges.last.$1, i + 1);
    } else {
      ranges.add((i, i + 1));
    }
  }
  if (q < query.length && ranges != null) ranges.length = start!;
  return q == query.length;
}
