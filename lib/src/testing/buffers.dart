import 'dart:typed_data';

import '../core/traits.dart';

/// In-memory bytes as a [Source]: every reader streams them anew from its `from`
/// offset, so readings (`text`, `json` …) and `pipe` work on it in tests.
final class BufferReader implements Source, Reader {
  final Uint8List _bytes;
  int _pos = 0;

  BufferReader(this._bytes);

  @override
  int? get lengthHint => _bytes.length;

  /// A fresh reader over the bytes from [from] (this reader is unaffected).
  @override
  Future<Reader> reader({int from = 0}) async => BufferReader(Uint8List.sublistView(_bytes, from))._at(0);

  BufferReader _at(int pos) => this.._pos = pos;

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

/// An in-memory [Target] collecting everything written into it. A `resume` writer appends
/// to what it holds; an aborted write leaves what it held before.
///
/// Copies every chunk: [SourceReadings.pipe] reuses its buffer between writes.
final class BufferWriter implements Target, Writer {
  BytesBuilder _builder = BytesBuilder(copy: true);
  BytesBuilder? _pending;

  @override
  Future<int> size() async => _builder.length;

  /// A writer into this buffer: it replaces the contents on close, or appends with
  /// [resume]; an abort keeps the old contents.
  @override
  Future<Writer> writer({bool resume = false}) async {
    final pending = BytesBuilder(copy: true);
    if (resume) pending.add(_builder.toBytes());
    _pending = pending;
    return this;
  }

  @override
  Future<int> write(Uint8List data) async {
    (_pending ?? _builder).add(Uint8List.fromList(data));
    return data.length;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (_pending case final pending?) {
      _builder = pending;
      _pending = null;
    }
  }

  @override
  Future<void> abort() async {
    _pending = null;
  }

  /// Everything written so far.
  Uint8List take() => _builder.takeBytes();
}
