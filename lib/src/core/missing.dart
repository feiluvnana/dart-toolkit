part of '../core.dart';

/// A reading found nothing: a key, a column, a selector, an entry, a tool, a frame.
/// `Missing <what> [in <where>]`.
///
/// It is the package's one signal that a value is absent, and the only error a reading's `or:`,
/// `orNull` and `or` answer for. It is an [Exception], not an [Error]: absence is expected.
///
/// ```dart
/// final title = (() => a.attr('title')).orNull;   // null: the attribute is not there
/// final port  = Env.get<int>('PORT', or: 8080);   // a mistyped PORT still throws
/// ```
///
/// {@category Utilities}
final class MissingException implements Exception {
  /// What was not there.
  final String what;

  /// Where it was looked for, when that says more than [what].
  final String? where;

  const MissingException(this.what, {this.where});

  /// `Missing <what> [in <where>]`.
  String get message => where == null ? 'Missing $what' : 'Missing $what in $where';

  @override
  String toString() => message;
}

/// Several items of a `Batch` failed: [failures], each a [Failed] with its item and error, and
/// [values], every success in input order. `<n> of <m> failed: <first error>`.
///
/// {@category Utilities}
final class BatchException<I, T> implements Exception {
  final List<Failed<I, T>> failures;
  final List<T> values;

  /// Items in all.
  final int count;

  const BatchException(this.failures, this.values, this.count);

  @override
  String toString() =>
      '${failures.length} of $count failed: ${failures.isEmpty ? '' : '${failures.first}'}'.trimRight();
}
