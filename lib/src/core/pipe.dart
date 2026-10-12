import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'decoding.dart';
import 'traits.dart';

const _chunk = 256 * 1024;

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
    final codec = textCodecs[this];
    return codec == null ? utf8.decode(data) : codec.decode(data);
  }

  /// The text, line by line. UTF-8 bodies stream through `utf8.decoder` (a
  /// legacy charset decodes whole first); cancelling the subscription stops
  /// the source — a `break` after line 1 reads no further.
  Stream<String> lines() {
    final self = this;
    late final StreamController<List<int>> controller;
    Reader? reader;
    var stopped = false;
    var paused = false;
    Completer<void>? resumed;
    controller = StreamController<List<int>>(
      onListen: () async {
        try {
          reader = await self.reader();
          final chunk = Uint8List(_chunk);
          // The charset is known once the reader is open (a request is sent by now): a
          // legacy one decodes the whole body first, then streams its lines.
          final codec = textCodecs[self];
          if (codec != null && !codec.streamsUtf8()) {
            final all = BytesBuilder(copy: false);
            while (!stopped) {
              final n = await reader!.read(chunk);
              if (n <= 0) break;
              all.add(Uint8List.fromList(Uint8List.sublistView(chunk, 0, n)));
            }
            if (!stopped) controller.add(utf8.encode(codec.decode(all.takeBytes())));
            await reader?.close();
            await controller.close();
            return;
          }
          while (!stopped) {
            while (paused) {
              resumed ??= Completer<void>();
              await resumed!.future;
            }
            final n = await reader!.read(chunk);
            if (n <= 0) break;
            controller.add(Uint8List.fromList(Uint8List.sublistView(chunk, 0, n)));
          }
          await reader?.close();
        } catch (e, st) {
          controller.addError(e, st);
        }
        await controller.close();
      },
      onPause: () {
        paused = true;
      },
      onResume: () {
        paused = false;
        resumed?.complete();
        resumed = null;
      },
      onCancel: () {
        stopped = true;
        paused = false;
        resumed?.complete();
        resumed = null;
        final r = reader;
        if (r != null) {
          // Release without awaiting: a process reader's close waits for exit.
          unawaited(() async {
            try {
              await r.close();
            } catch (_) {
              // Cancelling never throws: the reader's outcome is moot.
            }
          }());
        }
      },
    );
    return controller.stream.transform(utf8.decoder).transform(const LineSplitter());
  }

  /// Copies every byte into [dst] and answers how many. With [resume], it continues from
  /// what [dst] already holds (`Range` for HTTP, a seek for a file). [onProgress] hears the
  /// running total; it is a display aid, not a status source.
  ///
  /// A failed pipe leaves the target as it was: the writer is aborted, never
  /// closed. Both ends are opened inside the `try`, so a writer that throws on
  /// open still closes the reader.
  Future<int> pipe(Target dst, {bool resume = false, void Function(int bytes)? onProgress}) async {
    final from = resume ? await dst.size() : 0;
    final r = await reader(from: from);
    Writer w;
    try {
      w = await dst.writer(resume: resume);
    } catch (_) {
      await r.close();
      rethrow;
    }
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
    } catch (_) {
      try {
        await r.close();
      } catch (_) {
        // The reader's error is the one that matters; closing never hides it.
      }
      try {
        await w.abort();
      } catch (_) {
        // Abort never hides the write failure.
      }
      rethrow;
    }
    try {
      await r.close();
      await w.close();
    } catch (_) {
      try {
        await w.abort();
      } catch (_) {
        // Abort never hides the close failure.
      }
      rethrow;
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
    } catch (_) {
      try {
        await w.abort();
      } catch (_) {
        // Abort never hides the write failure.
      }
      rethrow;
    }
    try {
      await w.close();
    } catch (_) {
      try {
        await w.abort();
      } catch (_) {
        // Abort never hides the close failure.
      }
      rethrow;
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
