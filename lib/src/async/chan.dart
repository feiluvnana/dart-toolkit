import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

/// A Rust-style Multi-Producer, Single-Consumer channel with an optional bounded buffer.
///
/// A [cap] above zero suspends a producer once that many items are queued until the consumer
/// reads ([send]); [trySend] never waits. The consumer reads a [Stream] from [recv], or one
/// item at a time with [next]/[tryRecv]. [close] signals EOF so `await for` ends cleanly.
///
/// ```dart
/// final chan = Chan<int>(cap: 100);
/// await chan.send(1);
/// await for (final v in chan.recv()) { print(v); }
/// ```
///
/// Fan-in from worker isolates: hand [sendPort] to another isolate and send
/// from there with [Chan.sendTo]; the consumer buffers in its own isolate, so
/// [cap] still bounds memory at the consumer.
///
/// ```dart
/// final chan = Chan<int>(cap: 100);
/// await Isolate.spawn(producer, chan.sendPort);
/// await for (final v in chan.recv()) { print(v); }
/// ```
final class Chan<T> {
  /// Capacity of the bounded buffer; `0` means every [send] waits for a reader.
  final int cap;

  final Queue<T> _queue = Queue<T>();
  final Queue<Completer<void>> _sendWaiters = Queue<Completer<void>>();
  final Queue<Completer<T?>> _recvWaiters = Queue<Completer<T?>>();
  bool _closed = false;

  ReceivePort? _remote;
  StreamSubscription<dynamic>? _remoteSub;
  final Queue<({T value, SendPort? ack})> _remotePending = Queue();

  Chan({this.cap = 0});

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Whether nothing is buffered right now.
  bool get isEmpty => _queue.isEmpty && _remotePending.isEmpty;

  /// How many items are buffered right now.
  int get len => _queue.length + _remotePending.length;

  /// Sends [val], suspending when the buffer is full until a reader makes room.
  Future<void> send(T val) async {
    if (_closed) throw StateError('Cannot send to closed channel');
    if (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(val);
      return;
    }
    if (cap > 0 && _queue.length >= cap) {
      final waiter = Completer<void>();
      _sendWaiters.add(waiter);
      await waiter.future;
      if (_closed) throw StateError('Cannot send to closed channel');
    }
    _queue.add(val);
    _pump();
  }

  /// Sends [val] without waiting. Answers `false` when the buffer is full or the channel closed.
  bool trySend(T val) {
    if (_closed) return false;
    if (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(val);
      return true;
    }
    if (cap > 0 && _queue.length >= cap) return false;
    _queue.add(val);
    _pump();
    return true;
  }

  /// Takes the next buffered item, or `null` when none is waiting.
  T? tryRecv() {
    if (_queue.isEmpty) return null;
    final item = _queue.removeFirst();
    _admitRemote();
    if (_sendWaiters.isNotEmpty) _sendWaiters.removeFirst().complete();
    return item;
  }

  /// Waits for the next item, or `null` once the channel is closed and drained.
  Future<T?> next() async {
    if (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      _admitRemote();
      if (_sendWaiters.isNotEmpty) _sendWaiters.removeFirst().complete();
      return item;
    }
    if (_closed) return null;
    final waiter = Completer<T?>();
    _recvWaiters.add(waiter);
    return waiter.future;
  }

  /// A stream of the channel's items, completing when it is closed and drained.
  Stream<T> recv() async* {
    while (true) {
      final val = await next();
      if (val == null) {
        if (_closed && _queue.isEmpty) break;
      } else {
        yield val;
      }
    }
  }

  /// Closes the channel: no more sends, queued items can still be read.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    while (_sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().completeError(StateError('Channel closed'));
    }
    while (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(null);
    }
    // Refuse and release remote senders waiting for room.
    for (final pending in _remotePending) {
      pending.ack?.send(false);
    }
    _remotePending.clear();
    await _remoteSub?.cancel();
    _remote?.close();
    _remote = null;
  }

  /// A [SendPort] other isolates send into with [sendTo].
  ///
  /// The port is created on first use and lives until [close]. Buffering
  /// happens here, on the consumer's isolate, so [cap] bounds memory at the
  /// consumer.
  SendPort get sendPort {
    final existing = _remote;
    if (existing != null) return existing.sendPort;
    final port = ReceivePort();
    _remote = port;
    _remoteSub = port.listen(_onRemote);
    return port.sendPort;
  }

  /// Sends [val] into the channel owned by another isolate through its
  /// [sendPort], waiting for room when the channel is bounded.
  ///
  /// Answers `false` when the channel is closed or full ([trySend] semantics
  /// when [wait] is false). With [wait] (the default) it suspends until a
  /// reader makes room, like [send].
  static Future<bool> sendTo<T>(SendPort sendPort, T val, {bool wait = true}) async {
    if (!wait) {
      final ack = ReceivePort();
      sendPort.send([val, ack.sendPort, false]);
      final ok = await ack.first as bool;
      ack.close();
      return ok;
    }
    final ack = ReceivePort();
    sendPort.send([val, ack.sendPort, true]);
    final ok = await ack.first as bool;
    ack.close();
    if (!ok) throw StateError('Cannot send to closed channel');
    return true;
  }

  void _onRemote(Object? msg) {
    final list = (msg as List).cast<Object?>();
    final value = list[0] as T;
    final ack = list[1] as SendPort?;
    if (_closed) {
      ack?.send(false);
      return;
    }
    if (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(value);
      ack?.send(true);
      return;
    }
    if (cap > 0 && _queue.length >= cap) {
      // No room: park it until the consumer takes. A non-waiting sender is
      // refused at once instead.
      final waiting = list.length > 2 && list[2] == true;
      if (!waiting) {
        ack?.send(false);
        return;
      }
      _remotePending.add((value: value, ack: ack));
      return;
    }
    _queue.add(value);
    ack?.send(true);
    _pump();
  }

  void _admitRemote() {
    while (_remotePending.isNotEmpty && (cap <= 0 || _queue.length < cap)) {
      final pending = _remotePending.removeFirst();
      _queue.add(pending.value);
      pending.ack?.send(true);
    }
    _pump();
  }

  /// Hands a buffered item to a waiting reader, if any.
  void _pump() {
    while (_queue.isNotEmpty && _recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(_queue.removeFirst());
      _admitRemote();
    }
  }
}
