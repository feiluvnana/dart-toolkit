import 'dart:convert';
import 'dart:typed_data';

import 'traits.dart';

Future<int> _pipe(Reader src, Writer dst, {int buf = 64 * 1024, void Function(int bytes)? onProgress}) async {
  final chunk = Uint8List(buf);
  var total = 0;
  while (true) {
    final n = await src.read(chunk);
    if (n <= 0) break;
    await dst.write(Uint8List.sublistView(chunk, 0, n));
    total += n;
    onProgress?.call(total);
  }
  await dst.flush();
  return total;
}

/// Universally connects any [Reader] to any [Writer], returning the number of bytes moved.
Future<int> pipe(Reader src, Writer dst, {int buf = 64 * 1024, void Function(int bytes)? onProgress}) =>
    _pipe(src, dst, buf: buf, onProgress: onProgress);

/// `src.pipe(dst)`.
extension ReaderPipe on Reader {
  Future<int> pipe(Writer dst, {int buf = 64 * 1024, void Function(int bytes)? onProgress}) =>
      _pipe(this, dst, buf: buf, onProgress: onProgress);
}

/// A byte buffer pipes as one write.
extension BytesPipe on Uint8List {
  Future<int> pipe(Writer dst, {int buf = 64 * 1024, void Function(int bytes)? onProgress}) async {
    await dst.write(this);
    await dst.flush();
    onProgress?.call(length);
    return length;
  }
}

/// The body of an awaitable byte source pipes once it arrives.
extension AwaitableBytesPipe on Future<Uint8List> {
  Future<int> pipe(Writer dst, {int buf = 64 * 1024, void Function(int bytes)? onProgress}) async =>
      (await this).pipe(dst, buf: buf, onProgress: onProgress);
}

/// An in-memory readable buffer.
final class BufferReader implements Reader, Closer {
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
final class BufferWriter implements Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  @override
  Future<int> write(Object data) async {
    final bytes = data is List<int>
        ? data
        : data is String
        ? utf8.encode(data)
        : utf8.encode(data.toString());
    _builder.add(bytes);
    return bytes.length;
  }

  @override
  Future<void> flush() async {}

  /// Everything written so far.
  Uint8List take() => _builder.takeBytes();
}
