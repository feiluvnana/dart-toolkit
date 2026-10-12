/// Long native calls as jobs on native threads (CONVENTIONS rule 52: heavy
/// work leaves the event loop).
///
/// A job queues native work with a `Done` listener, a stop byte and an id;
/// the future completes when the native thread calls back. Nothing that can
/// take more than ~1 ms runs on the event loop; short in-memory calls stay
/// synchronous. Package-internal: seams import it relatively, no topic
/// exports it (it carries `dart:ffi`, like the seams).
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'errors.dart';

/// A long call's end: the worker thread's job, taken and freed here.
typedef DoneFn = ffi.Void Function(ffi.Pointer<ffi.Void>);

/// Throttled progress: Dart's id, units done and total.
typedef ProgressFn = ffi.Void Function(ffi.Int64, ffi.Uint64, ffi.Uint64);

/// Queues one native long call: [start] copies its arguments, queues the work
/// with [done], [stop] and [id], and answers 0 once queued (negative when the
/// arguments are invalid). The native side copies every borrowed input before
/// returning, so Dart frees its buffers on return.
typedef StartJob =
    int Function(
      ffi.Pointer<ffi.NativeFunction<DoneFn>> done,
      ffi.Pointer<ffi.Uint8> stop,
      ffi.Pointer<ffi.NativeFunction<ProgressFn>> progress,
      int id,
    );

/// The per-library job surface: every long-call library binds its own
/// `tk_job_*` (heaps are shared, but each library keeps its own error slot,
/// so failures and `lastError` stay on the library that ran the work).
abstract interface class JobLibrary {
  /// The taken job's outcome code (a count, 0, or negative).
  int jobRc(ffi.Pointer<ffi.Void> job);

  /// The taken job's bytes into a `give` buffer; answers 0, or the failure
  /// code without touching [out].
  int jobTake(ffi.Pointer<ffi.Void> job, ffi.Pointer<ffi.Pointer<ffi.Uint8>> out, ffi.Pointer<ffi.IntPtr> len);

  /// The taken job's error message into [buf]; answers its full length.
  int jobError(ffi.Pointer<ffi.Void> job, ffi.Pointer<ffi.Uint8> buf, int cap);

  /// Releases a job taken by a `Done` callback.
  void jobFree(ffi.Pointer<ffi.Void> job);

  /// Releases a `give` buffer a [jobTake] handed out.
  void freeGiven(ffi.Pointer<ffi.Uint8> ptr, int len);

  /// [size] bytes of this library's memory (`tk_alloc`), released by [free].
  ffi.Pointer<ffi.Uint8> alloc(int size);

  /// Releases what [alloc] returned; [size] is what it was asked for.
  void free(ffi.Pointer<ffi.Uint8> ptr, int size);

  /// This library's last error, read synchronously after a failed `start`.
  String lastError();
}

/// One native long call in flight. The future completes with the outcome
/// bytes (or, for counts, an empty body — read the count off the job); a
/// failure completes with a `NativeException` holding the job's message.
///
/// [cancel] stops the work and fails the future with [error]: a timeout fails
/// with `TimeoutException`, closing the owning resource with
/// `StateError('closed')`. The late native outcome is taken and dropped. The
/// stop byte and any in-flight progress stay valid until the native side
/// reports back, so they are released there, never here.
final class NativeJob {
  final String _op;
  final JobLibrary _lib;
  final ffi.Pointer<ffi.Uint8> _stop;
  final Completer<Uint8List> _completer = Completer<Uint8List>();
  ffi.NativeCallable<DoneFn>? _done;
  ffi.NativeCallable<ProgressFn>? _progress;
  Timer? _timer;
  var _settled = false;

  /// The job's outcome code once it has completed: a count (files written, members
  /// listed …) or 0. Valid after [future] completes successfully.
  int rc = 0;

  NativeJob._(this._op, this._lib, this._stop);

  /// The outcome.
  Future<Uint8List> get future => _completer.future;

  /// Stops the work and fails the future with [error]. Idempotent.
  void cancel(Object error) {
    if (_settled) return;
    _settled = true;
    _stop.value = 1;
    _timer?.cancel();
    _completer.completeError(error);
  }

  /// Takes the taken job: completes the future (unless already cancelled),
  /// then releases everything the native side may still touch.
  void _onDone(ffi.Pointer<ffi.Void> job) {
    _timer?.cancel();
    Object? error;
    Uint8List? out;
    final rc = this.rc = _lib.jobRc(job);
    if (rc < 0) {
      error = _takeError(job);
    } else {
      final slots = _lib.alloc(16);
      final outPtr = slots.cast<ffi.Pointer<ffi.Uint8>>();
      final lenPtr = (slots + 8).cast<ffi.IntPtr>();
      try {
        if (_lib.jobTake(job, outPtr, lenPtr) < 0) {
          error = _takeError(job);
        } else {
          final len = lenPtr.value;
          out = Uint8List.fromList(outPtr.value.asTypedList(len));
          _lib.freeGiven(outPtr.value, len);
        }
      } finally {
        _lib.free(slots, 16);
      }
    }
    _lib.jobFree(job);
    _lib.free(_stop, 1);
    _done?.close();
    _done = null;
    _progress?.close();
    _progress = null;
    if (!_settled) {
      _settled = true;
      if (error != null) {
        _completer.completeError(error);
      } else {
        _completer.complete(out ?? Uint8List(0));
      }
    }
    // Else cancelled: the timeout or close already answered; the late
    // outcome is dropped after releasing everything above.
  }

  /// The taken job's error as the exception it means.
  Object _takeError(ffi.Pointer<ffi.Void> job) {
    const cap = 1024;
    final buf = _lib.alloc(cap);
    try {
      final n = _lib.jobError(job, buf, cap);
      final message = n <= 0 ? 'unknown error' : String.fromCharCodes(buf.asTypedList(n < cap ? n : cap));
      return NativeException(_op, message);
    } finally {
      _lib.free(buf, cap);
    }
  }
}

int _nextId = 0;

/// Queues one native long call for its [NativeJob] handle: owners fail it on
/// close, callers without an owner use [nativeJob] and await the future.
NativeJob startJob(
  String op,
  JobLibrary lib,
  StartJob start, {
  void Function(int done, int total)? onProgress,
  Duration? timeout,
}) {
  final stop = lib.alloc(1);
  stop.value = 0;
  final job = NativeJob._(op, lib, stop);
  job._done = ffi.NativeCallable<DoneFn>.listener(job._onDone);
  if (onProgress != null) {
    job._progress = ffi.NativeCallable<ProgressFn>.listener((int id, int done, int total) => onProgress(done, total));
  }
  final progress = job._progress?.nativeFunction ?? ffi.Pointer<ffi.NativeFunction<ProgressFn>>.fromAddress(0);
  try {
    final rc = start(job._done!.nativeFunction, stop, progress, _nextId++);
    if (rc < 0) throw NativeException(op, lib.lastError());
  } catch (_) {
    // Never queued: nothing will call back, so release everything here.
    job._done?.close();
    job._done = null;
    job._progress?.close();
    job._progress = null;
    lib.free(stop, 1);
    rethrow;
  }
  if (timeout != null) {
    job._timer = Timer(timeout, () => job.cancel(TimeoutException('Native $op timed out after $timeout', timeout)));
  }
  return job;
}

/// Runs a native long call: [start] queues it with the listener's pointer and
/// a stop byte; the future completes when the native thread calls back.
///
/// [lib] is the subsystem that runs it: each library keeps its own error
/// slot, so [lib] tells whose `lastError` a refused queue reads (rule 43).
/// A timeout sets the stop byte and completes with `TimeoutException` (the
/// late outcome is dropped). Long calls without an owning resource use this;
/// owners keep the [NativeJob] from [startJob] and cancel it on close.
Future<Uint8List> nativeJob(
  String op,
  JobLibrary lib,
  StartJob start, {
  void Function(int done, int total)? onProgress,
  Duration? timeout,
}) => startJob(op, lib, start, onProgress: onProgress, timeout: timeout).future;

/// Runs a native long call that answers a count (its outcome code), not bytes.
Future<int> nativeCount(
  String op,
  JobLibrary lib,
  StartJob start, {
  void Function(int done, int total)? onProgress,
  Duration? timeout,
}) {
  final job = startJob(op, lib, start, onProgress: onProgress, timeout: timeout);
  return job.future.then((_) => job.rc);
}
