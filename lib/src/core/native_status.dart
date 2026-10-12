/// Where the three native seams report, so [Native] checks them without
/// importing them (importing a seam compiles its FFI).
///
/// A seam registers on first use; [Native.ok] covers the seams used so far —
/// true when none failed (and when none was touched yet).
library;

/// What one native seam says about its library.
final class NativeCheck {
  /// Whether the library loads right now.
  final bool Function() loads;

  /// Why it does not load, or `null` when it does.
  final String? Function() reason;

  /// Forgets the cached open so the next call looks again (tests only).
  final void Function() reset;

  const NativeCheck(this.loads, this.reason, this.reset);
}

abstract final class NativeStatus {
  static final Map<String, NativeCheck> _checks = {};

  /// Registers [name]'s check (first registration wins).
  static void register(String name, NativeCheck check) => _checks.putIfAbsent(name, () => check);

  /// Every registered check, in registration order.
  static Iterable<MapEntry<String, NativeCheck>> get checks => _checks.entries;
}

/// Test seams for the native libraries.
abstract final class NativeReset {
  /// Forgets every cached native open so the next call looks again.
  static void all() {
    for (final check in NativeStatus.checks) {
      check.value.reset();
    }
  }
}
