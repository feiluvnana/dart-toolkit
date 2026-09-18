// The seam between something that makes progress and something that renders it.
//
// Both interfaces live here, in the one module every other module already depends
// on, so a producer (`http`) and a renderer (`cli`) can meet without an edge
// between them.
//
// {@category Utilities}

part of '../../util.dart';

/// One unit of work inside a batch, as a renderer needs to see it.
///
/// {@category Utilities}
abstract interface class TaskProgress {
  /// Stable identity, so repeated updates land in the same slot.
  String get taskId;

  /// What to show for this task.
  String get label;

  /// Completion from 0.0 to 1.0, or `null` when the size is unknown.
  double? get ratio;

  /// Units processed so far, or `null` when not measured.
  int? get received;

  /// Units expected, or `null` when unknown.
  int? get total;

  /// Whether this task has finished, however it finished.
  bool get isDone;

  /// A terminal label such as `done`, `skipped` or `failed`, or `null` while running.
  String? get status;
}

/// A batch of [TaskProgress] units.
///
/// {@category Utilities}
abstract interface class BatchProgress {
  /// Units finished so far.
  int get completed;

  /// Units in the batch, or `null` while the source is still producing them.
  int? get total;

  /// The update that triggered this event.
  TaskProgress get current;
}
