import 'dart:async';

import 'package:rxdart/rxdart.dart';

/// Clean stream operator extensions powered by RxDart.
///
/// {@category Concurrency}
extension ToolkitStreamExtensions<T> on Stream<T> {
  /// Batches stream items into lists of [size] elements (mirrors `Iterable.chunk`).
  Stream<List<T>> chunk(int size) => bufferCount(size);

  /// Batches stream items collected within each time window of [duration].
  Stream<List<T>> buffer(Duration duration) => bufferTime(duration);

  /// Emits an item from this stream only after [duration] has passed with no new events.
  Stream<T> debounce(Duration duration) => debounceTime(duration);

  /// Emits at most one item per [duration] window.
  Stream<T> throttle(Duration duration, {bool leading = true, bool trailing = false}) =>
      throttleTime(duration, leading: leading, trailing: trailing);

  /// Shifts the emission of all items on this stream forward by [duration].
  Stream<T> delay(Duration duration) => DelayStreamTransformer<T>(duration).bind(this);

  /// Maps each item to a new stream and flattens them concurrently.
  Stream<R> flatmap<R>(Stream<R> Function(T item) mapper) => flatMap(mapper);
}

/// Nullability filter extensions on streams of nullable items.
///
/// {@category Concurrency}
extension ToolkitNullableStreamExtensions<T extends Object> on Stream<T?> {
  /// Filters out all null values, returning a non-nullable `Stream<T>`.
  Stream<T> notnull() => whereNotNull();
}
