part of '../native.dart';

/// What a long native call hears progress through: `completed` of `total` entries, `bytes` of
/// `bytesTotal`, now on `name` (UTF-8, `nameLen` bytes; null for none).
typedef NativeProgressFn =
    Void Function(Uint64 completed, Uint64 total, Uint64 bytes, Uint64 bytesTotal, Pointer<Uint8> name, IntPtr nameLen);

/// A long native call's progress callback, or `nullptr` for none.
typedef NativeProgress = Pointer<NativeFunction<NativeProgressFn>>;

/// One progress report of a long native call, as [NativeProgressFn] gave it.
typedef NativeReport = ({int completed, int total, int bytes, int bytesTotal, String name});

/// How often a worker's reports cross to the caller at most: more would only be drawn over.
const _reportEvery = Duration(milliseconds: 40);

/// Long native calls, run off the caller's isolate.
extension NativeWork on NativeHandle {
  /// [call] on a worker isolate, handed a progress callback (`nullptr` without [onProgress])
  /// and a stop byte it passes to the library. A cancel of the work around the caller sets the
  /// byte, and the library stops at its next read: the call then throws a [CancelledException]
  /// rather than what the library said, and nothing is killed mid-call.
  ///
  /// [call] runs on the worker, so it captures only plain values (paths, numbers). The work
  /// waits for the worker before its cleanups run (a cleanup deferred before this call runs
  /// after the worker is gone), so a cleanup never races the library.
  Future<R> run<R>(
    Work work,
    R Function(NativeProgress progress, Pointer<Uint8> stop) call, {
    void Function(NativeReport report)? onProgress,
  }) async {
    final token = Cancel.token;
    if (token != null && token.isCancelled) throw CancelledException.of(token);
    final stop = alloc(1)..value = 0;
    var stopped = false;
    final unlisten = token?.onCancel(() {
      stopped = true;
      stop.value = 1;
    });
    final reports = onProgress == null ? null : ReceivePort();
    reports?.listen((message) {
      final (completed, total, bytes, bytesTotal, name) = message as (int, int, int, int, String);
      onProgress!((completed: completed, total: total, bytes: bytes, bytesTotal: bytesTotal, name: name));
    });
    final running = _spawn(name, _path!, reports?.sendPort, stop.address, call);
    final done = running.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      unlisten?.call();
      reports?.close();
      free(stop, 1);
    });
    work.defer(() => done);
    try {
      return await running;
    } catch (_) {
      if (stopped) throw CancelledException.of(token!);
      rethrow;
    }
  }
}

/// [call] on a new isolate, which opens library [name] at [path] as this one did.
Future<R> _spawn<R>(
  String name,
  String path,
  SendPort? port,
  int stop,
  R Function(NativeProgress progress, Pointer<Uint8> stop) call,
) => Isolate.run(() {
  (name == 'native' ? NativeBridge.main : NativeBridge.torrent)._adopt(path);
  return _onWorker(port, stop, call);
});

/// [call] with a callback that sends each report to [port], at most every [_reportEvery], and
/// the stop byte at [stop].
R _onWorker<R>(SendPort? port, int stop, R Function(NativeProgress progress, Pointer<Uint8> stop) call) {
  var last = -_reportEvery.inMicroseconds;
  final callable = port == null
      ? null
      : NativeCallable<NativeProgressFn>.isolateLocal((
          int completed,
          int total,
          int bytes,
          int bytesTotal,
          Pointer<Uint8> name,
          int nameLen,
        ) {
          final now = Clock.current.elapsed.inMicroseconds;
          if (now - last < _reportEvery.inMicroseconds && !(total > 0 && completed >= total)) return;
          last = now;
          final text = name == nullptr || nameLen == 0
              ? ''
              : utf8.decode(name.asTypedList(nameLen), allowMalformed: true);
          port.send((completed, total, bytes, bytesTotal, text));
        });
  try {
    return call(callable?.nativeFunction ?? nullptr, Pointer.fromAddress(stop));
  } finally {
    callable?.close();
  }
}
