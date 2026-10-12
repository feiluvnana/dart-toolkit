import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'decoding.dart';
import 'traits.dart';

const _chunk = 64 * 1024;

/// The readings every [Source] has. Other modules add `json`, `html`, `image`, `hash` and
/// `unpack` in their own files, so an import costs only what it uses (rule 50).
extension SourceReadings on Source {
  /// Every byte.
  Future<Uint8List> bytes() async {
    final r = await reader();
    final out = BytesBuilder(copy: false);
    final chunk = Uint8List(_chunk);
    try {
      while (true) {
        final n = await r.read(chunk);
        if (n <= 0) break;
        out.add(Uint8List.fromList(Uint8List.sublistView(chunk, 0, n)));
      }
    } finally {
      await r.close();
    }
    return out.takeBytes();
  }

  /// Every byte as text: UTF-8 (malformed bytes are a FormatException), or the charset an
  /// HTTP response declares.
  Future<String> text() async {
    final data = await bytes();
    return switch (this) {
      final Decoding source => source.decode(data),
      _ => utf8.decode(data),
    };
  }

  /// The text, line by line, streamed (a response in a legacy charset is decoded whole first).
  Stream<String> lines() async* {
    if (this is Decoding) {
      yield* Stream.fromIterable(const LineSplitter().convert(await text()));
      return;
    }
    final r = await reader();
    final chunk = Uint8List(_chunk);
    final controller = StreamController<List<int>>();
    // decode incrementally: feed chunks through utf8 + LineSplitter
    final out = controller.stream.transform(utf8.decoder).transform(const LineSplitter());
    () async {
      try {
        while (true) {
          final n = await r.read(chunk);
          if (n <= 0) break;
          controller.add(Uint8List.fromList(Uint8List.sublistView(chunk, 0, n)));
        }
        await r.close();
      } catch (e, s) {
        controller.addError(e, s);
      } finally {
        await controller.close();
      }
    }();
    yield* out;
  }

  /// Copies every byte into [dst] and answers how many. With [resume], it continues from
  /// what [dst] already holds (`Range` for HTTP, a seek for a file). [onProgress] hears the
  /// running total; it is a display aid, not a status source.
  Future<int> pipe(Target dst, {bool resume = false, void Function(int bytes)? onProgress}) async {
    final from = resume ? await dst.size() : 0;
    final r = await reader(from: from);
    final w = await dst.writer(resume: resume);
    var total = 0;
    final chunk = Uint8List(_chunk);
    try {
      while (true) {
        final n = await r.read(chunk);
        if (n <= 0) break;
        await w.write(Uint8List.sublistView(chunk, 0, n));
        total += n;
        onProgress?.call(from + total);
      }
      await w.flush();
    } finally {
      await r.close();
      await w.close();
    }
    return total;
  }
}

/// Bytes in hand pipe like any source (a screenshot, an encoded image).
extension BytesPipe on Uint8List {
  Future<int> pipe(Target dst, {void Function(int bytes)? onProgress}) async {
    final w = await dst.writer();
    try {
      await w.write(this);
      await w.flush();
    } finally {
      await w.close();
    }
    onProgress?.call(length);
    return length;
  }
}

/// `page.screenshot().pipe(File('s.png'))` without an extra await.
extension FutureBytesPipe on Future<Uint8List> {
  Future<int> pipe(Target dst, {void Function(int bytes)? onProgress}) async =>
      (await this).pipe(dst, onProgress: onProgress);
}
