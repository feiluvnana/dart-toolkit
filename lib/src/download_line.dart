/// A first-use download's progress (ffmpeg, 7-Zip, Chrome for Testing):
/// the Tui's status row while one runs, else a live line on a terminal,
/// else the one line it always printed. Light on purpose: the media and
/// archive modules load it at startup.
library;

import 'dart:io' as io;

import 'bridge.dart';
import 'format.dart';

final class DownloadLine {
  /// Start showing [what] (`ffmpeg-9.0.2.zip`).
  DownloadLine(String what) : _label = 'downloading $what' {
    final bridge = TuiBridge.current;
    if (bridge != null) {
      _bridge = bridge;
      _id = bridge.barStarted(
        () => (label: _label, done: _done, total: _total, unit: Unit.bytes, rate: _window.rate(), spinning: false),
      );
    } else if (!_live) {
      io.stderr.writeln('dart_toolkit: $_label (once per machine)');
    } else {
      _draw();
    }
  }

  static final _live = io.stderr.hasTerminal && io.Platform.environment['TERM'] != 'dumb';

  final String _label;
  TuiBridge? _bridge;
  Object? _id;
  var _done = 0;
  int? _total;
  final _window = Window();

  /// [done] of [total] bytes so far.
  void update(int done, int? total) {
    _window.add(done - _done);
    _done = done;
    _total = total;
    final bridge = _bridge;
    if (bridge != null) return bridge.barChanged(_id!);
    if (_live) _draw();
  }

  /// The download is over; the live line stays as its record.
  void end({required bool ok}) {
    final bridge = _bridge;
    if (bridge != null) return bridge.barEnded(_id!, ok);
    if (!_live) return;
    _draw();
    io.stderr.write(ok ? '\n' : ' ✗\n');
  }

  void _draw() => io.stderr.write('\r\x1b[K$_label  ${fmtCounts(_done, _total, Unit.bytes)}  ${fmtRate(_window.rate())}');
}
