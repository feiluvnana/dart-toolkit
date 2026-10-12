import 'dart:typed_data';

import '../core/traits.dart';

/// An in-memory readable buffer.
final class BufferReader implements Reader {
  final Uint8List _bytes;
  int _pos = 0;

  BufferReader(this._bytes);

  @override
  Future<int> read(Uint8List buf) async {
    if (_pos >= _bytes.length) return 0;
    final available = _bytes.length - _pos;
    final n = buf.length < available ? buf.length : available;
    buf.setRange(0, n, _bytes, _pos);
    _pos += n;
    return n;
  }

  @override
  Future<void> close() async {}
}

/// An in-memory sink collecting everything written into it.
///
/// Copies every chunk: [SourceReadings.pipe] reuses its buffer between writes.
final class BufferWriter implements Writer {
  final BytesBuilder _builder = BytesBuilder(copy: true);

  @override
  Future<int> write(Uint8List data) async {
    _builder.add(data);
    return data.length;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  /// Everything written so far.
  Uint8List take() => _builder.takeBytes();
}
