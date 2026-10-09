// The one state model: every Task, Batch and Job reports `Status`, every display reads it.

part of '../core.dart';

/// What one [item] on its way to a value [T] is doing now: [Waiting], [Running], [Paused],
/// [Done], [Skipped], [Failed] or [Stopped], with [Warned] notes in between.
///
/// ```dart
/// switch (status) {
///   case Running(:final received, :final total): print('$received of $total');
///   case Done(:final value, fresh: false):         print('already had $value');
///   case Done(:final value):                       print('got $value');
///   case Skipped(:final reason) || Stopped(:final reason): print(reason);
///   case Failed(:final error):                     print('failed: $error');
///   case Warned(warning: RetryWarning(:final attempt)): print('retry $attempt');
///   case Waiting() || Paused():
/// }
/// ```
///
/// {@category Utilities}
sealed class Status<I, T> {
  /// What the work is about: a URL, a file, an input of `parallelize`.
  final I item;

  final String? _label;

  const Status(this.item, {String? label}) : _label = label;

  /// The item as a row names it, set by whoever made the status (a file's `folder/name`, a URL's
  /// host and path), else `'$item'`.
  String get label => _label ?? '$item';

  /// Whether this is how the work ended: [Done], [Skipped], [Failed] or [Stopped].
  bool get isFinal => switch (this) {
    Done() || Skipped() || Failed() || Stopped() => true,
    _ => false,
  };

  /// This status about another [item], keeping what it says.
  Status<J, T> _about<J>(J item, String? label) => switch (this) {
    Waiting() => Waiting(item, label: label),
    Running(:final received, :final total, :final unit, :final step) => Running(
      item,
      label: label,
      received: received,
      total: total,
      unit: unit,
      step: step,
    ),
    Paused() => Paused(item, label: label),
    Done(:final value, :final fresh) => Done(item, value, fresh: fresh, label: label),
    Skipped(:final reason) => Skipped(item, reason, label: label),
    Failed(:final error, :final stackTrace) => Failed(item, error, stackTrace, label: label),
    Stopped(:final reason) => Stopped(item, reason, label: label),
    Warned(:final warning) => Warned(item, warning, label: label),
  };
}

/// What the amounts of a [Running] count.
///
/// {@category Utilities}
enum Unit { bytes, items, none }

/// Queued, not started.
///
/// {@category Utilities}
final class Waiting<I, T> extends Status<I, T> {
  const Waiting(super.item, {super.label});

  @override
  String toString() => 'Waiting($label)';
}

/// Under way: [received] of [total] (`null` while unknown) in [unit], on [step] (a short
/// phrase: `'verifying'`, `'retry 1/3'`) when there is one.
///
/// Amounts only: how fast and how long are for whoever draws it to work out.
///
/// {@category Utilities}
final class Running<I, T> extends Status<I, T> {
  final int received;
  final int? total;
  final Unit unit;
  final String? step;

  const Running(super.item, {super.label, this.received = 0, this.total, this.unit = Unit.bytes, this.step});

  /// From 0.0 to 1.0, or `null` while [total] is unknown.
  double? get ratio => switch (total) {
    final all? when all > 0 => (received / all).clamp(0.0, 1.0),
    _ => null,
  };

  @override
  String toString() => 'Running($label, $received/${total ?? '?'}${step == null ? '' : ', $step'})';
}

/// Stopped by hand, and able to resume: only a `Job` pauses.
///
/// {@category Utilities}
final class Paused<I, T> extends Status<I, T> {
  const Paused(super.item, {super.label});

  @override
  String toString() => 'Paused($label)';
}

/// Finished with its [value]. [fresh] is `false` when nothing had to be done: the file was
/// already there, the server said "not modified".
///
/// {@category Utilities}
final class Done<I, T> extends Status<I, T> {
  final T value;
  final bool fresh;

  const Done(super.item, this.value, {super.label, this.fresh = true});

  @override
  String toString() => 'Done($label, $value${fresh ? '' : ', already'})';
}

/// Deliberately not done, for [reason], and there is no value: a page outside the crawl, a rule
/// in robots.txt.
///
/// {@category Utilities}
final class Skipped<I, T> extends Status<I, T> {
  final String reason;

  const Skipped(super.item, this.reason, {super.label});

  @override
  String toString() => 'Skipped($label, $reason)';
}

/// Could not be done: [error], a typed exception a `switch` can reach
/// (`Failed(error: StatusException(:final response))`), thrown at [stackTrace].
///
/// {@category Utilities}
final class Failed<I, T> extends Status<I, T> {
  final Object error;
  final StackTrace stackTrace;

  const Failed(super.item, this.error, this.stackTrace, {super.label});

  /// `label: error`, the error on one line: the line a display prints for it.
  @override
  String toString() => '$label: ${'$error'.trim().replaceAll(_breaks, ' ')}';
}

/// Cancelled, removed, or ended with its scope, for [reason]. Never a failure.
///
/// {@category Utilities}
final class Stopped<I, T> extends Status<I, T> {
  final String reason;

  const Stopped(super.item, this.reason, {super.label});

  /// The reason of work stopped to be resumed later: a paused `Job`. What it made so far is kept.
  static const paused = 'paused';

  /// The reason of work stopped for good: a removed `Job`. What it made so far goes too.
  static const removed = 'removed';

  @override
  String toString() => 'Stopped($label, $reason)';
}

/// A note about the item, not a state: the item stays in its last state. A display prints it
/// once, above what it draws.
///
/// {@category Utilities}
final class Warned<I, T> extends Status<I, T> {
  final Warning warning;

  const Warned(super.item, this.warning, {super.label});

  /// `label: warning`: the line a display prints for it.
  @override
  String toString() => '$label: $warning';
}

/// What a [Warned] says: a [RetryWarning] or a [NoteWarning].
///
/// {@category Utilities}
sealed class Warning {
  const Warning();
}

/// The [attempt]th try of [of] failed with [cause]; the next starts after [wait].
///
/// {@category Utilities}
final class RetryWarning extends Warning {
  final int attempt;
  final int of;
  final Duration wait;
  final Object cause;

  const RetryWarning(this.attempt, this.of, this.wait, this.cause);

  @override
  String toString() => 'retry $attempt/$of in ${wait.humanized}: ${'$cause'.trim().replaceAll(_breaks, ' ')}';
}

/// Anything else worth a line: a dropped link, a cleanup that threw.
///
/// {@category Utilities}
final class NoteWarning extends Warning {
  final String text;

  const NoteWarning(this.text);

  @override
  String toString() => text;
}

/// A line break and the space around it, which one-line text makes one space.
final _breaks = RegExp(r'\s*\n\s*');

/// Not API: what producers in other libraries need from [Status].
abstract final class StatusInternals {
  /// [status] about [item] instead, labelled [label] (its own label when `null`).
  static Status<J, T> about<J, T>(Status<Object?, T> status, J item, [String? label]) =>
      status._about(item, label ?? status._label);
}
