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
///
/// [onProgress] is a display convenience only (a bytes-so-far tap for indicators):
/// it is never a status source and producers report through the `Work`/`Status`
/// model instead.
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

/// The body of an awaitable [Reader] pipes once it arrives, so
/// `Http.get(url).pipe(File('huge.iso'))` streams without buffering.
extension AwaitableReaderPipe<T extends Reader> on Future<T> {
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
///
/// Copies every chunk: [pipe] reuses its buffer between writes.
final class BufferWriter implements Writer {
  final BytesBuilder _builder = BytesBuilder(copy: true);

  @override
  Future<int> write(Object data) async {
    final List<int> bytes;
    if (data is String) {
      bytes = utf8.encode(data);
    } else if (data is List<int>) {
      bytes = data;
    } else {
      throw ArgumentError.value(data, 'data', 'Must be String, List<int> or Uint8List');
    }
    _builder.add(bytes);
    return bytes.length;
  }

  @override
  Future<void> flush() async {}

  /// Everything written so far.
  Uint8List take() => _builder.takeBytes();
}

/// Adapts a read callback as a [Reader], the seam native handles plug into.
///
/// The callback fills [buf] and answers how many bytes were written (`0` = end),
/// mirroring [Reader.read]. Used to wrap FFI `read_fn` callbacks without
/// leaking them across the module boundary.
final class FnReader implements Reader {
  final Future<int> Function(Uint8List buf) _read;

  FnReader(this._read);

  @override
  Future<int> read(Uint8List buf) => _read(buf);
}

/// Adapts a write callback as a [Writer], the seam native sinks plug into.
///
/// The callback handles one chunk per call and answers the bytes accepted,
/// mirroring [Writer.write] (a `String` is UTF-8, bytes verbatim).
final class FnWriter implements Writer {
  final Future<int> Function(Object data) _write;

  FnWriter(this._write);

  @override
  Future<int> write(Object data) => _write(data);

  @override
  Future<void> flush() async {}
}
