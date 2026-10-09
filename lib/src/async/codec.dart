part of '../async.dart';

// How jobs cross a process boundary: items and values by the worker's serializers, statuses
// as JSON, and failures as the types they were.

/// A worker's items and values as JSON: by its [Worker.item] and [Worker.value] serializers, or
/// as they are when it has none, which a round trip checks.
final class _Codec<I, T> {
  final Serializer<I>? _item;
  final Serializer<T>? _value;

  _Codec(Worker<I, T> worker) : _item = worker.item, _value = worker.value;

  Object? item(I item) => _encode(item, _item, 'item');

  /// [item] as JSON, unchecked: for one [item] has checked already.
  Object? json(I item) => _item == null ? item : _item.encode(item);

  I itemOf(Object? json) => _item == null ? json as I : _item.decode(json);

  Object? value(T value) => _encode(value, _value, 'value');

  /// [value] as JSON, unchecked: for one [value] has checked already.
  Object? valueJson(T value) => _value == null ? value : _value.encode(value);

  T valueOf(Object? json) => _value == null ? json as T : _value.decode(json);

  /// [x] as JSON, checked by a round trip so a bad serializer fails here, at once: an
  /// [ArgumentError] naming [what].
  static Object? _encode<X>(X x, Serializer<X>? serializer, String what) {
    final Object? json;
    final X back;
    try {
      json = jsonDecode(jsonEncode(serializer == null ? x : serializer.encode(x)));
      back = serializer == null ? json as X : serializer.decode(json);
    } catch (e) {
      throw ArgumentError.value(
        x,
        what,
        'Invalid $what: it does not make the round trip to JSON ($e); give the worker a Serializer<$X> `$what`',
      );
    }
    if (back != x) {
      throw ArgumentError.value(
        x,
        what,
        'Invalid $what: it comes back from JSON as $back; give the worker a Serializer<$X> `$what` and value equality',
      );
    }
    return json;
  }

  Map<String, Object?> status(Status<I, T> status) => switch (status) {
    Waiting() => const {'kind': 'waiting'},
    Running(:final received, :final total, :final unit, :final step) => {
      'kind': 'running',
      'received': received,
      'total': ?total,
      'unit': unit.name,
      'step': ?step,
    },
    Paused() => const {'kind': 'paused'},
    // Checked once, as the job finished: kept and sent as often as it is, it is not again.
    Done(:final value, :final fresh) => {'kind': 'done', 'value': valueJson(value), 'fresh': fresh},
    Skipped(:final reason) => {'kind': 'skipped', 'reason': reason},
    Failed(:final error, :final stackTrace) => {
      'kind': 'failed',
      'error': IsolateBridge.errorJson(error),
      'trace': '$stackTrace',
    },
    Stopped(:final reason) => {'kind': 'stopped', 'reason': reason},
    Warned(:final warning) => {'kind': 'warned', 'warning': _warningJson(warning)},
  };

  Status<I, T> statusOf(I item, Object? json) {
    final map = json is Map ? json : const <Object?, Object?>{};
    return switch (map['kind']) {
      'running' => Running(
        item,
        received: (map['received'] as num?)?.toInt() ?? 0,
        total: (map['total'] as num?)?.toInt(),
        unit: Unit.values.asNameMap()[map['unit']] ?? Unit.bytes,
        step: map['step'] as String?,
      ),
      'paused' => Paused(item),
      'done' => Done(item, valueOf(map['value']), fresh: map['fresh'] != false),
      'skipped' => Skipped(item, '${map['reason']}'),
      'failed' => Failed(item, IsolateBridge.errorOf(map['error']), StackTrace.fromString('${map['trace'] ?? ''}')),
      'stopped' => Stopped(item, '${map['reason']}'),
      'warned' => Warned(item, _warningOf(map['warning'])),
      _ => Waiting(item),
    };
  }
}

Map<String, Object?> _warningJson(Warning warning) => switch (warning) {
  RetryWarning(:final attempt, :final of, :final wait, :final cause) => {
    'retry': attempt,
    'of': of,
    'wait': wait.inMicroseconds,
    'cause': IsolateBridge.errorJson(cause),
  },
  NoteWarning(:final text) => {'note': text},
};

Warning _warningOf(Object? json) => switch (json) {
  {'retry': final int attempt, 'of': final int of, 'wait': final int wait} => RetryWarning(
    attempt,
    of,
    Duration(microseconds: wait),
    IsolateBridge.errorOf(json['cause']),
  ),
  {'note': final String text} => NoteWarning(text),
  _ => NoteWarning('$json'),
};
