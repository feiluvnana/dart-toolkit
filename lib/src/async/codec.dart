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

  I itemOf(Object? json) => _item == null ? json as I : _item.decode(json);

  Object? value(T value) => _encode(value, _value, 'value');

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
    Done(:final value, :final fresh) => {'kind': 'done', 'value': this.value(value), 'fresh': fresh},
    Skipped(:final reason) => {'kind': 'skipped', 'reason': reason},
    Failed(:final error, :final stackTrace) => {'kind': 'failed', 'error': _errorJson(error), 'trace': '$stackTrace'},
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
      'failed' => Failed(item, _errorOf(map['error']), StackTrace.fromString('${map['trace'] ?? ''}')),
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
    'cause': _errorJson(cause),
  },
  NoteWarning(:final text) => {'note': text},
};

Warning _warningOf(Object? json) => switch (json) {
  {'retry': final int attempt, 'of': final int of, 'wait': final int wait} => RetryWarning(
    attempt,
    of,
    Duration(microseconds: wait),
    _errorOf(json['cause']),
  ),
  {'note': final String text} => NoteWarning(text),
  _ => NoteWarning('$json'),
};

/// [error] as JSON: its type and what rebuilds it. Every type of the error table that `core`
/// and `dart:io` know comes back as itself; a subtype comes back as the type it extends (a
/// `StatusException` as an `HttpException`, a `PasswordException` as a `FormatException`).
Map<String, Object?> _errorJson(Object error) {
  // `is` tests, not one switch of object patterns: that switch alone cost the import 80 ms.
  Map<String, Object?>? os(OSError? os) => os == null ? null : {'message': os.message, 'code': os.errorCode};
  if (error is CancelledException) return {'type': 'cancelled', 'reason': error.reason};
  if (error is MissingException) return {'type': 'missing', 'what': error.what, 'where': ?error.where};
  if (error is TimeoutException) {
    return {'type': 'timeout', 'message': ?error.message, 'duration': ?error.duration?.inMicroseconds};
  }
  if (error is FileSystemException) {
    final type = error is PathNotFoundException
        ? 'path-not-found'
        : error is PathExistsException
        ? 'path-exists'
        : error is PathAccessException
        ? 'path-access'
        : 'file-system';
    return {'type': type, 'message': error.message, 'path': ?error.path, 'os': ?os(error.osError)};
  }
  if (error is ProcessException) {
    return {
      'type': 'process',
      'executable': error.executable,
      'arguments': error.arguments,
      'message': error.message,
      'code': error.errorCode,
    };
  }
  if (error is SocketException) {
    return {'type': 'socket', 'message': error.message, 'port': ?error.port, 'os': ?os(error.osError)};
  }
  if (error is HttpException) return {'type': 'http', 'message': error.message, 'uri': ?error.uri?.toString()};
  if (error is FormatException) {
    final source = error.source;
    return {
      'type': 'format',
      'message': error.message,
      'offset': ?error.offset,
      if (source is String && source.length <= 4096) 'source': source,
    };
  }
  if (error is ArgumentError) return {'type': 'argument', 'message': ?error.message?.toString(), 'name': ?error.name};
  if (error is StateError) return {'type': 'state', 'message': error.message};
  if (error is UnsupportedError) return {'type': 'unsupported', 'message': ?error.message};
  if (error is Error) return {'type': 'error', 'text': '$error', 'trace': '${error.stackTrace ?? ''}'};
  return {'type': 'exception', 'text': '$error'};
}

/// What [_errorJson] wrote, as the error it was.
Object _errorOf(Object? json) {
  final map = json is Map ? json : <Object?, Object?>{'type': 'exception', 'text': '$json'};
  OSError? os() => switch (map['os']) {
    {'message': final String message, 'code': final int code} => OSError(message, code),
    _ => null,
  };
  final message = '${map['message'] ?? ''}';
  final path = map['path'] as String?;
  return switch (map['type']) {
    'cancelled' => CancelledException('${map['reason']}'),
    'missing' => MissingException('${map['what']}', where: map['where'] as String?),
    'timeout' => _CarriedTimeout(
      map['message'] as String?,
      map['duration'] == null ? null : Duration(microseconds: (map['duration'] as num).toInt()),
    ),
    'path-not-found' => PathNotFoundException(path ?? '', os() ?? const OSError(), message),
    'path-exists' => PathExistsException(path ?? '', os() ?? const OSError(), message),
    'path-access' => PathAccessException(path ?? '', os() ?? const OSError(), message),
    'file-system' => FileSystemException(message, path, os()),
    'process' => ProcessException(
      '${map['executable']}',
      [for (final a in map['arguments'] as List? ?? const []) '$a'],
      message,
      (map['code'] as num?)?.toInt() ?? 0,
    ),
    'socket' => SocketException(message, osError: os(), port: (map['port'] as num?)?.toInt()),
    'http' => HttpException(message, uri: map['uri'] == null ? null : Uri.parse('${map['uri']}')),
    'format' => FormatException(message, map['source'], (map['offset'] as num?)?.toInt()),
    'argument' => ArgumentError(map['message'], map['name'] as String?),
    'state' => StateError(message),
    'unsupported' => UnsupportedError(message),
    'error' => RemoteError('${map['text']}', '${map['trace'] ?? ''}'),
    _ => _Carried('${map['text']}'),
  };
}

/// An exception of a type this library cannot rebuild (another module's), carried as its text.
final class _Carried implements Exception {
  final String text;

  const _Carried(this.text);

  @override
  String toString() => text;
}

/// A [TimeoutException] carried across: it reads as the library's own do, `TimeoutException: <message>`.
final class _CarriedTimeout extends TimeoutException {
  _CarriedTimeout(super.message, [super.duration]);

  @override
  String toString() => message == null ? super.toString() : 'TimeoutException: $message';
}
