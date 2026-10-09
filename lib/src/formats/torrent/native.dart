part of '../../../torrent.dart';

typedef _Session = Pointer<Void>;
typedef _Done = Void Function(Int64 code, Pointer<Uint8> data, IntPtr len);
typedef _DoneFn = Pointer<NativeFunction<_Done>>;
typedef _Json = Int32 Function(_Session, Uint64, Pointer<Pointer<Uint8>>, Pointer<IntPtr>);
typedef _JsonFn = int Function(_Session, int, Pointer<Pointer<Uint8>>, Pointer<IntPtr>);

/// The engine's calls (`dart_toolkit_torrent`) and the piece hashing (`dart_toolkit_native`).
/// Each isolate binds its own.
final class _TorrentNative {
  static final lib = NativeBridge.torrent.require();

  static final freeSessionPtr = lib.lookup<NativeFunction<Void Function(_Session)>>('tk_torrent_session_free');
  static final freeSession = freeSessionPtr.asFunction<void Function(_Session)>();
  static final finalizer = NativeFinalizer(freeSessionPtr.cast());

  static final sessionNew = lib
      .lookupFunction<_Session Function(Pointer<Uint8>, IntPtr), _Session Function(Pointer<Uint8>, int)>(
        'tk_torrent_session_new',
      );
  static final port = lib.lookupFunction<Int32 Function(_Session), int Function(_Session)>('tk_torrent_port');
  static final list = lib
      .lookupFunction<
        Int32 Function(_Session, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(_Session, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_torrent_list');
  static final add = lib
      .lookupFunction<
        Int64 Function(_Session, Pointer<Uint8>, IntPtr, Uint32, Pointer<Uint8>, IntPtr, _DoneFn),
        int Function(_Session, Pointer<Uint8>, int, int, Pointer<Uint8>, int, _DoneFn)
      >('tk_torrent_add');
  static final info = lib.lookupFunction<_Json, _JsonFn>('tk_torrent_info');
  static final metainfo = lib.lookupFunction<_Json, _JsonFn>('tk_torrent_metainfo');
  static final stats = lib.lookupFunction<_Json, _JsonFn>('tk_torrent_stats');
  static final wait = lib
      .lookupFunction<Int64 Function(_Session, Uint64, _DoneFn), int Function(_Session, int, _DoneFn)>(
        'tk_torrent_wait',
      );
  static final control = lib.lookupFunction<Int32 Function(_Session, Uint64, Uint32), int Function(_Session, int, int)>(
    'tk_torrent_control',
  );
  static final select = lib
      .lookupFunction<
        Int32 Function(_Session, Uint64, Pointer<Uint8>, IntPtr),
        int Function(_Session, int, Pointer<Uint8>, int)
      >('tk_torrent_select');
  static final limits = lib.lookupFunction<Int32 Function(_Session, Uint32, Uint32), int Function(_Session, int, int)>(
    'tk_torrent_limits',
  );
  static final streamOpen = lib
      .lookupFunction<Pointer<Void> Function(_Session, Uint64, Uint64), Pointer<Void> Function(_Session, int, int)>(
        'tk_torrent_stream_open',
      );
  static final streamRead = lib
      .lookupFunction<
        Int64 Function(Pointer<Void>, IntPtr, _DoneFn, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(Pointer<Void>, int, _DoneFn, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_torrent_stream_read');
  static final streamSeek = lib.lookupFunction<Int32 Function(Pointer<Void>, Uint64), int Function(Pointer<Void>, int)>(
    'tk_torrent_stream_seek',
  );
  static final streamFree = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'tk_torrent_stream_free',
  );
  static final cancel = lib.lookupFunction<Int32 Function(Uint64), int Function(int)>('tk_torrent_cancel');
  static final free = lib.lookupFunction<Void Function(Pointer<Uint8>, IntPtr), void Function(Pointer<Uint8>, int)>(
    'tk_free',
  );

  static final hash = NativeBridge.main
      .require()
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr, Uint64, Uint64, Uint64, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(Pointer<Uint8>, int, int, int, int, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_torrent_hash');
  static final verify = NativeBridge.main
      .require()
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr, Uint64, Pointer<Uint8>, IntPtr, Uint64, Uint64, Pointer<Uint8>),
        int Function(Pointer<Uint8>, int, int, Pointer<Uint8>, int, int, int, Pointer<Uint8>)
      >('tk_torrent_verify');

  /// What [body] returns, as JSON.
  static Object? json(String op, int Function(Pointer<Pointer<Uint8>> out, Pointer<IntPtr> len) body) =>
      jsonDecode(utf8.decode(NativeBridge.torrent.take(op, body)));

  /// [run] with [value] as JSON in native memory.
  static R withJson<R>(Object? value, R Function(Pointer<Uint8> p, int n) run) =>
      NativeBridge.torrent.withBytes(utf8.encode(jsonEncode(value)), run);

  /// A call that answers through a callback: [start] gets the callback and returns a ticket.
  /// Completes with the code and the bytes, or the engine's failure as [_engine] maps it; a
  /// cancelled [token] stops it with a [CancelledException].
  static Future<(int, Uint8List)> call(String op, CancelToken? token, int Function(_DoneFn done) start) {
    token?.check();
    final result = Completer<(int, Uint8List)>();
    void Function()? unlink;
    late final NativeCallable<_Done> callback;
    callback = NativeCallable<_Done>.listener((int code, Pointer<Uint8> data, int len) {
      final bytes = Uint8List.fromList(data.asTypedList(len));
      free(data, len);
      callback.close();
      unlink?.call();
      if (result.isCompleted) return;
      if (code < 0) {
        result.completeError(_engine(op, utf8.decode(bytes, allowMalformed: true)));
      } else {
        result.complete((code, bytes));
      }
    });
    final ticket = start(callback.nativeFunction);
    if (ticket < 0) {
      callback.close();
      throw _engine(op, NativeBridge.torrent.lastError());
    }
    if (token != null) {
      unlink = token.onCancel(() {
        // 0: the result is already on its way, and the callback settles the future.
        if (cancel(ticket) == 1) {
          callback.close();
          result.completeError(CancelledException.of(token));
        }
      });
    }
    return result.future;
  }
}

/// What the engine said about [op], as the exception it means: a system error is a
/// [SocketException] when it is about listening and a [FileSystemException] (about [path])
/// otherwise; a torrent it cannot read a [FormatException]; anything else a [NativeException].
Exception _engine(String op, String message, {String? path}) {
  final os = RegExp(r'\(os error (\d+)\)').firstMatch(message);
  if (os != null) {
    final error = OSError(message.substring(0, os.start).trim(), int.parse(os[1]!));
    if (RegExp('bind|listen|address', caseSensitive: false).hasMatch(message)) {
      return SocketException('Cannot $op', osError: error);
    }
    if (path != null && (error.errorCode == 2 || error.errorCode == 3)) {
      return PathNotFoundException(path, error, 'Cannot $op');
    }
    return FileSystemException('Cannot $op', path, error);
  }
  if (RegExp(r'bencode|deserializ|torrent file|info dict|parsing', caseSensitive: false).hasMatch(message)) {
    return FormatException('Invalid torrent: $message');
  }
  return NativeException(op, message);
}
