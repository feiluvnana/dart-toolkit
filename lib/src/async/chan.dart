import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

/// A multi-producer, single-consumer channel with a bounded buffer.
///
/// [cap] suspends a producer once that many items are queued until the
/// consumer reads ([send]). The consumer reads a [Stream] from [recv].
/// [close] signals EOF so `await for` ends cleanly.
///
/// ```dart
/// final chan = Chan<int>(10);
/// await chan.send(1);
/// await chan.close();
/// ```
///
/// Fan-in from worker isolates: hand [port] to another isolate and send
/// from there with [Chan.post]; the consumer buffers in its own isolate, so
/// [cap] still bounds memory at the consumer.
///
/// ```dart
/// final chan = Chan<int>(10);
/// await Isolate.spawn(producer, chan.port);
/// await for (final v in chan.recv()) { print(v); }
/// ```
/// The closed-channel marker handed to waiting readers: a private sentinel, so
/// a `null` item and a closed channel never look alike.
const _done = _Closed();

final class _Closed {
  const _Closed();
}

final class Chan<T> {
  /// Capacity of the bounded buffer.
  final int cap;

  final Queue<T> _queue = Queue<T>();
  final Queue<Completer<void>> _sendWaiters = Queue<Completer<void>>();
  final Queue<Completer<Object?>> _recvWaiters = Queue<Completer<Object?>>();
  bool _closed = false;

  ReceivePort? _remote;
  // Held, never cancelled: the listener answers late posts with `false` after
  // close, so the port (and its subscription) outlives the channel.
  // ignore: unused_field
  StreamSubscription<dynamic>? _remoteSub;
  final Queue<({T value, SendPort? ack})> _remotePending = Queue();

  Chan(this.cap) {
    if (cap < 1) throw ArgumentError.value(cap, 'cap', 'Must be at least 1');
  }

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

  /// A stream of the channel's items, completing when it is closed and drained.
  ///
  /// Cancelling the subscription removes its waiter, so a cancelled `recv`
  /// neither hangs nor swallows the next [send].
  Stream<T> recv() {
    late final StreamController<T> controller;
    Completer<Object?>? waiter;
    Future<Object?> take() {
      if (_queue.isNotEmpty) {
        final item = _queue.removeFirst();
        _admitRemote();
        if (_sendWaiters.isNotEmpty) _sendWaiters.removeFirst().complete();
        return Future.value(item);
      }
      if (_closed) return Future.value(_done);
      final w = Completer<Object?>();
      waiter = w;
      _recvWaiters.add(w);
      return w.future.whenComplete(() {
        if (identical(waiter, w)) waiter = null;
      });
    }

    controller = StreamController<T>(
      onListen: () {
        () async {
          try {
            while (true) {
              final val = await take();
              if (identical(val, _done)) break;
              controller.add(val as T);
            }
          } catch (e, st) {
            controller.addError(e, st);
          }
          await controller.close();
        }();
      },
      onCancel: () {
        final w = waiter;
        waiter = null;
        if (w != null && !w.isCompleted) {
          // No longer listening: leave the queue for the next reader.
          _recvWaiters.remove(w);
          w.complete(_done);
        }
      },
    );
    return controller.stream;
  }

  /// Closes the channel: no more sends, queued items can still be read.
  /// Blocked senders fail; waiting readers drain, then end. The remote port
  /// stays open so a late [post] still gets its `false` instead of hanging.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    while (_sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().completeError(StateError('Channel closed'));
    }
    while (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(_done);
    }
    // Refuse and release remote senders waiting for room.
    for (final pending in _remotePending) {
      pending.ack?.send(false);
    }
    _remotePending.clear();
  }

  /// A [SendPort] other isolates send into with [post].
  ///
  /// The port is created on first use and lives until [close]. Buffering
  /// happens here, on the consumer's isolate, so [cap] bounds memory at the
  /// consumer.
  SendPort get port {
    final existing = _remote;
    if (existing != null) return existing.sendPort;
    final port = ReceivePort();
    _remote = port;
    _remoteSub = port.listen(_onRemote);
    return port.sendPort;
  }

  /// Sends [val] into the channel owned by another isolate through its
  /// [port], waiting for room when the channel is bounded.
  ///
  /// Answers `false` when the channel is closed or full ([post] with
  /// [wait] false). With [wait] (the default) it suspends until a reader
  /// makes room, like [send].
  static Future<bool> post<T>(SendPort port, T val, {bool wait = true}) async {
    final ack = ReceivePort();
    port.send([val, ack.sendPort, wait]);
    final ok = await ack.first as bool;
    ack.close();
    if (!ok && wait) throw StateError('Cannot send to closed channel');
    return ok;
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
